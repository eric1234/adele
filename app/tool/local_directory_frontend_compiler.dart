import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/directory_picker_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

Future<Uint8List> compileLocalDirectoryFrontend({
  required Directory repositoryRoot,
}) async {
  final Compiler compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const DirectoryPickerDeclarations())
    ..entrypoints.add(
      'package:local_directory_project_selector_frontend/local_directory_project_selector_frontend.dart',
    );
  final Program program = compiler.compile({
    'local_directory_project_selector_frontend': {
      'local_directory_project_selector_frontend.dart': await File(
        '${repositoryRoot.path}/plugins/local_directory_project_selector/packages/frontend/lib/local_directory_project_selector_frontend.dart',
      ).readAsString(),
    },
    'adele_ui': {
      'directory_picker_bridge.dart': await File(
        '${repositoryRoot.path}/packages/ui/lib/directory_picker_bridge.dart',
      ).readAsString(),
    },
  });
  return program.write();
}
