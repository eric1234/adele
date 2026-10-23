part of 'git_portable_unstaged_snapshot.dart';

/// Hunk, complete-file or complete-layer index mutation through one captured grant.
/// Used by the stock contextual dispatcher and independent compatible consumers.
final class GitPortableReviewApprovalService
    implements ReviewApprovalHandlerService {
  GitPortableReviewApprovalService({
    required AuthorizedEnvironmentBufferedProcessService processes,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) : _inspection = GitPortableUnstagedSnapshotService(
         processes: processes,
         limits: limits,
       );

  final GitPortableUnstagedSnapshotService _inspection;

  @override
  Future<void> approveAllUnstaged(ReviewLayerSelection selection) =>
      _mutate(null, selection.expectedRevision, reverse: false);

  @override
  Future<void> unapproveAllStaged(ReviewLayerSelection selection) =>
      _mutate(null, selection.expectedRevision, reverse: true);

  @override
  Future<void> approveFile(ReviewFileSelection selection) => _mutate(
    selection.relativePath,
    selection.expectedRevision,
    reverse: false,
  );

  @override
  Future<void> unapproveFile(ReviewFileSelection selection) => _mutate(
    selection.relativePath,
    selection.expectedRevision,
    reverse: true,
  );

  @override
  Future<void> approveHunk(ReviewHunkSelection selection) => _mutate(
    selection.relativePath,
    selection.expectedRevision,
    hunkIndex: selection.hunkIndex,
    reverse: false,
  );

  @override
  Future<void> unapproveHunk(ReviewHunkSelection selection) => _mutate(
    selection.relativePath,
    selection.expectedRevision,
    hunkIndex: selection.hunkIndex,
    reverse: true,
  );

  Future<void> _mutate(
    String? path,
    String expectedRevision, {
    int? hunkIndex,
    required bool reverse,
  }) async {
    final operation = _PortableSnapshot(
      _inspection.processes,
      _inspection.limits,
    );
    var confirmedFailure = false;
    Future<void> run() async {
      // Native decoding validates too; do not rely on an interpreted constructor.
      try {
        if (path == null) {
          ReviewLayerSelection(expectedRevision: expectedRevision);
        } else if (hunkIndex == null) {
          ReviewFileSelection(
            relativePath: path,
            expectedRevision: expectedRevision,
          );
        } else {
          ReviewHunkSelection(
            relativePath: path,
            hunkIndex: hunkIndex,
            expectedRevision: expectedRevision,
          );
        }
      } on ArgumentError {
        throw _reviewFailure(
          'invalid_selection',
          'The review selection is invalid.',
        );
      }
      if (path != null && !_reviewablePath(path)) {
        throw _reviewFailure(
          'unsupported_target',
          'Control-character filenames are not review targets.',
        );
      }
      final identity = path == null
          ? await operation.processes.capturedIdentity()
          : null;
      final snapshot = await operation.snapshot(
        includeStaged: reverse,
        includeCommitted: false,
        taskAnchor: null,
        selectedPath: path,
      );
      final layer = reverse
          ? snapshot.uncommitted.staged
          : snapshot.uncommitted.unstaged;
      final files = layer.files;
      if (files.isEmpty) {
        throw _reviewFailure(
          'stale_selection',
          'The selected change is no longer present. Refresh the snapshot.',
        );
      }
      final revision = path == null
          ? layer.layerReviewRevision
          : hunkIndex == null
          ? files.single.fileReviewRevision
          : files.single.reviewRevision;
      if (revision == null) {
        throw _reviewFailure(
          'unsupported_target',
          'The complete selection is not an eligible text review target.',
        );
      }
      if (expectedRevision != revision) {
        throw _reviewFailure(
          'stale_selection',
          'The selected change or comparison changed. Refresh the snapshot.',
        );
      }
      if (hunkIndex != null && hunkIndex >= files.single.hunks.length) {
        throw _reviewFailure(
          'hunk_unavailable',
          'The selected hunk does not exist.',
        );
      }
      final observation = operation.reviewObservation!;
      if (identity != null &&
          (identity.sessionId != observation.identity.sessionId ||
              identity.environmentId != observation.identity.environmentId)) {
        throw _changed();
      }
      final targets = <String, _ReviewTarget>{};
      final patch = <int>[];
      var zeroContext = false;
      for (final file in files) {
        final selectedPath = file.relativePath;
        final entry = observation.entries[selectedPath];
        final addition = file.changeKind == 'added';
        final deletion = file.changeKind == 'deleted';
        final before = (await operation.blob(entry?.oid ?? ''))!;
        final hunks = hunkIndex == null ? file.hunks : [file.hunks[hunkIndex]];
        final after = _applyReviewHunks(before, hunks, reverse: reverse);
        if (after.length > operation.limits.fileBytes ||
            (!addition && !deletion && _equalBytes(before, after))) {
          throw _reviewFailure(
            'unsupported_target',
            'The selection has no bounded index result.',
          );
        }
        final expectedOid = (addition && reverse) || (deletion && !reverse)
            ? null
            : _blobHash(after, observation.head.commit.length);
        if (hunkIndex == null &&
            expectedOid !=
                (reverse
                    ? observation.headEntries[selectedPath]?.oid
                    : operation.workingOids[selectedPath])) {
          throw _malformed();
        }
        if (addition && reverse && after.isNotEmpty) throw _malformed();
        if (deletion && !reverse && after.isNotEmpty) throw _malformed();
        final mode =
            entry?.oldMode ??
            (deletion
                ? observation.headEntries[selectedPath]!.oldMode
                : (operation.observed[selectedPath]!.executable
                      ? '100755'
                      : '100644'));
        targets[selectedPath] = (
          file: file,
          before: before,
          after: after,
          original: entry == null ? null : (mode: mode, oid: entry.oid),
          expected: expectedOid == null ? null : (mode: mode, oid: expectedOid),
        );
        patch.addAll(
          _reviewPatch(
            '${operation.repository!.prefix}$selectedPath',
            hunks,
            mode: mode,
            beforeOid: entry?.oid ?? '0' * observation.head.commit.length,
            afterOid: expectedOid ?? '0' * observation.head.commit.length,
            reverse: reverse,
            isolated: hunkIndex != null,
            addition: addition,
            deletion: deletion,
          ),
        );
        if (patch.length > environmentBufferedProcessStdinLimit) {
          throw _reviewFailure(
            'unsupported_target',
            'The combined patch exceeds its input bound.',
          );
        }
        zeroContext |= hunks.any(
          (hunk) => !hunk.lines.any((line) => line.kind == 'context'),
        );
      }
      final arguments = [
        '-c',
        'apply.ignoreWhitespace=false',
        'apply',
        '--cached',
        '--whitespace=nowarn',
        '--no-ignore-whitespace',
        '-p1',
        if (reverse) '--reverse',
        if (zeroContext) '--unidiff-zero',
      ];
      final budget = _reviewVerificationBudget(
        operation,
        observation,
        files,
        blobBytes: targets.values.fold<int>(
          0,
          (sum, target) =>
              sum +
              (target.after.length > target.before.length
                  ? target.after.length
                  : target.before.length),
        ),
        wholeLayer: path == null,
      );
      void reserve(int verifications, int applies) {
        if (operation.byteCount +
                    applies * patch.length +
                    verifications * budget.bytes >
                operation.limits.totalBytes ||
            operation.commandCount +
                    applies +
                    verifications * budget.processes >
                operation.limits.processes) {
          throw _reviewFailure(
            'inspection_failed',
            'The review operation has insufficient verification budget.',
          );
        }
      }

      reserve(2, 2);
      await operation.git([...arguments, '--check', '--', '-'], input: patch);
      await _verifyReviewState(
        operation,
        observation,
        targets,
        expectUnchangedIndex: true,
        wholeLayer: path == null,
      );
      // Reserve the known postcondition traffic before admitting any write.
      // External growth can still exceed it; such effects are then uncertain.
      reserve(1, 1);
      final applied = await operation.git(
        [...arguments, '--', '-'],
        input: patch,
        indexMutation: true,
      );
      await _verifyReviewState(
        operation,
        observation,
        targets,
        applied: applied.exitCode == 0,
        verifyBlobs: true,
        expectUnchangedIndex: applied.exitCode != 0,
        wholeLayer: path == null,
      );
      if (applied.exitCode != 0) {
        confirmedFailure = true;
        throw _reviewFailure(
          'mutation_failed',
          'Git rejected the index update; the observed index is unchanged.',
        );
      }
      operation.checkOpen();
    }

    try {
      await run().timeout(operation.limits.operationTimeout);
    } catch (error) {
      if (operation.mutationAttempted && !confirmedFailure) {
        throw _reviewFailure(
          'outcome_uncertain',
          'The index mutation was attempted but its final effect could not be confirmed. Refresh the snapshot before another action.',
        );
      }
      if (error is ReviewApprovalFailure) rethrow;
      if (error is TimeoutException ||
          error is ChangeSetFailure && error.code == 'operation_timeout') {
        throw _reviewFailure(
          'operation_timeout',
          'The review operation exceeded its deadline before mutation.',
        );
      }
      if (error is ChangeSetFailure && error.code == 'snapshot_changed') {
        throw _reviewFailure(
          'stale_selection',
          'The observed file or repository changed. Refresh the snapshot.',
        );
      }
      throw _reviewFailure(
        'inspection_failed',
        'The selected Environment could not complete review inspection.',
      );
    } finally {
      // No unary cancellation or rollback is implied. Fence all late continuation.
      operation.closed = true;
    }
  }
}

typedef _ReviewTarget = ({
  ChangedFile file,
  List<int> before,
  List<int> after,
  ({String mode, String oid})? original,
  ({String mode, String oid})? expected,
});

Future<void> _verifyReviewState(
  _PortableSnapshot operation,
  _ReviewObservation observation,
  Map<String, _ReviewTarget> targets, {
  bool applied = false,
  bool verifyBlobs = false,
  bool expectUnchangedIndex = false,
  bool wholeLayer = false,
}) async {
  final raw = await _readReviewIndex(operation);
  if (expectUnchangedIndex && raw != observation.index) {
    throw _changed();
  }
  final entries = parseGitIndex(
    raw,
    maximumEntries: operation.limits.inventoryEntries,
  );
  final beforeEntries = parseGitIndex(
    observation.index,
    maximumEntries: operation.limits.inventoryEntries,
  );
  final repositoryPaths = {
    for (final path in targets.keys) '${operation.repository!.prefix}$path',
  };
  final expectedCount =
      beforeEntries.length -
      repositoryPaths.where(beforeEntries.containsKey).length +
      targets.values
          .where(
            (target) => (applied ? target.expected : target.original) != null,
          )
          .length;
  if (entries.length != expectedCount ||
      _otherIndexRecords(raw, repositoryPaths) !=
          _otherIndexRecords(observation.index, repositoryPaths)) {
    throw _changed();
  }
  for (final entry in targets.entries) {
    final expected = applied ? entry.value.expected : entry.value.original;
    final selected = entries['${operation.repository!.prefix}${entry.key}'];
    if (expected == null
        ? selected != null
        : selected !=
              (
                oldMode: expected.mode,
                newMode: expected.mode,
                oid: expected.oid,
                kind: 'modified',
              )) {
      throw _changed();
    }
    // Hash-checked bytes prove each actual index blob, not just its header.
    if (verifyBlobs && expected != null) {
      final actual = await operation.blob(expected.oid);
      final expectedBytes = applied ? entry.value.after : entry.value.before;
      if (actual == null || !_equalBytes(actual, expectedBytes)) {
        throw _changed();
      }
    }
  }
  await operation.verifyMetadata(operation.observed.keys.toList());
  for (final entry in targets.entries) {
    final path = entry.key;
    if (entry.value.file.changeKind == 'deleted') {
      if (operation.workingAbsences[path] == null ||
          await operation.workingAbsence(path) !=
              operation.workingAbsences[path]) {
        throw _changed();
      }
    } else {
      final working = (await operation.command('/usr/bin/head', [
        '-c',
        '${operation.limits.fileBytes + 1}',
        '--',
        './$path',
      ])).bytes;
      if (working.length != operation.observed[path]!.size ||
          _blobHash(working, observation.head.commit.length) !=
              operation.workingOids[path]) {
        throw _changed();
      }
    }
  }
  await operation.verifyMetadata(operation.observed.keys.toList());
  for (final entry in targets.entries) {
    final path = entry.key;
    if (entry.value.file.changeKind == 'added') {
      if (!await _reviewAdditionPathSafe(operation, path)) throw _changed();
      if ((applied ? entry.value.expected : entry.value.original) == null &&
          !_equalBytes(
            (await operation.git([
              'ls-files',
              '--others',
              '--exclude-standard',
              '-z',
              '--',
              './$path',
            ])).bytes,
            utf8.encode('$path\u0000'),
          )) {
        throw _changed();
      }
    }
    if (await operation.readAttributes(path) != operation.attributes[path]) {
      throw _changed();
    }
  }
  if (wholeLayer) {
    final inventory = await operation.enumerate();
    if (!applied) {
      if (inventory != observation.inventory) throw _changed();
    } else {
      // Index membership transitions alter only these two working inventories.
      // New or missing unrelated paths cannot silently shrink an All operation.
      final untracked = _records(observation.inventory.untracked).toSet();
      final deleted = _records(observation.inventory.deleted).toSet();
      for (final entry in targets.entries) {
        if (entry.value.file.changeKind == 'added') {
          if (entry.value.expected == null) {
            untracked.add(entry.key);
          } else {
            untracked.remove(entry.key);
          }
        } else if (entry.value.file.changeKind == 'deleted') {
          if (entry.value.expected == null) {
            deleted.remove(entry.key);
          } else {
            deleted.add(entry.key);
          }
        }
      }
      String sorted(Iterable<String> paths) =>
          (paths.toList()..sort()).join('\u0000');
      if (sorted(_records(inventory.untracked)) != sorted(untracked) ||
          sorted(_records(inventory.deleted)) != sorted(deleted) ||
          inventory.killed != observation.inventory.killed) {
        throw _changed();
      }
    }
  }
  if (await operation.readSettings() != observation.settings ||
      await operation.readHead() != observation.head ||
      await operation.discover() != operation.repository) {
    throw _changed();
  }
  final identity = await operation.processes.capturedIdentity();
  if (identity.environmentId != observation.identity.environmentId ||
      identity.sessionId != observation.identity.sessionId) {
    throw _changed();
  }
  if (await _readReviewIndex(operation) != raw) {
    throw _changed();
  }
  for (final entry in targets.entries) {
    if (entry.value.file.changeKind == 'deleted' &&
        await operation.workingAbsence(entry.key) !=
            operation.workingAbsences[entry.key]) {
      throw _changed();
    }
  }
  operation.checkOpen();
}

// Index mutation is repository-wide even when presentation is source-scoped.
Future<String> _readReviewIndex(_PortableSnapshot operation) async => _decode(
  (await operation.git([
    '-C',
    operation.repository!.worktree,
    'ls-files',
    '--cached',
    '--stage',
    '--debug',
    '-z',
    '--',
    '.',
  ])).bytes,
);

// Both inputs have already passed parseGitIndex. Preserve every unrelated stage,
// flag and stat record, including conflict sides collapsed by its display map.
String _otherIndexRecords(String raw, Set<String> selectedPaths) {
  final result = StringBuffer();
  var start = 0;
  while (start < raw.length) {
    final nul = raw.indexOf('\u0000', start);
    final tab = raw.indexOf('\t', start);
    var end = nul + 1;
    for (var line = 0; line < 5; line++) {
      end = raw.indexOf('\n', end) + 1;
    }
    if (!selectedPaths.contains(raw.substring(tab + 1, nul))) {
      result.write(raw.substring(start, end));
    }
    start = end;
  }
  return result.toString();
}

List<int> _applyReviewHunks(
  List<int> before,
  List<DiffHunk> hunks, {
  required bool reverse,
}) {
  final text = _decodeContent(before);
  final lines = <String>[];
  var offset = 0;
  while (offset < text.length) {
    final newline = text.indexOf('\n', offset);
    final end = newline < 0 ? text.length : newline + 1;
    lines.add(text.substring(offset, end));
    offset = end;
  }
  final result = StringBuffer();
  var consumed = 0;
  for (final hunk in hunks) {
    final count = reverse ? hunk.newCount : hunk.oldCount;
    final start =
        (reverse ? hunk.newStart : hunk.oldStart) - (count == 0 ? 0 : 1);
    if (start < consumed || start + count > lines.length) throw _malformed();
    result.writeAll(lines.getRange(consumed, start));
    var source = start;
    for (final line in hunk.lines) {
      final value = '${line.text}${line.noNewline ? '' : '\n'}';
      if (line.kind != (reverse ? 'deletion' : 'addition')) {
        if (source >= lines.length || lines[source++] != value) {
          throw _malformed();
        }
      }
      if (line.kind != (reverse ? 'addition' : 'deletion')) {
        result.write(value);
      }
    }
    if (source != start + count) throw _malformed();
    consumed = source;
  }
  result.writeAll(lines.skip(consumed));
  return utf8.encode(result.toString());
}

List<int> _reviewPatch(
  String path,
  List<DiffHunk> hunks, {
  required String mode,
  required String beforeOid,
  required String afterOid,
  required bool reverse,
  required bool isolated,
  bool addition = false,
  bool deletion = false,
}) {
  final oldPath = _quoteReviewPath('a/$path');
  final newPath = _quoteReviewPath('b/$path');
  final patch = StringBuffer()..writeln('diff --git $oldPath $newPath');
  if (addition) patch.writeln('new file mode $mode');
  if (deletion) patch.writeln('deleted file mode $mode');
  patch
    ..writeln(
      'index ${reverse ? afterOid : beforeOid}..${reverse ? beforeOid : afterOid}${addition || deletion ? '' : ' $mode'}',
    )
    ..writeln('--- ${addition ? '/dev/null' : oldPath}')
    ..writeln('+++ ${deletion ? '/dev/null' : newPath}');
  for (final hunk in hunks) {
    // Only an isolated hunk needs rebasing to its actual source-side coordinate.
    // A complete patch must retain original coordinates across all line shifts.
    final sourceCount = reverse ? hunk.newCount : hunk.oldCount;
    final offset =
        (reverse ? hunk.newStart : hunk.oldStart) - (sourceCount == 0 ? 0 : 1);
    final oldStart = isolated
        ? offset + (hunk.oldCount == 0 ? 0 : 1)
        : hunk.oldStart;
    final newStart = isolated
        ? offset + (hunk.newCount == 0 ? 0 : 1)
        : hunk.newStart;
    patch.writeln(
      '@@ -$oldStart,${hunk.oldCount} +$newStart,${hunk.newCount} @@',
    );
    for (final line in hunk.lines) {
      patch.writeln(
        '${switch (line.kind) {
          'context' => ' ',
          'addition' => '+',
          'deletion' => '-',
          _ => throw _malformed(),
        }}${line.text}',
      );
      if (line.noNewline) patch.writeln(r'\ No newline at end of file');
    }
  }
  return utf8.encode(patch.toString());
}

