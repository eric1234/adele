part of 'git_change_set_source.dart';

const _maximumReviewMetadataBytes = 16 * 1024 * 1024;

/// Git-specific review semantics. The caller supplies identities, never patches,
/// repository paths, content, or Git arguments.
final class GitReviewApprovalService implements ReviewApprovalService {
  GitReviewApprovalService({
    required this.provider,
    required this.authorizedRead,
    required this.authorizedReview,
    this.limits = const GitChangeSetLimits(),
    Map<String, String>? parentEnvironment,
    GitProcessStarter? startGit,
  }) : _startGit = startGit ?? Process.start,
       _parentEnvironment = Map.unmodifiable(
         parentEnvironment ?? Platform.environment,
       ) {
    // Keep the same provider-owned upper bounds as inspection.
    GitChangeSetSourceService(
      provider: provider,
      authorizedRead: authorizedRead,
      limits: limits,
      parentEnvironment: _parentEnvironment,
    );
  }

  final GitWorktreeEnvironmentProvider provider;
  final AuthorizedEnvironmentReadService authorizedRead;
  final AuthorizedEnvironmentReviewService authorizedReview;
  final GitChangeSetLimits limits;
  final Map<String, String> _parentEnvironment;
  final GitProcessStarter _startGit;

  @override
  Future<ReviewApprovalResult> approve(ReviewSelection selection) =>
      provider.runReview(() => _change(selection, reverse: false));

  @override
  Future<ReviewApprovalResult> unapprove(ReviewSelection selection) =>
      provider.runReview(() => _change(selection, reverse: true));

