import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

import 'git_process_environment.dart';
import 'git_worktree_environment_provider.dart';
import 'worktree_environment.dart';

/// Provider-local bounds, not caller-selected request settings.
final class GitChangeSetLimits {
  const GitChangeSetLimits({
    this.files = 256,
    this.inventoryEntries = 4096,
    this.fileBytes = 1024 * 1024,
    this.outputBytes = 2 * 1024 * 1024,
    this.stderrBytes = 64 * 1024,
    this.totalBytes = 8 * 1024 * 1024,
    this.lines = 8192,
    this.processTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 30),
  });

  final int files;
  final int inventoryEntries;
  final int fileBytes;
  final int outputBytes;
  final int stderrBytes;
  final int totalBytes;
  final int lines;
  final Duration processTimeout;
  final Duration operationTimeout;
}

final class GitChangeSetSourceService implements ChangeSetSourceService {
  GitChangeSetSourceService({
    required this.provider,
    required this.authorizedRead,
    this.limits = const GitChangeSetLimits(),
    Map<String, String>? parentEnvironment,
  }) : _parentEnvironment = Map.unmodifiable(
         parentEnvironment ?? Platform.environment,
       ) {
    const defaults = GitChangeSetLimits();
    for (final (value, maximum) in [
      (limits.files, defaults.files),
      (limits.inventoryEntries, defaults.inventoryEntries),
      (limits.fileBytes, defaults.fileBytes),
      (limits.outputBytes, defaults.outputBytes),
      (limits.stderrBytes, defaults.stderrBytes),
      (limits.totalBytes, defaults.totalBytes),
      (limits.lines, defaults.lines),
      (
        limits.processTimeout.inMicroseconds,
        defaults.processTimeout.inMicroseconds,
      ),
      (
        limits.operationTimeout.inMicroseconds,
        defaults.operationTimeout.inMicroseconds,
      ),
    ]) {
      if (value < 1 || value > maximum) {
        throw ArgumentError('Snapshot limits may only be reduced.');
      }
    }
  }

  final GitWorktreeEnvironmentProvider provider;
  final AuthorizedEnvironmentReadService authorizedRead;
  final GitChangeSetLimits limits;
  final Map<String, String> _parentEnvironment;

  @override
  Future<ChangeSetSnapshot> snapshotUnstaged() async {
    final operation = _SnapshotOperation(limits, _parentEnvironment);
    try {
      return await (() async {
        final identity = await authorizedRead.authority();
        final id = EnvironmentId(identity.environmentId);
        WorktreeEnvironment resolve() {
          operation.checkOpen();
          if (!provider.liveObjects.contains(id)) {
            throw _failure(
              'environment_not_live',
              'The Environment is no longer live.',
            );
          }
          return provider.liveObjects.resolve(id);
        }

        final environment = resolve();
        final result = await operation.snapshot(environment);
        if (!identical(resolve(), environment)) {
          throw _failure(
            'environment_not_live',
            'The Environment binding changed.',
          );
        }
        // Revalidate the operation grant, not merely the locally retained object.
        final current = await authorizedRead.authority();
        if (current.environmentId != identity.environmentId ||
            current.sessionId != identity.sessionId) {
          throw _failure(
            'authority_changed',
            'The Environment authority changed.',
          );
        }
        return result;
      })().timeout(limits.operationTimeout);
    } on TimeoutException {
      throw _failure(
        'operation_timeout',
        'The change snapshot exceeded its deadline.',
      );
    } on FileSystemException {
      throw _failure(
        'snapshot_unavailable',
        'The change snapshot could not read its files.',
      );
    } finally {
      await operation.close();
    }
  }
}

final class _SnapshotOperation {
  _SnapshotOperation(this.limits, this.parentEnvironment);

  final GitChangeSetLimits limits;
  final Map<String, String> parentEnvironment;
  final Set<Process> _processes = {};
  final Set<StreamSubscription<List<int>>> _pipes = {};
  final Set<void Function()> _abortProcesses = {};
  final Map<String, FileStat> _observed = {};
  Directory? _temporary;
  late Directory _gitDirectory;
  late Directory _worktreeRoot;
  bool _closed = false;
  int _totalBytes = 0;
  int _lines = 0;
  bool _contentConversion = false;
  bool _fileMode = true;

