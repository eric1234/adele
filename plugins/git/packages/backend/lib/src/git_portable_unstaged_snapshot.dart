import 'dart:async';
import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

import 'git_snapshot_parsing.dart';

/// Operation-local bounds. Callers may reduce, but never increase, the defaults.
final class GitPortableUnstagedLimits {
  const GitPortableUnstagedLimits({
    this.files = 256,
    this.inventoryEntries = 4096,
    this.fileBytes = 1024 * 1024,
    this.verificationFileBytes = 16 * 1024 * 1024,
    this.verificationTotalBytes = 64 * 1024 * 1024,
    this.outputBytes = 2 * 1024 * 1024,
    this.stderrBytes = 64 * 1024,
    this.totalBytes = 8 * 1024 * 1024,
    this.lines = 8192,
    this.processes = 4096,
    this.processTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 30),
  });

  final int files;
  final int inventoryEntries;
  final int fileBytes;
  final int verificationFileBytes;
  final int verificationTotalBytes;
  final int outputBytes;
  final int stderrBytes;
  final int totalBytes;
  final int lines;
  final int processes;
  final Duration processTimeout;
  final Duration operationTimeout;
}

/// Unstaged and layered Uncommitted inspection using the captured process grant.
///
/// Requires Linux-style /bin/sh, /bin/pwd, and /usr/bin/{env,git,stat,head}
/// in the selected Environment. No host filesystem or provider implementation is
/// consulted. Static path checks are not an OS sandbox or a filesystem transaction.
final class GitPortableUnstagedSnapshotService {
  GitPortableUnstagedSnapshotService({
    required this.processes,
    this.limits = const GitPortableUnstagedLimits(),
  }) {
    const maximum = GitPortableUnstagedLimits();
    for (final (value, bound) in [
      (limits.files, maximum.files),
      (limits.inventoryEntries, maximum.inventoryEntries),
      (limits.fileBytes, maximum.fileBytes),
      (limits.verificationFileBytes, maximum.verificationFileBytes),
      (limits.verificationTotalBytes, maximum.verificationTotalBytes),
      (limits.outputBytes, maximum.outputBytes),
      (limits.stderrBytes, maximum.stderrBytes),
      (limits.totalBytes, maximum.totalBytes),
      (limits.lines, maximum.lines),
      (limits.processes, maximum.processes),
      (
        limits.processTimeout.inMicroseconds,
        maximum.processTimeout.inMicroseconds,
      ),
      (
        limits.operationTimeout.inMicroseconds,
        maximum.operationTimeout.inMicroseconds,
      ),
    ]) {
      if (value < 1 || value > bound) {
        throw ArgumentError('Snapshot limits may only be reduced.');
      }
    }
  }

  final AuthorizedEnvironmentBufferedProcessService processes;
  final GitPortableUnstagedLimits limits;

  Future<ChangeSetSnapshot> snapshotUnstaged() =>
      _snapshot(false).then((snapshot) => snapshot.unstaged);

  Future<UncommittedChangeSetSnapshot> snapshotUncommitted() => _snapshot(true);

  Future<UncommittedChangeSetSnapshot> _snapshot(bool includeStaged) async {
    final operation = _PortableSnapshot(processes, limits);
    try {
      return await operation
          .snapshot(includeStaged: includeStaged)
          .timeout(limits.operationTimeout);
    } on TimeoutException {
      throw _failure(
        'operation_timeout',
        'The change snapshot exceeded its deadline.',
      );
    } on EnvironmentFailure catch (error) {
      throw ChangeSetFailure(
        code: 'environment_process_failed',
        message:
            'The selected Environment could not complete a snapshot process.',
        details: {'environmentCode': error.code},
      );
    } on FormatException {
      throw _malformed();
    } finally {
      // A timed-out unary request cannot be cancelled here. Fence its continuation
      // so it cannot launch more commands or publish a late snapshot.
      operation.closed = true;
    }
  }
}

final class _PortableSnapshot {
  _PortableSnapshot(this.processes, this.limits);

  final AuthorizedEnvironmentBufferedProcessService processes;
  final GitPortableUnstagedLimits limits;
  final Stopwatch watch = Stopwatch()..start();
  final Map<String, _PathState> observed = {};
  final Map<String, String> workingOids = {};
  final Map<String, String> attributes = {};
  bool closed = false;
  int commandCount = 0;
  int byteCount = 0;
  int verificationBytes = 0;
  int lineCount = 0;
  int presentationBytes = 0;
  int fileCount = 0;
  _Repository? repository;
  bool fileMode = true;
  bool contentConversion = false;

  void checkOpen() {
    if (closed || watch.elapsed >= limits.operationTimeout) {
      throw _failure(
        'operation_timeout',
        'The change snapshot is no longer active.',
      );
    }
  }

