part of 'git_portable_unstaged_snapshot.dart';

/// Explicit single-hunk index mutation through one captured process grant.
/// Implemented for independent consumers; not advertised by stock composition.
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
  Future<void> approveHunk(ReviewHunkSelection selection) =>
      _mutate(selection, reverse: false);

  @override
  Future<void> unapproveHunk(ReviewHunkSelection selection) =>
      _mutate(selection, reverse: true);

  Future<void> _mutate(
    ReviewHunkSelection selection, {
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
        ReviewHunkSelection(
          relativePath: selection.relativePath,
          hunkIndex: selection.hunkIndex,
          expectedRevision: selection.expectedRevision,
        );
      } on ArgumentError {
        throw _reviewFailure(
          'invalid_selection',
          'The review selection is invalid.',
        );
      }
      final path = selection.relativePath;
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
      if (file.reviewRevision == null) {
        throw _reviewFailure(
          'unsupported_target',
          'The selected file is not an eligible tracked text modification.',
        );
      }
      if (selection.expectedRevision != file.reviewRevision) {
        throw _reviewFailure(
          'stale_selection',
          'The selected file or comparison changed. Refresh the snapshot.',
        );
      }
      if (selection.hunkIndex >= file.hunks.length) {
        throw _reviewFailure(
          'hunk_unavailable',
          'The selected hunk does not exist.',
        );
      }
      final observation = operation.reviewObservation!;
      final entry = observation.entries[path]!;
      final before = (await operation.blob(entry.oid))!;
      final hunk = file.hunks[selection.hunkIndex];
      final after = _applyReviewHunk(before, hunk, reverse: reverse);
      if (after.length > operation.limits.fileBytes ||
          _equalBytes(before, after)) {
        throw _reviewFailure(
          'unsupported_target',
          'The selected hunk has no bounded index result.',
        );
      }
      final expectedOid = _blobHash(after, entry.oid.length);
      final patch = _reviewPatch(
        '${operation.repository!.prefix}$path',
        hunk,
        mode: entry.oldMode,
        beforeOid: entry.oid,
        afterOid: expectedOid,
        reverse: reverse,
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
        if (!hunk.lines.any((line) => line.kind == 'context')) '--unidiff-zero',
      ];
      await operation.git([...arguments, '--check', '--', '-'], input: patch);
      await _verifyReviewState(
        operation,
        observation,
        path,
        entry.oid,
        verifyBlob: false,
        expectUnchangedIndex: true,
      );
      // Reserve the known postcondition traffic before admitting any write.
      // External growth can still exceed it; such effects are then uncertain.
      final verificationBytes =
          2 * utf8.encode(observation.inventory.index).length +
          utf8.encode(observation.settings).length +
          utf8.encode(operation.attributes[path]!).length +
          (after.length > before.length ? after.length : before.length) +
          operation.observed[path]!.size +
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
          2 * utf8.encode(operation.repository.toString()).length;
      final statBatches = operation.pathBatches(
        operation.observed.keys.toList(),
        '/usr/bin/stat',
        const [r'--printf=%n\0%f %s %d %i %y %z\0', '--'],
      ).length;
      if (operation.byteCount + patch.length + verificationBytes >
              operation.limits.totalBytes ||
          operation.commandCount + 15 + 2 * statBatches >
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
        applied.exitCode == 0 ? expectedOid : entry.oid,
        expectUnchangedIndex: applied.exitCode != 0,
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
  String expectedOid, {
  bool verifyBlob = true,
  bool expectUnchangedIndex = false,
}) async {
  final raw = _decode(
    (await operation.git([
      'ls-files',
      '--cached',
      '--stage',
      '--debug',
      '-z',
      '--',
      '.',
    ])).bytes,
  );
  if (expectUnchangedIndex && raw != observation.inventory.index) {
    throw _changed();
  }
  final entries = parseGitIndex(
    raw,
    maximumEntries: operation.limits.inventoryEntries,
  );
  final beforeEntries = parseGitIndex(
    observation.inventory.index,
    maximumEntries: operation.limits.inventoryEntries,
  );
  if (entries.length != beforeEntries.length ||
      _otherIndexRecords(raw, path) !=
          _otherIndexRecords(observation.inventory.index, path)) {
    throw _changed();
  }
  for (final original in beforeEntries.entries) {
    final expected = original.value;
    final current = entries[original.key];
    if (current == null ||
        current.kind != expected.kind ||
        current.oldMode != expected.oldMode ||
        current.newMode != expected.newMode ||
        current.oid != (original.key == path ? expectedOid : expected.oid)) {
      throw _changed();
    }
  }
  // Hash-checked object bytes prove the actual index content, not just its header.
  if (verifyBlob && await operation.blob(expectedOid) == null) throw _changed();
  await operation.verifyMetadata(operation.observed.keys.toList());
  final working = (await operation.command('/usr/bin/head', [
    '-c',
    '${operation.limits.fileBytes + 1}',
    '--',
    './$path',
  ])).bytes;
  if (working.length != operation.observed[path]!.size ||
      _blobHash(working, expectedOid.length) != operation.workingOids[path]) {
    throw _changed();
  }
  await operation.verifyMetadata(operation.observed.keys.toList());
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
  if (_decode(
        (await operation.git([
          'ls-files',
          '--cached',
          '--stage',
          '--debug',
          '-z',
          '--',
          '.',
        ])).bytes,
      ) !=
      raw) {
    throw _changed();
  }
  operation.checkOpen();
}

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

List<int> _applyReviewHunk(
  List<int> before,
  DiffHunk hunk, {
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
  final count = reverse ? hunk.newCount : hunk.oldCount;
  final start =
      (reverse ? hunk.newStart : hunk.oldStart) - (count == 0 ? 0 : 1);
  if (start < 0 || start + count > lines.length) throw _malformed();
  final replacement = <String>[];
  var source = start;
  for (final line in hunk.lines) {
    final value = '${line.text}${line.noNewline ? '' : '\n'}';
    if (line.kind != (reverse ? 'deletion' : 'addition')) {
      if (source >= lines.length || lines[source++] != value) {
        throw _malformed();
      }
    }
    if (line.kind != (reverse ? 'addition' : 'deletion')) {
      replacement.add(value);
    }
  }
  if (source != start + count) throw _malformed();
  lines.replaceRange(start, source, replacement);
  return utf8.encode(lines.join());
}

List<int> _reviewPatch(
  String path,
  DiffHunk hunk, {
  required String mode,
  required String beforeOid,
  required String afterOid,
  required bool reverse,
}) {
  // Earlier, unselected hunks may change line counts. Locate this isolated hunk
  // from its actual source side, not the full patch's destination coordinates.
  final sourceCount = reverse ? hunk.newCount : hunk.oldCount;
  final offset =
      (reverse ? hunk.newStart : hunk.oldStart) - (sourceCount == 0 ? 0 : 1);
  final oldStart = offset + (hunk.oldCount == 0 ? 0 : 1);
  final newStart = offset + (hunk.newCount == 0 ? 0 : 1);
  final oldPath = _quoteReviewPath('a/$path');
  final newPath = _quoteReviewPath('b/$path');
  final patch = StringBuffer()
    ..writeln('diff --git $oldPath $newPath')
    ..writeln(
      'index ${reverse ? afterOid : beforeOid}..${reverse ? beforeOid : afterOid} $mode',
    )
    ..writeln('--- $oldPath')
    ..writeln('+++ $newPath')
    ..writeln('@@ -$oldStart,${hunk.oldCount} +$newStart,${hunk.newCount} @@');
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
    required this.inventory,
    required this.entries,
    required this.settings,
  });

  final AuthorizedEnvironmentIdentity identity;
  final ({String commit, String reference}) head;
  final _Inventory inventory;
  final Map<String, GitIndexEntry> entries;
  final String settings;
  late final String indexRevision = sha256
      .convert(utf8.encode(inventory.index))
      .toString();
}