String _quoteReviewPath(String path) {
  final quoted = StringBuffer('"');
  for (final byte in utf8.encode(path)) {
    if (byte == 0x22 || byte == 0x5c) {
      quoted.write('\\${String.fromCharCode(byte)}');
    } else if (byte < 0x20 || byte >= 0x7f) {
      quoted.write('\\${byte.toRadixString(8).padLeft(3, '0')}');
    } else {
      quoted.writeCharCode(byte);
    }
  }
  return '$quoted"';
}

ReviewApprovalFailure _reviewFailure(String code, String message) =>
    ReviewApprovalFailure(code: code, message: message);

final class _ReviewObservation {
  _ReviewObservation({
    required this.identity,
    required this.head,
    required this.index,
    required this.entries,
    required this.headEntries,
    required this.settings,
    required this.inventory,
  });

  final AuthorizedEnvironmentIdentity identity;
  final ({String commit, String reference}) head;
  final String index;
  final Map<String, GitIndexEntry> entries;
  final Map<String, GitIndexEntry> headEntries;
  final String settings;
  final _Inventory inventory;
  late final String indexRevision = sha256
      .convert(utf8.encode(index))
      .toString();
}

// Compute known verification work without another repository inspection. Reserve
// both success and rejected-write postconditions, including index growth.
({int bytes, int processes}) _reviewVerificationBudget(
  _PortableSnapshot operation,
  _ReviewObservation observation,
  List<ChangedFile> files, {
  required int blobBytes,
  required bool wholeLayer,
}) {
  final indexCopies = wholeLayer ? 3 : 2;
  var bytes =
      indexCopies * utf8.encode(observation.index).length +
      utf8.encode(observation.settings).length +
      blobBytes +
      8192 +
      2 * utf8.encode(operation.repository.toString()).length +
      2 *
          operation.observed.entries.fold<int>(
            0,
            (sum, entry) =>
                sum +
                utf8
                    .encode(
                      './${entry.key}\u0000${entry.value.description}\u0000',
                    )
                    .length,
          );
  final statBatches = operation.pathBatches(
    operation.observed.keys.toList(),
    '/usr/bin/stat',
    const [r'--printf=%n\0%f %s %d %i %y %z\0', '--'],
  ).length;
  // Two index reads, settings, HEAD/ref, discovery, and per-file blob/working/attrs.
  var processes = 10 + 2 * statBatches + 4 * files.length;
  if (wholeLayer) {
    processes += 4;
    bytes +=
        utf8.encode(observation.inventory.untracked).length +
        utf8.encode(observation.inventory.deleted).length +
        utf8.encode(observation.inventory.killed).length;
  }
  for (final file in files) {
    final path = file.relativePath;
    bytes +=
        utf8.encode(operation.attributes[path]!).length +
        (operation.observed[path]?.size ?? 0) +
        2 * utf8.encode(operation.workingAbsences[path] ?? '').length;
    if (file.changeKind == 'added' || file.changeKind == 'deleted') {
      processes += 3;
      bytes +=
          (indexCopies + 1) *
          (utf8.encode('${operation.repository!.prefix}$path').length + 512);
    }
  }
  return (bytes: bytes, processes: processes);
}