  Future<UncommittedChangeSetSnapshot> snapshot({
    required bool includeStaged,
  }) async {
    repository = await discover();
    final head = includeStaged ? await readHead() : null;
    final tree = head == null ? '' : await readTree(head.commit);
    final headEntries = parseGitTree(
      tree,
      maximumEntries: limits.inventoryEntries,
    );
    final settings = await readSettings();
    final effective = <String, String>{};
    for (final record in _records(settings)) {
      final separator = record.indexOf('\n');
      final key = separator < 0 ? record : record.substring(0, separator);
      if (!const {
        'core.autocrlf',
        'core.eol',
        'core.filemode',
        'core.worktree',
        'core.bare',
      }.contains(key)) {
        throw _malformed();
      }
      // Git emits a key without LF/value for an implicit boolean (true).
      effective[key] = separator < 0
          ? 'true'
          : record.substring(separator + 1).toLowerCase();
    }
    const falseValues = {'', 'false', 'no', 'off', '0'};
    fileMode = !falseValues.contains(effective['core.filemode']);
    contentConversion =
        effective.containsKey('core.eol') ||
        (effective.containsKey('core.autocrlf') &&
            !falseValues.contains(effective['core.autocrlf']));
    final inventory = await enumerate();
    final entries = parseGitIndex(
      inventory.index,
      maximumEntries: limits.inventoryEntries,
    );
    if (head != null &&
        [...headEntries.values, ...entries.values].any(
          (entry) =>
              entry.oid.isNotEmpty && entry.oid.length != head.commit.length,
        )) {
      throw _malformed();
    }
    addGitUntrackedEntries(
      inventory.untracked,
      entries,
      maximumEntries: limits.inventoryEntries,
    );
    final deleted = _records(inventory.deleted).toSet();
    final killed = _records(inventory.killed).toSet();
    for (final path in [...deleted, ...killed]) {
      _validatePath(path);
    }
    if (deleted.any((path) => !entries.containsKey(path))) throw _malformed();
    final staged = <ChangedFile>[];
    final files = <ChangedFile>[];
    final conflicts = <ChangedFile>[];
    final union = {...headEntries.keys, ...entries.keys};
    if (union.length > limits.inventoryEntries) {
      throw _failure(
        'inventory_too_large',
        'The combined inventory exceeds the supported entry count.',
      );
    }
    final paths = union.toList()..sort();
    for (final path in paths) {
      _validatePath(path);
    }
    await observeWorking(
      paths.where(entries.containsKey).toList(),
      entries,
      deleted,
      killed,
    );
    for (final path in paths) {
      checkOpen();
      final entry = entries[path];
      if (includeStaged && entry?.kind == 'conflicted') {
        retain(await inspect(path, entry!, deleted, killed), conflicts);
        continue;
      }
      if (head != null) {
        retain(
          await inspectStaged(path, head.commit, headEntries[path], entry),
          staged,
        );
      }
      if (entry != null) {
        retain(await inspect(path, entry, deleted, killed), files);
      }
    }
    await verifyMetadata(observed.keys.toList());
    for (final entry in attributes.entries) {
      if (await readAttributes(entry.key) != entry.value) throw _changed();
    }
    if (await enumerate() != inventory ||
        await readSettings() != settings ||
        await discover() != repository ||
        (head != null &&
            (await readTree(head.commit) != tree ||
                await readHead() != head))) {
      throw _changed();
    }
    checkOpen();
    return UncommittedChangeSetSnapshot(
      staged: ChangeSetSnapshot(files: staged),
      unstaged: ChangeSetSnapshot(files: files),
      conflicts: conflicts,
    );
  }

  void retain(ChangedFile? file, List<ChangedFile> layer) {
    if (file == null) return;
    if (++fileCount > limits.files) {
      throw _failure(
        'snapshot_too_large',
        'The change snapshot exceeds its file limit.',
      );
    }
    // Count both appearances of a path and escaped text across every layer.
    presentationBytes +=
        512 + 6 * (file.relativePath.length + (file.detail?.length ?? 0));
    for (final hunk in file.hunks) {
      presentationBytes += 128;
      for (final line in hunk.lines) {
        presentationBytes += 128 + 6 * line.text.length;
      }
    }
    if (presentationBytes > 6 * 1024 * 1024) {
      throw _failure(
        'snapshot_too_large',
        'The snapshot exceeds its presentation budget.',
      );
    }
    layer.add(file);
  }