  Future<ReviewApprovalResult> _change(
    ReviewSelection selection, {
    required bool reverse,
  }) async {
    if (!_validSelection(selection)) return _reviewResult('ineligible');
    final operation = _SnapshotOperation(limits, _parentEnvironment, _startGit);
    final deadline = Timer(limits.operationTimeout, operation.expire);
    File? lock;
    RandomAccessFile? lockHandle;
    Directory? permissionDirectory;
    var ownsLock = false;
    try {
      return await (() async {
        final proof = await operation.awaitAuthority(
          authorizedReview.authority,
        );
        final identity = await operation.awaitAuthority(
          authorizedRead.authority,
        );
        if (proof.environmentId != identity.environmentId ||
            proof.sessionId != identity.sessionId) {
          throw _reviewFailure(
            'authority_changed',
            'The review and read authorities differ.',
          );
        }
        final id = EnvironmentId(identity.environmentId);
        WorktreeEnvironment resolve() {
          operation.checkOpen();
          if (provider.isClosing || !provider.liveObjects.contains(id)) {
            throw _reviewFailure(
              'environment_not_live',
              'The Environment is no longer live.',
            );
          }
          return provider.liveObjects.resolve(id);
        }

        final environment = resolve();
        final gitDirectory = environment.gitDirectory;
        if (gitDirectory == null || environment.gitWorktreeRoot == null) {
          return _reviewResult('ineligible');
        }
        await operation._validateRoot(gitDirectory);
        resolve();
        lock = File('${gitDirectory.path}/index.lock');
        // Dart's File.open(write) is NOT exclusive. File.create(exclusive:true)
        // maps to O_CREAT|O_EXCL; Git's documented lock protocol permits closing
        // and reopening our lock while its pathname remains reserved.
        try {
          lock!.createSync(exclusive: true);
          ownsLock = true;
          lockHandle = lock!.openSync(mode: FileMode.write);
        } on PathExistsException {
          throw _reviewFailure(
            'index_locked',
            'Another Git writer holds the index lock.',
          );
        }
        final snapshot = await operation.snapshot(
          environment,
          includeStaged: reverse,
          includeCommitted: false,
          reviewKey: provider.reviewKey,
          reviewEnvironmentId: identity.environmentId,
        );
        final layerName = reverse ? 'staged' : 'unstaged';
        final layer = reverse
            ? snapshot.uncommitted.staged
            : snapshot.uncommitted.unstaged;
        if (layer.reviewRevision == null) return _reviewResult('ineligible');
        if (layer.reviewRevision != selection.expectedRevision) {
          return _reviewResult('stale');
        }
        final indexMode = Platform.isWindows
            ? null
            : FileStat.statSync('${gitDirectory.path}/index').mode & 0xfff;
        if (indexMode != null && indexMode & 0xe00 != 0) {
          return _reviewResult('ineligible');
        }
        final files = selection.granularity == 'layer'
            ? layer.files
            : layer.files
                  .where((file) => file.relativePath == selection.relativePath)
                  .toList();
        if (files.isEmpty ||
            files.any((file) => !file.reviewEligible) ||
            (selection.granularity == 'layer' &&
                snapshot.uncommitted.conflicts.isNotEmpty) ||
            (selection.granularity == 'hunk' &&
                selection.hunkIndex! >= files.single.hunks.length)) {
          return _reviewResult('ineligible');
        }
        final temporary = operation._temporary!;
        final privateIndex = File('${temporary.path}/index');
        await privateIndex.writeAsBytes(operation._indexBytes, flush: true);
        operation.checkOpen();
        final updates = <String, ({Uint8List bytes, String mode})>{};
        final prefix =
            environment.root.path == environment.gitWorktreeRoot!.path
            ? ''
            : '${environment.root.path.substring(environment.gitWorktreeRoot!.path.length + 1).replaceAll(Platform.pathSeparator, '/')}/';
        for (final file in files) {
          final retained =
              operation._reviewFiles[layerName]![file.relativePath]!;
          final Uint8List bytes;
          final String mode;
          if (selection.granularity == 'hunk') {
            bytes = _reconstructHunk(
              retained,
              file.hunks[selection.hunkIndex!],
              reverse,
            );
            // An addition/deletion has exactly one complete hunk. Empty-file
            // changes have no hunks and are handled only at file/layer level.
            mode = reverse ? retained.oldMode : retained.newMode;
          } else {
            bytes = reverse ? retained.old : retained.current;
            mode = reverse ? retained.oldMode : retained.newMode;
          }
          updates['$prefix${file.relativePath}'] = (bytes: bytes, mode: mode);
        }
        final originalEntries = operation._completeIndexEntries;
        // Index-info permits replacement of colliding file/directory entries.
        // Every such removal must be explicitly selected, never incidental.
        final selected = {
          for (final entry in updates.entries)
            latin1.decode(utf8.encode(entry.key)): entry.value,
        };
        for (final update in selected.entries.where(
          (entry) => entry.value.mode != '000000',
        )) {
          operation.checkOpen();
          for (final original in originalEntries.keys) {
            if ((original.path.startsWith('${update.key}/') ||
                    update.key.startsWith('${original.path}/')) &&
                selected[original.path]?.mode != '000000') {
              return _reviewResult('ineligible');
            }
          }
        }
        await operation._validateObjectStore(null);
        final protectedObjects = _ReviewBlobProtection(
          operation,
          environment.root,
        );
        final records = BytesBuilder();
        for (final update in [
          ...updates.entries.where((entry) => entry.value.mode == '000000'),
          ...updates.entries.where((entry) => entry.value.mode != '000000'),
        ]) {
          final bytes = update.value.bytes;
          final mode = update.value.mode;
          var oid = ''.padLeft(operation._reviewHead!.commit.length, '0');
          if (mode != '000000') {
            oid = _blobIdentity(bytes, operation._reviewHead!.commit.length);
            if (!await protectedObjects.prepare(
              oid,
              bytes,
              update.key.substring(prefix.length),
              privateIndex.path,
            )) {
              return _reviewResult('ineligible');
            }
          }
          records.add(utf8.encode('$mode $oid\t${update.key}\u0000'));
        }
        // Git may inspect racily-clean entries when serializing an index. An
        // empty worktree makes every such lstat miss, so no unrelated content
        // can reach clean/process filters, even with future cached mtimes.
        final emptyWorktree = await Directory(
          '${temporary.path}/empty-worktree',
        ).create();
        await operation.git(
          emptyWorktree,
          ['update-index', '-z', '--index-info'],
          privateIndex: privateIndex.path,
          input: records.takeBytes(),
        );
        final prospective = await operation._readBoundedMetadata(privateIndex);
        final prospectiveEntries = <({String path, int stage}), Uint8List>{};
        if (!_supportedReviewIndex(
          prospective,
          operation._reviewHead!.commit.length ~/ 2,
          entries: prospectiveEntries,
        )) {
          throw _reviewFailure(
            'index_unsupported',
            'Git produced an unsupported index.',
          );
        }
        for (final key in {
          ...originalEntries.keys,
          ...prospectiveEntries.keys,
        }) {
          if (selected.containsKey(key.path)) continue;
          final before = originalEntries[key];
          final after = prospectiveEntries[key];
          if (before == null || after == null || !_bytesEqual(before, after)) {
            throw _reviewFailure(
              'index_preservation_failed',
              'Git could not preserve unrelated index entries.',
            );
          }
        }
        if (FileSystemEntity.typeSync(lock!.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw _reviewFailure(
            'index_lock_changed',
            'The index lock changed unexpectedly.',
          );
        }
        if (indexMode != null &&
            FileStat.statSync(lock!.path).mode & 0xfff != indexMode) {
          // A permission child must never target the reusable index.lock path:
          // even a late launch can only touch this operation's unique payload.
          permissionDirectory = await gitDirectory.createTemp(
            'review-index-mode-',
          );
          final payload = File('${permissionDirectory!.path}/index');
          payload.createSync(exclusive: true);
          final opened = payload.openSync(mode: FileMode.write);
          try {
            await operation._prepareIndexMode(payload, indexMode);
            opened.writeFromSync(prospective);
            opened.flushSync();
          } finally {
            opened.closeSync();
          }
          operation.checkOpen();
          if (FileStat.statSync(payload.path).mode & 0xfff != indexMode) {
            throw _reviewFailure(
              'index_permissions_unavailable',
              'The prepared index permissions could not be retained.',
            );
          }
          lockHandle!.closeSync();
          lockHandle = null;
          // Same-directory-filesystem rename retains the reserved lock pathname.
          payload.renameSync(lock!.path);
        } else {
          lockHandle!.writeFromSync(prospective);
          lockHandle!.flushSync();
        }
        for (var observation = 0; observation < 2; observation++) {
          await operation._settlementValidation!();
          final currentProof = await operation.awaitAuthority(
            authorizedReview.authority,
          );
          if (currentProof.environmentId != identity.environmentId ||
              currentProof.sessionId != identity.sessionId) {
            throw _reviewFailure(
              'authority_changed',
              'The review authority changed.',
            );
          }
          final current = await operation.awaitAuthority(
            authorizedRead.authority,
          );
          if (current.environmentId != identity.environmentId ||
              current.sessionId != identity.sessionId) {
            throw _reviewFailure(
              'authority_changed',
              'The Environment authority changed.',
            );
          }
          if (!identical(resolve(), environment)) {
            throw _reviewFailure(
              'environment_not_live',
              'The Environment binding changed.',
            );
          }
          // No asynchronous suspension between final local admission and rename.
          // Cooperating Git writers cannot modify index until this rename removes
          // our lock. Direct, lock-ignoring filesystem attackers are not supported.
          operation._validatePublicationSync(environment, indexMode: indexMode);
          if (!protectedObjects.isCurrent()) {
            // Ordinary GC can relocate a freshly protected loose blob into a
            // pack. Reobserve once, then obtain fresh authority again; never reuse
            // admission across an asynchronous storage check or choose new bytes.
            if (observation != 0 || !await protectedObjects.reobserve()) {
              return _reviewResult('stale');
            }
            continue;
          }
          if (FileSystemEntity.typeSync(lock!.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              (indexMode != null &&
                  FileStat.statSync(lock!.path).mode & 0xfff != indexMode) ||
              !_bytesEqual(
                prospective,
                _readBoundedSync(lock!, _maximumReviewMetadataBytes),
              )) {
            throw _reviewFailure(
              'index_lock_changed',
              'The index lock changed unexpectedly.',
            );
          }
          lockHandle?.closeSync();
          lockHandle = null;
          operation.checkOpen();
          lock!.renameSync('${gitDirectory.path}/index');
          ownsLock = false;
          return _reviewResult('applied');
        }
        throw StateError('Review publication observation exhausted.');
      })();
    } on TimeoutException {
      throw _reviewFailure(
        'operation_timeout',
        'Review exceeded its deadline.',
      );
    } on ChangeSetFailure catch (error) {
      if (error.code == 'snapshot_changed') return _reviewResult('stale');
      throw _reviewFailure(error.code, error.message);
    } on FileSystemException {
      throw _reviewFailure(
        'review_unavailable',
        'The Git review transaction could not access its files.',
      );
    } finally {
      deadline.cancel();
      try {
        lockHandle?.closeSync();
      } on FileSystemException {
        // Still attempt lock and temporary-index cleanup.
      }
      // Fence every continuation before dropping the real index lock. Cleanup
      // never rolls back a successfully published index.
      await operation.close();
      if (ownsLock) {
        try {
          lock!.deleteSync();
        } on FileSystemException {
          // A failed cleanup leaves a visible Git lock, never a partial index.
        }
      }
      if (permissionDirectory != null) {
        try {
          await permissionDirectory!
              .delete(recursive: true)
              .timeout(const Duration(seconds: 1));
        } on Object {
          // Only this operation's bounded private permission payload remains.
        }
      }
    }
  }
}

bool _validSelection(ReviewSelection selection) {
  if (selection.expectedRevision.length != 64 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(selection.expectedRevision)) {
    return false;
  }
  final path = selection.relativePath;
  final index = selection.hunkIndex;
  if (selection.granularity == 'layer') return path == null && index == null;
  if (path == null || path.length > 4096 || utf8.encode(path).length > 4096) {
    return false;
  }
  try {
    _validatePath(path);
  } on ChangeSetFailure {
    return false;
  }
  return switch (selection.granularity) {
    'file' => index == null,
    'hunk' => index != null && index >= 0 && index < 8192,
    _ => false,
  };
}

ReviewApprovalResult _reviewResult(String status) =>
    ReviewApprovalResult(status: status);
ReviewApprovalFailure _reviewFailure(String code, String message) =>
    ReviewApprovalFailure(code: code, message: message, details: const {});

final class _ReviewFile {
  const _ReviewFile(this.old, this.current, this.oldMode, this.newMode);
  final Uint8List old;
  final Uint8List current;
  final String oldMode;
  final String newMode;
}

/// Per-transaction storage observations, not an object registry. Git remains the
/// object reader/writer; ordinary GC may move a freshly protected loose object.
final class _ReviewBlobProtection {
  _ReviewBlobProtection(this.operation, this.root);
  final _SnapshotOperation operation;
  final Directory root;
  final Map<String, ({Uint8List bytes, DateTime? fresh})> _selected = {};
  final Map<String, FileStat> _loose = {};
  ({FileStat directory, Map<String, FileStat> files})? _packs;
  Set<String>? _indexRoots;
  Set<String>? _history;
  bool _historyUnavailable = false;

  String _loosePath(String oid) =>
      '${operation._commonDirectory!.path}/objects/${oid.substring(0, 2)}/${oid.substring(2)}';

  Future<String> _description(String oid) async => _decode(
    (await operation.git(
      root,
      ['cat-file', '--batch-check=%(objecttype) %(objectsize)'],
      input: Uint8List.fromList(utf8.encode('$oid\n')),
      requireCleanStderr: true,
    )).bytes,
  );

  Future<void> _verify(String oid, Uint8List bytes) async {
    if (await _description(oid) != 'blob ${bytes.length}\n' ||
        !_bytesEqual(
          bytes,
          (await operation.git(
            root,
            ['cat-file', 'blob', oid],
            maximum: math.min(bytes.length + 1, operation.limits.outputBytes),
            requireCleanStderr: true,
          )).bytes,
        )) {
      throw _reviewFailure(
        'object_identity_invalid',
        'Git did not retain the exact selected blob.',
      );
    }
  }

  Future<bool> _rooted(String oid, String path, {required bool history}) async {
    if (_indexRoots == null) {
      _indexRoots = {};
      for (final entry in operation._completeIndexEntries.values) {
        operation.checkOpen();
        _indexRoots!.add(
          entry
              .skip(40)
              .take(oid.length ~/ 2)
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join(),
        );
      }
    }
    if (_indexRoots!.contains(oid)) return true;
    // A direct tip-tree lookup avoids walking unrelated history for ordinary
    // whole-file unapproval and never renders the staged layer during Approve.
    final tree = _decode(
      (await operation.git(root, [
        'ls-tree',
        '-z',
        operation._reviewHead!.commit,
        '--',
        path,
      ])).bytes,
    );
    if (tree.isNotEmpty) {
      final tab = tree.indexOf('\t');
      if (tab < 0 || tree.indexOf('\u0000') != tree.length - 1) {
        throw _malformed();
      }
      if (tree.substring(0, tab).split(' ').last == oid) return true;
    }
    if (!history || _historyUnavailable) return false;
    if (_history == null) {
      // Grafted or changing shallow history cannot establish a stable GC root.
      final common = operation._commonDirectory!.path;
      try {
        operation._captureReviewMetadata('$common/info/grafts');
        operation._captureReviewMetadata('$common/shallow');
        if (operation._reviewMetadataFiles['$common/info/grafts']!.bytes !=
            null) {
          _historyUnavailable = true;
          return false;
        }
        final raw = _decode(
          (await operation.git(root, [
            'rev-list',
            '--objects',
            '--no-object-names',
            operation._reviewHead!.commit,
          ])).bytes,
        );
        final identities = raw.split('\n').where((line) => line.isNotEmpty);
        final valid = RegExp('^[0-9a-f]{${oid.length}}\$');
        _history = {};
        for (final identity in identities) {
          operation.checkOpen();
          if (!valid.hasMatch(identity)) throw _malformed();
          _history!.add(identity);
        }
      } on ChangeSetFailure catch (error) {
        if (error.code != 'git_output_limit' &&
            error.code != 'review_metadata_unavailable') {
          rethrow;
        }
        _historyUnavailable = true;
        return false;
      }
    }
    return _history!.contains(oid);
  }

  Future<bool> prepare(
    String oid,
    Uint8List bytes,
    String path,
    String privateIndex,
  ) async {
    if (_selected.containsKey(oid)) return true;
    await operation._validateObjectStore(oid);
    final missing = await _description(oid) == '$oid missing\n';
    final leaf = File(_loosePath(oid));
    final loose =
        FileSystemEntity.typeSync(leaf.path, followLinks: false) ==
        FileSystemEntityType.file;
    if (missing &&
        FileSystemEntity.typeSync(leaf.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw _reviewFailure(
        'object_identity_invalid',
        'An existing loose object could not be verified.',
      );
    }
    if (!missing) await _verify(oid, bytes);
    var rooted = !missing && await _rooted(oid, path, history: !loose);
    DateTime? fresh;
    if (missing || (loose && !rooted)) {
      final beforeWrite = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
      );
      await operation._validateObjectStore(oid);
      final written = _decode(
        (await operation.git(
          root,
          ['hash-object', '--no-filters', '-w', '--stdin'],
          privateIndex: privateIndex,
          input: bytes,
        )).bytes,
      ).trim();
      if (written != oid) throw _malformed();
      await operation._validateObjectStore(oid);
      final state = leaf.statSync();
      // Git may choose an existing pack instead of making/freshening a loose
      // object. Only an observed fresh loose file grants freshness provenance.
      if (state.type == FileSystemEntityType.file &&
          !state.modified.isBefore(beforeWrite)) {
        fresh = beforeWrite;
      } else {
        rooted = await _rooted(oid, path, history: true);
      }
    }
    if (!rooted && fresh == null) return false;
    _selected[oid] = (bytes: bytes, fresh: fresh);
    return await _observe(oid);
  }

  Future<({FileStat directory, Map<String, FileStat> files})>
  _packInventory() async {
    final directory = Directory(
      '${operation._commonDirectory!.path}/objects/pack',
    );
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        directory.resolveSymbolicLinksSync() != directory.path) {
      throw _failure('snapshot_changed', 'Git object storage changed.');
    }
    final state = directory.statSync();
    final result = <String, FileStat>{};
    await for (final entry in directory.list(followLinks: false)) {
      operation.checkOpen();
      if (result.length >= operation.limits.inventoryEntries ||
          FileSystemEntity.typeSync(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw _failure(
          'snapshot_changed',
          'Git object storage cannot be verified.',
        );
      }
      final stat = entry.statSync();
      if (stat.mode & 0xf000 != 0x8000) {
        throw _failure('snapshot_changed', 'Git object storage changed.');
      }
      result[entry.path] = stat;
    }
    if (!_sameState(state, directory.statSync())) {
      throw _failure('snapshot_changed', 'Git object storage changed.');
    }
    return (directory: state, files: result);
  }

  bool _packsCurrent(
    ({FileStat directory, Map<String, FileStat> files}) before,
  ) {
    final directory = Directory(
      '${operation._commonDirectory!.path}/objects/pack',
    );
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        directory.resolveSymbolicLinksSync() != directory.path ||
        !_sameState(before.directory, directory.statSync())) {
      return false;
    }
    // Never enumerate at publication: only inspect retained bounded paths and
    // directory identity/state. New membership causes reobservation or rejection.
    for (final entry in before.files.entries) {
      operation.checkOpen();
      if (FileSystemEntity.typeSync(entry.key, followLinks: false) !=
              FileSystemEntityType.file ||
          !_sameState(entry.value, FileStat.statSync(entry.key))) {
        return false;
      }
    }
    return _sameState(before.directory, directory.statSync());
  }

  Future<bool> _observe(String oid) async {
    await operation._validateObjectStore(oid);
    final value = _selected[oid]!;
    final path = _loosePath(oid);
    final state = FileStat.statSync(path);
    final loose =
        FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.file;
    final packs = loose ? null : await _packInventory();
    if (loose && value.fresh != null && state.modified.isBefore(value.fresh!)) {
      return false;
    }
    await _verify(oid, value.bytes);
    await operation._validateObjectStore(oid);
    if (loose) {
      if (!_sameState(state, FileStat.statSync(path))) return false;
      _loose[oid] = state;
    } else {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          !_packsCurrent(packs!) ||
          (_packs != null && !_packsCurrent(_packs!))) {
        return false;
      }
      _packs = packs;
    }
    return true;
  }

