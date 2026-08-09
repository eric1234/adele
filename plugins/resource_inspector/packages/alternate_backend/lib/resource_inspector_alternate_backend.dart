import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

final class AlternateResourceInspector implements ResourceInspectorService {
  const AlternateResourceInspector();

  @override
  Future<ResourceInspection> inspect(ResourceRef resource) async =>
      ResourceInspection(
        resource: resource,
        providerLabel: 'Alternate Inspector',
        summary: 'Alternate inspection of ${resource.uri}',
      );
}