  Future<void> observeWorking(
    List<String> paths,
    Map<String, GitIndexEntry> entries,
    Set<String> deleted,
    Set<String> killed,
  ) async {
    final candidates = paths.where((path) {
      final entry = entries[path]!;
      return const {'modified', 'added'}.contains(entry.kind) &&
          const {'000000', '100644', '100755'}.contains(entry.oldMode) &&
          !deleted.contains(path) &&
          !killed.any(
            (parent) => path == parent || path.startsWith('$parent/'),
          );
    }).toList();
    final parents = <int, Set<String>>{};
    var parentCount = 0;
    var parentText = 0;
    for (final path in candidates) {
      final components = path.split('/');
      var parent = '';
      for (var depth = 0; depth < components.length - 1; depth++) {
        parent = parent.isEmpty
            ? components[depth]
            : '$parent/${components[depth]}';
        if ((parents[depth] ??= {}).add(parent)) {
          parentCount++;
          parentText += parent.length;
          if (parentCount > limits.inventoryEntries ||
              parentText > limits.totalBytes) {
            throw _failure(
              'snapshot_too_large',
              'The snapshot exceeds its parent-path observation budget.',
            );
          }
        }
      }
    }
    bool parentIsDirectory(String path) {
      final separator = path.lastIndexOf('/');
      return separator < 0 ||
          observed[path.substring(0, separator)]?.type == 0x4000;
    }

    // Inspect each depth before admitting descendants. A static parent symlink
    // must not cause even the initial leaf metadata scan to follow its target.
    final depths = parents.keys.toList()..sort();
    for (final depth in depths) {
      final safe = parents[depth]!.where(parentIsDirectory).toList()..sort();
      observed.addAll(await statMany(safe));
    }
    observed.addAll(
      await statMany(
        candidates
            .where(
              (path) => parentIsDirectory(path) && !observed.containsKey(path),
            )
            .toList(),
      ),
    );

    final hashPaths = <String>[];
    for (final path in candidates) {
      final entry = entries[path]!;
      final state = observed[path];
      if (entry.kind != 'modified' ||
          state == null ||
          state.type != 0x8000 ||
          (fileMode && state.executable != (entry.oldMode == '100755'))) {
        continue;
      }
      if (state.size <= limits.fileBytes) {
        // Hashing saves transport, not the budget for compared source content.
        chargeBytes(state.size);
      } else {
        if (state.size > limits.verificationFileBytes ||
            state.size > limits.verificationTotalBytes - verificationBytes) {
          continue;
        }
        verificationBytes += state.size;
      }
      hashPaths.add(path);
    }
    const arguments = ['hash-object', '--no-filters', '--'];
    for (final batch in pathBatches(
      hashPaths,
      '/usr/bin/git',
      gitArguments(arguments),
    )) {
      final raw = _decode(
        (await git([...arguments, for (final path in batch) './$path'])).bytes,
      );
      if (!raw.endsWith('\n')) throw _malformed();
      final hashes = raw.substring(0, raw.length - 1).split('\n');
      if (hashes.length != batch.length) throw _malformed();
      for (var index = 0; index < batch.length; index++) {
        final path = batch[index];
        final oid = hashes[index];
        if (!_oid(oid) || oid.length != entries[path]!.oid.length) {
          throw _malformed();
        }
        workingOids[path] = oid;
      }
    }
    await verifyMetadata(hashPaths);
  }

  Future<void> verifyMetadata(List<String> paths) async {
    final current = await statMany(paths);
    for (final path in paths) {
      if (current[path] != observed[path]) throw _changed();
    }
  }