  Future<bool> reobserve() async {
    _loose.clear();
    _packs = null;
    for (final oid in _selected.keys) {
      if (!await _observe(oid)) return false;
    }
    return true;
  }

  bool isCurrent() {
    try {
      operation.checkOpen();
      final objects = Directory('${operation._commonDirectory!.path}/objects');
      if (FileSystemEntity.typeSync(objects.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          objects.resolveSymbolicLinksSync() != objects.path) {
        return false;
      }
      for (final entry in _loose.entries) {
        final file = File(_loosePath(entry.key));
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            file.parent.resolveSymbolicLinksSync() != file.parent.path ||
            !_sameState(entry.value, file.statSync())) {
          return false;
        }
      }
      return _packs == null || _packsCurrent(_packs!);
    } on FileSystemException {
      return false;
    }
  }
}

Uint8List _reconstructHunk(_ReviewFile file, DiffHunk hunk, bool reverse) {
  final source = reverse ? file.current : file.old;
  final lines = <Uint8List>[];
  var start = 0;
  for (var i = 0; i < source.length; i++) {
    if (source[i] == 10) {
      lines.add(Uint8List.sublistView(source, start, i + 1));
      start = i + 1;
    }
  }
  if (start < source.length) lines.add(Uint8List.sublistView(source, start));
  final count = reverse ? hunk.newCount : hunk.oldCount;
  final coordinate = reverse ? hunk.newStart : hunk.oldStart;
  final offset = count == 0 ? coordinate : coordinate - 1;
  if (offset < 0 || offset + count > lines.length) throw _malformed();
  final expected = BytesBuilder();
  final replacement = BytesBuilder();
  for (final line in hunk.lines) {
    final bytes = utf8.encode('${line.text}${line.noNewline ? '' : '\n'}');
    if (line.kind != (reverse ? 'deletion' : 'addition')) expected.add(bytes);
    if (line.kind != (reverse ? 'addition' : 'deletion')) {
      replacement.add(bytes);
    }
  }
  final actual = BytesBuilder();
  for (final line in lines.skip(offset).take(count)) {
    actual.add(line);
  }
  if (!_bytesEqual(actual.takeBytes(), expected.takeBytes())) {
    throw _malformed();
  }
  final result = BytesBuilder();
  for (final line in lines.take(offset)) {
    result.add(line);
  }
  result.add(replacement.takeBytes());
  for (final line in lines.skip(offset + count)) {
    result.add(line);
  }
  return result.takeBytes();
}

