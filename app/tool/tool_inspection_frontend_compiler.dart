import 'dart:io';

import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

enum ToolInspectionFrontend { filesystem, command }

Future<void> compileToolInspectionFrontend({
  required Directory repositoryRoot,
  required File artifact,
  required ToolInspectionFrontend frontend,
}) async {
  final String tool = frontend == ToolInspectionFrontend.filesystem
      ? 'filesystem_tools'
      : 'command_tools';
  final String package = '${tool}_frontend';
  final Compiler compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const ToolActivityInspectionDeclarations())
    ..entrypoints.add('package:$package/$package.dart');
  final Program program = compiler.compile({
    package: {
      '$package.dart': await File(
        '${repositoryRoot.path}/plugins/$tool/packages/frontend/lib/$package.dart',
      ).readAsString(),
    },
    'adele_ui': {
      'tool_activity_inspection_bridge.dart': await File(
        '${repositoryRoot.path}/packages/ui/lib/tool_activity_inspection_bridge.dart',
      ).readAsString(),
      'inspection_display.dart': await File(
        '${repositoryRoot.path}/packages/ui/lib/inspection_display.dart',
      ).readAsString(),
    },
  });
  await artifact.writeAsBytes(program.write());
}