  Future<ChangedFile?> inspect(
    String path,
    GitIndexEntry entry,
    Set<String> deleted,
    Set<String> killed,
  ) async {
    ChangedFile placeholder(
      String status,
      String detail, {
      String kind = 'unsupported',
    }) => ChangedFile(
      relativePath: path,
      changeKind: kind,
      contentStatus: status,
      detail: detail,
      hunks: const [],
    );
    if (entry.kind == 'conflicted') {
      return placeholder(
        'conflicted',
        'Unmerged index entries are not rendered as a text diff.',
        kind: 'conflicted',
      );
    }
    if (entry.kind == 'untrackedRepository' || entry.oldMode == '160000') {
      return placeholder(
        'unsupported',
        'Nested repository or submodule contents were not inspected.',
      );
    }
    if (entry.kind == 'unsupported' ||
        !const {'000000', '100644', '100755'}.contains(entry.oldMode)) {
      return placeholder(
        'unsupported',
        'Index flags or file type prevent ordinary text inspection.',
      );
    }
    if (killed.any((parent) => path == parent || path.startsWith('$parent/'))) {
      return placeholder(
        'unsupported',
        'An obstructing working-tree path prevents ordinary inspection.',
      );
    }
    final missing = deleted.contains(path);
    final kind = missing ? 'deleted' : entry.kind;
    if (missing && entry.kind == 'added') {
      return placeholder(
        'unsupported',
        'An intent-to-add path is missing from the working tree.',
      );
    }
    List<int> current = const [];
    _PathState? state;
    if (!missing) {
      var parent = '.';
      for (final component
          in path.split('/').take(path.split('/').length - 1)) {
        parent = parent == '.' ? component : '$parent/$component';
        if (observed[parent]?.type != 0x4000) {
          return placeholder(
            'unsupported',
            'A parent path is a symbolic link or is not a directory.',
          );
        }
      }
      state = observed[path];
      if (state == null) throw _changed();
      if (state.type != 0x8000) {
        return placeholder(
          'unsupported',
          'Symbolic links and special working files are not rendered.',
        );
      }
      if (entry.kind == 'modified' &&
          fileMode &&
          state.executable != (entry.oldMode == '100755')) {
        return placeholder(
          'unsupported',
          'Executable-mode changes are not rendered as text.',
          kind: 'typeChanged',
        );
      }
      final workingOid = workingOids[path];
      if (entry.kind == 'modified' && workingOid == entry.oid) return null;
      if (state.size > limits.fileBytes) {
        if (entry.kind == 'added') {
          return placeholder(
            'oversized',
            'The working file exceeds the rendering limit.',
            kind: 'added',
          );
        }
        if (workingOid == null) {
          return placeholder(
            'oversized',
            'The working file exceeds the verification budget; change state is unknown.',
          );
        }
        return placeholder(
          'oversized',
          'The oversized working file differs from the index.',
          kind: 'modified',
        );
      }
      current = (await command('/usr/bin/head', [
        '-c',
        '${limits.fileBytes + 1}',
        '--',
        './$path',
      ])).bytes;
      if (current.length != state.size || await stat(path) != state) {
        throw _changed();
      }
      if (entry.kind == 'modified' &&
          _blobHash(current, entry.oid.length) != workingOid) {
        throw _changed();
      }
    }
    final old = await blob(entry.oid);
    if (old == null) {
      return placeholder(
        'oversized',
        'The index file exceeds the rendering limit.',
        kind: kind,
      );
    }
    final classification = await classify(path, old, current);
    if (classification != null) {
      return placeholder(
        classification.status,
        classification.detail,
        kind: kind,
      );
    }
    final patch = await git(
      [
        'diff',
        '--no-index',
        '--no-ext-diff',
        '--no-textconv',
        '--text',
        '--no-renames',
        '--no-color',
        '--no-prefix',
        '--no-relative',
        '--full-index',
        '--diff-algorithm=myers',
        '--no-indent-heuristic',
        '--unified=3',
        '--inter-hunk-context=0',
        '--',
        '-',
        missing ? '/dev/null' : './$path',
      ],
      input: old,
      detached: true,
      allowDifference: true,
    );
    if (patch.exitCode == 0 && patch.bytes.isNotEmpty) throw _malformed();
    if (patch.exitCode == 1 && patch.bytes.isEmpty) throw _malformed();
    if (state != null && await stat(path) != state) throw _changed();
    // A second bounded raw read checks bytes, not only timestamps, around Git's
    // direct operand. It still cannot detect an external change-and-restore race.
    if (state != null) {
      final after = (await command('/usr/bin/head', [
        '-c',
        '${limits.fileBytes + 1}',
        '--',
        './$path',
      ])).bytes;
      if (!_equalBytes(after, current) || await stat(path) != state) {
        throw _changed();
      }
    }
    final hunks = parseGitPatch(
      _decode(patch.bytes),
      maximumLines: limits.lines - lineCount,
      requireIndex: false,
    );
    lineCount += hunks.fold<int>(0, (sum, hunk) => sum + hunk.lines.length);
    if (patch.exitCode == 0 && kind == 'modified') throw _changed();
    return ChangedFile(
      relativePath: path,
      changeKind: kind,
      contentStatus: 'text',
      detail: null,
      hunks: hunks,
    );
  }

  Future<({String status, String detail})?> classify(
    String path,
    List<int> old,
    List<int> current,
  ) async {
    final attrs = attributes[path] ??= await readAttributes(path);
    final records = _records(attrs);
    const names = [
      'diff',
      'text',
      'eol',
      'crlf',
      'working-tree-encoding',
      'filter',
      'ident',
    ];
    if (records.length != names.length * 3) throw _malformed();
    var binaryAttribute = false;
    var unsupportedAttribute = false;
    for (var i = 0; i < names.length; i++) {
      if (records[3 * i] != path || records[3 * i + 1] != names[i]) {
        throw _malformed();
      }
      final value = records[3 * i + 2];
      if (names[i] == 'diff' && value == 'unset') binaryAttribute = true;
      if (value != 'unspecified' &&
          value != 'unset' &&
          !(names[i] == 'diff' && value == 'set')) {
        unsupportedAttribute = true;
      }
    }
    if (contentConversion || unsupportedAttribute) {
      return (
        status: 'unsupported',
        detail:
            'Git content conversion or custom diff attributes are not supported.',
      );
    }
    if (binaryAttribute || old.contains(0) || current.contains(0)) {
      return (
        status: 'binary',
        detail: 'Binary content is not rendered as text.',
      );
    }
    try {
      utf8.decode(old, allowMalformed: false);
      utf8.decode(current, allowMalformed: false);
    } on FormatException {
      return (
        status: 'unsupported',
        detail: 'Content is not valid UTF-8 text.',
      );
    }
    return null;
  }

