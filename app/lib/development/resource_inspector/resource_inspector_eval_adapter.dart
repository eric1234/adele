import 'dart:io';

import 'package:adele_desktop/development/resource_inspector/resource_inspector_eval_bridge.dart';
import 'package:adele_desktop/frontend/interpreted_widget.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';

final class ResourceInspectorEvalAdapter {
  ResourceInspectorEvalAdapter._({
    required this.runtime,
    required this.bridge,
    required this.widget,
  });

  final Runtime runtime;
  final ResourceInspectorEvalBridge bridge;
  final Widget widget;

  static Future<ResourceInspectorEvalAdapter> compileAndLoad({
    required Directory repositoryRoot,
    required ResourceInspectorEvalBridge bridge,
  }) async {
    final File frontend = File(
      '${repositoryRoot.path}/plugins/resource_inspector/packages/consumer/lib/resource_inspector_consumer.dart',
    );
    final Compiler compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge)
      ..entrypoints.add(
        'package:resource_inspector_consumer/resource_inspector_consumer.dart',
      );
    final Program program = compiler.compile(<String, Map<String, String>>{
      'resource_inspector_consumer': <String, String>{
        'resource_inspector_consumer.dart': await frontend.readAsString(),
        'src/adele_eval_bridge.dart': _bridgeSource,
      },
    });
    final InterpretedWidget loaded = await loadInterpretedWidget(
      bytes: program.write(),
      bridge: bridge,
      library:
          'package:resource_inspector_consumer/resource_inspector_consumer.dart',
      entrypoint: 'buildCapabilityDemo',
    );
    return ResourceInspectorEvalAdapter._(
      runtime: loaded.runtime,
      bridge: bridge,
      widget: loaded.widget,
    );
  }

  void invalidate() => bridge.invalidate();
}

const String _bridgeSource = '''
final class CapabilityProviderData {
  const CapabilityProviderData({required this.id, required this.displayName});
  final String id;
  final String displayName;
}
final class ResolvedInspectorData {
  const ResolvedInspectorData({required this.status, required this.token, required this.providerId});
  final String status;
  final String token;
  final String providerId;
}
final class InspectionData {
  const InspectionData({required this.status, required this.providerLabel, required this.summary});
  final String status;
  final String providerLabel;
  final String summary;
}
Future<List<CapabilityProviderData>> resourceInspectorProviders() => throw UnsupportedError('Bridge function.');
Future<ResolvedInspectorData> resolveResourceInspector([String? providerId]) => throw UnsupportedError('Bridge function.');
Future<InspectionData> inspectResource(String token, String resourceUri) => throw UnsupportedError('Bridge function.');
''';
