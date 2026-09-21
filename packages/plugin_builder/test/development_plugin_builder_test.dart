import 'dart:io';

import 'package:plugin_builder/plugin_builder.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory plugin;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele builder ');
    plugin = Directory('${root.path}/plugin')..createSync();
    File('${plugin.path}/adele_plugin.yaml').writeAsStringSync('''
manifestVersion: 1
id: dev.adele.workspace-demo
packages:
  contract: packages/contract
  backend: packages/backend
  backendEntrypoint: bin/workspace_demo_backend.dart
''');
    Directory(
      '${plugin.path}/packages/contract/lib',
    ).createSync(recursive: true);
    File('${plugin.path}/packages/contract/pubspec.yaml').writeAsStringSync('''
name: temporary_contract
''');
    File(
      '${plugin.path}/packages/contract/lib/temporary_contract.dart',
    ).writeAsStringSync("part 'temporary_contract.g.dart';\n");
    Directory(
      '${plugin.path}/packages/backend/bin',
    ).createSync(recursive: true);
    Directory(
      '${plugin.path}/packages/contract/lib',
    ).createSync(recursive: true);
    File(
      '${plugin.path}/packages/contract/lib/plugin_contract.dart',
    ).writeAsStringSync('library;');
    File(
      '${plugin.path}/packages/backend/bin/workspace_demo_backend.dart',
    ).writeAsStringSync('void main() {}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('reports a toolchain mismatch with captured diagnostics', () async {
    final File log = File('${root.path}/commands.txt');
    final File fake = _script(root, 'fake', '''
printf '%s\n' "\$*" >> '${log.path}'
echo "Dart 0.0" >&2
''');
    await expectLater(
      const DevelopmentPluginBuilder().prepareBackend(
        repositoryRoot: root,
        pluginDirectory: plugin,
        dartExecutable: fake.path,
        flutterExecutable: fake.path,
        expectedDartVersion: '3.10.9',
        expectedFlutterVersion: '3.38.10',
      ),
      throwsA(
        isA<PluginBuildFailure>()
            .having(
              (PluginBuildFailure value) => value.message,
              'message',
              contains('mismatch'),
            )
            .having(
              (PluginBuildFailure value) => value.diagnostic?.stderrText,
              'stderr',
              contains('Dart 0.0'),
            ),
      ),
    );
    expect(log.readAsLinesSync(), <String>['--version']);
  });

  test('does not activate a build without both artifacts', () async {
    final Directory build = Directory(
      '${root.path}/plugins/id/builds/generation',
    )..createSync(recursive: true);
    final PluginBuildResult result = PluginBuildResult(
      buildId: 'generation',
      buildDirectory: build,
      backendArtifact: File('${build.path}/backend.aot')
        ..writeAsBytesSync(<int>[1]),
      frontendArtifact: File('${build.path}/frontend.evc'),
      diagnostics: const <PluginBuildDiagnostic>[],
    );
    await expectLater(
      const DevelopmentPluginBuilder().activate(result),
      throwsA(isA<PluginBuildFailure>()),
    );
    expect(
      File('${build.parent.parent.path}/current.json').existsSync(),
      isFalse,
    );
  });

  for (final bool stale in <bool>[false, true]) {
    test(
      'generates the selected ${stale ? 'stale' : 'missing'} contract before compilation',
      () async {
        final File source = File(
          '${plugin.path}/packages/contract/lib/temporary_contract.dart',
        );
        final File generated = File(
          '${plugin.path}/packages/contract/lib/temporary_contract.g.dart',
        );
        if (stale) generated.writeAsStringSync('stale contract');
        final String generator =
            '${root.path}/packages/contract_codegen/bin/contract_codegen.dart';
        final File log = File('${root.path}/commands.txt');
        final File fake = _script(root, 'fake', '''
printf '%s\n' "\$1" >> '${log.path}'
if [ "\$1" = "--version" ]; then
  printf 'Dart 3.10.9\n{"frameworkVersion":"3.38.10"}\n'
elif [ "\$1" = "run" ]; then
  [ "\$#" = "4" ] && [ "\$2" = '$generator' ] &&
    [ "\$3" = "--source" ] && [ "\$4" = '${source.path}' ] || exit 98
  printf 'generated contract' > "\${4%.dart}.g.dart"
  printf 'generation output'
  printf 'generation diagnostics' >&2
elif [ "\$1" = "compile" ]; then
  [ "\$(cat '${generated.path}')" = 'generated contract' ] || exit 97
  printf snapshot > "\$5"
elif [ "\$1" != "pub" ]; then
  exit 99
fi
''');

        final PluginBuildResult build = await const DevelopmentPluginBuilder()
            .prepareBackend(
              repositoryRoot: root,
              pluginDirectory: plugin,
              dartExecutable: fake.path,
              flutterExecutable: fake.path,
              expectedDartVersion: '3.10.9',
              expectedFlutterVersion: '3.38.10',
            );

        expect(generated.readAsStringSync(), 'generated contract');
        expect(build.backendArtifact.readAsStringSync(), 'snapshot');
        expect(log.readAsLinesSync(), <String>[
          '--version',
          'run',
          '--version',
          'pub',
          'compile',
        ]);
        expect(
          build.diagnostics.map((PluginBuildDiagnostic value) => value.stage),
          <String>[
            'configuration',
            'contract-generation',
            'configuration',
            'dependency-resolution',
            'backend-compilation',
          ],
        );
        final PluginBuildDiagnostic generation = build.diagnostics[1];
        expect(generation.command, <String>[
          fake.path,
          'run',
          generator,
          '--source',
          source.absolute.path,
        ]);
        expect(generation.workingDirectory, root.absolute.path);
        expect(generation.exitCode, 0);
        expect(generation.stdoutText, 'generation output');
        expect(generation.stderrText, 'generation diagnostics');
      },
    );
  }

  for (final (String kind, int exitCode, String stderr)
      in <(String, int, String)>[
        ('generation', 7, 'cannot write generated output'),
        (
          'schema',
          1,
          'temporary_contract.dart:1:1: unsupported contract schema',
        ),
        ('tooling', 64, 'contract_codegen.dart: tool unavailable'),
      ]) {
    test(
      'stops on $kind failure with captured generation diagnostics',
      () async {
        final File log = File('${root.path}/commands.txt');
        final List<String> arguments = <String>[
          'run',
          '${root.path}/packages/contract_codegen/bin/contract_codegen.dart',
          '--source',
          '${plugin.path}/packages/contract/lib/temporary_contract.dart',
        ];
        final File fake = _script(root, 'fake', '''
printf '%s\n' "\$@" >> '${log.path}'
if [ "\$1" = "--version" ]; then
  echo "Dart 3.10.9" >&2
  exit 0
fi
if [ "\$1" = "run" ]; then
  printf 'generation output'
  printf '%s' '$stderr' >&2
  exit $exitCode
fi
exit 99
''');

        await expectLater(
          const DevelopmentPluginBuilder().prepareBackend(
            repositoryRoot: root,
            pluginDirectory: plugin,
            dartExecutable: fake.path,
            flutterExecutable: fake.path,
            expectedDartVersion: '3.10.9',
            expectedFlutterVersion: '3.38.10',
          ),
          throwsA(
            isA<PluginBuildFailure>()
                .having(
                  (PluginBuildFailure value) => value.message,
                  'message',
                  'contract-generation failed with exit code $exitCode.',
                )
                .having(
                  (PluginBuildFailure value) => value.diagnostic?.stage,
                  'stage',
                  'contract-generation',
                )
                .having(
                  (PluginBuildFailure value) => value.diagnostic?.command,
                  'command',
                  <String>[fake.path, ...arguments],
                )
                .having(
                  (PluginBuildFailure value) =>
                      value.diagnostic?.workingDirectory,
                  'working directory',
                  root.absolute.path,
                )
                .having(
                  (PluginBuildFailure value) => value.diagnostic?.exitCode,
                  'exit code',
                  exitCode,
                )
                .having(
                  (PluginBuildFailure value) => value.diagnostic?.stdoutText,
                  'stdout',
                  'generation output',
                )
                .having(
                  (PluginBuildFailure value) => value.diagnostic?.stderrText,
                  'stderr',
                  stderr,
                ),
          ),
        );

        expect(log.readAsLinesSync(), <String>['--version', ...arguments]);
        expect(Directory('${root.path}/.dart_tool').existsSync(), isFalse);
      },
    );
  }

  test(
    'reports a generator process-start failure before compilation',
    () async {
      final File log = File('${root.path}/commands.txt');
      final File fake = _script(root, 'fake', '''
printf '%s\n' "\$*" >> '${log.path}'
echo "Dart 3.10.9" >&2
rm "\$0"
''');

      await expectLater(
        const DevelopmentPluginBuilder().prepareBackend(
          repositoryRoot: root,
          pluginDirectory: plugin,
          dartExecutable: fake.path,
          flutterExecutable: fake.path,
          expectedDartVersion: '3.10.9',
          expectedFlutterVersion: '3.38.10',
        ),
        throwsA(
          isA<PluginBuildFailure>()
              .having(
                (PluginBuildFailure value) => value.message,
                'message',
                allOf(
                  contains('contract-generation could not start'),
                  contains(fake.path),
                ),
              )
              .having(
                (PluginBuildFailure value) => value.diagnostic,
                'diagnostic',
                isNull,
              ),
        ),
      );
      expect(log.readAsLinesSync(), <String>['--version']);
      expect(Directory('${root.path}/.dart_tool').existsSync(), isFalse);
    },
  );

  test('fails clearly when the derived contract source is missing', () async {
    File(
      '${plugin.path}/packages/contract/lib/temporary_contract.dart',
    ).deleteSync();
    final File log = File('${root.path}/commands.txt');
    final File fake = _script(root, 'fake', '''
printf '%s\n' "\$*" >> '${log.path}'
echo "Dart 3.10.9" >&2
''');
    await expectLater(
      const DevelopmentPluginBuilder().prepareBackend(
        repositoryRoot: root,
        pluginDirectory: plugin,
        dartExecutable: fake.path,
        flutterExecutable: fake.path,
        expectedDartVersion: '3.10.9',
        expectedFlutterVersion: '3.38.10',
      ),
      throwsA(
        isA<PluginBuildFailure>().having(
          (PluginBuildFailure value) => value.message,
          'message',
          contains('Contract source does not exist'),
        ),
      ),
    );
    expect(log.readAsLinesSync(), <String>['--version']);
  });

  test(
    'builds the shared host through the checked snapshot compiler',
    () async {
      final File fake = _script(root, 'fake', 'printf snapshot > "\$5"');
      final BackendHostBuildResult build =
          await const DevelopmentPluginBuilder().buildBackendHost(
            repositoryRoot: root,
            dartExecutable: fake.path,
          );

      expect(build.artifact.readAsStringSync(), 'snapshot');
      expect(build.diagnostic.stage, 'backend-host-compilation');
      expect(build.diagnostic.command, <String>[
        fake.path,
        'compile',
        'aot-snapshot',
        '${root.path}/packages/plugin_backend_host/bin/adele_backend_host.dart',
        '-o',
        build.artifact.absolute.path,
      ]);
    },
  );

  for (final int compilerExitCode in <int>[0, 9]) {
    test(
      'preserves backend diagnostic files on exit $compilerExitCode',
      () async {
        final File fake = _script(root, 'fake', '''
if [ "\$1" = "--version" ]; then
  printf 'Dart 3.10.9\n{"frameworkVersion":"3.38.10"}\n'
elif [ "\$1" = "compile" ]; then
  printf 'compiler output'
  printf 'compiler diagnostics' >&2
  if [ '$compilerExitCode' = '0' ]; then printf snapshot > "\$5"; fi
  exit $compilerExitCode
fi
''');
        final Future<PluginBuildResult> pending =
            const DevelopmentPluginBuilder().prepareBackend(
              repositoryRoot: root,
              pluginDirectory: plugin,
              dartExecutable: fake.path,
              flutterExecutable: fake.path,
              expectedDartVersion: '3.10.9',
              expectedFlutterVersion: '3.38.10',
            );
        if (compilerExitCode == 0) {
          final PluginBuildResult build = await pending;
          expect(build.backendArtifact.readAsStringSync(), 'snapshot');
          expect(build.diagnostics.last.stage, 'backend-compilation');
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<PluginBuildFailure>().having(
                (PluginBuildFailure failure) => failure.diagnostic?.exitCode,
                'exit code',
                compilerExitCode,
              ),
            ),
          );
        }
        final Iterable<File> files = root
            .listSync(recursive: true)
            .whereType<File>();
        expect(
          files
              .singleWhere(
                (File file) => file.path.endsWith('backend.stdout.txt'),
              )
              .readAsStringSync(),
          'compiler output',
        );
        expect(
          files
              .singleWhere(
                (File file) => file.path.endsWith('backend.stderr.txt'),
              )
              .readAsStringSync(),
          'compiler diagnostics',
        );
        expect(
          files.where((File file) => file.path.endsWith('current.json')),
          isEmpty,
        );
      },
    );
  }
}

File _script(Directory directory, String name, String body) {
  final File file = File('${directory.path}/$name.sh');
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
  return file;
}