extension _ReviewSnapshot on _SnapshotOperation {
  Future<void> _prepareIndexMode(File payload, int mode) async {
    checkOpen();
    String? executable;
    for (final candidate in ['/usr/bin/chmod', '/bin/chmod']) {
      final stat = File(candidate).statSync();
      if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
        executable = candidate;
        break;
      }
    }
    if (executable == null ||
        FileSystemEntity.typeSync(payload.path, followLinks: false) !=
            FileSystemEntityType.file ||
        payload.parent.resolveSymbolicLinksSync() != payload.parent.path) {
      throw _reviewFailure(
        'index_permissions_unavailable',
        'The index permissions cannot be safely prepared.',
      );
    }
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      checkOpen();
      final micros = math.min(
        (limits.operationTimeout - _elapsed.elapsed).inMicroseconds,
        (limits.processTimeout - elapsed.elapsed).inMicroseconds,
      );
      if (micros <= 0) throw TimeoutException('Index permission deadline');
      return Duration(microseconds: micros);
    }

    Process? process;
    var completed = false;
    var launchExpired = false;
    try {
      final startBudget = remaining();
      process =
          await Process.start(
                executable,
                ['--', mode.toRadixString(8), payload.path],
                workingDirectory: _gitDirectory.path,
                environment: const {'LC_ALL': 'C'},
                includeParentEnvironment: false,
                runInShell: false,
              )
              .then((started) {
                if (_closed || launchExpired) {
                  started.kill(ProcessSignal.sigkill);
                }
                return started;
              })
              .timeout(startBudget);
      final started = process;
      _processes.add(started);
      checkOpen();
      await started.stdin.close().timeout(remaining());
      var output = 0;
      Future<void> drain(Stream<List<int>> stream) => stream.forEach((chunk) {
        if ((output += chunk.length) > limits.stderrBytes) {
          throw _reviewFailure(
            'index_permissions_unavailable',
            'Index permission diagnostics exceeded their bound.',
          );
        }
      });
      int? exitCode;
      final completionBudget = remaining();
      await Future.wait<void>([
        started.exitCode.then<void>((code) {
          completed = true;
          exitCode = code;
        }),
        drain(started.stdout),
        drain(started.stderr),
      ], eagerError: true).timeout(completionBudget);
      checkOpen();
      if (exitCode != 0 ||
          FileStat.statSync(payload.path).mode & 0xfff != mode) {
        throw _reviewFailure(
          'index_permissions_unavailable',
          'The existing index permissions could not be preserved.',
        );
      }
    } on ProcessException {
      throw _reviewFailure(
        'index_permissions_unavailable',
        'The index permission tool could not be started.',
      );
    } on TimeoutException {
      checkOpen();
      throw _reviewFailure(
        'index_permissions_unavailable',
        'Index permission preparation exceeded its deadline.',
      );
    } finally {
      launchExpired = true;
      if (process != null) {
        if (!completed) process.kill(ProcessSignal.sigkill);
        _processes.remove(process);
      }
    }
  }

  Future<void> _validateObjectStore(String? oid) async {
    checkOpen();
    final objects = Directory('${_commonDirectory!.path}/objects');
    final fanout = oid == null
        ? null
        : Directory('${objects.path}/${oid.substring(0, 2)}');
    final info = Directory('${objects.path}/info');
    final packs = Directory('${objects.path}/pack');
    for (final directory in [
      objects,
      if (oid == null) ...[info, packs],
      ?fanout,
    ]) {
      final type = FileSystemEntity.typeSync(
        directory.path,
        followLinks: false,
      );
      if (directory != objects && type == FileSystemEntityType.notFound) {
        continue;
      }
      if (type != FileSystemEntityType.directory ||
          directory.resolveSymbolicLinksSync() != directory.path) {
        throw _reviewFailure(
          'object_store_unsupported',
          'Review requires direct Git object storage.',
        );
      }
    }
    if (oid != null) {
      final leaf = File('${fanout!.path}/${oid.substring(2)}');
      final type = FileSystemEntity.typeSync(leaf.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          (type != FileSystemEntityType.file ||
              leaf.resolveSymbolicLinksSync() != leaf.path)) {
        throw _reviewFailure(
          'object_store_unsupported',
          'Review requires a direct regular loose-object destination.',
        );
      }
      return;
    }
    for (final name in ['alternates', 'http-alternates']) {
      if (FileSystemEntity.typeSync('${info.path}/$name', followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw _reviewFailure(
          'object_store_unsupported',
          'Review does not support alternate object storage.',
        );
      }
    }
    if (packs.existsSync()) {
      var count = 0;
      await for (final entry in packs.list(followLinks: false)) {
        checkOpen();
        if (++count > limits.inventoryEntries ||
            FileSystemEntity.typeSync(entry.path, followLinks: false) !=
                FileSystemEntityType.file ||
            entry.resolveSymbolicLinksSync() != entry.path) {
          throw _reviewFailure(
            'object_store_unsupported',
            'Review requires bounded direct pack storage.',
          );
        }
      }
    }
    final compatibility = _decode(
      (await git(_worktreeRoot, [
        'config',
        '--get',
        'extensions.compatobjectformat',
      ], allowDifference: true)).bytes,
    ).trim();
    if (compatibility.isNotEmpty) {
      throw _reviewFailure(
        'object_store_unsupported',
        'Review does not support dual-format object storage.',
      );
    }
  }

  Future<void> _captureReviewDirectories(
    Directory root,
    Map<String, GitIndexEntry> inventory,
  ) async {
    final parents = <String>{};
    for (final path in inventory.keys) {
      final parts = path.split('/');
      for (var i = 1; i < parts.length; i++) {
        parents.add(parts.take(i).join('/'));
      }
    }
    for (final parent in parents) {
      final source = '${root.path}/$parent/.gitignore';
      _captureReviewMetadata(source);
      _reviewIgnorePaths.add(source);
    }
    var observeRoot = true;
    if (root.path != _worktreeRoot.path) {
      final relative = root.path
          .substring(_worktreeRoot.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      final ignored = await git(
        _worktreeRoot,
        ['check-ignore', '--no-index', '-z', '--stdin'],
        input: Uint8List.fromList(utf8.encode('./$relative\u0000')),
        allowDifference: true,
      );
      observeRoot = ignored.bytes.isEmpty;
    }
    final pending = [(directory: root, observe: observeRoot)];
    var count = 0;
    var listed = 0;
    try {
      while (pending.isNotEmpty) {
        checkOpen();
        final next = pending.removeLast();
        final directory = next.directory;
        final ignoreSource = '${directory.path}/.gitignore';
        _captureReviewMetadata(ignoreSource);
        _reviewIgnorePaths.add(ignoreSource);
        if (next.observe) {
          _reviewDirectories[directory.path] = await directory.stat();
        }
        final children = <String, Directory>{};
        await for (final entity
            in next.observe
                ? directory.list(followLinks: false)
                : Stream<FileSystemEntity>.fromIterable([
                    for (final parent in parents)
                      if (Directory('${root.path}/$parent').parent.path ==
                          directory.path)
                        Directory('${root.path}/$parent'),
                  ])) {
          checkOpen();
          // Index/object/lock activity is repository metadata, not working data.
          if (entity.path.split(Platform.pathSeparator).last == '.git') {
            continue;
          }
          if (++listed > limits.inventoryEntries) {
            _reviewContentComplete = false;
            _reviewDirectories.clear();
            return;
          }
          if (entity is! Directory) continue;
          final relative = entity.path
              .substring(root.path.length + 1)
              .replaceAll(Platform.pathSeparator, '/');
          if (inventory[relative]?.oldMode == '160000') {
            continue;
          }
          children[relative] = entity;
          if (children.length > limits.inventoryEntries) {
            _reviewContentComplete = false;
            _reviewDirectories.clear();
            return;
          }
        }
        if (children.isEmpty) continue;
        // An excluded parent cannot be re-included by its descendants' rules.
        // Visit only known tracked parents, never an ignored cache subtree.
        final ignored = !next.observe
            ? children.keys.map((path) => './$path').toSet()
            : _nulRecords(
                _decode(
                  (await git(
                    root,
                    ['check-ignore', '--no-index', '-z', '--stdin'],
                    input: Uint8List.fromList(
                      utf8.encode(
                        children.keys.map((path) => './$path\u0000').join(),
                      ),
                    ),
                    allowDifference: true,
                  )).bytes,
                ),
              ).toSet();
        for (final entry in children.entries) {
          final ignore = ignored.contains('./${entry.key}');
          if (ignore && !parents.contains(entry.key)) continue;
          // Do not enter an independent repository to discover its local policy.
          // Ordinary ignored caches were already pruned by Git above.
          if (!parents.contains(entry.key) &&
              await FileSystemEntity.type(
                    '${entry.value.path}/.git',
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.notFound) {
            _indexReviewable = false;
            return;
          }
          if (++count > limits.inventoryEntries) {
            _reviewContentComplete = false;
            _reviewDirectories.clear();
            return;
          }
          pending.add((directory: entry.value, observe: !ignore));
        }
      }
    } on FileSystemException {
      _reviewContentComplete = false;
      _reviewDirectories.clear();
    }
  }

  void _validateReviewDirectoriesSync() {
    for (final entry in _reviewDirectories.entries) {
      final current = FileStat.statSync(entry.key);
      if (!_sameState(current, entry.value)) {
        throw _failure(
          'snapshot_changed',
          'Working directory membership changed.',
        );
      }
    }
  }

  Future<void> _captureHeadFiles(Directory root) async {
    if (!_indexReviewable || _reviewHead == null) return;
    final reference = _reviewHead!.reference;
    if (reference.isNotEmpty && !reference.endsWith('\n')) {
      _indexReviewable = false;
      return;
    }
    final storage = _decode(
      (await git(root, [
        'config',
        '--get',
        'extensions.refstorage',
      ], allowDifference: true)).bytes,
    ).trim();
    if (storage.isNotEmpty && storage != 'files') {
      _indexReviewable = false;
      return;
    }
    for (final name in [
      'HEAD',
      'packed-refs',
      'commondir',
      if (reference.isNotEmpty) reference.substring(0, reference.length - 1),
    ]) {
      final output = _decode(
        (await git(root, [
          'rev-parse',
          '--path-format=absolute',
          '--git-path',
          name,
        ])).bytes,
      );
      if (!output.endsWith('\n')) throw _malformed();
      final path = output.substring(0, output.length - 1);
      try {
        _headFiles[path] = _readOptionalMetadataSync(path);
        // Compare captured Git-formatted bytes exactly: trimming can alias
        // distinct legal ref names. Chains/noncanonical HEAD stay read-only.
        if (name == 'HEAD' &&
            reference.isNotEmpty &&
            !_bytesEqual(
              _headFiles[path] ?? const [],
              utf8.encode('ref: $reference'),
            )) {
          _indexReviewable = false;
          _headFiles.clear();
          return;
        }
      } on ChangeSetFailure catch (error) {
        if (error.code != 'review_metadata_unavailable') rethrow;
        _indexReviewable = false;
        _headFiles.clear();
        return;
      }
    }
  }

  Uint8List? _readOptionalMetadataSync(String path) {
    checkOpen();
    try {
      var parent = File(path).parent;
      while (!parent.existsSync() && parent.path != parent.parent.path) {
        if (FileSystemEntity.typeSync(parent.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw _failure(
            'review_metadata_unavailable',
            'Review metadata has an indirect parent.',
          );
        }
        parent = parent.parent;
      }
      if (parent.resolveSymbolicLinksSync() != parent.path) {
        throw _failure(
          'review_metadata_unavailable',
          'Review metadata is indirect.',
        );
      }
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      final state = FileStat.statSync(path);
      // Dart reports some devices/FIFOs as notFound, even in FileStat. Resolve
      // the path without opening it to distinguish real absence from a special
      // or inaccessible policy source; never block reading a pipe here.
      if (type == FileSystemEntityType.notFound && state.mode == 0) {
        try {
          File(path).resolveSymbolicLinksSync();
        } on FileSystemException catch (error) {
          // resolveSymbolicLinksSync uses a generic FileSystemException, unlike
          // open. ENOTDIR also proves this optional file cannot exist (for
          // example, a D/F replacement has a regular file in its parent path).
          if (error.osError?.errorCode == 2 ||
              (!Platform.isWindows && error.osError?.errorCode == 20) ||
              (Platform.isWindows && error.osError?.errorCode == 3)) {
            return null;
          }
          rethrow;
        }
        throw _failure(
          'review_metadata_unavailable',
          'Review metadata is not a regular file.',
        );
      }
      final file = File(path);
      if (type != FileSystemEntityType.file ||
          (state.mode & 0xf000) != 0x8000 ||
          file.lengthSync() > limits.reviewMetadataBytes) {
        throw _failure(
          'review_metadata_unavailable',
          'Review metadata cannot be safely inspected.',
        );
      }
      return _readBoundedSync(file, limits.reviewMetadataBytes);
    } on FileSystemException {
      throw _failure(
        'review_metadata_unavailable',
        'Review metadata could not be read.',
      );
    }
  }

  void _validateHeadFilesSync() {
    for (final entry in _headFiles.entries) {
      final current = _readOptionalMetadataSync(entry.key);
      if (entry.value == null
          ? current != null
          : current == null || !_bytesEqual(current, entry.value!)) {
        throw _failure('snapshot_changed', 'HEAD reference storage changed.');
      }
    }
  }

  Future<Uint8List> _readBoundedMetadata(File file) async {
    checkOpen();
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.resolveSymbolicLinks() != file.path ||
          ((await file.stat()).mode & 0xf000) != 0x8000) {
        throw _failure(
          'review_metadata_unavailable',
          'Review index metadata is not a direct file.',
        );
      }
      final opened = await file.open();
      try {
        final length = await opened.length();
        if (length > limits.reviewMetadataBytes) {
          throw _failure(
            'review_metadata_unavailable',
            'The complete Git index exceeds the review limit.',
          );
        }
        final bytes = await opened.read(length + 1);
        checkOpen();
        if (bytes.length != length) {
          throw _failure('snapshot_changed', 'Git index metadata changed.');
        }
        return bytes;
      } finally {
        await opened.close();
      }
    } on FileSystemException {
      throw _failure(
        'review_metadata_unavailable',
        'Review index metadata could not be read.',
      );
    }
  }

  Future<Uint8List> _readIndex() =>
      _readBoundedMetadata(File('${_gitDirectory.path}/index'));

  Future<String> _readAttributes(Directory root, String path) async => _decode(
    (await git(root, [
      'check-attr',
      '-z',
      'diff',
      'text',
      'eol',
      'working-tree-encoding',
      'filter',
      'ident',
      '--',
      path,
    ])).bytes,
  );

  void _captureReviewMetadata(String source) {
    if (_reviewMetadataFiles.containsKey(source)) return;
    checkOpen();
    if (_reviewMetadataFiles.length >= limits.inventoryEntries) {
      throw _failure(
        'review_metadata_unavailable',
        'Git review metadata has too many sources.',
      );
    }
    final state = FileStat.statSync(source);
    final bytes = _readOptionalMetadataSync(source);
    if (!_sameState(state, FileStat.statSync(source))) {
      throw _failure('snapshot_changed', 'Git review metadata changed.');
    }
    _reviewMetadataFiles[source] = (state: state, bytes: bytes);
    if (_reviewMetadataFiles.values.fold<int>(
          0,
          (total, value) => total + (value.bytes?.length ?? 0),
        ) >
        limits.reviewMetadataBytes) {
      throw _failure(
        'review_metadata_unavailable',
        'Git review metadata exceeds its byte bound.',
      );
    }
  }

  Future<List<String>> _reviewPathVariable(
    Directory root,
    String variable,
    int maximum,
  ) async {
    final value = await git(
      root,
      ['var', variable],
      allowDifference: true,
      allowUnknownVariable: true,
    );
    if (value.exitCode != 0) {
      throw _failure(
        'review_metadata_unavailable',
        'Git metadata source discovery is unavailable.',
      );
    }
    final output = _decode(value.bytes);
    final paths = output.endsWith('\n')
        ? output.substring(0, output.length - 1).split('\n')
        : <String>[];
    if (paths.isEmpty ||
        paths.length > maximum ||
        paths.any((path) => path.isEmpty)) {
      throw _failure(
        'review_metadata_unavailable',
        'Git metadata sources cannot be safely identified.',
      );
    }
    return [
      for (final path in paths)
        File.fromUri(_worktreeRoot.uri.resolveUri(File(path).uri)).path,
    ];
  }

  Future<List<String>> _captureReviewConfigSources(Directory root) async {
    if (_reviewConfigPaths case final paths?) return paths;
    if (['HOME', 'XDG_CONFIG_HOME', 'USERPROFILE'].any((key) {
      final value = parentEnvironment[key];
      return value != null &&
          value.isNotEmpty &&
          (value.contains('\n') || !File(value).isAbsolute);
    })) {
      throw _failure(
        'review_metadata_unavailable',
        'Git configuration paths cannot be safely identified.',
      );
    }
    final paths = <String>[
      '${_commonDirectory!.path}/config',
      '${_gitDirectory.path}/config.worktree',
    ];
    for (final path in paths) {
      _captureReviewMetadata(path);
    }
    for (final (variable, maximum) in [
      ('GIT_CONFIG_SYSTEM', 1),
      ('GIT_CONFIG_GLOBAL', 2),
    ]) {
      for (final path in await _reviewPathVariable(root, variable, maximum)) {
        _captureReviewMetadata(path);
        paths.add(path);
      }
    }
    final includes = await git(root, [
      'config',
      '--includes',
      '--null',
      '--get-regexp',
      r'^(include\.path|includeif\..*\.path)$',
    ], allowDifference: true);
    if (includes.bytes.isNotEmpty) {
      throw _failure(
        'review_metadata_unavailable',
        'Included Git configuration is not supported for review.',
      );
    }
    return _reviewConfigPaths = paths;
  }

  Future<void> _captureReviewIgnoreSources(
    Directory root,
    Map<String, GitIndexEntry> index,
  ) async {
    try {
      _reviewIgnorePaths.addAll(await _captureReviewConfigSources(root));
      final info = '${_commonDirectory!.path}/info/exclude';
      _captureReviewMetadata(info);
      _reviewIgnorePaths.add(info);
      final configured = await git(root, [
        'config',
        '--path',
        '--null',
        '--get',
        'core.excludesFile',
      ], allowDifference: true);
      String global;
      if (configured.exitCode == 0) {
        final values = _nulRecords(_decode(configured.bytes));
        if (values.length != 1) {
          throw _failure(
            'review_metadata_unavailable',
            'Git global ignore path is unavailable.',
          );
        }
        global = values.single;
      } else {
        final xdg = parentEnvironment['XDG_CONFIG_HOME'];
        final home = parentEnvironment['HOME'];
        if (xdg != null && xdg.isNotEmpty) {
          global = '$xdg/git/ignore';
        } else if (home != null && home.isNotEmpty) {
          global = '$home/.config/git/ignore';
        } else {
          throw _failure(
            'review_metadata_unavailable',
            'Git default global ignore path is unavailable.',
          );
        }
      }
      // An explicitly empty core.excludesFile disables the global ignore file.
      if (global.isNotEmpty) {
        final path = File.fromUri(
          _worktreeRoot.uri.resolveUri(File(global).uri),
        ).path;
        _captureReviewMetadata(path);
        _reviewIgnorePaths.add(path);
      }
      var directory = root;
      while (true) {
        final path = '${directory.path}/.gitignore';
        _captureReviewMetadata(path);
        _reviewIgnorePaths.add(path);
        if (directory.path == _worktreeRoot.path) break;
        directory = directory.parent;
      }
      // Cached index paths identify tracked parents without consulting ignore
      // rules. All ignore-dependent enumeration happens after this capture.
      await _captureReviewDirectories(root, index);
    } on ChangeSetFailure catch (error) {
      if (error.code != 'review_metadata_unavailable') rethrow;
      _indexReviewable = false;
    } on FileSystemException {
      _indexReviewable = false;
    }
  }

  Future<void> _captureReviewAttributeSources(
    Directory root,
    String path,
  ) async {
    if (_reviewAttributePaths.containsKey(path)) return;
    Never unavailable() => throw _failure(
      'review_metadata_unavailable',
      'Git attribute sources cannot be safely inspected.',
    );
    try {
      if (_reviewGlobalAttributePaths == null) {
        final global = <String>[...await _captureReviewConfigSources(root)];
        final unsupportedConfig = await git(root, [
          'config',
          '--includes',
          '--null',
          '--get-regexp',
          r'^attr\.tree$',
        ], allowDifference: true);
        if (unsupportedConfig.bytes.isNotEmpty) unavailable();
        for (final variable in ['GIT_ATTR_SYSTEM', 'GIT_ATTR_GLOBAL']) {
          for (final source in await _reviewPathVariable(root, variable, 1)) {
            _captureReviewMetadata(source);
            global.add(source);
          }
        }
        final info = '${_commonDirectory!.path}/info/attributes';
        _captureReviewMetadata(info);
        global.add(info);
        _reviewGlobalAttributePaths = global;
      }
      final relevant = {..._reviewGlobalAttributePaths!};
      var directory = File('${root.path}/$path').parent;
      while (true) {
        final source = '${directory.path}/.gitattributes';
        _captureReviewMetadata(source);
        relevant.add(source);
        if (directory.path == _worktreeRoot.path) break;
        if (!directory.path.startsWith(
          '${_worktreeRoot.path}${Platform.pathSeparator}',
        )) {
          unavailable();
        }
        directory = directory.parent;
      }
      _reviewAttributePaths[path] = relevant.toList()..sort();
    } on ChangeSetFailure catch (error) {
      if (error.code != 'review_metadata_unavailable') rethrow;
      _indexReviewable = false;
    } on FileSystemException {
      _indexReviewable = false;
    }
  }

  void _validateReviewMetadataSync(Iterable<String> paths) {
    try {
      for (final path in paths) {
        checkOpen();
        final previous = _reviewMetadataFiles[path]!;
        final current = _readOptionalMetadataSync(path);
        if (!_sameState(previous.state, FileStat.statSync(path)) ||
            (previous.bytes == null
                ? current != null
                : current == null || !_bytesEqual(current, previous.bytes!))) {
          throw _failure(
            'snapshot_changed',
            'Git review metadata sources changed.',
          );
        }
      }
    } on ChangeSetFailure catch (error) {
      if (error.code != 'review_metadata_unavailable') rethrow;
      throw _failure(
        'snapshot_changed',
        'Git review metadata sources cannot be verified.',
      );
    } on FileSystemException {
      throw _failure(
        'snapshot_changed',
        'Git review metadata sources cannot be verified.',
      );
    }
  }

  String? _reviewRevision(
    WorktreeEnvironment environment,
    List<int> key,
    String layer,
    List<ChangedFile> files,
    List<ChangedFile> conflicts,
  ) {
    if (!_indexReviewable ||
        !_reviewContentComplete ||
        _reviewHead == null ||
        _indexBytes.isEmpty) {
      return null;
    }
    if (layer == 'unstaged' &&
        files.any(
          (file) =>
              file.contentStatus != 'conflicted' &&
              !_workingDigests.containsKey(file.relativePath) &&
              !_observedLinks.containsKey(file.relativePath) &&
              _observed[file.relativePath]?.type !=
                  FileSystemEntityType.notFound,
        )) {
      return null;
    }
    // Unsupported bounded reads still remain visible, but cannot issue a token
    // that purports to identify content we did not completely observe.
    if (_observed.entries.any(
      (entry) =>
          entry.value.type == FileSystemEntityType.file &&
          !_workingDigests.containsKey(entry.key),
    )) {
      return null;
    }
    final metadataDigests = {
      for (final entry in _reviewMetadataFiles.entries)
        entry.key: entry.value.bytes == null
            ? null
            : sha256.convert(entry.value.bytes!).toString(),
    };
    Object describe(ChangedFile file) => [
      file.relativePath,
      file.changeKind,
      file.contentStatus,
      file.reviewEligible,
      _attributes[file.relativePath],
      for (final source
          in _reviewAttributePaths[file.relativePath] ?? const <String>[])
        [source, metadataDigests[source]],
      for (final hunk in file.hunks)
        [
          hunk.oldStart,
          hunk.oldCount,
          hunk.newStart,
          hunk.newCount,
          for (final line in hunk.lines) [line.kind, line.text, line.noNewline],
        ],
    ];
    final working = _workingDigests.keys.toList()..sort();
    final observed = _observed.keys.toList()..sort();
    final links = _observedLinks.keys.toList()..sort();
    final ignores = _reviewIgnorePaths.toList()..sort();
    final conflictPaths = {
      ...conflicts.map((file) => file.relativePath),
      ...files
          .where((file) => file.contentStatus == 'conflicted')
          .map((file) => file.relativePath),
    }.toList()..sort();
    return Hmac(sha256, key)
        .convert(
          utf8.encode(
            jsonEncode([
              'git-review-v1',
              _reviewEnvironmentId,
              environment.reviewGeneration,
              environment.root.path,
              _gitDirectory.path,
              _worktreeRoot.path,
              _reviewHead!.commit,
              _reviewHead!.reference,
              sha256.convert(_indexBytes).toString(),
              layer,
              for (final source in ignores) [source, metadataDigests[source]],
              for (final file in files.where(
                (file) => file.contentStatus != 'conflicted',
              ))
                describe(file),
              conflictPaths,
              for (final path in working) [path, _workingDigests[path]],
              for (final path in observed)
                [
                  path,
                  _observed[path]!.type.toString(),
                  _observed[path]!.mode,
                  _observed[path]!.size,
                ],
              for (final path in links) [path, _observedLinks[path]],
            ]),
          ),
        )
        .toString();
  }

  ChangeSetSnapshot _reviewSnapshot(
    WorktreeEnvironment environment,
    List<int> key,
    String layer,
    List<ChangedFile> files,
    List<ChangedFile> conflicts,
  ) {
    final paths = files.map((file) => file.relativePath).toSet();
    final prefix = environment.root.path == _worktreeRoot.path
        ? ''
        : '${environment.root.path.substring(_worktreeRoot.path.length + 1).replaceAll(Platform.pathSeparator, '/')}/';
    final visible = <ChangedFile>[];
    for (final file in files) {
      checkOpen();
      final fullPath = latin1.decode(
        utf8.encode('$prefix${file.relativePath}'),
      );
      final ambiguous =
          file.reviewEligible &&
          (paths.any(
                (other) =>
                    other != file.relativePath &&
                    (other.startsWith('${file.relativePath}/') ||
                        file.relativePath.startsWith('$other/')),
              ) ||
              _completeIndexEntries.keys.any(
                (other) =>
                    other.path != fullPath &&
                    (other.path.startsWith('$fullPath/') ||
                        fullPath.startsWith('${other.path}/')),
              ));
      visible.add(
        !ambiguous
            ? file
            : ChangedFile(
                relativePath: file.relativePath,
                changeKind: file.changeKind,
                contentStatus: file.contentStatus,
                hunks: file.hunks,
                reviewEligible: false,
                detail:
                    'File/directory replacements are not eligible for review.',
              ),
      );
    }
    final revision = _reviewRevision(
      environment,
      key,
      layer,
      visible,
      conflicts,
    );
    return ChangeSetSnapshot(
      reviewRevision: revision,
      files: revision != null
          ? visible
          : [
              for (final file in visible)
                if (file.contentStatus != 'text')
                  file
                else
                  ChangedFile(
                    relativePath: file.relativePath,
                    changeKind: file.changeKind,
                    contentStatus: file.contentStatus,
                    detail:
                        file.detail ??
                        'Review is unavailable because required Git metadata or working state cannot be safely verified.',
                    reviewEligible: false,
                    hunks: file.hunks,
                  ),
            ],
    );
  }

  Future<void> _validateWorkingContent(Directory root) async {
    var total = 0;
    for (final entry in _workingDigests.entries) {
      // Oversized inspection already streams and validates its one bounded raw
      // read. Do not charge or repeat that independent inspection budget. The
      // mutation's final synchronous check still hashes these complete bytes.
      if (entry.value.startsWith('git:')) continue;
      final state = await _directState(root, entry.key);
      if (state.type == FileSystemEntityType.notFound &&
          _observed[entry.key]?.type == state.type) {
        continue;
      }
      if (state.type != FileSystemEntityType.file) {
        throw _failure(
          'snapshot_changed',
          'Working content cannot be completely revalidated.',
        );
      }
      if (state.size > limits.verificationFileBytes ||
          (total += state.size) > limits.verificationTotalBytes) {
        _reviewContentComplete = false;
        continue;
      }
      final opened = await File('${root.path}/${entry.key}').open();
      try {
        final bytes = await opened.read(state.size + 1);
        checkOpen();
        if (bytes.length != state.size ||
            !_matchesWorkingDigest(bytes, entry.value)) {
          throw _failure('snapshot_changed', 'Working content changed.');
        }
      } finally {
        await opened.close();
      }
    }
  }

  void _validatePublicationSync(
    WorktreeEnvironment environment, {
    required int? indexMode,
  }) {
    checkOpen();
    _validateHeadFilesSync();
    _validateReviewDirectoriesSync();
    for (final root in [
      environment.root,
      _gitDirectory,
      _worktreeRoot,
      ?_commonDirectory,
    ]) {
      if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          root.resolveSymbolicLinksSync() != root.path) {
        throw _failure('snapshot_changed', 'The bound repository changed.');
      }
    }
    final index = File('${_gitDirectory.path}/index');
    if (FileSystemEntity.typeSync(index.path, followLinks: false) !=
            FileSystemEntityType.file ||
        (indexMode != null &&
            FileStat.statSync(index.path).mode & 0xfff != indexMode) ||
        index.lengthSync() != _indexBytes.length ||
        !_bytesEqual(
          _readBoundedSync(index, _maximumReviewMetadataBytes),
          _indexBytes,
        )) {
      throw _failure('snapshot_changed', 'The complete index changed.');
    }
    var ordinaryTotal = 0;
    var streamedTotal = 0;
    for (final entry in _observed.entries) {
      var path = environment.root.path;
      for (final component in entry.key.split('/')) {
        path = '$path/$component';
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw _failure('snapshot_changed', 'A working path became indirect.');
        }
      }
      final state = FileStat.statSync(path);
      if (!_sameState(state, entry.value)) {
        throw _failure('snapshot_changed', 'A working path changed.');
      }
      final digest = _workingDigests[entry.key];
      if (digest == null || state.type == FileSystemEntityType.notFound) {
        continue;
      }
      final total = digest.startsWith('git:')
          ? (streamedTotal += state.size)
          : (ordinaryTotal += state.size);
      if (state.size > limits.verificationFileBytes ||
          total > limits.verificationTotalBytes ||
          !_matchesWorkingDigest(
            _readBoundedSync(File(path), limits.verificationFileBytes),
            digest,
          )) {
        throw _failure(
          'snapshot_changed',
          'Working content changed before publication.',
        );
      }
    }
    for (final entry in _observedLinks.entries) {
      final path = '${environment.root.path}/${entry.key}';
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.link ||
          Link(path).parent.resolveSymbolicLinksSync() !=
              Link(path).parent.path ||
          Link(path).targetSync() != entry.value) {
        throw _failure(
          'snapshot_changed',
          'A symbolic link changed before publication.',
        );
      }
    }
    _validateReviewMetadataSync(_reviewMetadataFiles.keys);
  }
}