  Future<ChangedFile?> inspectStaged(
    String path,
    String commit,
    GitIndexEntry? old,
    GitIndexEntry? current,
  ) async {
    // Untracked and intent-to-add paths have no staged object. Working content
    // never supplies a side of this comparison, even when it cancels the index.
    if (current?.oid.isEmpty ?? false) current = null;
    if (old == null && current == null) return null;
    if (old != null &&
        current != null &&
        old.oid == current.oid &&
        old.oldMode == current.oldMode) {
      return null;
    }
    final kind = old == null
        ? 'added'
        : current == null
        ? 'deleted'
        : old.oldMode != current.oldMode
        ? 'typeChanged'
        : 'modified';
    ChangedFile placeholder(String status, String detail) => ChangedFile(
      relativePath: path,
      changeKind: kind,
      contentStatus: status,
      detail: detail,
      hunks: const [],
    );
    const regular = {'100644', '100755'};
    if ((old != null && !regular.contains(old.oldMode)) ||
        (current != null &&
            (!regular.contains(current.oldMode) ||
                current.kind == 'unsupported'))) {
      return placeholder(
        'unsupported',
        'File type or index flags prevent ordinary text inspection.',
      );
    }
    if (kind == 'typeChanged') {
      return placeholder(
        'unsupported',
        'File mode changes are not rendered as text.',
      );
    }
    final left = await blob(old?.oid ?? '');
    final right = await blob(current?.oid ?? '');
    if (left == null || right == null) {
      return placeholder(
        'oversized',
        'A file side exceeds the rendering limit.',
      );
    }
    final classification = await classify(path, left, right);
    if (classification != null) {
      return placeholder(classification.status, classification.detail);
    }
    final filter = switch (kind) {
      'added' => 'A',
      'deleted' => 'D',
      _ => 'M',
    };
    final patch = await git([
      '-c',
      'diff.suppressBlankEmpty=false',
      'diff',
      '--cached',
      commit,
      '--patch',
      '--exit-code',
      '--no-ext-diff',
      '--no-textconv',
      '--text',
      '--no-renames',
      '--no-color',
      '--no-prefix',
      '--no-relative',
      '--full-index',
      '--ignore-submodules=all',
      '--ita-invisible-in-index',
      // A literal file path can also select descendants after a file/directory
      // replacement. The captured kind excludes those opposite-kind changes.
      '--diff-filter=$filter',
      '--diff-algorithm=myers',
      '--no-indent-heuristic',
      '--unified=3',
      '--inter-hunk-context=0',
      '--output-indicator-new=+',
      '--output-indicator-old=-',
      '--output-indicator-context= ',
      '--',
      './$path',
    ], allowDifference: true);
    if (patch.exitCode != 1 || patch.bytes.isEmpty) throw _changed();
    final text = _decode(patch.bytes);
    final zero = '0' * commit.length;
    final identity = RegExp(
      r'^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: ([0-7]{6}))?$',
      multiLine: true,
    ).allMatches(text).toList();
    if (identity.length != 1 ||
        identity.single[1] != (old?.oid ?? zero) ||
        identity.single[2] != (current?.oid ?? zero) ||
        identity.single[3] != (kind == 'modified' ? old!.oldMode : null)) {
      throw _changed();
    }
    final hunks = parseGitPatch(text, maximumLines: limits.lines - lineCount);
    lineCount += hunks.fold<int>(0, (sum, hunk) => sum + hunk.lines.length);
    // Attribute identity to the inventory, not quoted patch-header filenames.
    // Reconstruct the exact captured index bytes so a valid but incomplete hunk
    // prefix cannot be published as a successful staged comparison.
    final oldText = _decode(left);
    final oldLines = oldText.isEmpty ? <String>[] : oldText.split('\n');
    if (oldText.endsWith('\n')) oldLines.removeLast();
    final newText = _decode(right);
    final newLines = newText.isEmpty ? <String>[] : newText.split('\n');
    if (newText.endsWith('\n')) newLines.removeLast();
    final rebuilt = StringBuffer();
    var oldOffset = 0;
    var newOffset = 0;
    for (final hunk in hunks) {
      final start = hunk.oldStart - (hunk.oldCount == 0 ? 0 : 1);
      if (start < oldOffset || start > oldLines.length) throw _malformed();
      while (oldOffset < start) {
        rebuilt.write(oldLines[oldOffset++]);
        if (oldOffset < oldLines.length || oldText.endsWith('\n')) {
          rebuilt.write('\n');
        }
        newOffset++;
      }
      if (hunk.newStart - (hunk.newCount == 0 ? 0 : 1) != newOffset) {
        throw _malformed();
      }
      for (final line in hunk.lines) {
        if (line.kind != 'addition') {
          if (oldOffset >= oldLines.length ||
              oldLines[oldOffset] != line.text ||
              line.noNewline !=
                  (oldOffset == oldLines.length - 1 &&
                      !oldText.endsWith('\n'))) {
            throw _malformed();
          }
          oldOffset++;
        }
        if (line.kind != 'deletion') {
          if (newOffset >= newLines.length ||
              newLines[newOffset] != line.text ||
              line.noNewline !=
                  (newOffset == newLines.length - 1 &&
                      !newText.endsWith('\n'))) {
            throw _malformed();
          }
          rebuilt.write(line.text);
          if (!line.noNewline) rebuilt.write('\n');
          newOffset++;
        }
      }
    }
    while (oldOffset < oldLines.length) {
      rebuilt.write(oldLines[oldOffset++]);
      if (oldOffset < oldLines.length || oldText.endsWith('\n')) {
        rebuilt.write('\n');
      }
    }
    if (rebuilt.toString() != newText) throw _malformed();
    return ChangedFile(
      relativePath: path,
      changeKind: kind,
      contentStatus: 'text',
      detail: null,
      hunks: hunks,
    );
  }

