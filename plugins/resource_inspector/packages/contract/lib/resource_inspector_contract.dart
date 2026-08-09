/// Shared Phase III resource-inspection capability and transport declarations.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

part 'resource_inspector_contract.g.dart';

final capabilities.CapabilityKey resourceInspectCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.resource.inspect'),
      majorVersion: 1,
    );

final capabilities.ProviderId basicResourceInspectorProviderId =
    capabilities.ProviderId('dev.adele.resource-inspector.basic');

final capabilities.ProviderId alternateResourceInspectorProviderId =
    capabilities.ProviderId('dev.adele.resource-inspector.alternate');

@AdeleValue('resourceInspector.inspection')
final class ResourceInspection {
  const ResourceInspection({
    required this.resource,
    required this.providerLabel,
    required this.summary,
  });

  final ResourceRef resource;
  final String providerLabel;
  final String summary;
}

@AdeleService('resourceInspector')
abstract interface class ResourceInspectorService {
  @AdeleMethod('inspect')
  Future<ResourceInspection> inspect(ResourceRef resource);
}

@AdeleFailure('resourceInspector.failure')
final class ResourceInspectorFailure implements Exception {
  const ResourceInspectorFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ResourceInspectorFailure($code): $message';
}
