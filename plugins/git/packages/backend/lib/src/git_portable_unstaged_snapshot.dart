import 'dart:async';
import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

import 'git_snapshot_parsing.dart';

part 'git_portable_review_approval.dart';

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

/// Trusted backend construction metadata, never a semantic request parameter.
final class GitTaskComparisonAnchor {
  const GitTaskComparisonAnchor({
    required this.baselineCommit,
    required this.expectedBranchRef,
  });

  final String baselineCommit;
  final String expectedBranchRef;
}

/// Layered change inspection using the captured process grant.
///
/// Requires Linux-style /bin/sh, /bin/pwd, and /usr/bin/{env,git,stat,head}
/// in the selected Environment. No host filesystem or provider implementation is
/// consulted. Static path checks are not an OS sandbox or a filesystem transaction.
final class GitPortableUnstagedSnapshotService {
  GitPortableUnstagedSnapshotService({
    required this.processes,
    this.limits = const GitPortableUnstagedLimits(),
    this.taskAnchor,
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
  final GitTaskComparisonAnchor? taskAnchor;

  Future<ChangeSetSnapshot> snapshotUnstaged() =>
      _snapshot(false).then((snapshot) => snapshot.uncommitted.unstaged);

  Future<UncommittedChangeSetSnapshot> snapshotUncommitted() =>
      _snapshot(true).then((snapshot) => snapshot.uncommitted);

  Future<TaskChangeSetSnapshot> snapshotTaskChanges() =>
      _snapshot(true, includeCommitted: true);

  Future<TaskChangeSetSnapshot> _snapshot(
    bool includeStaged, {
    bool includeCommitted = false,
  }) async {
    final operation = _PortableSnapshot(processes, limits);
    try {
      return await operation
          .snapshot(
            includeStaged: includeStaged,
            includeCommitted: includeCommitted,
            taskAnchor: taskAnchor,
          )
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
  final Map<String, String> workingAbsences = {};
  final Map<String, String> attributes = {};
  final Map<String, int> objectSizes = {};
  final Set<String> reviewableWorkingPaths = {};
  final Set<String> parentPaths = {};
  int parentPathText = 0;
  int? additionOidWidth;
  AuthorizedEnvironmentIdentity? capturedIdentity;
  _ReviewObservation? reviewObservation;
  bool closed = false;
  bool mutationAttempted = false;
  int commandCount = 0;
  int byteCount = 0;
  int verificationBytes = 0;
  int lineCount = 0;
  // Three layer envelopes, including their required nullable review revisions.
  int presentationBytes = 1024;
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

  Future<TaskChangeSetSnapshot> snapshot({
    required bool includeStaged,
    required bool includeCommitted,
    required GitTaskComparisonAnchor? taskAnchor,
    String? selectedPath,
  }) async {
    if (includeCommitted && taskAnchor == null) {
      throw _failure(
        'baseline_unavailable',
        'Task changes require a retained comparison baseline.',
      );
    }
    repository = await discover();
    final anchor = includeCommitted ? taskAnchor! : null;
    final oidWidth = anchor == null ? null : await readObjectWidth();
    if (anchor != null) {
      await validateCommit(anchor.baselineCommit, oidWidth!, baseline: true);
      if (!anchor.expectedBranchRef.startsWith('refs/heads/') ||
          anchor.expectedBranchRef.contains(RegExp(r'[\x00-\x20\x7f]'))) {
        throw _failure(
          'invalid_branch',
          'Task changes require a full branch ref.',
        );
      }
      final valid = await git([
        'check-ref-format',
        anchor.expectedBranchRef,
      ], allowDifference: true);
      if (valid.exitCode != 0 || valid.bytes.isNotEmpty) {
        throw _failure(
          'invalid_branch',
          'The retained Task branch ref is invalid.',
        );
      }
    }
    final head = includeStaged ? await readHead() : null;
    if (anchor != null) {
      if (head!.commit.length != oidWidth) throw _malformed();
      if (head.reference.isEmpty) {
        throw _failure(
          'detached_head',
          'Task changes require the retained branch.',
        );
      }
      if (head.reference != '${anchor.expectedBranchRef}\n') {
        throw _failure(
          'unexpected_branch',
          'HEAD is not on the retained Task branch.',
        );
      }
      if (head.commit != anchor.baselineCommit) {
        await validateCommit(head.commit, oidWidth!, baseline: false);
      }
    }
    final tree = head == null ? '' : await readTree(head.commit);
    final headEntries = parseGitTree(
      tree,
      maximumEntries: limits.inventoryEntries,
    );
    final baselineTree = anchor == null
        ? ''
        : await readTree(anchor.baselineCommit);
    final baselineEntries = parseGitTree(
      baselineTree,
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
    if (effective.containsKey('core.worktree')) {
      throw _failure(
        'unsupported_repository_configuration',
        'An explicit core.worktree can redirect the selected checkout.',
      );
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
        [
          ...baselineEntries.values,
          ...headEntries.values,
          ...entries.values,
        ].any(
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
    final committed = <ChangedFile>[];
    final staged = <ChangedFile>[];
    final files = <ChangedFile>[];
    final conflicts = <ChangedFile>[];
    final union = {
      ...baselineEntries.keys,
      ...headEntries.keys,
      ...entries.keys,
    };
    if (union.length > limits.inventoryEntries) {
      throw _failure(
        'inventory_too_large',
        'The combined inventory exceeds the supported entry count.',
      );
    }
    final paths =
        union
            .where((path) => selectedPath == null || path == selectedPath)
            .toList()
          ..sort();
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
      if (anchor != null) {
        retain(
          await inspectObjects(
            path,
            anchor.baselineCommit,
            baselineEntries[path],
            headEntries[path],
            currentCommit: head!.commit,
          ),
          committed,
        );
      }
      if (includeStaged && entry?.kind == 'conflicted') {
        retain(await inspect(path, entry!, deleted, killed), conflicts);
        continue;
      }
      if (head != null) {
        retain(
          await inspectObjects(path, head.commit, headEntries[path], entry),
          staged,
        );
      }
      if (entry != null) {
        retain(await inspect(path, entry, deleted, killed), files);
      }
    }
    // Review revisions are preconditions, never invocation authority. Reuse the
    // comment capture where present; clean scans retain their batched cost.
    final hunkCandidates = <ChangedFile>{};
    final fileCandidates = <ChangedFile>{};
    for (final file in [...staged, ...files]) {
      final deletion = file.changeKind == 'deleted';
      final reverse = staged.contains(file);
      if (!deletion && !reviewableWorkingPaths.contains(file.relativePath)) {
        continue;
      }
      for (final wholeFile in [false, true]) {
        if (_reviewableFile(
          file,
          repository!.prefix,
          indexBytes:
              deletion && reverse || entries[file.relativePath]?.oid == ''
              ? 0
              : objectSizes[entries[file.relativePath]?.oid],
          maximumFileBytes: limits.fileBytes,
          reverse: reverse,
          wholeFile: wholeFile,
        )) {
          if (deletion) {
            final proof = await workingAbsence(file.relativePath);
            if (proof == null) continue;
            workingAbsences[file.relativePath] = proof;
          }
          (wholeFile ? fileCandidates : hunkCandidates).add(file);
        }
      }
    }
    final candidates = {...hunkCandidates, ...fileCandidates};
    var reviewHead = head;
    if (candidates.isNotEmpty && reviewHead == null) {
      try {
        reviewHead = await readHead();
      } on ChangeSetFailure catch (error) {
        if (error.code != 'head_unavailable') rethrow;
        // An unborn repository remains displayable, but has no review targets.
      }
    }
    var reviewTree = head == null ? null : tree;
    var reviewHeadEntries = headEntries;
    if (fileCandidates.isNotEmpty && reviewHead != null) {
      if (reviewTree == null) {
        reviewTree = await readTree(reviewHead.commit);
        reviewHeadEntries = parseGitTree(
          reviewTree,
          maximumEntries: limits.inventoryEntries,
        );
      }
      fileCandidates.removeWhere((file) {
        final original = reviewHeadEntries[file.relativePath];
        if (file.changeKind == 'added') return original != null;
        if (file.changeKind == 'deleted' && staged.contains(file)) {
          return original == null ||
              !const {'100644', '100755'}.contains(original.oldMode);
        }
        // Further edits of a staged addition remain outside file approval.
        return original == null ||
            !const {'100644', '100755'}.contains(original.oldMode) ||
            original.oldMode != entries[file.relativePath]?.oldMode;
      });
    }
    if (candidates.isNotEmpty && reviewHead != null) {
      checkOpen();
      final identity = capturedIdentity ??= await processes.capturedIdentity();
      checkOpen();
      final reviewIndex = repository!.prefix.isEmpty
          ? inventory.index
          : await _readReviewIndex(this);
      final indexEntries = parseGitIndex(
        reviewIndex,
        maximumEntries: limits.inventoryEntries,
      );
      final membershipChanges = fileCandidates
          .where((file) => const {'added', 'deleted'}.contains(file.changeKind))
          .toList();
      final fullHeadEntries =
          membershipChanges.isNotEmpty && repository!.prefix.isNotEmpty
          ? parseGitTree(
              _decode(
                (await git([
                  '-C',
                  repository!.worktree,
                  'ls-tree',
                  '-r',
                  '-z',
                  reviewHead.commit,
                  '--',
                  '.',
                ])).bytes,
              ),
              maximumEntries: limits.inventoryEntries,
            )
          : reviewHeadEntries;
      for (final file in membershipChanges) {
        final path = file.relativePath;
        final repositoryPath = '${repository!.prefix}$path';
        final indexed = indexEntries[repositoryPath];
        final reverse = staged.contains(file);
        final deletion = file.changeKind == 'deleted';
        final insertsEntry = deletion ? reverse : !reverse;
        final validIndex = !insertsEntry
            ? indexed != null &&
                  indexed.kind == 'modified' &&
                  const {'100644', '100755'}.contains(indexed.oldMode)
            : indexed == null &&
                  (deletion || _records(inventory.untracked).contains(path));
        if (!validIndex ||
            (insertsEntry &&
                ('\u0000'.allMatches(reviewIndex).length >=
                        limits.inventoryEntries ||
                    utf8.encode(reviewIndex).length +
                            utf8.encode(repositoryPath).length +
                            512 >
                        limits.outputBytes)) ||
            _reviewPathCollision(repositoryPath, indexEntries.keys) ||
            _reviewPathCollision(repositoryPath, fullHeadEntries.keys)) {
          fileCandidates.remove(file);
          continue;
        }
        if (deletion) {
          final original = fullHeadEntries[repositoryPath];
          if (original == null ||
              !const {'100644', '100755'}.contains(original.oldMode) ||
              (!reverse && indexed!.oldMode != original.oldMode)) {
            fileCandidates.remove(file);
            continue;
          }
          // Approving B -> absence supersedes A -> B. Require A to remain a
          // bounded ordinary text file too; reversal will restore A, never B.
          final originalBytes = await blob(original.oid);
          if (originalBytes == null ||
              classifyBytes(originalBytes, const []) != null) {
            fileCandidates.remove(file);
          }
        } else if (fullHeadEntries.containsKey(repositoryPath) ||
            !await _reviewAdditionPathSafe(this, path)) {
          fileCandidates.remove(file);
        }
      }
      final observation = _ReviewObservation(
        identity: identity,
        head: reviewHead,
        index: reviewIndex,
        entries: {
          for (final path in entries.keys)
            path: ?indexEntries['${repository!.prefix}$path'],
        },
        headEntries: reviewHeadEntries,
        settings: settings,
        inventory: inventory,
      );
      reviewObservation = observation;
      for (final (layer, name) in [(files, 'unstaged'), (staged, 'staged')]) {
        for (var i = 0; i < layer.length; i++) {
          final file = layer[i];
          if (!candidates.contains(file)) continue;
          layer[i] = ChangedFile(
            commentComparisonIdentity: file.commentComparisonIdentity,
            fileReviewRevision: fileCandidates.contains(file)
                ? _reviewRevision(
                    this,
                    observation,
                    file.relativePath,
                    name,
                    wholeFile: true,
                    addition: file.changeKind == 'added',
                    deletion: file.changeKind == 'deleted',
                  )
                : null,
            relativePath: file.relativePath,
            changeKind: file.changeKind,
            contentStatus: file.contentStatus,
            detail: file.detail,
            hunks: file.hunks,
            reviewRevision: hunkCandidates.contains(file)
                ? _reviewRevision(this, observation, file.relativePath, name)
                : null,
          );
        }
      }
    }
    // ls-files can report a deletion through an unsafe ancestor. Certify that
    // working-side absence only when the existing inspection proved it, without
    // introducing comment-specific probes or requiring an approval revision.
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      if (file.changeKind != 'deleted' ||
          !workingAbsences.containsKey(file.relativePath)) {
        continue;
      }
      final entry = entries[file.relativePath]!;
      files[i] = ChangedFile(
        relativePath: file.relativePath,
        changeKind: file.changeKind,
        contentStatus: file.contentStatus,
        detail: file.detail,
        reviewRevision: file.reviewRevision,
        fileReviewRevision: file.fileReviewRevision,
        commentComparisonIdentity: await commentIdentity(
          path: file.relativePath,
          kind: file.changeKind,
          layer: 'unstaged',
          oldSource: 'index',
          newSource: 'working',
          oldMode: entry.oldMode,
          oldOid: entry.oid,
          newMode: null,
          newOid: null,
          hunks: file.hunks,
        ),
        hunks: file.hunks,
      );
    }
    await verifyMetadata(observed.keys.toList());
    for (final entry in workingAbsences.entries) {
      if (await workingAbsence(entry.key) != entry.value) throw _changed();
    }
    for (final entry in attributes.entries) {
      if (await readAttributes(entry.key) != entry.value) throw _changed();
    }
    for (final file in fileCandidates) {
      if (file.changeKind == 'added' &&
          !await _reviewAdditionPathSafe(this, file.relativePath)) {
        throw _changed();
      }
    }
    if (anchor != null) {
      // Only required changed-object sides are revisited; clean tree identities
      // never cause per-file processes. Large sides remain size-only observations.
      for (final entry in objectSizes.entries.toList()) {
        await blob(entry.key);
        if (objectSizes[entry.key] != entry.value) throw _changed();
      }
      await validateCommit(anchor.baselineCommit, oidWidth!, baseline: true);
      if (head!.commit != anchor.baselineCommit) {
        await validateCommit(head.commit, oidWidth, baseline: false);
      }
      if (await readObjectWidth() != oidWidth ||
          await readTree(anchor.baselineCommit) != baselineTree) {
        throw _changed();
      }
    }
    if (await enumerate() != inventory ||
        await readSettings() != settings ||
        await discover() != repository ||
        (reviewHead != null && await readHead() != reviewHead) ||
        (head != null &&
            (await readTree(head.commit) != tree || head != reviewHead))) {
      throw _changed();
    }
    if (reviewObservation != null &&
        repository!.prefix.isNotEmpty &&
        await _readReviewIndex(this) != reviewObservation!.index) {
      throw _changed();
    }
    if (head == null &&
        reviewTree != null &&
        await readTree(reviewHead!.commit) != reviewTree) {
      throw _changed();
    }
    checkOpen();
    return TaskChangeSetSnapshot(
      committed: ChangeSetSnapshot(files: committed, layerReviewRevision: null),
      uncommitted: UncommittedChangeSetSnapshot(
        staged: ChangeSetSnapshot(
          files: staged,
          layerReviewRevision: selectedPath == null && conflicts.isEmpty
              ? _layerReviewRevision(this, staged, reverse: true)
              : null,
        ),
        unstaged: ChangeSetSnapshot(
          files: files,
          layerReviewRevision: selectedPath == null && conflicts.isEmpty
              ? _layerReviewRevision(this, files, reverse: false)
              : null,
        ),
        conflicts: conflicts,
      ),
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
    // Count every appearance of a path and escaped text across all layers.
    // Include both approval revisions and the comment identity in the allowance.
    presentationBytes +=
        768 + 6 * (file.relativePath.length + (file.detail?.length ?? 0));
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
    for (final path in candidates) {
      final components = path.split('/');
      var parent = '';
      for (var depth = 0; depth < components.length - 1; depth++) {
        parent = parent.isEmpty
            ? components[depth]
            : '$parent/${components[depth]}';
        if ((parents[depth] ??= {}).add(parent)) {
          retainParentPath(parent);
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
      if (state.size > limits.verificationFileBytes ||
          state.size > limits.verificationTotalBytes - verificationBytes) {
        if (state.size <= limits.fileBytes) {
          throw _failure(
            'snapshot_too_large',
            'The snapshot exceeds its raw-file verification budget.',
          );
        }
        continue;
      }
      // Raw hashing consumes verification work; only its output is transported.
      verificationBytes += state.size;
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

  void retainParentPath(String path) {
    if (!parentPaths.add(path)) return;
    parentPathText += path.length;
    if (parentPaths.length > limits.inventoryEntries ||
        parentPathText > limits.totalBytes) {
      throw _failure(
        'snapshot_too_large',
        'The snapshot exceeds its parent-path observation budget.',
      );
    }
  }

  /// A deletion-only negative observation, not a failed ordinary file read.
  Future<String?> workingAbsence(String path) async {
    final components = path.split('/');
    final prefixes = <String>['.'];
    var prefix = '';
    for (final component in components) {
      prefix = prefix.isEmpty ? component : '$prefix/$component';
      prefixes.add(prefix);
    }
    for (final parent in prefixes.skip(1).take(components.length - 1)) {
      retainParentPath(parent);
    }
    final result = await command('/bin/sh', [
      '-c',
      // Each cd pins a physical directory. Check its canonical path and identity
      // before looking at a descendant, so a substituted ancestor cannot redirect
      // a later stat into another tree. This remains best-effort, not openat/CAS.
      r'''
unavailable() { printf 'unavailable\000'; exit 1; }
probe() {
  state=$(/usr/bin/stat --printf='%f %s %d %i %y %z' -- "$1" 2>&1)
  result=$?
  if [ "$result" -eq 0 ]; then return 0; fi
  if [ "$result" -eq 1 ]; then
    case "$state" in
      "/usr/bin/stat: cannot statx "*": No such file or directory") return 1 ;;
    esac
  fi
  printf '%s\n' "$state" >&2
  exit 2
}
root=$1
remaining=$2
parent=.
[ "$(/bin/pwd -P)" = "$root" ] || exit 2
probe . || exit 2
[ "$((0x${state%% *} & 61440))" -eq 16384 ] || exit 2
parent_state=$state
set -- . "$state"
while :; do
  component=${remaining%%/*}
  if [ "$parent" = . ]; then next=$component; else next=$parent/$component; fi
  if ! probe "./$component"; then
    probe . || exit 2
    [ "$state" = "$parent_state" ] || exit 2
    if [ "$parent" = . ]; then expected=$root; else expected=${root%/}/$parent; fi
    [ "$(/bin/pwd -P)" = "$expected" ] || exit 2
    printf '%s\000' "$@" "$next" absent
    exit 0
  fi
  [ "$remaining" != "$component" ] || unavailable
  [ "$((0x${state%% *} & 61440))" -eq 16384 ] || unavailable
  parent_state=$state
  CDPATH= cd -P -- "./$component" || exit 2
  [ "$(/bin/pwd -P)" = "${root%/}/$next" ] || exit 2
  probe . || exit 2
  [ "$state" = "$parent_state" ] || exit 2
  if probe ./.git; then unavailable; fi
  set -- "$@" "$next" "$parent_state"
  remaining=${remaining#*/}
  parent=$next
done
''',
      'adele-review-absence',
      repository!.root,
      path,
    ], allowDifference: true);
    final proof = _decodeContent(result.bytes);
    if (result.exitCode == 1) {
      if (proof != 'unavailable\u0000') throw _malformed();
      return null;
    }
    final records = _records(proof);
    if (records.length < 4 ||
        records.length.isOdd ||
        records.length > prefixes.length * 2 ||
        records.last != 'absent') {
      throw _malformed();
    }
    for (var index = 0; index < records.length ~/ 2; index++) {
      if (records[index * 2] != prefixes[index]) throw _malformed();
      if (index < records.length ~/ 2 - 1 &&
          _parsePathState(records[index * 2 + 1]).type != 0x4000) {
        throw _malformed();
      }
    }
    return proof;
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
      commentComparisonIdentity: null,
      fileReviewRevision: null,
      relativePath: path,
      reviewRevision: null,
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
      if (entry.kind == 'modified' && workingOid == entry.oid) {
        if (state.executable == (entry.oldMode == '100755')) {
          reviewableWorkingPaths.add(path);
        }
        return null;
      }
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
    verifyGitPatchContent(hunks, _decodeContent(old), _decodeContent(current));
    if (patch.exitCode == 0 && kind == 'modified') throw _changed();
    if (kind == 'modified' &&
        state != null &&
        state.executable == (entry.oldMode == '100755')) {
      reviewableWorkingPaths.add(path);
    }
    if (kind == 'added' && state != null) {
      // Untracked paths are not in the tracked hash batch. Hash only the bounded
      // raw bytes independently reread above, never Git's content-cleaning path.
      workingOids[path] = _blobHash(
        current,
        additionOidWidth ??= await readObjectWidth(),
      );
      reviewableWorkingPaths.add(path);
    }
    return ChangedFile(
      commentComparisonIdentity: missing
          ? null
          : await commentIdentity(
              path: path,
              kind: kind,
              layer: 'unstaged',
              oldSource: 'index',
              newSource: 'working',
              oldMode: entry.oid.isEmpty ? null : entry.oldMode,
              oldOid: entry.oid.isEmpty ? null : entry.oid,
              newMode: state!.executable ? '100755' : '100644',
              newOid: workingOids[path],
              hunks: hunks,
            ),
      fileReviewRevision: null,
      relativePath: path,
      reviewRevision: null,
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
    return classifyBytes(old, current, binaryAttribute: binaryAttribute);
  }

  ({String status, String detail})? classifyBytes(
    List<int> old,
    List<int> current, {
    bool binaryAttribute = false,
  }) {
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

  Future<ChangedFile?> inspectObjects(
    String path,
    String commit,
    GitIndexEntry? old,
    GitIndexEntry? current, {
    String? currentCommit,
  }) async {
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
      commentComparisonIdentity: null,
      fileReviewRevision: null,
      relativePath: path,
      reviewRevision: null,
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
    // Immutable committed objects do not inherit today's working attributes or
    // conversion settings. Cached comparisons retain their established policy.
    final classification = currentCommit == null
        ? await classify(path, left, right)
        : classifyBytes(left, right);
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
      if (currentCommit == null) '--cached',
      commit,
      ?currentCommit,
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
    verifyGitPatchContent(hunks, _decodeContent(left), _decodeContent(right));
    return ChangedFile(
      commentComparisonIdentity: await commentIdentity(
        path: path,
        kind: kind,
        layer: currentCommit == null ? 'staged' : 'committed',
        oldSource: currentCommit == null ? 'head' : 'baseline',
        newSource: currentCommit == null ? 'index' : 'head',
        oldMode: old?.oldMode,
        oldOid: old?.oid,
        newMode: current?.oldMode,
        newOid: current?.oid,
        hunks: hunks,
      ),
      fileReviewRevision: null,
      relativePath: path,
      reviewRevision: null,
      changeKind: kind,
      contentStatus: 'text',
      detail: null,
      hunks: hunks,
    );
  }

  Future<String?> commentIdentity({
    required String path,
    required String kind,
    required String layer,
    required String oldSource,
    required String newSource,
    required String? oldMode,
    required String? oldOid,
    required String? newMode,
    required String? newOid,
    required List<DiffHunk> hunks,
  }) async {
    if (!hunks.any((hunk) => hunk.lines.isNotEmpty) ||
        path.length > ReviewDraftLimits.maxPathLength ||
        path.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      return null;
    }
    checkOpen();
    final identity = capturedIdentity ??= await processes.capturedIdentity();
    checkOpen();
    const domain = 'git-comment-comparison-v1';
    final repo = repository!;
    // Only the selected comparison's source objects belong here, not whole-tree
    // commits, index inventory, approval state, or unrelated working metadata.
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode([
          domain,
          identity.sessionId,
          identity.environmentId,
          repo.root,
          repo.worktree,
          repo.directory,
          repo.prefix,
          layer,
          path,
          kind,
          ['old', oldSource, oldMode, oldOid],
          ['new', newSource, newMode, newOid],
          for (final hunk in hunks)
            [
              hunk.oldStart,
              hunk.oldCount,
              hunk.newStart,
              hunk.newCount,
              for (final line in hunk.lines)
                [line.kind, line.text, line.noNewline],
            ],
        ]),
      ),
    );
    return '$domain:$digest';
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
        'Layered changes require a valid HEAD commit.',
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

  Future<int> readObjectWidth() async => switch (_scalar(
    (await git(['rev-parse', '--show-object-format'])).bytes,
  )) {
    'sha1' => 40,
    'sha256' => 64,
    _ => throw _malformed(),
  };

  Future<void> validateCommit(
    String commit,
    int oidWidth, {
    required bool baseline,
  }) async {
    if (!_oid(commit) || commit.length != oidWidth) {
      if (!baseline) throw _malformed();
      throw _failure(
        'invalid_baseline',
        'The retained Task baseline is not an exact repository commit identity.',
      );
    }
    final String type;
    final List<int> bytes;
    try {
      // Do not peel tags or accept revision expressions as retained authority.
      type = _decode((await git(['cat-file', '-t', commit])).bytes);
      bytes = type == 'commit\n'
          ? (await git(['cat-file', 'commit', commit])).bytes
          : const [];
    } on ChangeSetFailure catch (error) {
      if (error.code != 'git_failed') rethrow;
      throw _failure(
        baseline ? 'baseline_unavailable' : 'head_unavailable',
        baseline
            ? 'The retained Task baseline commit is unavailable.'
            : 'The captured HEAD commit is unavailable.',
      );
    }
    if (type != 'commit\n' ||
        _objectHash(bytes, oidWidth, 'commit') != commit) {
      if (!baseline) throw _malformed();
      throw _failure(
        'invalid_baseline',
        'The retained Task baseline is not an exact commit identity.',
      );
    }
  }

  Future<List<int>?> blob(String oid) async {
    if (oid.isEmpty) return const [];
    if (!_oid(oid)) throw _malformed();
    final sizeText = _scalar((await git(['cat-file', '-s', oid])).bytes);
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(sizeText)) throw _malformed();
    final size = int.tryParse(sizeText);
    if (size == null) throw _malformed();
    objectSizes[oid] = size;
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
        states[path] = _parsePathState(records[index * 2 + 1]);
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
    untracked: _decodeContent(
      (await git([
        'ls-files',
        '--others',
        '--exclude-standard',
        '-z',
        '--',
        '.',
      ])).bytes,
    ),
    deleted: _decodeContent(
      (await git(['ls-files', '--deleted', '-z', '--', '.'])).bytes,
    ),
    killed: _decodeContent(
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

  Future<String> readAttributes(String path) async => _decodeContent(
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
    bool indexMutation = false,
  }) => command(
    '/usr/bin/git',
    gitArguments(arguments, detached: detached, discover: discover),
    input: input,
    detached: detached,
    allowDifference: allowDifference,
    indexMutation: indexMutation,
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
    bool indexMutation = false,
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
    chargeBytes(input.length);
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
    if (indexMutation) mutationAttempted = true;
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
    chargeBytes(output.length + errors.length);
    if (indexMutation && result.exitCode > 0) {
      // A nonzero exit is not itself proof of no effect. The review operation
      // must verify the unchanged preimage before reporting mutation_failed.
      return (bytes: output, exitCode: result.exitCode);
    }
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

_PathState _parsePathState(String raw) {
  final match = RegExp(
    r'^([0-9a-f]+) (\d+) (\d+) (\d+) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{9} [+-]\d{4}) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{9} [+-]\d{4})$',
  ).firstMatch(raw);
  if (match == null || match.end != raw.length) throw _malformed();
  final mode = int.tryParse(match[1]!, radix: 16);
  final size = int.tryParse(match[2]!);
  if (mode == null || size == null) throw _malformed();
  return _PathState(mode: mode, size: size, description: raw);
}

bool _oid(String value) =>
    const {40, 64}.contains(value.length) &&
    !RegExp(r'[^0-9a-f]').hasMatch(value);
String _blobHash(List<int> bytes, int oidLength) =>
    _objectHash(bytes, oidLength, 'blob');
String _objectHash(List<int> bytes, int oidLength, String type) =>
    (oidLength == 64 ? sha256 : sha1).convert([
      ...utf8.encode('$type ${bytes.length}\u0000'),
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
// Dart's UTF-8 decoder consumes a leading BOM. File contents, unlike process
// scalar metadata, must preserve those bytes when reconstructing an index object.
// Filename-first NUL inventories also use this decoder to retain literal names.
String _decodeContent(List<int> bytes) =>
    '${bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? '\ufeff' : ''}${_decode(bytes)}';
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