// Complete operations include sequential inspection and two verification passes.
// Keep headroom inside the shared 30-second deadline; this is not a latency SLA.
const _maximumLayerReviewFiles = 16;

String? _layerReviewRevision(
  _PortableSnapshot operation,
  List<ChangedFile> files, {
  required bool reverse,
}) {
  final observation = operation.reviewObservation;
  if (observation == null ||
      files.isEmpty ||
      files.length > _maximumLayerReviewFiles ||
      files.any((file) => file.fileReviewRevision == null)) {
    return null;
  }
  final sorted = files.toList()
    ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
  var patchBytes = 0;
  var beforeBytes = 0;
  var blobBytes = 0;
  var insertions = 0;
  var growth = 0;
  var untrackedBytes = utf8.encode(observation.inventory.untracked).length;
  var deletedBytes = utf8.encode(observation.inventory.deleted).length;
  for (final file in sorted) {
    final path = file.relativePath;
    final beforeOid = observation.entries[path]?.oid;
    final afterOid = reverse
        ? observation.headEntries[path]?.oid
        : operation.workingOids[path];
    final before = beforeOid == null ? 0 : operation.objectSizes[beforeOid];
    final after = afterOid == null
        ? 0
        : reverse
        ? operation.objectSizes[afterOid]
        : operation.observed[path]?.size;
    if (before == null ||
        after == null ||
        _reviewPathCollision(path, sorted.map((file) => file.relativePath))) {
      return null;
    }
    beforeBytes += before;
    blobBytes += before > after ? before : after;
    patchBytes += _reviewPatchBound(file, operation.repository!.prefix);
    if (beforeOid == null && afterOid != null) {
      insertions++;
      growth +=
          utf8.encode('${operation.repository!.prefix}$path').length + 512;
    }
    if (reverse && file.changeKind == 'added') {
      untrackedBytes += utf8.encode(path).length + 1;
    } else if (reverse && file.changeKind == 'deleted') {
      deletedBytes += utf8.encode(path).length + 1;
    }
  }
  if (patchBytes > environmentBufferedProcessStdinLimit ||
      '\u0000'.allMatches(observation.index).length + insertions >
          operation.limits.inventoryEntries ||
      utf8.encode(observation.index).length + growth >
          operation.limits.outputBytes ||
      untrackedBytes > operation.limits.outputBytes ||
      deletedBytes > operation.limits.outputBytes) {
    return null;
  }
  final budget = _reviewVerificationBudget(
    operation,
    observation,
    sorted,
    blobBytes: blobBytes,
    wholeLayer: true,
  );
  // Construction rereads original blobs; check and apply share the same stdin.
  // Preflight and postflight share the original operation's remaining budgets.
  if (operation.byteCount +
              beforeBytes +
              64 * files.length +
              2 * patchBytes +
              2 * budget.bytes >
          operation.limits.totalBytes ||
      operation.commandCount + 2 * files.length + 2 + 2 * budget.processes >
          operation.limits.processes) {
    return null;
  }
  final layer = reverse ? 'staged' : 'unstaged';
  const domain = 'git-layer-review-v1';
  final repo = operation.repository!;
  final digest = sha256.convert(
    utf8.encode(
      jsonEncode([
        domain,
        layer,
        observation.identity.sessionId,
        observation.identity.environmentId,
        repo.root,
        repo.worktree,
        repo.directory,
        repo.prefix,
        observation.head.commit,
        observation.head.reference,
        observation.indexRevision,
        for (final file in sorted)
          [
            file.relativePath,
            file.changeKind,
            file.fileReviewRevision,
            operation.observed[file.relativePath]?.description,
          ],
      ]),
    ),
  );
  return '$domain:$layer:$digest';
}

