import 'dart:io';

import 'package:adele_desktop/phase1/eval/workspace_demo_eval_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';

final class WorkspaceDemoEvalRuntime {
  WorkspaceDemoEvalRuntime._({
    required this.runtime,
    required this.bridge,
    required this.widget,
  });

  final Runtime runtime;
  final WorkspaceDemoEvalBridge bridge;
  final Widget widget;

  static Future<void> compile({
    required Directory pluginDirectory,
    required File artifact,
    required WorkspaceDemoEvalBridge bridge,
  }) async {
    final File frontendSource = File(
      '${pluginDirectory.path}${Platform.pathSeparator}packages${Platform.pathSeparator}frontend${Platform.pathSeparator}lib${Platform.pathSeparator}workspace_demo_frontend.dart',
    );
    final Compiler compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge)
      ..entrypoints.add(
        'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      );
    final Program program = compiler.compile(<String, Map<String, String>>{
      'workspace_demo_frontend': <String, String>{
        'workspace_demo_frontend.dart': await frontendSource.readAsString(),
      },
      'workspace_demo_contract': <String, String>{
        'workspace_demo_contract.dart': _evalContractSource,
      },
    });
    await artifact.writeAsBytes(program.write());
  }

  static Future<WorkspaceDemoEvalRuntime> load({
    required File artifact,
    required WorkspaceDemoEvalBridge bridge,
  }) async {
    final Runtime runtime =
        Runtime((await artifact.readAsBytes()).buffer.asByteData())
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge);
    final Object? pending = runtime.executeLib(
      'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      'buildWorkspaceDemo',
    );
    final Object? result = pending is Future<Object?> ? await pending : pending;
    final Object? reified = result is $Value ? result.$reified : result;
    if (reified is! Widget) {
      throw StateError('The interpreted entrypoint did not return a Widget.');
    }
    return WorkspaceDemoEvalRuntime._(
      runtime: runtime,
      bridge: bridge,
      widget: reified,
    );
  }

  void invalidate() => bridge.invalidate();
}

const String _evalContractSource = '''
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({required this.names, required this.uris});
  final List<String> names;
  final List<String> uris;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value);
  final String value;
}

Future<WorkspaceDemoViewData> loadWorkspaceDemoDirectory() {
  throw UnsupportedError('Bridge function.');
}

Future<WorkspaceDemoTextData> loadWorkspaceDemoText(String uri) {
  throw UnsupportedError('Bridge function.');
}
''';
