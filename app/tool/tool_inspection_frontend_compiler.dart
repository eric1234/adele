import 'dart:io';

import 'package:adele_desktop/frontend/console_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/terminal_projection_bridge.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

import 'command_output_frontend_compiler.dart';

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
  if (frontend == ToolInspectionFrontend.command) {
    compiler
      ..addPlugin(const OwningBackendDeclarations())
      ..addPlugin(const ConsoleDeclarations())
      ..addPlugin(const TerminalProjectionDeclarations())
      ..entrypoints.add('package:$package/command_output_view.dart')
      ..entrypoints.add('package:adele_contract/adele_contract.dart')
      ..entrypoints.add(
        'package:command_tools_contract/command_tools_contract.dart',
      );
  }
  final Program program = compiler.compile({
    package: {
      '$package.dart': await File(
        '${repositoryRoot.path}/plugins/$tool/packages/frontend/lib/$package.dart',
      ).readAsString(),
      if (frontend == ToolInspectionFrontend.command)
        'command_output_view.dart': await File(
          '${repositoryRoot.path}/plugins/$tool/packages/frontend/lib/command_output_view.dart',
        ).readAsString(),
    },
    if (frontend == ToolInspectionFrontend.command)
      'command_tools_contract': {
        'command_tools_contract.dart': await commandOutputContractSource(
          repositoryRoot,
        ),
      },
    if (frontend == ToolInspectionFrontend.command)
      'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    'adele_ui': {
      'tool_activity_inspection_bridge.dart': await File(
        '${repositoryRoot.path}/packages/ui/lib/tool_activity_inspection_bridge.dart',
      ).readAsString(),
      'inspection_display.dart': await File(
        '${repositoryRoot.path}/packages/ui/lib/inspection_display.dart',
      ).readAsString(),
      if (frontend == ToolInspectionFrontend.command)
        for (final name in [
          'owning_backend_bridge.dart',
          'console_bridge.dart',
          'terminal_projection_bridge.dart',
        ])
          name: await File(
            '${repositoryRoot.path}/packages/ui/lib/$name',
          ).readAsString(),
    },
  });
  await artifact.writeAsBytes(program.write());
}
