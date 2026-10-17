import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart'
    show GitPortableUnstagedSnapshotService;
import 'package:test/test.dart';

void main() {
  for (final (name, root, worktree, prefix) in [
    ('filesystem root', '/', '/', ''),
    ('child of filesystem root', '/workspace', '/', 'workspace/'),
    ('nested repository source', '/repo/subdir', '/repo', 'subdir/'),
    ('repository root', '/repo', '/repo', ''),
    ('deep source', '/repo/subdir/deep', '/repo', 'subdir/deep/'),
    ('newline in root child', '/work\nspace\n', '/', 'work\nspace\n/'),
    ('newline in repository root', '/repo\n', '/repo\n', ''),
    (
      'newline in nested source',
      '/repo\n/sub\ndir\n',
      '/repo\n',
      'sub\ndir\n/',
    ),
  ]) {
    test(
      'discovery accepts $name through the selected process service',
      () async {
        final processes = _DiscoveryProcesses(
          root: root,
          worktree: worktree,
          prefix: prefix,
          directory: '/metadata\n/git\n',
        );

        final snapshot = await GitPortableUnstagedSnapshotService(
          processes: processes,
        ).snapshotUnstaged();

        expect(snapshot.files, isEmpty);
        expect(processes.discoveryCount, 2);
        expect(processes.inventoryCount, 8);
      },
    );
  }

  for (final (name, root, worktree, prefix) in [
    ('sibling with common prefix', '/repository', '/repo', 'sitory/'),
    ('sibling subtree', '/repo-other/subdir', '/repo', 'subdir/'),
    ('source outside worktree', '/other/subdir', '/repo', 'subdir/'),
    ('source above worktree', '/repo', '/repo/subdir', ''),
    ('filesystem root above worktree', '/', '/repo', ''),
    ('missing nested prefix', '/repo/subdir', '/repo', ''),
    ('wrong nested prefix', '/repo/subdir', '/repo', 'other/'),
    ('prefix at repository root', '/repo', '/repo', 'repo/'),
    ('prefix at filesystem root', '/', '/', '/'),
    ('root child prefix missing first letter', '/workspace', '/', 'orkspace/'),
    ('absolute prefix', '/repo/subdir', '/repo', '/subdir/'),
    ('prefix without trailing slash', '/repo/subdir', '/repo', 'subdir'),
    ('prefix doubled separator', '/repo/subdir', '/repo', 'subdir//'),
    ('prefix dot component', '/repo/subdir', '/repo', './subdir/'),
    ('prefix parent component', '/repo/subdir', '/repo', 'other/../subdir/'),
    ('prefix NUL', '/repo/subdir', '/repo', 'subdir/\u0000'),
  ]) {
    test('discovery rejects $name', () async {
      final processes = _DiscoveryProcesses(
        root: root,
        worktree: worktree,
        prefix: prefix,
      );

      await _expectUnavailable(processes);
    });
  }

  for (final (name, path) in [
    ('empty path', ''),
    ('relative path', 'repo'),
    ('NUL', '/repo\u0000'),
    ('doubled leading separator', '//repo'),
    ('doubled interior separator', '/repo//subdir'),
    ('trailing separator', '/repo/'),
    ('root doubled separator', '//'),
    ('dot component', '/repo/./subdir'),
    ('terminal dot component', '/repo/.'),
    ('parent component', '/repo/../subdir'),
    ('terminal parent component', '/repo/..'),
  ]) {
    test('discovery rejects $name in pwd', () async {
      await _expectUnavailable(
        _DiscoveryProcesses(
          root: path,
          worktree: '/',
          prefix: path.startsWith('/') ? '${path.substring(1)}/' : 'repo/',
        ),
      );
    });
    test(
      'discovery rejects $name in worktree even with matching pwd',
      () async {
        await _expectUnavailable(
          _DiscoveryProcesses(root: path, worktree: path, prefix: ''),
        );
      },
    );
    test('discovery rejects $name in Git directory', () async {
      await _expectUnavailable(_DiscoveryProcesses(directory: path));
    });
  }

  test('discovery rejects a root outside a Git working tree', () async {
    await _expectUnavailable(_DiscoveryProcesses(inside: 'false'));
  });
}

Future<void> _expectUnavailable(_DiscoveryProcesses processes) async {
  await expectLater(
    GitPortableUnstagedSnapshotService(processes: processes).snapshotUnstaged(),
    throwsA(
      isA<ChangeSetFailure>().having(
        (failure) => failure.code,
        'code',
        'repository_unavailable',
      ),
    ),
  );
  expect(processes.discoveryCount, 1);
  expect(processes.inventoryCount, 0);
}

// No processes or filesystem access: even '/' is only a controlled response.
final class _DiscoveryProcesses
    implements AuthorizedEnvironmentBufferedProcessService {
  _DiscoveryProcesses({
    this.root = '/repo/subdir',
    this.worktree = '/repo',
    this.directory = '/repo/.git',
    this.prefix = 'subdir/',
    this.inside = 'true',
  });

  final String root;
  final String worktree;
  final String directory;
  final String prefix;
  final String inside;
  int discoveryCount = 0;
  int inventoryCount = 0;

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    expect(request.program, '/bin/sh');
    expect(request.relativeWorkingDirectory, isEmpty);
    expect(request.stdinBase64, isEmpty);
    final arguments = request.arguments.sublist(3);
    if (arguments.first == '/bin/pwd') {
      expect(arguments, ['/bin/pwd', '-P']);
      discoveryCount++;
      return _result('$root\n');
    }

    expect(arguments.first, '/usr/bin/git');
    final commandIndex = arguments.indexWhere(
      (argument) =>
          const {'rev-parse', 'config', 'ls-files'}.contains(argument),
    );
    expect(commandIndex, greaterThan(0));
    final command = arguments.sublist(commandIndex);
    final pins = arguments.where(
      (argument) =>
          argument.startsWith('--git-dir=') ||
          argument.startsWith('--work-tree='),
    );
    if (command.first == 'rev-parse') {
      expect(pins, isEmpty);
      final value = switch (command) {
        ['rev-parse', '--is-inside-work-tree'] => inside,
        ['rev-parse', '--show-toplevel'] => worktree,
        ['rev-parse', '--absolute-git-dir'] => directory,
        ['rev-parse', '--show-prefix'] => prefix,
        _ => throw StateError('Unexpected discovery command: $command'),
      };
      return _result('$value\n');
    }

    expect(pins, ['--git-dir=$directory', '--work-tree=$worktree']);
    if (command.first == 'config') {
      expect(command, [
        'config',
        '--null',
        '--get-regexp',
        r'^core\.(autocrlf|eol|filemode|worktree|bare)$',
      ]);
      return _result('', exitCode: 1);
    }
    expect(
      command,
      anyOf([
        ['ls-files', '--cached', '--stage', '--debug', '-z', '--', '.'],
        ['ls-files', '--others', '--exclude-standard', '-z', '--', '.'],
        ['ls-files', '--deleted', '-z', '--', '.'],
        ['ls-files', '--killed', '-z', '--', '.'],
      ]),
    );
    inventoryCount++;
    return _result('');
  }
}

EnvironmentBufferedProcessResult _result(String stdout, {int exitCode = 0}) =>
    EnvironmentBufferedProcessResult(
      exitCode: exitCode,
      stdoutBase64: base64Encode(utf8.encode(stdout)),
      stderrBase64: '',
    );
