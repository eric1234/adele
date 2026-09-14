import 'dart:io';

import 'package:adele_desktop/plugins/chat_frontend_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

Future<void> compileChatFrontend({
  required Directory repositoryRoot,
  required File artifact,
}) async {
  final Directory source = Directory(
    '${repositoryRoot.path}/plugins/chat_strategy/packages/frontend/lib',
  );
  final Compiler compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const ChatFrontendDeclarations())
    ..entrypoints.add(chatFrontendLibrary);
  final Program program = compiler.compile({
    'chat_strategy_frontend': {
      'chat_strategy_frontend.dart': await File(
        '${source.path}/chat_strategy_frontend.dart',
      ).readAsString(),
      'src/chat_frontend_bridge.dart': await File(
        '${source.path}/src/chat_frontend_bridge.dart',
      ).readAsString(),
    },
  });
  await artifact.writeAsBytes(program.write());
}
