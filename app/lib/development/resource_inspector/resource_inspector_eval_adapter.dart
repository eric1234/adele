import 'dart:io';

import 'package:adele_desktop/development/resource_inspector/resource_inspector_eval_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
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
    final Runtime runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
    final Object? pending = runtime.executeLib(
      'package:resource_inspector_consumer/resource_inspector_consumer.dart',
      'buildCapabilityDemo',
    );
    final Object? result = pending is Future<Object?> ? await pending : pending;
    final Object? reified = result is $Value ? result.$reified : result;
    if (reified is! Widget) {
      throw StateError('Capability consumer did not return a Widget.');
    }
    return ResourceInspectorEvalAdapter._(
      runtime: runtime,
      bridge: bridge,
      widget: reified,
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
  const ResolvedInspectorData({required this.token, required this.providerId});
  final String token;
  final String providerId;
}
final class InspectionData {
  const InspectionData({required this.providerLabel, required this.summary, required this.cancelled});
  final String providerLabel;
  final String summary;
  final bool cancelled;
}
Future<List<CapabilityProviderData>> resourceInspectorProviders() => throw UnsupportedError('Bridge function.');
Future<ResolvedInspectorData> resolveResourceInspector([String? providerId]) => throw UnsupportedError('Bridge function.');
Future<InspectionData> inspectResource(String token, String resourceUri) => throw UnsupportedError('Bridge function.');
''';
