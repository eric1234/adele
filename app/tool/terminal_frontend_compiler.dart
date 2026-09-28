import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/environment_terminal_bridge.dart';
import 'package:adele_desktop/frontend/terminal_surface_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const terminalFrontendLibrary =
    'package:terminal_frontend/terminal_frontend.dart';

Future<Uint8List> compileTerminalFrontend({
  required Directory repositoryRoot,
}) async {
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const EnvironmentTerminalDeclarations())
    ..addPlugin(const TerminalSurfaceDeclarations())
    ..entrypoints.add(terminalFrontendLibrary);
  final root = repositoryRoot.path;
  final program = compiler.compile({
    'terminal_frontend': {
      'terminal_frontend.dart': await File(
        '$root/plugins/terminal/packages/frontend/lib/terminal_frontend.dart',
      ).readAsString(),
    },
    'adele_ui': {
      'environment_terminal_bridge.dart': await File(
        '$root/packages/ui/lib/environment_terminal_bridge.dart',
      ).readAsString(),
      'terminal_surface_bridge.dart': await File(
        '$root/packages/ui/lib/terminal_surface_bridge.dart',
      ).readAsString(),
    },
  });
  return program.write();
}