bool _reviewablePath(String path) =>
    path.length <= 4096 && !path.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _reviewableFile(
  ChangedFile file,
  String prefix, {
  required int? indexBytes,
  required int maximumFileBytes,
  required bool reverse,
}) {
  if (file.changeKind != 'modified' ||
      file.contentStatus != 'text' ||
      file.hunks.isEmpty ||
      file.hunks.length > 8192 ||
      !_reviewablePath(file.relativePath) ||
      indexBytes == null) {
    return false;
  }
  // Four quoted headers, worst-case octal UTF-8 escaping, and fixed metadata.
  final metadata = 512 + 16 * utf8.encode('$prefix${file.relativePath}').length;
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
    if (size > environmentBufferedProcessStdinLimit ||
        resultBytes < 0 ||
        resultBytes > maximumFileBytes) {
      return false;
    }
  }
  return true;
}

String _reviewRevision(
  _PortableSnapshot operation,
  _ReviewObservation observation,
  String path,
  String layer,
) {
  final repo = operation.repository!;
  final entry = observation.entries[path]!;
  final digest = sha256.convert(
    utf8.encode(
      jsonEncode([
        'git-review-v1',
        layer,
        observation.identity.environmentId,
        repo.root,
        repo.worktree,
        repo.directory,
        repo.prefix,
        path,
        observation.head.commit,
        observation.head.reference,
        entry.oldMode,
        entry.oid,
        entry.kind,
        observation.indexRevision,
        operation.workingOids[path],
        operation.observed[path]!.mode,
        observation.settings,
        operation.attributes[path],
      ]),
    ),
  );
  return 'git-review-v1:$layer:$digest';
}
