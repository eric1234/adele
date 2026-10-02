import 'dart:io';

import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const codeEditorFrontendLibrary = 'package:code_editor_probe/main.dart';

/// Compiles only public UI and Flutter source. No editor owner is initialized
/// during preparation; the native body is supplied by the eventual host.
Future<Program> compileCodeEditorFrontend({
  required Directory repositoryRoot,
  required File artifact,
  File? fixture,
}) async {
  final root = repositoryRoot.path;
  final program =
      (Compiler()
            ..addPlugin(flutterEvalPlugin)
            ..addPlugin(const CodeEditorDeclarations())
            ..entrypoints.add(codeEditorFrontendLibrary))
          .compile({
            'code_editor_probe': {
              'main.dart':
                  await (fixture ??
                          File(
                            '$root/app/test/fixtures/code_editor_frontend.dart',
                          ))
                      .readAsString(),
            },
            'adele_ui': {
              'code_editor_bridge.dart': await File(
                '$root/packages/ui/lib/code_editor_bridge.dart',
              ).readAsString(),
            },
          });
  await artifact.writeAsBytes(program.write());
  return program;
}