  void checkOpen() {
    if (_closed) {
      throw _failure(
        'operation_timeout',
        'The change snapshot is no longer active.',
      );
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final abort in _abortProcesses.toList()) {
      abort();
    }
    for (final process in _processes) {
      process.kill(ProcessSignal.sigkill);
    }
    for (final pipe in _pipes.toList()) {
      unawaited(pipe.cancel());
    }
    final temporary = _temporary;
    if (temporary != null) {
      try {
        await temporary
            .delete(recursive: true)
            .timeout(const Duration(seconds: 1));
      } on Object {
        // This directory contains only bounded private copies, never source files.
      }
    }
  }

  Future<ChangeSetSnapshot> snapshot(WorktreeEnvironment environment) async {
    final root = environment.root;
    if (environment.gitDirectory == null ||
        environment.gitWorktreeRoot == null) {
      throw _failure(
        'git_identity_unavailable',
        'The live Environment has no bound Git repository identity.',
      );
    }
    _gitDirectory = environment.gitDirectory!;
    _worktreeRoot = environment.gitWorktreeRoot!;
    await _validateRoot(_gitDirectory);
    await _validateRoot(_worktreeRoot);
    if (root.path != _worktreeRoot.path &&
        !root.path.startsWith(
          '${_worktreeRoot.path}${Platform.pathSeparator}',
        )) {
      throw _failure(
        'git_identity_unavailable',
        'The live Environment is outside its bound Git worktree.',
      );
    }
    await _validateRoot(root);
    final settings = await _settings(root);
    final effectiveSettings = <String, String>{};
    for (final entry in _nulRecords(settings)) {
      final newline = entry.indexOf('\n');
      final key = newline < 0 ? entry : entry.substring(0, newline);
      final value = newline < 0
          ? ''
          : entry.substring(newline + 1).toLowerCase();
      effectiveSettings[key] = value;
    }
    const falseValues = {'false', 'no', 'off', '0'};
    _fileMode = !falseValues.contains(effectiveSettings['core.filemode']);
    _contentConversion =
        effectiveSettings.containsKey('core.eol') ||
        (effectiveSettings.containsKey('core.autocrlf') &&
            !falseValues.contains(effectiveSettings['core.autocrlf']));
    final before = await _enumerate(root);
    final files = <ChangedFile>[];
    var wireBytes = 64;
    for (final entry in before.entries) {
      checkOpen();
      final file = await _file(root, entry.key, entry.value);
      if (file != null) {
        // Leave framing/DTO headroom below the host's bounded transport. Count
        // escaped text, not just input bytes (control characters expand in JSON).
        wireBytes += utf8.encode(jsonEncode(file.relativePath)).length + 512;
        for (final hunk in file.hunks) {
          wireBytes += 128;
          for (final line in hunk.lines) {
            wireBytes += utf8.encode(jsonEncode(line.text)).length + 96;
          }
        }
        if (wireBytes > 6 * 1024 * 1024) {
          throw _failure(
            'snapshot_too_large',
            'The change snapshot exceeds its transport budget.',
          );
        }
        files.add(file);
        if (files.length > limits.files) {
          throw _failure(
            'too_many_files',
            'The change snapshot exceeds the supported file count.',
          );
        }
      }
    }
    final after = await _enumerate(root);
    if (settings != await _settings(root) ||
        before.length != after.length ||
        before.entries.any((entry) => after[entry.key] != entry.value)) {
      throw _failure(
        'snapshot_changed',
        'The index or working tree changed during the snapshot.',
      );
    }
    for (final entry in _observed.entries) {
      if (!_sameState(entry.value, await _directState(root, entry.key))) {
        throw _failure(
          'snapshot_changed',
          'A working file changed before snapshot completion.',
        );
      }
    }
    await _validateRoot(root);
    await _validateRoot(_gitDirectory);
    await _validateRoot(_worktreeRoot);
    return ChangeSetSnapshot(files: files);
  }

