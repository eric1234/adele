import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/layout_builder_bridge.dart';
import 'package:adele_desktop/frontend/task_browser_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const taskBrowserFrontendLibrary =
    'package:task_browser_frontend/task_browser_frontend.dart';

Future<Uint8List> compileTaskBrowserFrontend({
  required Directory repositoryRoot,
}) async {
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const LayoutBuilderBridge())
    ..addPlugin(const TaskBrowserDeclarations())
    ..entrypoints.add(taskBrowserFrontendLibrary);
  final root = repositoryRoot.path;
  final program = compiler.compile({
    'task_browser_frontend': {
      'task_browser_frontend.dart': await File(
        '$root/plugins/task_browser/packages/frontend/lib/task_browser_frontend.dart',
      ).readAsString(),
    },
    'adele_ui': {
      'task_browser_bridge.dart': await File(
        '$root/packages/ui/lib/task_browser_bridge.dart',
      ).readAsString(),
    },
  });
  return program.write();
}
