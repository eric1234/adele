import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/command_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';

Future<Uint8List> compileSessionEvaluatorFrontend({
  required Directory repositoryRoot,
}) async {
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/lib/core/core.dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Cannot locate the pinned Dart SDK.');
    }
    directory = directory.parent;
  }
  final root = repositoryRoot.path;
  final contract =
      await ContractGenerator(
        sdkPath: '${directory.path}/dart-sdk',
      ).generateEvalClient(
        File(
          '$root/plugins/session_evaluator/packages/contract/lib/session_evaluator_contract.dart',
        ),
      );
  final program =
      (Compiler()
            ..addPlugin(const CommandDeclarations())
            ..addPlugin(const OwningBackendDeclarations())
            ..entrypoints.add('package:adele_contract/adele_contract.dart')
            ..entrypoints.add(
              'package:session_evaluator_contract/session_evaluator_contract.dart',
            )
            ..entrypoints.add(
              'package:session_evaluator_frontend/session_evaluator_frontend.dart',
            ))
          .compile({
            'session_evaluator_frontend': {
              for (final source in [
                'session_evaluator_frontend.dart',
                'src/read_prepared_handoff.dart',
              ])
                source: await File(
                  '$root/plugins/session_evaluator/packages/frontend/lib/$source',
                ).readAsString(),
            },
            'session_evaluator_contract': {
              'session_evaluator_contract.dart': contract,
            },
            'adele_contract': {
              'adele_contract.dart': evalContractSupportSource,
            },
            'adele_ui': {
              for (final source in [
                'command_bridge.dart',
                'owning_backend_bridge.dart',
              ])
                source: await File(
                  '$root/packages/ui/lib/$source',
                ).readAsString(),
            },
          });
  return program.write();
}
