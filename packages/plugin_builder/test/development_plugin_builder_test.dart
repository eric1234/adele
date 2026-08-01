import 'dart:io';

import 'package:plugin_builder/plugin_builder.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory plugin;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele-builder-');
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
    final File fake = _script(root, 'fake', 'echo "Dart 0.0" >&2');
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

  test('validates Dart before generated contracts', () async {
    final File fake = _script(root, 'fake', '''
echo "Dart 3.10.9" >&2
if [ "\$1" = "run" ]; then
  echo "stale generated files" >&2
  exit 7
fi
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
              (PluginBuildFailure value) => value.diagnostic?.stage,
              'stage',
              'contract-generation-verification',
            )
            .having(
              (PluginBuildFailure value) => value.diagnostic?.stderrText,
              'stderr',
              contains('stale generated files'),
            ),
      ),
    );
  });

  test(
    'checks the requested plugin contract source before compilation',
    () async {
      final File log = File('${root.path}/commands.txt');
      final File fake = _script(root, 'fake', '''
printf '%s\n' "\$*" >> '${log.path}'
if [ "\$1" = "--version" ]; then
  echo "Dart 3.10.9" >&2
  exit 0
fi
if [ "\$1" = "run" ]; then
  echo "stale generated files" >&2
  exit 7
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
          isA<PluginBuildFailure>().having(
            (PluginBuildFailure value) => value.diagnostic?.stage,
            'stage',
            'contract-generation-verification',
          ),
        ),
      );

      final List<String> commands = log.readAsLinesSync();
      expect(commands.first, '--version');
      expect(commands, hasLength(2));
      expect(commands.last, contains('--check --source'));
      expect(
        commands.last,
        endsWith(
          File(
            '${plugin.path}/packages/contract/lib/temporary_contract.dart',
          ).absolute.path,
        ),
      );
      expect(commands.last, isNot(contains('contract_codegen.yaml')));
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
}

File _script(Directory directory, String name, String body) {
  final File file = File('${directory.path}/$name.sh');
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
  return file;
}