int _reviewPatchBound(ChangedFile file, String prefix) {
  // Four quoted headers, worst-case octal UTF-8 escaping, and fixed metadata.
  var size = 512 + 16 * utf8.encode('$prefix${file.relativePath}').length;
  for (final hunk in file.hunks) {
    size += 128;
    for (final line in hunk.lines) {
      size += utf8.encode(line.text).length + 2 + (line.noNewline ? 28 : 0);
    }
  }
  return size;
}

bool _reviewablePath(String path) =>
    path.length <= 4096 &&
    !path.split('/').contains('.git') &&
    !path.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _reviewPathCollision(String path, Iterable<String> paths) => paths.any(
  (other) => other.startsWith('$path/') || path.startsWith('$other/'),
);

Future<bool> _reviewAdditionPathSafe(
  _PortableSnapshot operation,
  String path,
) async {
  final ignored = await operation.git([
    'ls-files',
    '--cached',
    '--others',
    '--ignored',
    '--exclude-standard',
    '-z',
    '--',
    './$path',
  ]);
  if (ignored.bytes.isNotEmpty) return false;
  if (!path.contains('/')) return true;
  // All parent directories have already been observed without following links.
  // Fixed shell code inspects literal argv, never interpolated filenames.
  final boundary = await operation.command('/bin/sh', [
    '-c',
    r'path=$1; while [ "${path%/*}" != "$path" ]; do path=${path%/*}; if [ -e "$path/.git" ] || [ -L "$path/.git" ]; then exit 1; fi; done',
    'adele-review-parents',
    path,
  ], allowDifference: true);
  if (boundary.bytes.isNotEmpty) throw _malformed();
  return boundary.exitCode == 0;
}

