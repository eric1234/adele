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
  backend: packages/backend
''');
    Directory(
      '${plugin.path}/packages/backend/bin',
    ).createSync(recursive: true);
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

  test('verifies generated contracts before toolchain configuration', () async {
    final File fake = _script(root, 'fake', '''
if [ "\$1" = "run" ]; then
  echo "stale generated files" >&2
  exit 7
fi
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
}

File _script(Directory directory, String name, String body) {
  final File file = File('${directory.path}/$name.sh');
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
  return file;
}
