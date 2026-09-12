import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _hostEntrypoint =
    'packages/plugin_backend_host/bin/adele_backend_host.dart';
const String _gitEntrypoint =
    'plugins/git_environment/packages/backend/bin/git_environment_backend.dart';

void main() {
  late Directory root;
  late Directory sdkBin;
  late File commands;
  late File launchArguments;
  late Map<String, String> environment;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele launcher ');
    // Copy only the SDK-only launcher graph, with no pubspec/package config.
    for (final String path in <String>[
      'tools/adele.dart',
      'tools/backend_artifacts.dart',
      'tools/test_runner.dart',
      'packages/plugin_builder/lib/plugin_builder.dart',
      'packages/plugin_builder/lib/src/development_plugin_builder.dart',
    ]) {
      final File destination = File('${root.path}/$path');
      destination.parent.createSync(recursive: true);
      File(path).copySync(destination.path);
    }
    Directory('${root.path}/app').createSync();
    for (final String entrypoint in <String>[_hostEntrypoint, _gitEntrypoint]) {
      final File source = File('${root.path}/$entrypoint');
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('void main() {}');
    }
    final Directory bin = Directory('${root.path}/bin')..createSync();
    final Directory flutterRoot = Directory('${root.path}/flutter sdk');
    sdkBin = Directory('${flutterRoot.path}/bin/cache/dart-sdk/bin')
      ..createSync(recursive: true);
    commands = File('${root.path}/commands.txt');
    launchArguments = File('${root.path}/launch-arguments.txt');
    environment = <String, String>{
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
    };
    _script(File('${bin.path}/flutter'), '''
if [ "\$1" = "--version" ]; then
  printf 'inspect-sdk\n' >> '${commands.path}'
  printf '%s\n' '${jsonEncode(<String, String>{'flutterRoot': flutterRoot.path})}'
else
  test "\$PWD" = '${root.path}/app' || exit 98
  printf 'flutter-launch\n' >> '${commands.path}'
  printf '%s\n' "\$@" > '${launchArguments.path}'
fi
''');
    _script(File('${bin.path}/dart'), 'exit 99');
    _script(File('${sdkBin.path}/dartaotruntime'), 'exit 99');
    _script(File('${sdkBin.path}/dart'), '''
test "\$PWD" = '${root.path}' || exit 98
test "\$1" = compile && test "\$2" = aot-snapshot && test "\$4" = -o || exit 97
test -f "\$3" || exit 96
printf 'compile|%s\n' "\$3" >> '${commands.path}'
if [ "\$ADELE_TEST_FAIL_ENTRYPOINT" = "\$3" ]; then
  printf 'snapshot compiler failed' >&2
  exit 17
fi
if [ "\$ADELE_TEST_OMIT_ARTIFACT" != 1 ]; then
  printf 'snapshot %s\n' "\$3" > "\$5"
fi
printf 'compiled|%s\n' "\$3" >> '${commands.path}'
''');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> invoke(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    <String>['tools/adele.dart', ...arguments],
    workingDirectory: root.path,
    environment: environment,
  );

  test(
    'test-plan runs pre-bootstrap without inspecting or compiling',
    () async {
      final ProcessResult result = await invoke(<String>[
        'test-plan',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final Map<String, Object?> plan =
          jsonDecode(result.stdout.toString()) as Map<String, Object?>;
      expect(plan['include'], isNotEmpty);
      expect(commands.existsSync(), isFalse);
      expect(Directory('${root.path}/.dart_tool').existsSync(), isFalse);
    },
  );

  test(
    'run and profile build compile first and provision exact fresh defines',
    () async {
      final Set<String> outputDirectories = <String>{};
      final Map<String, String> retainedArtifacts = <String, String>{};
      for (final List<String> arguments in <List<String>>[
        <String>['run', 'linux'],
        <String>['build', 'linux', '--profile'],
      ]) {
        final ProcessResult result = await invoke(arguments);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          'compile|$_hostEntrypoint',
          'compiled|$_hostEntrypoint',
          'compile|$_gitEntrypoint',
          'compiled|$_gitEntrypoint',
          'flutter-launch',
        ]);
        final List<String> launched = launchArguments.readAsLinesSync();
        final bool run = arguments.first == 'run';
        expect(launched.take(run ? 4 : 3), <String>[
          arguments.first,
          if (run) '-d',
          'linux',
          run ? '--debug' : '--profile',
        ]);
        final Map<String, String> defines = <String, String>{};
        for (final String argument in launched.skip(run ? 4 : 3)) {
          expect(argument, startsWith('--dart-define='));
          final String define = argument.substring('--dart-define='.length);
          final int separator = define.indexOf('=');
          defines[define.substring(0, separator)] = define.substring(
            separator + 1,
          );
        }
        expect(launched, hasLength(run ? 7 : 6));
        expect(
          defines.keys,
          unorderedEquals(<String>[
            'ADELE_DARTAOTRUNTIME_EXECUTABLE',
            'ADELE_BACKEND_HOST_ARTIFACT',
            'ADELE_GIT_ENVIRONMENT_ARTIFACT',
          ]),
        );
        expect(
          defines['ADELE_DARTAOTRUNTIME_EXECUTABLE'],
          '${sdkBin.path}/dartaotruntime',
        );
        final File host = File(defines['ADELE_BACKEND_HOST_ARTIFACT']!);
        final File git = File(defines['ADELE_GIT_ENVIRONMENT_ARTIFACT']!);
        expect(host.uri.isAbsolute, isTrue);
        expect(git.uri.isAbsolute, isTrue);
        expect(host.path, endsWith('/host.aot'));
        expect(git.path, endsWith('/git-environment.aot'));
        expect(host.parent.path, git.parent.path);
        expect(
          host.parent.path,
          startsWith('${root.path}/.dart_tool/adele/desktop-backends/build-'),
        );
        expect(outputDirectories.add(host.parent.path), isTrue);
        expect(host.readAsStringSync(), 'snapshot $_hostEntrypoint\n');
        expect(git.readAsStringSync(), 'snapshot $_gitEntrypoint\n');
        retainedArtifacts[host.path] = host.readAsStringSync();
        retainedArtifacts[git.path] = git.readAsStringSync();
        for (final MapEntry<String, String> artifact
            in retainedArtifacts.entries) {
          expect(File(artifact.key).readAsStringSync(), artifact.value);
        }
        commands.deleteSync();
      }
    },
  );

  for (final String failedEntrypoint in <String>[
    _hostEntrypoint,
    _gitEntrypoint,
  ]) {
    for (final String command in <String>['run', 'build']) {
      test('$command never launches after $failedEntrypoint fails', () async {
        environment['ADELE_TEST_FAIL_ENTRYPOINT'] = failedEntrypoint;
        final ProcessResult result = await invoke(<String>[
          command,
          'linux',
          '--profile',
        ]);
        expect(result.exitCode, 17);
        expect(result.stderr, contains('snapshot compiler failed'));
        expect(result.stderr, contains('failed with exit code 17'));
        expect(commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          'compile|$_hostEntrypoint',
          if (failedEntrypoint == _gitEntrypoint) ...<String>[
            'compiled|$_hostEntrypoint',
            'compile|$_gitEntrypoint',
          ],
        ]);
        expect(launchArguments.existsSync(), isFalse);
      });
    }
  }

  test('missing matched runtime fails before compiling or launching', () async {
    File('${sdkBin.path}/dartaotruntime').deleteSync();
    final ProcessResult result = await invoke(<String>['run', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('Required SDK executable is missing'));
    expect(commands.readAsLinesSync(), <String>['inspect-sdk']);
    expect(launchArguments.existsSync(), isFalse);
  });

  test('compiler success without a snapshot does not launch Flutter', () async {
    environment['ADELE_TEST_OMIT_ARTIFACT'] = '1';
    final ProcessResult result = await invoke(<String>['run', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('produced no artifact'));
    expect(commands.readAsLinesSync(), <String>[
      'inspect-sdk',
      'compile|$_hostEntrypoint',
      'compiled|$_hostEntrypoint',
    ]);
    expect(launchArguments.existsSync(), isFalse);
  });
}

void _script(File file, String body) {
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
}