  Future<String> _settings(Directory root) async => _decode(
    (await git(root, [
      'config',
      '--null',
      '--get-regexp',
      r'^core\.(autocrlf|eol|filemode)$',
    ], allowDifference: true)).bytes,
  );

  Future<void> _validateRoot(Directory root) async {
    checkOpen();
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await root.resolveSymbolicLinks() != root.path) {
      throw _failure(
        'snapshot_changed',
        'The Environment root is no longer a direct directory.',
      );
    }
  }

  Future<Map<String, GitIndexEntry>> _enumerate(Directory root) async {
    // Cached inventory never hashes worktree content or invokes clean filters.
    // --modified/diff-files are unsafe here, even when only raw output is asked.
    final changes = parseGitIndex(
      _decode(
        (await git(root, [
          'ls-files',
          '--cached',
          '--stage',
          '--debug',
          '-z',
          '--',
          '.',
        ])).bytes,
      ),
      maximumEntries: limits.inventoryEntries,
    );
    final untracked = await git(root, [
      'ls-files',
      '--others',
      '--exclude-standard',
      '-z',
      '--',
      '.',
    ]);
    addGitUntrackedEntries(
      _decode(untracked.bytes),
      changes,
      maximumEntries: limits.inventoryEntries,
    );
    final paths = changes.keys.toList()..sort();
    return {for (final path in paths) path: changes[path]!};
  }

  Future<ChangedFile?> _file(
    Directory root,
    String path,
    GitIndexEntry change,
  ) async {
    ChangedFile placeholder(String status, String detail) => ChangedFile(
      relativePath: path,
      changeKind: change.kind,
      contentStatus: status,
      detail: detail,
      hunks: const [],
    );
    if (change.kind == 'untrackedRepository') {
      return ChangedFile(
        relativePath: path,
        changeKind: 'unsupported',
        contentStatus: 'unsupported',
        detail: 'Nested repository contents were not inspected.',
        hunks: const [],
      );
    }
    if (change.kind == 'conflicted') {
      return placeholder(
        'conflicted',
        'Unmerged index entries are not rendered as a text diff.',
      );
    }
    if (change.oldMode == '160000' || change.newMode == '160000') {
      return placeholder(
        'unsupported',
        'Submodule content not inspected; change state unavailable.',
      );
    }
    if (change.oldMode == '120000' || change.newMode == '120000') {
      try {
        await _directState(root, path);
      } on ChangeSetFailure catch (error) {
        if (error.code != 'symlink_path') rethrow;
        final target = utf8.encode(await Link('${root.path}/$path').target());
        final hash = change.oid.length == 64 ? sha256 : sha1;
        if (hash.convert([
              ...utf8.encode('blob ${target.length}\u0000'),
              ...target,
            ]).toString() ==
            change.oid) {
          return null;
        }
      }
      return placeholder(
        'unsupported',
        'Symbolic-link changes are not supported.',
      );
    }
    if (change.kind == 'typeChanged' || change.kind == 'unsupported') {
      return placeholder(
        'unsupported',
        'File type, mode, or index flags prevent ordinary text inspection.',
      );
    }

    final FileStat state;
    try {
      state = await _directState(root, path);
    } on ChangeSetFailure catch (error) {
      if (error.code != 'symlink_path') rethrow;
      return placeholder('unsupported', 'Symbolic links are not followed.');
    }
    _observed[path] = state;
    final deleted =
        state.type == FileSystemEntityType.notFound && change.kind != 'added';
    if (deleted) {
      change = (
        oldMode: change.oldMode,
        newMode: '000000',
        oid: change.oid,
        kind: 'deleted',
      );
    }
    if (state.type !=
        (deleted ? FileSystemEntityType.notFound : FileSystemEntityType.file)) {
      return placeholder(
        'unsupported',
        'The path is missing, changed type, or is not a regular file.',
      );
    }
    if (state.size > limits.fileBytes) {
      if (change.kind == 'modified') {
        change = (
          oldMode: change.oldMode,
          newMode: change.newMode,
          oid: change.oid,
          kind: 'unsupported',
        );
      }
      return placeholder(
        'oversized',
        'The working file exceeds the supported size; content change state is unavailable.',
      );
    }
    if (!deleted &&
        change.kind == 'modified' &&
        _fileMode &&
        !Platform.isWindows &&
        ((state.mode & 0x49) != 0) != (change.oldMode == '100755')) {
      change = (
        oldMode: change.oldMode,
        newMode: change.newMode,
        oid: change.oid,
        kind: 'typeChanged',
      );
      return placeholder(
        'unsupported',
        'File mode changes are not rendered as text.',
      );
    }
    final current = deleted ? Uint8List(0) : await _readFile(root, path);
    if (current == null) {
      return placeholder(
        'oversized',
        'The working file exceeds the supported size.',
      );
    }
    if (!_sameState(state, await _directState(root, path))) {
      throw _failure(
        'snapshot_changed',
        'A working file changed during the snapshot.',
      );
    }
    if (change.kind == 'modified') {
      final hash = change.oid.length == 64 ? sha256 : sha1;
      if (hash.convert([
            ...utf8.encode('blob ${current.length}\u0000'),
            ...current,
          ]).toString() ==
          change.oid) {
        return null;
      }
    }
    final attributes = _nulRecords(
      _decode(
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
      ),
    );
    if (attributes.length != 18) throw _malformed();
    Uint8List old = Uint8List(0);
    if (change.oid.isNotEmpty && !RegExp(r'^0+$').hasMatch(change.oid)) {
      final size = await git(root, ['cat-file', '-s', change.oid]);
      final count = int.tryParse(_decode(size.bytes).trim());
      if (count == null || count < 0) throw _malformed();
      if (count > limits.fileBytes) {
        return placeholder(
          'oversized',
          'The index file exceeds the supported size.',
        );
      }
      old = (await git(root, [
        'cat-file',
        'blob',
        change.oid,
      ], maximum: limits.fileBytes)).bytes;
      if (old.length != count) throw _malformed();
    }
    if (_contentConversion) {
      return placeholder(
        'unsupported',
        'Configured line-ending conversion is not supported.',
      );
    }
    for (var i = 0; i < attributes.length; i += 3) {
      if (attributes[i] != path) throw _malformed();
      final name = attributes[i + 1];
      final value = attributes[i + 2];
      if (name == 'diff' && value == 'unset') {
        return placeholder(
          'binary',
          'Git attributes mark this file as binary.',
        );
      }
      if (value != 'unspecified' &&
          value != 'unset' &&
          !(name == 'diff' && value == 'set')) {
        return placeholder(
          'unsupported',
          'Git content conversion or custom diff attributes are not supported.',
        );
      }
    }
    if (old.contains(0) || current.contains(0)) {
      return placeholder('binary', 'Binary content is not rendered as text.');
    }
    try {
      utf8.decode(old, allowMalformed: false);
      utf8.decode(current, allowMalformed: false);
    } on FormatException {
      return placeholder('unsupported', 'Content is not valid UTF-8 text.');
    }
    _totalBytes += old.length + current.length;
    if (_totalBytes > limits.totalBytes) {
      throw _failure(
        'snapshot_too_large',
        'The change snapshot exceeds its total content limit.',
      );
    }
    if (_temporary == null) {
      final topLevel = _decode(
        (await git(root, ['rev-parse', '--show-toplevel'])).bytes,
      );
      if (!topLevel.endsWith('\n')) throw _malformed();
      final worktree = await Directory(
        topLevel.substring(0, topLevel.length - 1),
      ).resolveSymbolicLinks();
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      if (temporaryRoot == worktree ||
          temporaryRoot.startsWith('$worktree${Platform.pathSeparator}')) {
        throw _failure(
          'temporary_unavailable',
          'Private diff snapshots cannot be placed in the source worktree.',
        );
      }
      final temporary = await Directory(
        temporaryRoot,
      ).createTemp('adele-git-diff-');
      _temporary = temporary;
      if (_closed) {
        await close();
        checkOpen();
      }
    }
    checkOpen();
    final temporary = _temporary!;
    await File('${temporary.path}/old').writeAsBytes(old);
    await File('${temporary.path}/new').writeAsBytes(current);
    final _GitOutput patch;
    try {
      patch = await git(
        temporary,
        [
          'diff',
          '--no-index',
          '--no-ext-diff',
          '--no-textconv',
          '--no-renames',
          '--no-color',
          '--no-prefix',
          '--diff-algorithm=myers',
          '--no-indent-heuristic',
          '--unified=3',
          '--inter-hunk-context=0',
          '--',
          change.kind == 'added' ? _nullDevice : 'old',
          deleted ? _nullDevice : 'new',
        ],
        detached: true,
        allowDifference: true,
      );
    } on ChangeSetFailure catch (error) {
      if (error.code != 'git_output_limit') rethrow;
      return placeholder(
        'oversized',
        'The text patch exceeds the supported output size.',
      );
    }
    if (!_sameState(state, await _directState(root, path))) {
      throw _failure(
        'snapshot_changed',
        'A working file changed during patch generation.',
      );
    }
    if (patch.exitCode == 0 && change.kind == 'modified') return null;
    final hunks = parseGitPatch(
      _decode(patch.bytes),
      maximumLines: limits.lines - _lines,
    );
    _lines += hunks.fold(0, (total, hunk) => total + hunk.lines.length);
    _totalBytes += patch.bytes.length;
    if (_lines > limits.lines || _totalBytes > limits.totalBytes) {
      throw _failure(
        'snapshot_too_large',
        'The change snapshot exceeds its total output limit.',
      );
    }
    return ChangedFile(
      relativePath: path,
      changeKind: change.kind,
      contentStatus: 'text',
      detail: null,
      hunks: hunks,
    );
  }

  Future<Uint8List?> _readFile(Directory root, String path) async {
    checkOpen();
    final file = await File('${root.path}/$path').open();
    try {
      final bytes = BytesBuilder(copy: false);
      while (bytes.length <= limits.fileBytes) {
        checkOpen();
        final chunk = await file.read(
          (limits.fileBytes + 1 - bytes.length).clamp(1, 65536),
        );
        if (chunk.isEmpty) return bytes.takeBytes();
        bytes.add(chunk);
      }
      return null;
    } finally {
      await file.close();
    }
  }

  Future<FileStat> _directState(Directory root, String path) async {
    await _validateRoot(root);
    final parts = path.split('/');
    var parent = root.path;
    for (final part in parts.take(parts.length - 1)) {
      parent = '$parent/$part';
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return FileStat.stat('$parent/${parts.last}');
      }
      if (type != FileSystemEntityType.directory) {
        throw _failure(
          'snapshot_changed',
          'A changed path has an indirect or invalid parent.',
        );
      }
    }
    final target = '${root.path}/$path';
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw _failure('symlink_path', 'A changed path became a symbolic link.');
    }
    return FileStat.stat(target);
  }

  Future<_GitOutput> git(
    Directory directory,
    List<String> arguments, {
    int? maximum,
    bool detached = false,
    bool allowDifference = false,
  }) async {
    checkOpen();
    final environment = <String, String>{
      ...gitProcessEnvironment(
        parentEnvironment: parentEnvironment,
        readOnlyInspection: true,
      ),
      'PWD': directory.path,
      if (detached) 'GIT_CEILING_DIRECTORIES': directory.parent.path,
      if (detached) ...{
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_SYSTEM': _nullDevice,
        'GIT_CONFIG_GLOBAL': _nullDevice,
        'GIT_ATTR_NOSYSTEM': '1',
      },
    };
    if (environment['PATH']!.isEmpty) {
      throw _failure(
        'git_unavailable',
        'Git requires a nonempty absolute executable search path.',
      );
    }
    Process? process;
    final subscriptions = <StreamSubscription<List<int>>>[];
    final complete = Completer<_GitOutput>();
    final output = BytesBuilder(copy: false);
    var errors = 0;
    var outputDone = false;
    var errorDone = false;
    int? code;
    void finish() {
      if (!complete.isCompleted && outputDone && errorDone && code != null) {
        complete.complete(_GitOutput(output.takeBytes(), code!));
      }
    }

    void fail(ChangeSetFailure failure) {
      process?.kill(ProcessSignal.sigkill);
      if (!complete.isCompleted) complete.completeError(failure);
    }

    void abort() => fail(
      _failure('operation_timeout', 'The change snapshot is no longer active.'),
    );

    final watch = Stopwatch()..start();
    Timer? timer;
    var launchExpired = false;
    try {
      final started =
          await Process.start(
                'git',
                [
                  '--no-pager',
                  '--literal-pathspecs',
                  if (!detached) '--git-dir=${_gitDirectory.path}',
                  if (!detached) '--work-tree=${_worktreeRoot.path}',
                  '-c',
                  'core.fsmonitor=false',
                  '-c',
                  'core.untrackedCache=false',
                  if (detached) ...[
                    '-c',
                    'core.attributesFile=$_nullDevice',
                    '-c',
                    'core.autocrlf=false',
                    '-c',
                    'core.eol=lf',
                  ],
                  '-c',
                  'diff.external=',
                  ...arguments,
                ],
                workingDirectory: directory.path,
                environment: environment,
                includeParentEnvironment: false,
              )
              .then((started) {
                if (_closed || launchExpired) {
                  started.kill(ProcessSignal.sigkill);
                }
                return started;
              })
              .timeout(
                limits.processTimeout,
                onTimeout: () {
                  launchExpired = true;
                  throw _failure(
                    'git_timeout',
                    'Git could not start before its deadline.',
                  );
                },
              );
      process = started;
      checkOpen();
      _processes.add(started);
      _abortProcesses.add(abort);
      unawaited(started.stdin.close());
      timer = Timer(
        limits.processTimeout - watch.elapsed,
        () => fail(
          _failure(
            'git_timeout',
            'Git exceeded the change snapshot process deadline.',
          ),
        ),
      );
      void listen(Stream<List<int>> stream, bool stdout) {
        final subscription = stream.listen(
          (chunk) {
            if (complete.isCompleted) return;
            if (stdout) {
              if (output.length + chunk.length >
                  (maximum ?? limits.outputBytes)) {
                fail(
                  _failure(
                    'git_output_limit',
                    'Git output exceeded its byte limit.',
                  ),
                );
              } else {
                output.add(chunk);
              }
            } else {
              errors += chunk.length;
              if (errors > limits.stderrBytes) {
                fail(
                  _failure(
                    'git_diagnostic_limit',
                    'Git diagnostics exceeded their byte limit.',
                  ),
                );
              }
            }
          },
          onError: (Object _) =>
              fail(_failure('git_failed', 'Git output could not be read.')),
          onDone: () {
            if (stdout) {
              outputDone = true;
            } else {
              errorDone = true;
            }
            finish();
          },
        );
        subscriptions.add(subscription);
        _pipes.add(subscription);
      }

      listen(started.stdout, true);
      listen(started.stderr, false);
      unawaited(
        started.exitCode.then((value) {
          code = value;
          finish();
        }),
      );
      final result = await complete.future;
      checkOpen();
      if (result.exitCode != 0 && !(allowDifference && result.exitCode == 1)) {
        throw _failure(
          'git_failed',
          'Git could not produce the change snapshot.',
        );
      }
      return result;
    } on ProcessException {
      throw _failure('git_unavailable', 'Git could not be started.');
    } finally {
      timer?.cancel();
      _abortProcesses.remove(abort);
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
        _pipes.remove(subscription);
      }
      if (process != null) {
        if (code == null) process.kill(ProcessSignal.sigkill);
        _processes.remove(process);
      }
    }
  }
}

