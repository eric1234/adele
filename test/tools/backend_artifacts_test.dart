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
const String _openaiFrontendHarness =
    'tool/compile_openai_activity_frontend.dart';

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
    File(
      '${root.path}/app/$_openaiFrontendHarness',
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
      for (final suffix in [
        'CREDENTIAL_FILE',
        'CLIENT_ID',
        'INSTANCE_ID',
        'OAUTH_ISSUER',
        'REDIRECT_URI',
        'ENDPOINT',
        'MODEL',
      ])
        'ADELE_OPENAI_CHATGPT_$suffix': '',
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
  elif [ "\$5" = '$_openaiFrontendHarness' ]; then
    kind=openai
    output="\$ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT"
    label='$_openaiFrontendHarness'
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

  String readStartupArguments() {
    const prefix = '--dart-define=ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE=';
    final argument = launchArguments.readAsLinesSync().singleWhere(
      (value) => value.startsWith(prefix),
    );
    return File(argument.substring(prefix.length)).readAsStringSync();
  }

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
        containsAll(['adele_ui', 'plugin_runtime', 'adele_tools']),
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
      environment['ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT'] = '/wrong-openai';
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
          'compile|$_openaiFrontendHarness',
          'compiled|$_openaiFrontendHarness',
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
        expect(launched, hasLength(run ? 12 : 11));
        expect(
          defines.keys,
          unorderedEquals(<String>[
            'ADELE_DARTAOTRUNTIME_EXECUTABLE',
            'ADELE_BACKEND_HOST_ARTIFACT',
            'ADELE_PLUGIN_INSTALLATION_ROOT',
            'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE',
            'ADELE_CHAT_FRONTEND_ARTIFACT',
            'ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT',
            'ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT',
            'ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT',
          ]),
        );
        expect(
          defines['ADELE_DARTAOTRUNTIME_EXECUTABLE'],
          '${sdkBin.path}/dartaotruntime',
        );
        final File host = File(defines['ADELE_BACKEND_HOST_ARTIFACT']!);
        final Directory installations = Directory(
          defines['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        final File startupArguments = File(
          defines['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']!,
        );
        final File git = File.fromUri(
          installations.uri.resolve('git-environment/backend.aot'),
        );
        final File openai = File.fromUri(
          installations.uri.resolve('openai/backend.aot'),
        );
        final File frontend = File(defines['ADELE_CHAT_FRONTEND_ARTIFACT']!);
        expect(host.uri.isAbsolute, isTrue);
        expect(git.uri.isAbsolute, isTrue);
        expect(openai.uri.isAbsolute, isTrue);
        expect(frontend.uri.isAbsolute, isTrue);
        expect(host.path, endsWith('/host.aot'));
        expect(git.path, endsWith('/git-environment/backend.aot'));
        expect(openai.path, endsWith('/openai/backend.aot'));
        expect(frontend.path, endsWith('/chat.evc'));
        expect(frontendEnvironment.readAsLinesSync(), <String>[
          root.path,
          frontend.path,
        ]);
        expect(installations.uri.isAbsolute, isTrue);
        expect(installations.parent.path, host.parent.path);
        expect(startupArguments.uri.isAbsolute, isTrue);
        expect(startupArguments.parent.path, host.parent.path);
        expect(jsonDecode(startupArguments.readAsStringSync()), {
          'dev.adele.openai': ['--chatgpt-only'],
        });
        expect(
          installations.listSync().map(
            (entry) =>
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
          ),
          unorderedEquals(['git-environment', 'openai']),
        );
        for (final plugin in [
          (
            artifact: git,
            id: 'dev.adele.plugin.git-environment',
            name: 'Git Worktree Environment',
          ),
          (artifact: openai, id: 'dev.adele.openai', name: 'OpenAI'),
        ]) {
          final manifest = File.fromUri(
            plugin.artifact.parent.uri.resolve(
              'adele_plugin.installation.json',
            ),
          );
          expect(jsonDecode(manifest.readAsStringSync()), {
            'manifestVersion': 1,
            'metadata': {
              'id': plugin.id,
              'version': '0.1.0',
              'displayName': plugin.name,
            },
            'components': {
              'backend': {'artifact': 'backend.aot'},
            },
          });
          expect(plugin.artifact.parent.listSync(), hasLength(2));
          retainedArtifacts[manifest.path] = manifest.readAsStringSync();
        }
        retainedArtifacts[startupArguments.path] = startupArguments
            .readAsStringSync();
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
          (name: 'openai', define: 'ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT'),
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

  for (final explicitClient in [false, true]) {
    test(
      'writes only public OpenAI startup config, explicit client=$explicitClient',
      () async {
        final credentials = File('${root.path}/credentials.json')
          ..writeAsStringSync(
            jsonEncode({
              'accessToken': 'secret-access-token',
              'refreshToken': 'secret-refresh-token',
            }),
          );
        environment.addAll({
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': explicitClient
              ? 'public-client'
              : '  ',
          'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'work-instance',
          'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://issuer.example.com',
          'ADELE_OPENAI_CHATGPT_REDIRECT_URI': 'http://localhost:1455/callback',
          'ADELE_OPENAI_CHATGPT_ENDPOINT':
              'https://model.example.com/responses',
          'ADELE_OPENAI_CHATGPT_MODEL': 'app-model-not-backend-config',
          'ADELE_OPENAI_CHATGPT_ACCESS_TOKEN': 'secret-env-access-token',
          'ADELE_OPENAI_CHATGPT_REFRESH_TOKEN': 'secret-env-refresh-token',
          'OPENAI_API_KEY': 'secret-api-key',
        });
        final result = await invoke(['run', 'linux']);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final serialized = readStartupArguments();
        final arguments = jsonDecode(serialized) as Map<String, Object?>;
        expect(arguments.keys, ['dev.adele.openai']);
        final openai = (arguments['dev.adele.openai']! as List<Object?>)
            .cast<String>();
        expect(openai, hasLength(2));
        expect(openai.first, '--chatgpt-only');
        expect(jsonDecode(openai.last), {
          'credentialFile': credentials.path,
          if (explicitClient)
            'clientId': 'public-client'
          else
            'experimentalCodexClient': true,
          'instanceId': 'work-instance',
          'issuer': 'https://issuer.example.com',
          'redirectUri': 'http://localhost:1455/callback',
          'endpoint': 'https://model.example.com/responses',
        });
        for (final forbidden in ['secret-', 'app-model-not-backend-config']) {
          expect(serialized, isNot(contains(forbidden)));
          expect(
            launchArguments.readAsStringSync(),
            isNot(contains(forbidden)),
          );
        }
      },
    );
  }

  test(
    'credential references need not exist and blank public overrides are omitted',
    () async {
      final credentialPath = '${root.path}/not-created.json';
      environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'] = credentialPath;
      environment['ADELE_OPENAI_CHATGPT_INSTANCE_ID'] = '  ';
      environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'] = '  ';
      final result = await invoke(['build', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final serialized = readStartupArguments();
      expect(jsonDecode(serialized), {
        'dev.adele.openai': [
          '--chatgpt-only',
          jsonEncode({
            'credentialFile': credentialPath,
            'experimentalCodexClient': true,
          }),
        ],
      });
      expect(File(credentialPath).existsSync(), isFalse);
    },
  );

  test(
    'without credentials OpenAI stays chatgpt-only and ignores other config',
    () async {
      environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '  ',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'unused-client',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid',
        'OPENAI_API_KEY': 'must-not-enable-api-key-context',
      });
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final serialized = readStartupArguments();
      expect(jsonDecode(serialized), {
        'dev.adele.openai': ['--chatgpt-only'],
      });
    },
  );

  test(
    'invalid public URI is forwarded for backend-local validation',
    () async {
      environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '/not-read.json',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid-private-value',
      });
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final arguments =
          jsonDecode(readStartupArguments()) as Map<String, dynamic>;
      final openai = arguments['dev.adele.openai'] as List<dynamic>;
      expect(jsonDecode(openai[1] as String), {
        'credentialFile': '/not-read.json',
        'experimentalCodexClient': true,
        'issuer': 'https://[invalid-private-value',
      });
      expect(result.stderr, isNot(contains('invalid-private-value')));
      expect(launchArguments.existsSync(), isTrue);
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
    for (final String kind in ['chat', 'filesystem', 'command', 'openai']) {
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
                  kind == 'openai' ||
                  (kind == 'filesystem' && failure != 'exit'))
                'compiled|$_toolFrontendHarness|filesystem',
              if (kind == 'command' || kind == 'openai')
                'compile|$_toolFrontendHarness|command',
              if (kind == 'openai' || (kind == 'command' && failure != 'exit'))
                'compiled|$_toolFrontendHarness|command',
              if (kind == 'openai') 'compile|$_openaiFrontendHarness',
              if (kind == 'openai' && failure != 'exit')
                'compiled|$_openaiFrontendHarness',
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
