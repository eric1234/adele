import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

/// Establishes real product topology without filesystem or provider transport I/O.
final class OrchestrationTestLifecycle {
  OrchestrationTestLifecycle._(this.lifecycle, this.task);

  static Future<OrchestrationTestLifecycle> create(
    ExtensionRegistry extensions,
    SessionId sessionId,
  ) async {
    final _EnvironmentProvider provider = _EnvironmentProvider();
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: ProviderDescriptor(
        id: provider.providerId,
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.plugin.orchestration-fixture',
        displayName: 'Orchestration Fixture',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: _ProviderEndpoint(provider),
    );
    final ProductLifecycleCoordinator lifecycle = ProductLifecycleCoordinator(
      store: InMemoryProductStore(),
      registry: registry,
      extensions: extensions,
      ids: _Ids(sessionId),
      providerForBinding: (ProviderBinding binding) =>
          binding.endpointAs<_ProviderEndpoint>().provider,
    );
    final Project project = lifecycle.createProject(
      Uri.parse('file:///fixture'),
    );
    final TaskCreationResult created = await lifecycle.createTask(
      projectId: project.id,
      title: 'Orchestration execution fixture',
      providerId: provider.providerId,
    );
    return OrchestrationTestLifecycle._(lifecycle, created.task);
  }

  final ProductLifecycleCoordinator lifecycle;
  final Task task;

  Session createSession(OrchestrationStrategyId strategyId) =>
      lifecycle.createSession(taskId: task.id, strategyId: strategyId);
}

final class _Ids implements ProductIdSource {
  const _Ids(this.sessionId);

  final SessionId sessionId;

  @override
  ProjectId nextProjectId() => ProjectId('project-${sessionId.value}');

  @override
  TaskId nextTaskId() => TaskId('task-${sessionId.value}');

  @override
  EnvironmentId nextEnvironmentId() =>
      EnvironmentId('environment-${sessionId.value}');

  @override
  SessionId nextSessionId() => sessionId;
}

final class _ProviderEndpoint implements CapabilityEndpoint {
  const _ProviderEndpoint(this.provider);

  final EnvironmentProvider provider;

  @override
  bool get isAvailable => true;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _EnvironmentProvider implements EnvironmentProvider {
  @override
  final ProviderId providerId = ProviderId(
    'dev.adele.environment.orchestration-fixture',
  );

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async => EnvironmentProviderResult(
    providerState: const <String, Object?>{'established': true},
  );

  @override
  Future<EnvironmentProviderResult> restore(LocalEnvironment environment) =>
      throw UnimplementedError();

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String text,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => throw UnimplementedError();

  @override
  Future<void> deleteExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String expectedRevision,
  ) => throw UnimplementedError();

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => throw UnimplementedError();
}
