import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../main_content_fixture.dart';
import '../main_content_frontend_compiler.dart';
import 'compile_frontend.dart';

void main() {
  test('prepare editor EVC before building the desktop smoke', () async {
    final artifact = File('build/code_editor_smoke/editor_frontend.evc');
    await artifact.parent.create(recursive: true);
    await compileCodeEditorFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
    );
    expect(await artifact.length(), greaterThan(0));
  });
  if (const bool.fromEnvironment('ADELE_CODE_EDITOR_WORKSPACE')) {
    test('prepare workspace EVC into the stock development catalog', () async {
      const root = String.fromEnvironment('ADELE_PLUGIN_INSTALLATION_ROOT');
      expect(root, isNotEmpty);
      final artifact = File(
        'build/code_editor_smoke/main_content_frontend.evc',
      );
      await artifact.parent.create(recursive: true);
      await prepareMainContentFixture(
        repositoryRoot: Directory.current.parent,
        artifact: artifact,
      );
      expect(await artifact.length(), greaterThan(0));
      await installMainContentFixture(
        installationRoot: Directory(root),
        artifact: artifact,
      );
      expect(
        await File(
          '$root/$mainContentFixturePluginId/frontend.evc',
        ).readAsBytes(),
        await artifact.readAsBytes(),
      );
    });
  }
}
