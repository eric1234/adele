import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/session_accessory_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const agentConfigurationFrontendLibrary =
    'package:agent_configuration_frontend/agent_configuration_frontend.dart';

Future<Uint8List> compileAgentConfigurationFrontend({
  required Directory repositoryRoot,
}) async {
  // flutter_test runs inside flutter_tester. Use that toolchain's bundled SDK.
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/lib/core/core.dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Cannot locate the pinned Dart SDK.');
    }
    directory = directory.parent;
  }
  final packages = repositoryRoot.uri.resolve(
    'plugins/agent_configuration/packages/',
  );
  final contract =
      await ContractGenerator(
        sdkPath: '${directory.path}/dart-sdk',
      ).generateEvalClient(
        File.fromUri(
          packages.resolve('contract/lib/agent_configuration_contract.dart'),
        ),
      );
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const SessionAccessoryDeclarations())
    ..addPlugin(const OwningBackendDeclarations())
    ..entrypoints.addAll([
      agentConfigurationFrontendLibrary,
      'package:agent_configuration_contract/agent_configuration_contract.dart',
      'package:adele_contract/adele_contract.dart',
    ]);
  final program = compiler.compile({
    'agent_configuration_frontend': {
      'agent_configuration_frontend.dart': await File.fromUri(
        packages.resolve('frontend/lib/agent_configuration_frontend.dart'),
      ).readAsString(),
    },
    'agent_configuration_contract': {
      'agent_configuration_contract.dart': contract,
    },
    'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    'adele_ui': {
      for (final source in [
        'session_accessory_bridge.dart',
        'owning_backend_bridge.dart',
        'inspection_display.dart',
      ])
        source: await File.fromUri(
          repositoryRoot.uri.resolve('packages/ui/lib/$source'),
        ).readAsString(),
    },
  });
  return program.write();
}
