import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

final class BasicResourceInspector implements ResourceInspectorService {
  const BasicResourceInspector();

  @override
  Future<ResourceInspection> inspect(ResourceRef resource) async {
    if (resource.uri.scheme == 'fail') {
      throw const ResourceInspectorFailure(
        code: 'basic_rejected',
        message: 'The basic provider rejected this resource.',
        details: <String, Object?>{},
      );
    }
    return ResourceInspection(
      resource: resource,
      providerLabel: 'Basic Inspector',
      summary: 'Basic inspection of ${resource.uri}',
    );
  }
}