typedef GitIndexEntry = ({
  String oldMode,
  String newMode,
  String oid,
  String kind,
});

/// Parses public ls-files --cached --stage --debug -z output. Paths end at NUL;
/// fixed metadata follows each path. Unknown metadata formats fail closed.
Map<String, GitIndexEntry> parseGitIndex(
  String raw, {
  int maximumEntries = 4096,
}) {
  final changes = <String, GitIndexEntry>{};
  final header = RegExp(r'^([0-7]{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-3])$');
  final metadata = RegExp(
    r'  ctime: \d+:\d+\n  mtime: \d+:\d+\n  dev: \d+\tino: \d+\n  uid: \d+\tgid: \d+\n  size: \d+\tflags: ([0-9a-f]+)\n',
  );
  var offset = 0;
  var entries = 0;
  while (offset < raw.length) {
    if (++entries > maximumEntries) {
      throw _failure(
        'inventory_too_large',
        'The index inventory exceeds the supported entry count.',
      );
    }
    final nul = raw.indexOf('\u0000', offset);
    final tab = raw.indexOf('\t', offset);
    if (nul < 0 || tab < offset || tab > nul) throw _malformed();
    final match = header.firstMatch(raw.substring(offset, tab));
    if (match == null) throw _malformed();
    final path = raw.substring(tab + 1, nul);
    _validatePath(path);
    final stat = metadata.matchAsPrefix(raw, nul + 1);
    if (stat == null) throw _malformed();
    offset = stat.end;
    final flags = int.tryParse(stat[1]!, radix: 16);
    if (flags == null) throw _malformed();
    final oldMode = match[1]!;
    final intentToAdd = (flags & 0x20000000) != 0;
    final kind = match[3] != '0'
        ? 'conflicted'
        : (flags & 0x40008000) != 0 || oldMode == '160000'
        ? 'unsupported'
        : intentToAdd
        ? 'added'
        : 'modified';
    if (changes[path]?.kind == 'conflicted') continue;
    if (changes.containsKey(path) && kind != 'conflicted') throw _malformed();
    changes[path] = (
      oldMode: intentToAdd ? '000000' : oldMode,
      newMode: oldMode,
      oid: intentToAdd ? '' : match[2]!,
      kind: kind,
    );
  }
  return changes;
}

