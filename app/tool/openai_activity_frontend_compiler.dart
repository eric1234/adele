import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

Future<Uint8List> compileOpenAiActivityFrontend({
  required Directory repositoryRoot,
}) async {
  final Compiler compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const ModelNativeActivityDeclarations())
    ..entrypoints.add('package:openai_frontend/openai_frontend.dart');
  final Program program = compiler.compile({
    'openai_frontend': {
      'openai_frontend.dart': await File(
        '${repositoryRoot.path}/plugins/openai/packages/frontend/lib/openai_frontend.dart',
      ).readAsString(),
    },
    'adele_ui': {
      for (final name in ['model_native_activity_bridge', 'inspection_display'])
        '$name.dart': await File(
          '${repositoryRoot.path}/packages/ui/lib/$name.dart',
        ).readAsString(),
    },
  });
  return program.write();
}
