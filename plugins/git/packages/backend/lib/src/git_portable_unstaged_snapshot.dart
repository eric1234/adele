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
    this.processes = 18432,
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

/// Index-to-working-tree inspection using only the captured process grant.
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

  Future<ChangeSetSnapshot> snapshotUnstaged() async {
    final operation = _PortableSnapshot(processes, limits);
    try {
      return await operation.snapshot().timeout(limits.operationTimeout);
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
  final Map<String, String> attributes = {};
  bool closed = false;
  int commandCount = 0;
  int byteCount = 0;
  int verificationBytes = 0;
  int lineCount = 0;
  int presentationBytes = 0;
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

  Future<ChangeSetSnapshot> snapshot() async {
    repository = await discover();
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
    final files = <ChangedFile>[];
    final paths = entries.keys.toList()..sort();
    for (final path in paths) {
      checkOpen();
      _validatePath(path);
      final file = await inspect(path, entries[path]!, deleted, killed);
      if (file == null) continue;
      if (files.length == limits.files) {
        throw _failure(
          'snapshot_too_large',
          'The change snapshot exceeds its file limit.',
        );
      }
      // Conservative escaped JSON allowance, independent of the binary I/O budget.
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
      files.add(file);
    }
    for (final entry in observed.entries) {
      if (await stat(entry.key) != entry.value) throw _changed();
    }
    for (final entry in attributes.entries) {
      if (await readAttributes(entry.key) != entry.value) throw _changed();
    }
    if (await enumerate() != inventory ||
        await readSettings() != settings ||
        await discover() != repository) {
      throw _changed();
    }
    checkOpen();
    return ChangeSetSnapshot(files: files);
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
        'Unmerged index entries are not rendered as text.',
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
        final parentState = observed[parent] ?? await stat(parent);
        observed[parent] = parentState;
        if (parentState.type != 0x4000) {
          return placeholder(
            'unsupported',
            'A parent path is a symbolic link or is not a directory.',
          );
        }
      }
      state = await stat(path);
      observed[path] = state;
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
      if (state.size > limits.fileBytes) {
        if (entry.kind == 'added') {
          return placeholder(
            'oversized',
            'The working file exceeds the rendering limit.',
            kind: 'added',
          );
        }
        if (state.size > limits.verificationFileBytes ||
            state.size > limits.verificationTotalBytes - verificationBytes) {
          return placeholder(
            'oversized',
            'The working file exceeds the verification budget; change state is unknown.',
          );
        }
        verificationBytes += state.size;
        final oid = _scalar(
          (await git(['hash-object', '--no-filters', '--', './$path'])).bytes,
        );
        if (!_oid(oid) || oid.length != entry.oid.length) throw _malformed();
        if (await stat(path) != state) throw _changed();
        if (oid == entry.oid) return null;
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
          _blobHash(current, entry.oid.length) == entry.oid) {
        return null;
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
    final attrs = await readAttributes(path);
    attributes[path] = attrs;
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
      return placeholder(
        'unsupported',
        'Git content conversion or custom diff attributes are not supported.',
        kind: kind,
      );
    }
    if (binaryAttribute || old.contains(0) || current.contains(0)) {
      return placeholder(
        'binary',
        'Binary content is not rendered as text.',
        kind: kind,
      );
    }
    try {
      utf8.decode(old, allowMalformed: false);
      utf8.decode(current, allowMalformed: false);
    } on FormatException {
      return placeholder(
        'unsupported',
        'Content is not valid UTF-8 text.',
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

  Future<_PathState> stat(String path) async {
    final raw = _decode(
      (await command('/usr/bin/stat', [
        '--printf=%f %s %d %i %y %z\n',
        '--',
        './$path',
      ])).bytes,
    );
    final match = RegExp(
      r'^([0-9a-f]+) (\d+) (\d+) (\d+) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{9} [+-]\d{4}) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{9} [+-]\d{4})\n$',
    ).firstMatch(raw);
    if (match == null) throw _malformed();
    final mode = int.tryParse(match[1]!, radix: 16);
    final size = int.tryParse(match[2]!);
    if (mode == null || size == null) throw _malformed();
    return _PathState(mode: mode, size: size, description: raw);
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
    if (inside != 'true' ||
        !root.startsWith('/') ||
        !worktree.startsWith('/') ||
        !directory.startsWith('/') ||
        root.contains('\u0000') ||
        directory.contains('\u0000') ||
        (root != worktree && !root.startsWith('$worktree/')) ||
        prefix !=
            (root == worktree
                ? ''
                : '${root.substring(worktree.length + 1)}/')) {
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
    [
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
    ],
    input: input,
    detached: detached,
    allowDifference: allowDifference,
  );

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
      arguments: [
        '-c',
        // Fixed code, never interpolated filenames or Git configuration. Only
        // argv crosses the shell; the child gets a deliberately small environment.
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
      ],
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
    byteCount += input.length + output.length + errors.length;
    if (byteCount > limits.totalBytes) {
      throw _failure(
        'snapshot_too_large',
        'The snapshot exceeds its aggregate byte budget.',
      );
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

bool _oid(String value) =>
    RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(value);
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