Uint8List _readBoundedSync(File file, int maximum) {
  final opened = file.openSync();
  try {
    final length = opened.lengthSync();
    if (length > maximum) {
      throw _failure(
        'snapshot_changed',
        'A review input exceeded its byte bound.',
      );
    }
    final bytes = opened.readSync(length + 1);
    if (bytes.length != length) {
      throw _failure(
        'snapshot_changed',
        'A review input changed while reading.',
      );
    }
    return bytes;
  } finally {
    opened.closeSync();
  }
}

bool _matchesWorkingDigest(Uint8List bytes, String digest) {
  if (!digest.startsWith('git:')) {
    return sha256.convert(bytes).toString() == digest;
  }
  final parts = digest.split(':');
  return _blobIdentity(bytes, parts[1].length) == parts[2];
}

String _blobIdentity(Uint8List bytes, int oidLength) {
  late Digest result;
  final hash = oidLength == 64 ? sha256 : sha1;
  final sink = hash.startChunkedConversion(
    ChunkedConversionSink<Digest>.withCallback(
      (values) => result = values.single,
    ),
  );
  sink.add(utf8.encode('blob ${bytes.length}\u0000'));
  sink.add(bytes);
  sink.close();
  return result.toString();
}

bool _bytesEqual(List<int> a, List<int> b) =>
    a.length == b.length && a.indexed.every((entry) => entry.$2 == b[entry.$1]);

