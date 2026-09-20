import 'dart:io';

import 'package:adele_desktop/frontend/interpreted_widget.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';

import 'workspace_demo_eval_bridge.dart';

final class WorkspaceDemoEvalAdapter {
  WorkspaceDemoEvalAdapter._({
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
    // dart_eval 0.8.5 does not retain non-main libraries automatically. The
    // frontend and bridge also use boxed values to preserve async eval types.
    final Compiler compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge)
      ..entrypoints.add(
        'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      );
    final Program program = compiler.compile(<String, Map<String, String>>{
      'workspace_demo_frontend': <String, String>{
        'workspace_demo_frontend.dart': await frontendSource.readAsString(),
        'src/adele_eval_bridge.dart': _evalBridgeSource,
      },
    });
    await artifact.writeAsBytes(program.write());
  }

  static Future<WorkspaceDemoEvalAdapter> load({
    required File artifact,
    required WorkspaceDemoEvalBridge bridge,
  }) async {
    final InterpretedWidget loaded = await loadInterpretedWidget(
      bytes: await artifact.readAsBytes(),
      bridge: bridge,
      library: 'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      entrypoint: 'buildWorkspaceDemo',
    );
    return WorkspaceDemoEvalAdapter._(
      runtime: loaded.runtime,
      bridge: bridge,
      widget: loaded.widget,
    );
  }

  void invalidate() => bridge.invalidate();
}

const String _evalBridgeSource = '''
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({required this.names, required this.uris, required this.cancelled});
  final List<String> names;
  final List<String> uris;
  final bool cancelled;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value, {this.cancelled = false});
  final String value;
  final bool cancelled;
}

Future<WorkspaceDemoViewData> loadWorkspaceDemoDirectory() {
  throw UnsupportedError('Bridge function.');
}

Future<WorkspaceDemoTextData> loadWorkspaceDemoText(String uri) {
  throw UnsupportedError('Bridge function.');
}
''';