bool _reviewableFile(
  ChangedFile file,
  String prefix, {
  required int? indexBytes,
  required int maximumFileBytes,
  required bool reverse,
  bool wholeFile = false,
}) {
  final addition = wholeFile && file.changeKind == 'added';
  final deletion = wholeFile && file.changeKind == 'deleted';
  if ((!addition && !deletion && file.changeKind != 'modified') ||
      file.contentStatus != 'text' ||
      (!addition && !deletion && file.hunks.isEmpty) ||
      file.hunks.length > 8192 ||
      !_reviewablePath(file.relativePath) ||
      indexBytes == null) {
    return false;
  }
  // Four quoted headers, worst-case octal UTF-8 escaping, and fixed metadata.
  final metadata = 512 + 16 * utf8.encode('$prefix${file.relativePath}').length;
  var aggregateDelta = 0;
  for (final hunk in file.hunks) {
    var size = metadata;
    var delta = 0;
    for (final line in hunk.lines) {
      final bytes = utf8.encode(line.text).length;
      size += bytes + 2 + (line.noNewline ? 28 : 0);
      if (line.kind != 'context') {
        delta +=
            (bytes + (line.noNewline ? 0 : 1)) *
            (line.kind == 'addition' ? 1 : -1);
      }
    }
    final resultBytes = indexBytes + (reverse ? -delta : delta);
    if (!wholeFile &&
        (size > environmentBufferedProcessStdinLimit ||
            resultBytes < 0 ||
            resultBytes > maximumFileBytes)) {
      return false;
    }
    aggregateDelta += delta;
  }
  final resultBytes = indexBytes + (reverse ? -aggregateDelta : aggregateDelta);
  return !wholeFile ||
      (_reviewPatchBound(file, prefix) <=
              environmentBufferedProcessStdinLimit &&
          resultBytes >= 0 &&
          resultBytes <= maximumFileBytes);
}

String _reviewRevision(
  _PortableSnapshot operation,
  _ReviewObservation observation,
  String path,
  String layer, {
  bool wholeFile = false,
  bool addition = false,
  bool deletion = false,
}) {
  final domain = deletion
      ? 'git-file-deletion-review-v1'
      : addition
      ? 'git-file-addition-review-v1'
      : wholeFile
      ? 'git-file-review-v1'
      : 'git-review-v1';
  final repo = operation.repository!;
  final entry = observation.entries[path];
  final digest = sha256.convert(
    utf8.encode(
      jsonEncode([
        domain,
        layer,
        observation.identity.sessionId,
        observation.identity.environmentId,
        repo.root,
        repo.worktree,
        repo.directory,
        repo.prefix,
        path,
        observation.head.commit,
        observation.head.reference,
        entry?.oldMode,
        entry?.oid,
        entry?.kind,
        observation.indexRevision,
        operation.workingOids[path],
        operation.observed[path]?.mode,
        if (deletion) ...[
          observation.headEntries[path]?.oldMode,
          observation.headEntries[path]?.oid,
          operation.workingAbsences[path],
        ],
        observation.settings,
        operation.attributes[path],
      ]),
    ),
  );
  return '$domain:$layer:$digest';
}