// Updating a copied index lets Git preserve unrelated stat data, flags, modes,
// and resolve-undo records and invalidate cache-tree data correctly. Refuse
// extensions that this narrow policy would discard or whose update semantics
// we cannot preserve (split/sparse, fsmonitor, untracked cache, unknown data).
bool _supportedReviewIndex(
  Uint8List bytes,
  int hashBytes, {
  Map<({String path, int stage}), Uint8List>? entries,
}) {
  if (bytes.length < 12 + hashBytes ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'DIRC') {
    return false;
  }
  final data = ByteData.sublistView(bytes);
  final version = data.getUint32(4);
  if (version < 2 || version > 4) return false;
  final end = bytes.length - hashBytes;
  var offset = 12;
  var previous = '';
  var pathBytes = 0;
  try {
    for (var i = 0; i < data.getUint32(8); i++) {
      final start = offset;
      final flags = data.getUint16(offset + 40 + hashBytes);
      offset += 42 + hashBytes;
      if ((flags & 0x4000) != 0) offset += 2;
      final headerEnd = offset;
      var strip = 0;
      if (version == 4) {
        var byte = bytes[offset++];
        strip = byte & 0x7f;
        while ((byte & 0x80) != 0) {
          byte = bytes[offset++];
          strip = ((strip + 1) << 7) + (byte & 0x7f);
          if (strip > previous.length) return false;
        }
        if (strip > previous.length) return false;
      }
      final pathStart = offset;
      while (bytes[offset++] != 0) {}
      // Latin-1 is a lossless byte key, not a filesystem-path decoder. This
      // preserves unrelated non-UTF8 index names without inventing aliases.
      final path =
          '${version == 4 ? previous.substring(0, previous.length - strip) : ''}${latin1.decode(bytes.sublist(pathStart, offset - 1))}';
      if (path.length > 4096 ||
          (pathBytes += path.length) > _maximumReviewMetadataBytes) {
        return false;
      }
      _validatePath(path);
      final key = (path: path, stage: (flags >> 12) & 3);
      if (entries?.containsKey(key) ?? false) return false;
      entries?[key] = Uint8List.sublistView(bytes, start, headerEnd);
      previous = path;
      if (version != 4) offset = start + ((offset - start + 7) ~/ 8) * 8;
      if (offset > end) return false;
    }
    while (offset < end) {
      final signature = ascii.decode(
        bytes.sublist(offset, offset + 4),
        allowInvalid: true,
      );
      final size = data.getUint32(offset + 4);
      if (!const {'TREE', 'REUC'}.contains(signature)) return false;
      offset += 8 + size;
    }
  } on RangeError {
    return false;
  } on ChangeSetFailure {
    return false;
  }
  if (offset != end) return false;
  final hash = hashBytes == 32 ? sha256 : sha1;
  return _bytesEqual(
    hash.convert(bytes.sublist(0, end)).bytes,
    bytes.sublist(end),
  );
}
