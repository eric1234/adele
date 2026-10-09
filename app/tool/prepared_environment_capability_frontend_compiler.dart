import 'dart:io';

import 'package:adele_desktop/frontend/capability_access_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const preparedEnvironmentCapabilityFrontendLibrary =
    'package:environment_capability_consumer/main.dart';

Future<void> compilePreparedEnvironmentCapabilityFrontend({
  required Directory repositoryRoot,
  required File contract,
  required String sdkPath,
  required File artifact,
}) async {
  final root = repositoryRoot.path;
  final generated = await ContractGenerator(
    sdkPath: sdkPath,
  ).generateEvalClient(contract);
  final program =
      (Compiler()
            ..addPlugin(flutterEvalPlugin)
            ..addPlugin(const MainContentDeclarations())
            ..addPlugin(const CapabilityAccessDeclarations())
            ..addPlugin(const EnvironmentCapabilityAccessDeclarations())
            ..entrypoints.addAll([
              preparedEnvironmentCapabilityFrontendLibrary,
              'package:capability_probe_contract/contract.dart',
              'package:adele_contract/adele_contract.dart',
            ]))
          .compile({
            'environment_capability_consumer': {
              'main.dart': await File(
                '$root/app/test/fixtures/prepared_environment_capability_frontend.dart.txt',
              ).readAsString(),
            },
            'capability_probe_contract': {'contract.dart': generated},
            'adele_contract': {
              'adele_contract.dart': evalContractSupportSource,
            },
            'adele_ui': {
              for (final library in [
                'capability_bridge',
                'environment_capability_bridge',
                'main_content_bridge',
              ])
                '$library.dart': await File(
                  '$root/packages/ui/lib/$library.dart',
                ).readAsString(),
            },
          });
  await artifact.writeAsBytes(program.write());
}
