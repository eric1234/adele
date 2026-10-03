import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/environment_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const sourceEditorFrontendLibrary = 'package:source_editor_frontend/main.dart';

Future<Uint8List> compileSourceEditorFrontend({
  required Directory repositoryRoot,
}) async {
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const MainContentDeclarations())
    ..addPlugin(const CodeEditorDeclarations())
    ..addPlugin(const ContributionDeclarations())
    ..addPlugin(const EnvironmentAccessDeclarations())
    ..entrypoints.add(sourceEditorFrontendLibrary)
    // The pinned evaluator does not retain top-level helpers referenced only
    // from instance methods in an imported interpreted library.
    ..entrypoints.add('package:source_editor_frontend/source_documents.dart');
  final root = repositoryRoot.path;
  final library = Directory(
    '$root/plugins/source_editor/packages/frontend/lib',
  );
  final sources =
      await library.list(recursive: true, followLinks: false).toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  final program = compiler.compile({
    'source_editor_frontend': {
      for (final file in sources.whereType<File>())
        if (file.path.endsWith('.dart'))
          file.uri.path.substring(library.uri.path.length): await file
              .readAsString(),
    },
    'adele_ui': {
      for (final name in [
        'main_content_bridge.dart',
        'code_editor_bridge.dart',
        'contribution_bridge.dart',
        'environment_access_bridge.dart',
      ])
        name: await File('$root/packages/ui/lib/$name').readAsString(),
    },
  });
  return program.write();
}