/// Adds ls-files --others -z records without collecting an unbounded record list.
/// Only this untracked output permits a nested repository's trailing slash.
void addGitUntrackedEntries(
  String raw,
  Map<String, GitIndexEntry> changes, {
  int maximumEntries = 4096,
}) {
  var offset = 0;
  while (offset < raw.length) {
    final nul = raw.indexOf('\u0000', offset);
    if (nul < 0) throw _malformed();
    final record = raw.substring(offset, nul);
    offset = nul + 1;
    final directory = record.endsWith('/');
    final path = directory ? record.substring(0, record.length - 1) : record;
    _validatePath(path);
    if (changes.containsKey(path)) {
      throw _failure(
        'snapshot_changed',
        'A path changed index membership during enumeration.',
      );
    }
    if (changes.length >= maximumEntries) {
      throw _failure(
        'inventory_too_large',
        'The tracked and untracked inventory exceeds the supported entry count.',
      );
    }
    changes[path] = (
      oldMode: '000000',
      newMode: directory ? '040000' : '100644',
      oid: '',
      kind: directory ? 'untrackedRepository' : 'added',
    );
  }
}

/// Strict unified-hunk parser. Header path strings never establish path identity.
List<DiffHunk> parseGitPatch(String patch, {int maximumLines = 8192}) {
  if (patch.isEmpty) return [];
  if (!patch.endsWith('\n')) throw _malformed();
  final records = patch.substring(0, patch.length - 1).split('\n');
  final hunks = <DiffHunk>[];
  final header = RegExp(
    r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$',
  );
  var index = 0;
  var sawDiff = false;
  var sawOld = false;
  var sawNew = false;
  var sawMode = false;
  var sawIndex = false;
  while (index < records.length && !records[index].startsWith('@@')) {
    final line = records[index++];
    if (line.startsWith('diff --git ')) {
      if (sawDiff) throw _malformed();
      sawDiff = true;
    } else if (line.startsWith('index ')) {
      if (sawIndex ||
          !RegExp(
            r'^index [0-9a-f]+\.\.[0-9a-f]+(?: [0-7]{6})?$',
          ).hasMatch(line)) {
        throw _malformed();
      }
      sawIndex = true;
    } else if (line.startsWith('--- ')) {
      if (sawOld) throw _malformed();
      sawOld = true;
    } else if (line.startsWith('+++ ')) {
      if (sawNew) throw _malformed();
      sawNew = true;
    } else if (RegExp(r'^(?:new|deleted) file mode [0-7]{6}$').hasMatch(line)) {
      if (sawMode) throw _malformed();
      sawMode = true;
    } else {
      throw _malformed();
    }
  }
  if (!sawDiff ||
      !sawIndex ||
      (index < records.length ? !(sawOld && sawNew) : !sawMode)) {
    throw _malformed();
  }
  var previousOldEnd = 0;
  var previousNewEnd = 0;
  var lineCount = 0;
  while (index < records.length) {
    final match = header.firstMatch(records[index++]);
    if (match == null) throw _malformed();
    final oldStart = int.tryParse(match[1]!);
    final newStart = int.tryParse(match[3]!);
    final oldCount = int.tryParse(match[2] ?? '1');
    final newCount = int.tryParse(match[4] ?? '1');
    if (oldStart == null ||
        newStart == null ||
        oldCount == null ||
        newCount == null ||
        oldStart < previousOldEnd ||
        newStart < previousNewEnd ||
        (oldCount > 0 && oldStart == 0) ||
        (newCount > 0 && newStart == 0)) {
      throw _malformed();
    }
    var oldSeen = 0;
    var newSeen = 0;
    final lines = <DiffLine>[];
    while (index < records.length && !records[index].startsWith('@@')) {
      final line = records[index++];
      if (line == r'\ No newline at end of file') {
        if (lines.isEmpty || lines.last.noNewline) throw _malformed();
        final previous = lines.removeLast();
        lines.add(
          DiffLine(kind: previous.kind, text: previous.text, noNewline: true),
        );
        continue;
      }
      if (line.isEmpty) throw _malformed();
      if (++lineCount > maximumLines) {
        throw _failure(
          'snapshot_too_large',
          'The change snapshot exceeds its line limit.',
        );
      }
      final kind = switch (line[0]) {
        ' ' => 'context',
        '+' => 'addition',
        '-' => 'deletion',
        _ => throw _malformed(),
      };
      if (kind != 'addition') oldSeen++;
      if (kind != 'deletion') newSeen++;
      if (oldSeen > oldCount || newSeen > newCount) throw _malformed();
      lines.add(
        DiffLine(kind: kind, text: line.substring(1), noNewline: false),
      );
    }
    if (oldSeen != oldCount || newSeen != newCount || lines.isEmpty) {
      throw _malformed();
    }
    hunks.add(
      DiffHunk(
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        lines: lines,
      ),
    );
    previousOldEnd = oldStart + oldCount;
    previousNewEnd = newStart + newCount;
  }
  return hunks;
}

List<String> _nulRecords(String value) {
  if (value.isEmpty) return [];
  if (!value.endsWith('\u0000')) throw _malformed();
  return value.substring(0, value.length - 1).split('\u0000');
}

void _validatePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\u0000') ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..') ||
      (Platform.isWindows && (path.contains('\\') || path.contains(':')))) {
    throw _malformed();
  }
}

bool _sameState(FileStat a, FileStat b) =>
    a.type == b.type &&
    a.size == b.size &&
    a.mode == b.mode &&
    a.modified == b.modified &&
    a.changed == b.changed;

String _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw _malformed();
  }
}

String get _nullDevice => Platform.isWindows ? 'NUL' : '/dev/null';
ChangeSetFailure _failure(String code, String message) =>
    ChangeSetFailure(code: code, message: message);
ChangeSetFailure _malformed() => _failure(
  'invalid_git_output',
  'Git returned an unsupported or malformed change description.',
);

final class _GitOutput {
  const _GitOutput(this.bytes, this.exitCode);
  final Uint8List bytes;
  final int exitCode;
}