  Future<({String commit, String reference})> readHead() async {
    final String commit;
    try {
      commit = _scalar(
        (await git(['rev-parse', '--verify', 'HEAD^{commit}'])).bytes,
      );
    } on ChangeSetFailure catch (error) {
      if (error.code != 'git_failed') rethrow;
      throw _failure(
        'head_unavailable',
        'Uncommitted changes require a valid HEAD commit.',
      );
    }
    if (!_oid(commit)) throw _malformed();
    final symbolic = await git([
      'symbolic-ref',
      '--quiet',
      'HEAD',
    ], allowDifference: true);
    final reference = _decode(symbolic.bytes);
    if ((symbolic.exitCode == 0) != reference.isNotEmpty ||
        (reference.isNotEmpty &&
            (!reference.startsWith('refs/') ||
                !reference.endsWith('\n') ||
                reference
                    .substring(0, reference.length - 1)
                    .contains(RegExp(r'[\x00-\x20]'))))) {
      throw _malformed();
    }
    return (commit: commit, reference: reference);
  }

  Future<String> readTree(String commit) async =>
      _decode((await git(['ls-tree', '-r', '-z', commit, '--', '.'])).bytes);

  Future<List<int>?> blob(String oid) async {
    if (oid.isEmpty) return const [];
    if (!_oid(oid)) throw _malformed();
    final sizeText = _scalar((await git(['cat-file', '-s', oid])).bytes);
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(sizeText)) throw _malformed();
    final size = int.tryParse(sizeText);
    if (size == null) throw _malformed();
    if (size > limits.fileBytes) return null;
    final data = (await git(['cat-file', 'blob', oid])).bytes;
    if (data.length != size || _blobHash(data, oid.length) != oid) {
      throw _malformed();
    }
    return data;
  }

  Future<_PathState> stat(String path) async => (await statMany([path]))[path]!;

  Future<Map<String, _PathState>> statMany(List<String> paths) async {
    const arguments = [r'--printf=%n\0%f %s %d %i %y %z\0', '--'];
    final states = <String, _PathState>{};
    for (final batch in pathBatches(paths, '/usr/bin/stat', arguments)) {
      final records = _records(
        _decode(
          (await command('/usr/bin/stat', [
            ...arguments,
            for (final path in batch) './$path',
          ])).bytes,
        ),
      );
      if (records.length != batch.length * 2) throw _malformed();
      for (var index = 0; index < batch.length; index++) {
        final path = batch[index];
        if (records[index * 2] != './$path') throw _malformed();
        final raw = records[index * 2 + 1];
        final match = RegExp(
          r'^([0-9a-f]+) (\d+) (\d+) (\d+) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{9} [+-]\d{4}) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{9} [+-]\d{4})$',
        ).firstMatch(raw);
        if (match == null || match.end != raw.length) throw _malformed();
        final mode = int.tryParse(match[1]!, radix: 16);
        final size = int.tryParse(match[2]!);
        if (mode == null || size == null) throw _malformed();
        states[path] = _PathState(mode: mode, size: size, description: raw);
      }
    }
    return states;
  }

  Iterable<List<String>> pathBatches(
    List<String> paths,
    String program,
    List<String> arguments,
  ) sync* {
    final fixed = requestArguments(program, arguments);
    final fixedLength =
        '/bin/sh'.length + fixed.fold<int>(0, (sum, arg) => sum + arg.length);
    var batch = <String>[];
    var length = fixedLength;
    for (final path in paths) {
      final added = './'.length + path.length;
      if (fixed.length + 1 > 256 || fixedLength + added > 64 * 1024) {
        throw _failure(
          'snapshot_too_large',
          'A snapshot path exceeds the process metadata limit.',
        );
      }
      if (batch.length == 128 ||
          fixed.length + batch.length + 1 > 256 ||
          length + added > 64 * 1024) {
        yield batch;
        batch = [];
        length = fixedLength;
      }
      batch.add(path);
      length += added;
    }
    if (batch.isNotEmpty) yield batch;
  }

  Future<_Repository> discover() async {
    final root = _scalar((await command('/bin/pwd', ['-P'])).bytes);
    final inside = _scalar(
      (await git(['rev-parse', '--is-inside-work-tree'], discover: true)).bytes,
    );
    final worktree = _scalar(
      (await git(['rev-parse', '--show-toplevel'], discover: true)).bytes,
    );
    final directory = _scalar(
      (await git(['rev-parse', '--absolute-git-dir'], discover: true)).bytes,
    );
    final prefix = _scalar(
      (await git(['rev-parse', '--show-prefix'], discover: true)).bytes,
    );
    final worktreePrefix = worktree == '/' ? '/' : '$worktree/';
    if (inside != 'true' ||
        [root, worktree, directory].any(
          (path) =>
              !path.startsWith('/') ||
              path.contains('\u0000') ||
              (path != '/' &&
                  path
                      .substring(1)
                      .split('/')
                      .any(
                        (part) => part.isEmpty || part == '.' || part == '..',
                      )),
        ) ||
        (root != worktree && !root.startsWith(worktreePrefix)) ||
        prefix !=
            (root == worktree
                ? ''
                : '${root.substring(worktreePrefix.length)}/')) {
      throw _failure(
        'repository_unavailable',
        'Git discovery does not match the selected Environment root.',
      );
    }
    return (
      root: root,
      worktree: worktree,
      directory: directory,
      prefix: prefix,
    );
  }

  Future<_Inventory> enumerate() async => (
    index: _decode(
      (await git([
        'ls-files',
        '--cached',
        '--stage',
        '--debug',
        '-z',
        '--',
        '.',
      ])).bytes,
    ),
    untracked: _decode(
      (await git([
        'ls-files',
        '--others',
        '--exclude-standard',
        '-z',
        '--',
        '.',
      ])).bytes,
    ),
    deleted: _decode(
      (await git(['ls-files', '--deleted', '-z', '--', '.'])).bytes,
    ),
    killed: _decode(
      (await git(['ls-files', '--killed', '-z', '--', '.'])).bytes,
    ),
  );

  Future<String> readSettings() async => _decode(
    (await git([
      'config',
      '--null',
      '--get-regexp',
      r'^core\.(autocrlf|eol|filemode|worktree|bare)$',
    ], allowDifference: true)).bytes,
  );

  Future<String> readAttributes(String path) async => _decode(
    (await git([
      'check-attr',
      '-z',
      'diff',
      'text',
      'eol',
      'crlf',
      'working-tree-encoding',
      'filter',
      'ident',
      '--',
      path,
    ])).bytes,
  );

  Future<_Output> git(
    List<String> arguments, {
    List<int> input = const [],
    bool detached = false,
    bool discover = false,
    bool allowDifference = false,
  }) => command(
    '/usr/bin/git',
    gitArguments(arguments, detached: detached, discover: discover),
    input: input,
    detached: detached,
    allowDifference: allowDifference,
  );

  List<String> gitArguments(
    List<String> arguments, {
    bool detached = false,
    bool discover = false,
  }) => [
    '--no-pager',
    '--no-optional-locks',
    '--no-replace-objects',
    '--literal-pathspecs',
    if (detached) '--git-dir=/dev/null',
    if (!detached && !discover && repository != null) ...[
      '--git-dir=${repository!.directory}',
      '--work-tree=${repository!.worktree}',
    ],
    '-c',
    'core.fsmonitor=false',
    '-c',
    'core.untrackedCache=false',
    '-c',
    'core.hooksPath=/dev/null',
    '-c',
    'diff.external=',
    if (detached) ...[
      '-c',
      'core.attributesFile=/dev/null',
      '-c',
      'core.autocrlf=false',
      '-c',
      'core.filemode=false',
      '-c',
      'diff.suppressBlankEmpty=false',
    ],
    ...arguments,
  ];

  List<String> requestArguments(
    String program,
    List<String> arguments, {
    bool detached = false,
  }) => [
    '-c',
    // Fixed code; filenames and configuration never become shell source.
    r'exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}" LC_ALL=C LANG=C GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL= "$@"',
    'adele-git-inspection',
    if (detached) ...[
      '/usr/bin/env',
      'GIT_CONFIG_NOSYSTEM=1',
      'GIT_CONFIG_SYSTEM=/dev/null',
      'GIT_CONFIG_GLOBAL=/dev/null',
      'GIT_ATTR_NOSYSTEM=1',
    ],
    program, ...arguments,
  ];

  void chargeBytes(int count) {
    byteCount += count;
    if (byteCount > limits.totalBytes) {
      throw _failure(
        'snapshot_too_large',
        'The snapshot exceeds its aggregate byte budget.',
      );
    }
  }

  Future<_Output> command(
    String program,
    List<String> arguments, {
    List<int> input = const [],
    bool detached = false,
    bool allowDifference = false,
  }) async {
    checkOpen();
    if (++commandCount > limits.processes) {
      throw _failure(
        'snapshot_too_large',
        'The snapshot exceeds its process-count limit.',
      );
    }
    final remaining = limits.operationTimeout - watch.elapsed;
    final timeout = remaining < limits.processTimeout
        ? remaining
        : limits.processTimeout;
    final request = EnvironmentBufferedProcessRequest(
      program: '/bin/sh',
      arguments: requestArguments(program, arguments, detached: detached),
      relativeWorkingDirectory: '',
      timeoutSeconds: (timeout.inMicroseconds / Duration.microsecondsPerSecond)
          .ceil()
          .clamp(1, 10),
      stdinBase64: encodeEnvironmentProcessBytes(
        input,
        maximumBytes: environmentBufferedProcessStdinLimit,
      ),
    );
    final result = await processes.runBufferedProcess(request).timeout(timeout);
    checkOpen();
    final output = decodeEnvironmentProcessBytes(
      result.stdoutBase64,
      maximumBytes: environmentBufferedProcessStdoutLimit,
    );
    final errors = decodeEnvironmentProcessBytes(
      result.stderrBase64,
      maximumBytes: environmentBufferedProcessStderrLimit,
    );
    if (output.length > limits.outputBytes ||
        errors.length > limits.stderrBytes) {
      throw _failure(
        'snapshot_too_large',
        'A snapshot process exceeded its output limit.',
      );
    }
    chargeBytes(input.length + output.length + errors.length);
    // Git can exit successfully while reporting unreadable paths on stderr.
    // Never treat such an inventory (or a partially successful utility) as complete.
    if (errors.isNotEmpty ||
        (result.exitCode != 0 && !(allowDifference && result.exitCode == 1))) {
      throw _failure(
        'git_failed',
        'A required snapshot command failed or reported an incomplete observation.',
      );
    }
    return (bytes: output, exitCode: result.exitCode);
  }
}

