@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';
import 'package:git_backend/git_backend.dart'
    show GitPortableUnstagedSnapshotService;
import 'package:git_backend/src/git_snapshot_parsing.dart' show parseGitPatch;
import 'package:test/test.dart';

void main() {
  late Directory container;
  late Directory repository;
  late _Processes processes;
  late EnvironmentBufferedProcessRequest sourceRequest;

  Future<void> write(String path, String text) async {
    final file = File('${repository.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<String> commit() async {
    await _git(repository, ['add', '--all']);
    await _git(repository, ['commit', '-m', 'Fixture']);
    return (await _git(repository, ['rev-parse', 'HEAD'])).trim();
  }

  Future<void> capture([String prefix = '']) async {
    processes = _Processes(Directory('${repository.path}/$prefix'), container);
    await GitPortableUnstagedSnapshotService(
      processes: processes,
    ).snapshotUnstaged();
    sourceRequest = processes.requests.firstWhere(
      (request) =>
          request.arguments.contains('ls-files') &&
          request.arguments.contains('--cached'),
    );
    expect(sourceRequest.program, '/bin/sh');
    expect(
      sourceRequest.arguments,
      contains('--git-dir=${repository.path}/.git'),
    );
    expect(sourceRequest.arguments, contains('--work-tree=${repository.path}'));
  }

  Future<EnvironmentBufferedProcessResult> cached(
    String commit,
    String path, {
    bool exitCode = true,
    String? diffFilter,
  }) => processes.runBufferedProcess(
    _withCommand(
      sourceRequest,
      _cachedArguments(
        commit,
        path,
        exitCode: exitCode,
        diffFilter: diffFilter,
      ),
    ),
  );

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-cached-diff-');
    repository = await Directory('${container.path}/repository').create();
    await _git(repository, ['init', '--initial-branch=main']);
    await _git(repository, ['config', 'user.name', 'ADELE Test']);
    await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
    await write('tracked', 'before\n\nsame\nold tail');
    await commit();
    await capture();
  });

  tearDown(() async {
    await container.delete(recursive: true);
  });

  test(
    'cached diff cannot execute configured helpers or read FIFO workfiles',
    () async {
      const paths = [
        'clean',
        'process',
        'custom',
        'external',
        'fifo',
        'missing',
      ];
      for (final path in paths) {
        await write(path, 'before\n\nsame\nold tail');
      }
      final captured = await commit();
      for (final path in paths) {
        await write(path, 'after\n\nsame\nnew tail');
      }
      await _git(repository, ['add', '--all']);

      final helpers = <String, String>{};
      for (final name in [
        'clean',
        'process',
        'textconv',
        'external',
        'fsmonitor',
        'post-index-change',
      ]) {
        final helper = File('${container.path}/$name');
        await helper.writeAsString(
          '#!/bin/sh\nprintf executed > "${container.path}/$name.executed"\nexit 99\n',
        );
        await _command('/usr/bin/chmod', ['+x', helper.path]);
        helpers[name] = helper.path;
      }
      for (final (key, value) in [
        ('filter.clean.clean', helpers['clean']!),
        ('filter.clean.required', 'true'),
        ('filter.process.process', helpers['process']!),
        ('filter.process.required', 'true'),
        ('diff.hostile.textconv', helpers['textconv']!),
        ('diff.hostile.command', helpers['external']!),
        ('diff.external', helpers['external']!),
        ('core.fsmonitor', helpers['fsmonitor']!),
        ('core.hooksPath', container.path),
        ('core.untrackedCache', 'true'),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      await File('${repository.path}/.git/info/attributes').writeAsString(
        'clean filter=clean\nprocess filter=process\ncustom diff=hostile\n',
      );
      await File('${repository.path}/fifo').delete();
      await _command('/usr/bin/mkfifo', ['${repository.path}/fifo']);
      await File('${repository.path}/missing').delete();
      processes.environment.addAll({
        'GIT_EXTERNAL_DIFF': helpers['external']!,
        'GIT_DIFF_OPTS': '--unified=0',
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'core.fsmonitor',
        'GIT_CONFIG_VALUE_0': helpers['fsmonitor']!,
        'GIT_INDEX_FILE': '${container.path}/wrong-index',
        'GIT_DIR': '${container.path}/wrong-repository',
        'GIT_TRACE': '${container.path}/trace.executed',
      });
      final before = await _fingerprint(repository);
      for (final path in paths) {
        final patch = _patch(await cached(captured, path, diffFilter: 'M'));
        expect(_lines(patch), [
          'deletion:before',
          'addition:after',
          'context:',
          'context:same',
          'deletion:old tail',
          'addition:new tail',
        ]);
        final lines = parseGitPatch(patch).single.lines;
        expect(lines.where((line) => line.noNewline).length, 2);
      }
      expect(await _fingerprint(repository), before);
      for (final name in [...helpers.keys, 'trace']) {
        expect(
          await File('${container.path}/$name.executed').exists(),
          isFalse,
        );
      }
      expect(await File('${container.path}/wrong-index').exists(), isFalse);

      // Positive controls show these are executable traps, not inert configuration.
      for (final path in ['clean', 'process']) {
        final result = await _gitResult(repository, [
          'hash-object',
          '--path=$path',
          path,
        ]);
        expect(result.exitCode, isNot(0));
        expect(await File('${container.path}/$path.executed').exists(), isTrue);
      }
      for (final name in ['external', 'textconv']) {
        final result = await _gitResult(repository, [
          if (name == 'textconv') ...['-c', 'diff.hostile.command='],
          'diff',
          '--cached',
          if (name == 'textconv') ...['--no-ext-diff', '--textconv'],
          captured,
          '--',
          'custom',
        ]);
        expect(result.exitCode, isNot(0));
        expect(await File('${container.path}/$name.executed').exists(), isTrue);
      }
      await _gitResult(repository, ['status', '--porcelain']);
      expect(
        await File('${container.path}/fsmonitor.executed').exists(),
        isTrue,
      );
      await File('${repository.path}/.git/info/attributes').delete();
      await _git(repository, [
        '-c',
        'core.fsmonitor=false',
        'update-index',
        '--chmod=+x',
        'external',
      ]);
      expect(
        await File('${container.path}/post-index-change.executed').exists(),
        isTrue,
      );
    },
  );

  test(
    'captured commit and literal nested paths survive HEAD and discovery changes',
    () async {
      const names = [
        'space name',
        'tab\tname',
        'line\nname',
        '-leading',
        ':(glob)*',
        '[literal]*?',
        r'quote\"$(touch EXECUTED)',
      ];
      for (final name in names) {
        await write('selected/project/$name', 'captured\n');
      }
      await write('outside', 'outside before\n');
      final captured = await commit();
      await capture('selected/project');
      for (final name in names) {
        await write('selected/project/$name', 'moved HEAD\n');
      }
      final moved = await commit();
      expect(moved, isNot(captured));
      for (final name in names) {
        await write('selected/project/$name', 'index\n');
      }
      await write('outside', 'outside staged\n');
      await _git(repository, ['add', '--all']);
      for (final name in names) {
        await File('${repository.path}/selected/project/$name').delete();
      }
      // Even a newly introduced nested repository cannot replace the captured roots.
      await _git(processes.root, ['init']);
      final before = await _fingerprint(repository);
      for (final name in names) {
        expect(_lines(_patch(await cached(captured, name))), [
          'deletion:captured',
          'addition:index',
        ]);
        expect(_lines(_patch(await cached(moved, name))), [
          'deletion:moved HEAD',
          'addition:index',
        ]);
      }
      final scoped = _patch(await cached(captured, '.'));
      expect(scoped, isNot(contains('outside')));
      expect('diff --git '.allMatches(scoped), hasLength(names.length));
      expect(await File('${processes.root.path}/EXECUTED').exists(), isFalse);
      expect(await _fingerprint(repository), before);
    },
  );

  test(
    'change-kind filters isolate exact paths across file-directory replacements',
    () async {
      await write('file-to-dir', 'old flat\n');
      await write('dir-to-file/child', 'old child\n');
      final captured = await commit();
      await File('${repository.path}/file-to-dir').delete();
      await write('file-to-dir/child', 'new child\n');
      await Directory('${repository.path}/dir-to-file').delete(recursive: true);
      await write('dir-to-file', 'new flat\n');
      await _git(repository, ['add', '--all']);
      final before = await _fingerprint(repository);
      for (final path in ['file-to-dir', 'dir-to-file']) {
        final broad = _patch(await cached(captured, path));
        expect('diff --git '.allMatches(broad), hasLength(2));
        expect(() => parseGitPatch(broad), throwsA(anything));
      }
      for (final (path, filter, lines) in [
        ('file-to-dir', 'D', ['deletion:old flat']),
        ('file-to-dir/child', 'A', ['addition:new child']),
        ('dir-to-file', 'A', ['addition:new flat']),
        ('dir-to-file/child', 'D', ['deletion:old child']),
      ]) {
        final patch = _patch(await cached(captured, path, diffFilter: filter));
        expect('diff --git '.allMatches(patch), hasLength(1));
        expect(_lines(patch), lines);
      }
      expect(await _fingerprint(repository), before);
    },
  );

  test('intent-to-add remains absent from the cached layer', () async {
    final captured = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
    await write('intent', 'working only\n');
    await _git(repository, ['add', '--intent-to-add', '--', 'intent']);
    final before = await _fingerprint(repository);
    final result = await cached(captured, 'intent', diffFilter: 'A');
    expect(result.exitCode, 0);
    expect(_patch(result), isEmpty);
    expect(await _fingerprint(repository), before);
  });

  test(
    'fixed cached diff options neutralize configured patch formatting',
    () async {
      final captured = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      await write('tracked', 'after\n\nsame\nnew tail');
      await _git(repository, ['add', '--', 'tracked']);
      final expected = _patch(await cached(captured, 'tracked'));
      for (final (key, value) in [
        ('diff.outputIndicatorNew', '>'),
        ('diff.outputIndicatorOld', '<'),
        ('diff.outputIndicatorContext', '='),
        ('diff.suppressBlankEmpty', 'true'),
        ('diff.algorithm', 'histogram'),
        ('diff.indentHeuristic', 'true'),
        ('diff.context', '0'),
        ('diff.interHunkContext', '99'),
        ('diff.colorMoved', 'zebra'),
        ('color.ui', 'always'),
        ('color.diff', 'always'),
        ('diff.noprefix', 'false'),
        ('diff.mnemonicPrefix', 'true'),
        ('diff.srcPrefix', 'hostile-old/'),
        ('diff.dstPrefix', 'hostile-new/'),
        ('diff.relative', 'true'),
        ('diff.renames', 'copies'),
        ('diff.submodule', 'log'),
        ('diff.wordRegex', '.'),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      final before = await _fingerprint(repository);
      final actual = _patch(await cached(captured, 'tracked'));
      expect(actual, expected);
      expect(_lines(actual), contains('context:'));
      expect(await _fingerprint(repository), before);
    },
  );

  test(
    'cached diff has explicit difference exit codes and failing diagnostics',
    () async {
      final captured = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      final clean = await cached(captured, 'tracked');
      expect(clean.exitCode, 0);
      expect(_patch(clean), isEmpty);
      await write('tracked', 'after\n');
      await _git(repository, ['add', '--', 'tracked']);
      final changed = await cached(captured, 'tracked');
      expect(changed.exitCode, 1);
      expect(parseGitPatch(_patch(changed)), isNotEmpty);
      final withoutExitCode = await cached(
        captured,
        'tracked',
        exitCode: false,
      );
      expect(withoutExitCode.exitCode, 0);
      expect(withoutExitCode.stdoutBase64, changed.stdoutBase64);
      final before = await _fingerprint(repository);
      final invalid = await cached('1' * 40, 'tracked');
      expect(invalid.exitCode, 128);
      expect(_stderr(invalid), contains('bad object'));
      expect(() => _patch(invalid), throwsStateError);
      expect(await _fingerprint(repository), before);
    },
  );

  test(
    'diagnostics invalidate a patch even when Git exits with difference status',
    () async {
      final captured = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      await write('tracked', 'after\n');
      await _git(repository, ['add', '--', 'tracked']);
      final attributes = File('${repository.path}/.git/info/attributes');
      await attributes.writeAsString('tracked diff\n');
      await _command('/usr/bin/chmod', ['000', attributes.path]);
      try {
        final before = await _fingerprint(
          repository,
          unreadable: attributes.path,
        );
        final result = await cached(captured, 'tracked');
        expect(result.exitCode, 1);
        expect(_stderr(result), contains('Permission denied'));
        expect(base64Decode(result.stdoutBase64), isNotEmpty);
        expect(() => _patch(result), throwsStateError);
        expect(
          await _fingerprint(repository, unreadable: attributes.path),
          before,
        );
      } finally {
        await _command('/usr/bin/chmod', ['600', attributes.path]);
      }
    },
  );
}

// Preserve the actual production shell, environment and pinned Git options. Only
// the Git command suffix changes; this is not a parallel copy of the safe wrapper.
EnvironmentBufferedProcessRequest _withCommand(
  EnvironmentBufferedProcessRequest source,
  List<String> command,
) {
  final split = source.arguments.indexOf('ls-files');
  expect(split, greaterThan(0));
  return EnvironmentBufferedProcessRequest(
    program: source.program,
    arguments: [...source.arguments.take(split), ...command],
    relativeWorkingDirectory: source.relativeWorkingDirectory,
    timeoutSeconds: source.timeoutSeconds,
    stdinBase64: source.stdinBase64,
  );
}

List<String> _cachedArguments(
  String commit,
  String path, {
  required bool exitCode,
  String? diffFilter,
}) => [
  '-c',
  'diff.suppressBlankEmpty=false',
  'diff',
  '--cached',
  '--patch',
  if (exitCode) '--exit-code',
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
  '--ignore-submodules=all',
  '--ita-invisible-in-index',
  if (diffFilter != null) '--diff-filter=$diffFilter',
  '--output-indicator-new=+',
  '--output-indicator-old=-',
  '--output-indicator-context= ',
  commit,
  '--',
  path,
];

String _stderr(EnvironmentBufferedProcessResult result) =>
    utf8.decode(base64Decode(result.stderrBase64));

String _patch(EnvironmentBufferedProcessResult result) {
  final text = utf8.decode(base64Decode(result.stdoutBase64));
  if (_stderr(result).isNotEmpty ||
      (result.exitCode != 0 && result.exitCode != 1) ||
      (result.exitCode == 0) != text.isEmpty) {
    throw StateError(
      'Incomplete cached diff: ${result.exitCode}: ${_stderr(result)}',
    );
  }
  return text;
}

List<String> _lines(String patch) => [
  for (final hunk in parseGitPatch(patch))
    for (final line in hunk.lines) '${line.kind}:${line.text}',
];

final class _Processes implements AuthorizedEnvironmentBufferedProcessService {
  _Processes(this.root, Directory home)
    : environment = {
        'PATH': '/usr/bin:/bin',
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/config',
      };

  final Directory root;
  final Map<String, String> environment;
  final requests = <EnvironmentBufferedProcessRequest>[];

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    requests.add(request);
    final process = await Process.start(
      request.program,
      request.arguments,
      workingDirectory: root.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    try {
      final results = await Future.wait<Object?>([
        _capture(process.stdout, environmentBufferedProcessStdoutLimit),
        _capture(process.stderr, environmentBufferedProcessStderrLimit),
        process.exitCode,
        () async {
          process.stdin.add(base64Decode(request.stdinBase64));
          await process.stdin.close();
        }(),
      ], eagerError: true).timeout(Duration(seconds: request.timeoutSeconds));
      return EnvironmentBufferedProcessResult(
        exitCode: results[2]! as int,
        stdoutBase64: base64Encode(results[0]! as List<int>),
        stderrBase64: base64Encode(results[1]! as List<int>),
      );
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
}

Future<List<int>> _capture(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw StateError('Output overflow');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<String> _git(Directory root, List<String> arguments) async {
  final result = await _gitResult(root, arguments);
  expect(result.exitCode, 0, reason: 'git $arguments: ${result.stderr}');
  return result.stdout as String;
}

Future<ProcessResult> _gitResult(Directory root, List<String> arguments) =>
    Process.run(
      '/usr/bin/git',
      arguments,
      workingDirectory: root.path,
      environment: {
        'PATH': '/usr/bin:/bin',
        'HOME': root.parent.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
    );

Future<void> _command(String program, List<String> arguments) async {
  final result = await Process.run(program, arguments);
  expect(result.exitCode, 0, reason: '$program $arguments: ${result.stderr}');
}

Future<Map<String, Object>> _fingerprint(
  Directory root, {
  String? unreadable,
}) async {
  final result = <String, Object>{};
  await for (final entry in Directory(
    '${root.path}/.git',
  ).list(recursive: true, followLinks: false)) {
    final path = entry.path.substring(root.path.length + 1);
    if (entry is File) {
      final stat = await entry.stat();
      result[path] = (
        entry.path == unreadable
            ? 'unreadable'
            : sha256.convert(await entry.readAsBytes()).toString(),
        stat.size,
        stat.mode,
        stat.modified.microsecondsSinceEpoch,
      );
    } else {
      result[path] = 'directory';
    }
  }
  expect(result.keys, containsAll(['.git/HEAD', '.git/index', '.git/config']));
  return result;
}
