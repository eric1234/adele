import 'dart:io';

import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const chatFrontendLibrary =
    'package:chat_strategy_frontend/chat_strategy_frontend.dart';

Future<Map<String, Map<String, String>>> chatFrontendSources(
  Directory repositoryRoot,
) async {
  final root = repositoryRoot.path;
  final contract = await ContractGenerator(sdkPath: _dartSdk()).generateEvalClient(
    File(
      '$root/plugins/chat_strategy/packages/contract/lib/chat_strategy_contract.dart',
    ),
  );
  return {
    'chat_strategy_frontend': {
      'chat_strategy_frontend.dart': await File(
        '$root/plugins/chat_strategy/packages/frontend/lib/chat_strategy_frontend.dart',
      ).readAsString(),
    },
    'chat_strategy_contract': {'chat_strategy_contract.dart': contract},
    'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    'adele_ui': {
      for (final name in [
        'owning_backend_bridge.dart',
        'session_execution_bridge.dart',
        'inspection_display.dart',
      ])
        name: await File('$root/packages/ui/lib/$name').readAsString(),
    },
  };
}

String _dartSdk() {
  // flutter_test runs in flutter_tester, not the SDK's bin/dart executable.
  // Resolve the bundled SDK from that same pinned toolchain, never from PATH.
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final candidate = Directory('${directory.path}/dart-sdk');
    if (File('${candidate.path}/lib/core/core.dart').existsSync()) {
      return candidate.path;
    }
    directory = directory.parent;
  }
  throw StateError('Cannot locate the running Flutter toolchain Dart SDK.');
}

Future<void> compileChatFrontend({
  required Directory repositoryRoot,
  required File artifact,
}) async {
  final Compiler compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const OwningBackendDeclarations())
    ..addPlugin(const SessionExecutionDeclarations())
    ..entrypoints.add('package:adele_contract/adele_contract.dart')
    ..entrypoints.add(
      'package:chat_strategy_contract/chat_strategy_contract.dart',
    )
    ..entrypoints.add(chatFrontendLibrary);
  final Program program = compiler.compile(
    await chatFrontendSources(repositoryRoot),
  );
  await artifact.writeAsBytes(program.write());
}
