import 'dart:io';

import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

import 'main_content_fixture.dart';

/// Development preparation only. Neither declaration plugin acquires resources.
Future<Program> prepareMainContentFixture({
  required Directory repositoryRoot,
  required File artifact,
}) async {
  final root = repositoryRoot.path;
  final program =
      (Compiler()
            ..addPlugin(flutterEvalPlugin)
            ..addPlugin(const CodeEditorDeclarations())
            ..addPlugin(const MainContentDeclarations())
            ..entrypoints.add(mainContentFixtureLibrary))
          .compile({
            'main_content_fixture': {
              'main.dart': await File(
                '$root/app/test/fixtures/main_content_frontend.dart',
              ).readAsString(),
            },
            'adele_ui': {
              for (final name in [
                'code_editor_bridge.dart',
                'main_content_bridge.dart',
              ])
                name: await File('$root/packages/ui/lib/$name').readAsString(),
            },
          });
  await artifact.writeAsBytes(program.write());
  return program;
}
