import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

final testProjectProviderId = ProviderId('dev.adele.project.test');

/// Exercises the generated service boundary without substituting volatile storage.
final class TestProjectProvider
    implements ProjectProviderService, AdeleRequestChannel {
  TestProjectProvider(
    CapabilityRegistry registry, {
    ProviderId? providerId,
    String pluginId = 'dev.adele.plugin.test-project',
    this.prepare,
  }) : providerId = providerId ?? testProjectProviderId {
    registration = registry.register(
      provider: ProviderDescriptor(
        id: this.providerId,
        capability: projectProviderCapability,
        pluginId: pluginId,
        displayName: 'Test Project provider',
        serviceId: projectProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: this,
        serviceId: projectProviderServiceId,
        isAvailable: () => true,
      ),
    );
  }

  static const databaseRelativePath = 'test-project.sqlite3';
  final ProviderId providerId;
  final Future<ProjectBacking> Function(Uri)? prepare;
  final calls = <Uri>[];
  late final CapabilityRegistration registration;
  late final _dispatcher = ProjectProviderServiceDispatcher(this);
  int _requests = 0;

  @override
  Future<ProjectBacking> prepareSource(Uri sourceLocation) async {
    calls.add(sourceLocation);
    return prepare != null
        ? await prepare!(sourceLocation)
        : ProjectBacking(
            sourceLocation: sourceLocation,
            databaseRelativePath: databaseRelativePath,
          );
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await _dispatcher.dispatch({
      'kind': 'request',
      'requestId': ++_requests,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      throw StateError(
        'Project provider rejected request: ${response['error']}',
      );
    }
    return response['payload'];
  }

  Future<void> close() async {
    await registration.close();
    await _dispatcher.close();
  }
}