typedef _Repository = ({
  String root,
  String worktree,
  String directory,
  String prefix,
});
typedef _Inventory = ({
  String index,
  String untracked,
  String deleted,
  String killed,
});
typedef _Output = ({List<int> bytes, int exitCode});

final class _PathState {
  const _PathState({
    required this.mode,
    required this.size,
    required this.description,
  });
  final int mode;
  final int size;
  final String description;
  int get type => mode & 0xf000;
  bool get executable => (mode & 0x40) != 0;
  @override
  bool operator ==(Object other) =>
      other is _PathState && description == other.description;
  @override
  int get hashCode => description.hashCode;
}

bool _oid(String value) =>
    const {40, 64}.contains(value.length) &&
    !RegExp(r'[^0-9a-f]').hasMatch(value);
String _blobHash(List<int> bytes, int oidLength) =>
    (oidLength == 64 ? sha256 : sha1).convert([
      ...utf8.encode('blob ${bytes.length}\u0000'),
      ...bytes,
    ]).toString();
bool _equalBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: false);
String _scalar(List<int> bytes) {
  final text = _decode(bytes);
  if (!text.endsWith('\n')) throw _malformed();
  return text.substring(0, text.length - 1);
}

List<String> _records(String text) {
  if (text.isEmpty) return const [];
  if (!text.endsWith('\u0000')) throw _malformed();
  return text.substring(0, text.length - 1).split('\u0000');
}

void _validatePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\u0000') ||
      path
          .split('/')
          .any(
            (part) =>
                part.isEmpty || part == '.' || part == '..' || part == '.git',
          )) {
    throw _malformed();
  }
}

ChangeSetFailure _failure(String code, String message) =>
    ChangeSetFailure(code: code, message: message);
ChangeSetFailure _malformed() => _failure(
  'invalid_git_output',
  'A snapshot process returned malformed or unsupported output.',
);
ChangeSetFailure _changed() => _failure(
  'snapshot_changed',
  'The repository or an observed working file changed during inspection.',
);
