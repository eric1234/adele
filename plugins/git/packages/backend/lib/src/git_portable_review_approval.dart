part of 'git_portable_unstaged_snapshot.dart';

/// Explicit hunk or complete-file index mutation through one captured grant.
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
    String path,
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
        if (hunkIndex == null) {
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
      if (!_reviewablePath(path)) {
        throw _reviewFailure(
          'unsupported_target',
          'Control-character filenames are not review targets.',
        );
      }
      final snapshot = await operation.snapshot(
        includeStaged: reverse,
        includeCommitted: false,
        taskAnchor: null,
        selectedPath: path,
      );
      final files = reverse
          ? snapshot.uncommitted.staged.files
          : snapshot.uncommitted.unstaged.files;
      if (files.isEmpty) {
        throw _reviewFailure(
          'stale_selection',
          'The selected change is no longer present. Refresh the snapshot.',
        );
      }
      final file = files.single;
      final revision = hunkIndex == null
          ? file.fileReviewRevision
          : file.reviewRevision;
      if (revision == null) {
        throw _reviewFailure(
          'unsupported_target',
          'The selected file is not an eligible text review target.',
        );
      }
      if (expectedRevision != revision) {
        throw _reviewFailure(
          'stale_selection',
          'The selected file or comparison changed. Refresh the snapshot.',
        );
      }
      if (hunkIndex != null && hunkIndex >= file.hunks.length) {
        throw _reviewFailure(
          'hunk_unavailable',
          'The selected hunk does not exist.',
        );
      }
      final observation = operation.reviewObservation!;
      final entry = observation.entries[path];
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
                  ? observation.headEntries[path]?.oid
                  : operation.workingOids[path])) {
        throw _malformed();
      }
      if (addition && reverse && after.isNotEmpty) throw _malformed();
      if (deletion && !reverse && after.isNotEmpty) throw _malformed();
      final mode =
          entry?.oldMode ??
          (deletion
              ? observation.headEntries[path]!.oldMode
              : (operation.observed[path]!.executable ? '100755' : '100644'));
      final original = entry == null ? null : (mode: mode, oid: entry.oid);
      final expected = expectedOid == null
          ? null
          : (mode: mode, oid: expectedOid);
      final patch = _reviewPatch(
        '${operation.repository!.prefix}$path',
        hunks,
        mode: mode,
        beforeOid: entry?.oid ?? '0' * observation.head.commit.length,
        afterOid: expectedOid ?? '0' * observation.head.commit.length,
        reverse: reverse,
        isolated: hunkIndex != null,
        addition: addition,
        deletion: deletion,
      );
      if (patch.length > environmentBufferedProcessStdinLimit) {
        throw _reviewFailure(
          'unsupported_target',
          'The selected patch exceeds its input bound.',
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
        if (hunks.any(
          (hunk) => !hunk.lines.any((line) => line.kind == 'context'),
        ))
          '--unidiff-zero',
      ];
      await operation.git([...arguments, '--check', '--', '-'], input: patch);
      await _verifyReviewState(
        operation,
        observation,
        path,
        original,
        expectUnchangedIndex: true,
        addition: addition,
        deletion: deletion,
      );
      // Reserve the known postcondition traffic before admitting any write.
      // External growth can still exceed it; such effects are then uncertain.
      final verificationBytes =
          2 * utf8.encode(observation.index).length +
          utf8.encode(observation.settings).length +
          utf8.encode(operation.attributes[path]!).length +
          (after.length > before.length ? after.length : before.length) +
          (operation.observed[path]?.size ?? 0) +
          2 * utf8.encode(operation.workingAbsences[path] ?? '').length +
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
              ) +
          8192 +
          (addition || deletion
              ? 2 *
                    (utf8
                            .encode('${operation.repository!.prefix}$path')
                            .length +
                        512)
              : 0) +
          2 * utf8.encode(operation.repository.toString()).length;
      final statBatches = operation.pathBatches(
        operation.observed.keys.toList(),
        '/usr/bin/stat',
        const [r'--printf=%n\0%f %s %d %i %y %z\0', '--'],
      ).length;
      if (operation.byteCount + patch.length + verificationBytes >
              operation.limits.totalBytes ||
          operation.commandCount +
                  15 +
                  2 * statBatches +
                  (addition || deletion ? 3 : 0) >
              operation.limits.processes) {
        throw _reviewFailure(
          'inspection_failed',
          'The review operation has insufficient verification budget.',
        );
      }
      final applied = await operation.git(
        [...arguments, '--', '-'],
        input: patch,
        indexMutation: true,
      );
      await _verifyReviewState(
        operation,
        observation,
        path,
        applied.exitCode == 0 ? expected : original,
        expectedBytes: applied.exitCode == 0 ? after : before,
        expectUnchangedIndex: applied.exitCode != 0,
        addition: addition,
        deletion: deletion,
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

Future<void> _verifyReviewState(
  _PortableSnapshot operation,
  _ReviewObservation observation,
  String path,
  ({String mode, String oid})? expected, {
  List<int>? expectedBytes,
  bool expectUnchangedIndex = false,
  bool addition = false,
  bool deletion = false,
}) async {
  final raw = await _readReviewIndex(operation);
  final repositoryPath = '${operation.repository!.prefix}$path';
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
  final expectedCount =
      beforeEntries.length -
      (beforeEntries.containsKey(repositoryPath) ? 1 : 0) +
      (expected == null ? 0 : 1);
  if (entries.length != expectedCount ||
      _otherIndexRecords(raw, repositoryPath) !=
          _otherIndexRecords(observation.index, repositoryPath)) {
    throw _changed();
  }
  final selected = entries[repositoryPath];
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
  // Hash-checked object bytes prove the actual index content, not just its header.
  if (expectedBytes != null && expected != null) {
    final actual = await operation.blob(expected.oid);
    if (actual == null || !_equalBytes(actual, expectedBytes)) throw _changed();
  }
  await operation.verifyMetadata(operation.observed.keys.toList());
  if (deletion) {
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
  await operation.verifyMetadata(operation.observed.keys.toList());
  if (addition) {
    if (!await _reviewAdditionPathSafe(operation, path)) throw _changed();
    if (expected == null &&
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
  if (await operation.readAttributes(path) != operation.attributes[path] ||
      await operation.readSettings() != observation.settings ||
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
  if (deletion &&
      await operation.workingAbsence(path) != operation.workingAbsences[path]) {
    throw _changed();
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
String _otherIndexRecords(String raw, String selectedPath) {
  final result = StringBuffer();
  var start = 0;
  while (start < raw.length) {
    final nul = raw.indexOf('\u0000', start);
    final tab = raw.indexOf('\t', start);
    var end = nul + 1;
    for (var line = 0; line < 5; line++) {
      end = raw.indexOf('\n', end) + 1;
    }
    if (raw.substring(tab + 1, nul) != selectedPath) {
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
  });

  final AuthorizedEnvironmentIdentity identity;
  final ({String commit, String reference}) head;
  final String index;
  final Map<String, GitIndexEntry> entries;
  final Map<String, GitIndexEntry> headEntries;
  final String settings;
  late final String indexRevision = sha256
      .convert(utf8.encode(index))
      .toString();
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
  var aggregateSize = metadata;
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
    aggregateSize += size - metadata + 128;
    aggregateDelta += delta;
  }
  final resultBytes = indexBytes + (reverse ? -aggregateDelta : aggregateDelta);
  return !wholeFile ||
      (aggregateSize <= environmentBufferedProcessStdinLimit &&
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
