import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _hostEntrypoint =
    'packages/plugin_backend_host/bin/adele_backend_host.dart';
const String _gitEntrypoint =
    'plugins/git_environment/packages/backend/bin/git_environment_backend.dart';
const String _openaiEntrypoint =
    'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart';
const String _frontendHarness = 'tool/compile_chat_frontend.dart';
const String _toolFrontendHarness =
    'tool/compile_tool_inspection_frontends.dart';

void main() {
  late Directory root;
  late Directory sdkBin;
  late File commands;
  late File launchArguments;
  late File frontendArguments;
  late File frontendEnvironment;
  late Map<String, String> environment;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele launcher ');
    // Copy only the SDK-only launcher graph, with no pubspec/package config.
    for (final String path in <String>[
      'tools/adele.dart',
      'tools/backend_artifacts.dart',
      'tools/frontend_artifacts.dart',
      'tools/test_runner.dart',
      'packages/plugin_builder/lib/plugin_builder.dart',
      'packages/plugin_builder/lib/src/development_plugin_builder.dart',
    ]) {
      final File destination = File('${root.path}/$path');
      destination.parent.createSync(recursive: true);
      File(path).copySync(destination.path);
    }
    Directory('${root.path}/app').createSync();
    final File harness = File('${root.path}/app/$_frontendHarness');
    harness.parent.createSync();
    harness.writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_toolFrontendHarness',
    ).writeAsStringSync('void main() {}');
    for (final String entrypoint in <String>[
      _hostEntrypoint,
      _gitEntrypoint,
      _openaiEntrypoint,
    ]) {
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
    frontendArguments = File('${root.path}/frontend-arguments.txt');
    frontendEnvironment = File('${root.path}/frontend-environment.txt');
    environment = <String, String>{
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
    };
    _script(File('${bin.path}/flutter'), '''
if [ "\$1" = "--version" ]; then
  printf 'inspect-sdk\n' >> '${commands.path}'
  printf '%s\n' '${jsonEncode(<String, String>{'flutterRoot': flutterRoot.path})}'
elif [ "\$1" = test ]; then
  test "\$PWD" = '${root.path}/app' || exit 98
  test "\$#" = 5 && test "\$2" = --no-pub && test "\$3" = --concurrency && test "\$4" = 1 || exit 97
  test -f "\$5" || exit 96
  test "\$ADELE_REPOSITORY_ROOT" = '${root.path}' || exit 95
  if [ "\$5" = '$_frontendHarness' ]; then
    kind=chat
    output="\$ADELE_CHAT_FRONTEND_OUTPUT"
    label='$_frontendHarness'
    printf '%s\n' "\$@" > '${frontendArguments.path}'
    printf '%s\n' "\$ADELE_REPOSITORY_ROOT" "\$output" > '${frontendEnvironment.path}'
  else
    test "\$5" = '$_toolFrontendHarness' || exit 92
    kind="\$ADELE_TOOL_INSPECTION_FRONTEND"
    output="\$ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT"
    label="$_toolFrontendHarness|\$kind"
  fi
  case "\$output" in /*) ;; *) exit 94 ;; esac
  test ! -e "\$output" || exit 93
  printf 'compile|%s\n' "\$label" >> '${commands.path}'
  failure=''
  fail_exit=''
  if [ "\$kind" = "\${ADELE_TEST_FRONTEND_TARGET:-chat}" ]; then
    failure="\$ADELE_TEST_FRONTEND_ARTIFACT"
    fail_exit="\$ADELE_TEST_FAIL_FRONTEND"
  fi
  if [ "\$failure" != missing ]; then
    if [ "\$failure" = empty ]; then
      : > "\$output"
    else
      printf 'frontend bytecode\n' > "\$output"
    fi
  fi
  if [ "\$fail_exit" = 1 ]; then
    printf 'frontend compiler failed' >&2
    exit 23
  fi
  printf 'compiled|%s\n' "\$label" >> '${commands.path}'
  printf 'frontend compiler output\n'
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
      expect(
        (plan['include']! as List<Object?>).cast<Map<String, Object?>>().map(
          (Map<String, Object?> item) => item['name'],
        ),
        contains('adele_ui'),
      );
      expect(commands.existsSync(), isFalse);
      expect(Directory('${root.path}/.dart_tool').existsSync(), isFalse);
    },
  );

  test(
    'run and profile build compile first and provision exact fresh defines',
    () async {
      final Set<String> outputDirectories = <String>{};
      final Map<String, String> retainedArtifacts = <String, String>{};
      // Preparation must replace inherited inputs with this checkout's paths.
      environment['ADELE_REPOSITORY_ROOT'] = '/wrong-repository';
      environment['ADELE_CHAT_FRONTEND_OUTPUT'] = '/wrong-output';
      environment['ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT'] =
          '/wrong-tool-output';
      environment['ADELE_TOOL_INSPECTION_FRONTEND'] = 'wrong-tool';
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
          'compile|$_openaiEntrypoint',
          'compiled|$_openaiEntrypoint',
          'compile|$_frontendHarness',
          'compiled|$_frontendHarness',
          'compile|$_toolFrontendHarness|filesystem',
          'compiled|$_toolFrontendHarness|filesystem',
          'compile|$_toolFrontendHarness|command',
          'compiled|$_toolFrontendHarness|command',
          'flutter-launch',
        ]);
        expect(result.stdout, contains('frontend compiler output'));
        expect(frontendArguments.readAsLinesSync(), <String>[
          'test',
          '--no-pub',
          '--concurrency',
          '1',
          _frontendHarness,
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
        expect(launched, hasLength(run ? 11 : 10));
        expect(
          defines.keys,
          unorderedEquals(<String>[
            'ADELE_DARTAOTRUNTIME_EXECUTABLE',
            'ADELE_BACKEND_HOST_ARTIFACT',
            'ADELE_GIT_ENVIRONMENT_ARTIFACT',
            'ADELE_OPENAI_ARTIFACT',
            'ADELE_CHAT_FRONTEND_ARTIFACT',
            'ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT',
            'ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT',
          ]),
        );
        expect(
          defines['ADELE_DARTAOTRUNTIME_EXECUTABLE'],
          '${sdkBin.path}/dartaotruntime',
        );
        final File host = File(defines['ADELE_BACKEND_HOST_ARTIFACT']!);
        final File git = File(defines['ADELE_GIT_ENVIRONMENT_ARTIFACT']!);
        final File openai = File(defines['ADELE_OPENAI_ARTIFACT']!);
        final File frontend = File(defines['ADELE_CHAT_FRONTEND_ARTIFACT']!);
        expect(host.uri.isAbsolute, isTrue);
        expect(git.uri.isAbsolute, isTrue);
        expect(openai.uri.isAbsolute, isTrue);
        expect(frontend.uri.isAbsolute, isTrue);
        expect(host.path, endsWith('/host.aot'));
        expect(git.path, endsWith('/git-environment.aot'));
        expect(openai.path, endsWith('/openai.aot'));
        expect(frontend.path, endsWith('/chat.evc'));
        expect(frontendEnvironment.readAsLinesSync(), <String>[
          root.path,
          frontend.path,
        ]);
        expect(host.parent.path, git.parent.path);
        expect(host.parent.path, openai.parent.path);
        expect(
          host.parent.path,
          startsWith('${root.path}/.dart_tool/adele/desktop-backends/build-'),
        );
        expect(outputDirectories.add(host.parent.path), isTrue);
        expect(
          frontend.parent.path,
          startsWith('${root.path}/.dart_tool/adele/desktop-frontends/build-'),
        );
        expect(outputDirectories.add(frontend.parent.path), isTrue);
        expect(host.readAsStringSync(), 'snapshot $_hostEntrypoint\n');
        expect(git.readAsStringSync(), 'snapshot $_gitEntrypoint\n');
        expect(openai.readAsStringSync(), 'snapshot $_openaiEntrypoint\n');
        expect(frontend.readAsStringSync(), 'frontend bytecode\n');
        retainedArtifacts[host.path] = host.readAsStringSync();
        retainedArtifacts[git.path] = git.readAsStringSync();
        retainedArtifacts[openai.path] = openai.readAsStringSync();
        retainedArtifacts[frontend.path] = frontend.readAsStringSync();
        for (final tool in const [
          (
            name: 'filesystem',
            define: 'ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT',
          ),
          (name: 'command', define: 'ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT'),
        ]) {
          final File artifact = File(defines[tool.define]!);
          expect(artifact.uri.isAbsolute, isTrue);
          expect(artifact.path, endsWith('/${tool.name}.evc'));
          expect(artifact.parent.path, frontend.parent.path);
          expect(artifact.readAsStringSync(), 'frontend bytecode\n');
          retainedArtifacts[artifact.path] = artifact.readAsStringSync();
        }
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
    _openaiEntrypoint,
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
          if (failedEntrypoint != _hostEntrypoint) ...<String>[
            'compiled|$_hostEntrypoint',
            'compile|$_gitEntrypoint',
          ],
          if (failedEntrypoint == _openaiEntrypoint) ...<String>[
            'compiled|$_gitEntrypoint',
            'compile|$_openaiEntrypoint',
          ],
        ]);
        expect(launchArguments.existsSync(), isFalse);
      });
    }
  }

  for (final String command in <String>['run', 'build']) {
    for (final String kind in ['chat', 'filesystem', 'command']) {
      for (final String failure in <String>['exit', 'missing', 'empty']) {
        test(
          '$command never launches after $kind frontend $failure failure',
          () async {
            environment['ADELE_TEST_FRONTEND_TARGET'] = kind;
            if (failure == 'exit') {
              environment['ADELE_TEST_FAIL_FRONTEND'] = '1';
            } else {
              environment['ADELE_TEST_FRONTEND_ARTIFACT'] = failure;
            }
            final ProcessResult result = await invoke(<String>[
              command,
              'linux',
              '--profile',
            ]);
            expect(result.exitCode, failure == 'exit' ? 23 : 1);
            expect(result.stderr, contains('$kind-frontend-compilation'));
            if (failure == 'exit') {
              expect(result.stderr, contains('frontend compiler failed'));
              expect(result.stderr, contains('failed with exit code 23'));
              expect(
                File(frontendEnvironment.readAsLinesSync()[1]).lengthSync(),
                greaterThan(0),
              );
            } else {
              expect(result.stderr, contains('produced no non-empty artifact'));
            }
            expect(commands.readAsLinesSync(), <String>[
              'inspect-sdk',
              'compile|$_hostEntrypoint',
              'compiled|$_hostEntrypoint',
              'compile|$_gitEntrypoint',
              'compiled|$_gitEntrypoint',
              'compile|$_openaiEntrypoint',
              'compiled|$_openaiEntrypoint',
              'compile|$_frontendHarness',
              if (kind != 'chat' || failure != 'exit')
                'compiled|$_frontendHarness',
              if (kind != 'chat') 'compile|$_toolFrontendHarness|filesystem',
              if (kind == 'command' ||
                  (kind == 'filesystem' && failure != 'exit'))
                'compiled|$_toolFrontendHarness|filesystem',
              if (kind == 'command') 'compile|$_toolFrontendHarness|command',
              if (kind == 'command' && failure != 'exit')
                'compiled|$_toolFrontendHarness|command',
            ]);
            expect(launchArguments.existsSync(), isFalse);
          },
        );
      }
    }
  }

  test(
    'frontend failure never reuses a retained successful artifact',
    () async {
      final ProcessResult first = await invoke(<String>['build', 'linux']);
      expect(first.exitCode, 0, reason: first.stderr.toString());
      final File previous = File(frontendEnvironment.readAsLinesSync()[1]);
      launchArguments.deleteSync();
      commands.deleteSync();

      environment['ADELE_TEST_FRONTEND_ARTIFACT'] = 'missing';
      final ProcessResult second = await invoke(<String>['run', 'linux']);
      expect(second.exitCode, 1);
      expect(second.stderr, contains('produced no non-empty artifact'));
      expect(previous.readAsStringSync(), 'frontend bytecode\n');
      expect(frontendEnvironment.readAsLinesSync()[1], isNot(previous.path));
      expect(commands.readAsLinesSync(), isNot(contains('flutter-launch')));
      expect(launchArguments.existsSync(), isFalse);
    },
  );

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
