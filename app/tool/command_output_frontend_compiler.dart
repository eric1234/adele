import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const commandOutputFrontendLibrary = 'package:command_output_probe/main.dart';

Future<String> commandOutputContractSource(Directory repositoryRoot) async {
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/lib/core/core.dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Cannot locate the pinned Dart SDK.');
    }
    directory = directory.parent;
  }
  return ContractGenerator(
    sdkPath: '${directory.path}/dart-sdk',
  ).generateEvalClient(
    File(
      '${repositoryRoot.path}/plugins/command_tools/packages/contract/lib/command_tools_contract.dart',
    ),
  );
}

Future<void> compileCommandOutputFrontend({
  required Directory repositoryRoot,
  required File artifact,
  required String sessionId,
  required String runId,
  required String toolInvocationId,
}) async {
  final root = repositoryRoot.path;
  final contract = await commandOutputContractSource(repositoryRoot);
  final fixture =
      (await File(
            '$root/app/test/fixtures/command_output_frontend.dart',
          ).readAsString())
          .replaceAll("'FIXTURE_SESSION'", jsonEncode(sessionId))
          .replaceAll("'FIXTURE_RUN'", jsonEncode(runId))
          .replaceAll("'FIXTURE_INVOCATION'", jsonEncode(toolInvocationId));
  final program =
      (Compiler()
            ..addPlugin(flutterEvalPlugin)
            ..addPlugin(const OwningBackendDeclarations())
            ..entrypoints.add('package:adele_contract/adele_contract.dart')
            ..entrypoints.add(
              'package:command_tools_contract/command_tools_contract.dart',
            )
            ..entrypoints.add(commandOutputFrontendLibrary))
          .compile({
            'command_output_probe': {'main.dart': fixture},
            'command_tools_contract': {'command_tools_contract.dart': contract},
            'adele_contract': {
              'adele_contract.dart': evalContractSupportSource,
            },
            'adele_ui': {
              'owning_backend_bridge.dart': await File(
                '$root/packages/ui/lib/owning_backend_bridge.dart',
              ).readAsString(),
            },
          });
  await artifact.writeAsBytes(program.write());
}
