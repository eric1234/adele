import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  final ProviderId providerId = ProviderId(
    'dev.adele.environment.lifecycle-fixture',
  );

  test('Task establishment stays unpublished until provider success', () async {
    final InMemoryProductStore store = InMemoryProductStore();
    final CapabilityRegistry registry = CapabilityRegistry();
    final _BlockingProvider provider = _BlockingProvider(providerId);
    registry.register(
      provider: _descriptor(providerId),
      endpoint: _ProviderEndpoint(provider),
    );
    final ProductLifecycleCoordinator coordinator = ProductLifecycleCoordinator(
      store: store,
      registry: registry,
      ids: _FixedIds(),
      providerForBinding: (ProviderBinding binding) =>
          binding.endpointAs<_ProviderEndpoint>().provider,
    );
    final Project project = coordinator.createProject(
      Uri.parse('file:///tmp/source'),
    );

    final Future<TaskCreationResult> creating = coordinator.createTask(
      projectId: project.id,
      title: 'Establish a Task',
      providerId: providerId,
    );
    await provider.started.future;

    final LocalEnvironment provisional = provider.environment!;
    expect(provisional.task.project.id, project.id);
    expect(provisional.task.project.sourceLocation, project.sourceLocation);
    expect(provisional.task.title, 'Establish a Task');
    expect(provisional.role, EnvironmentRole.primary);
    expect(provisional.providerId, providerId);
    expect(provisional.providerState, isNull);
    expect(store.task(provisional.task.id), isNull);
    expect(store.environment(provisional.id), isNull);
    expect(store.tasksFor(project.id), isEmpty);

    provider.complete(<String, Object?>{
      'schemaVersion': 1,
      'worktree': '/tmp/worktree',
    });
    final TaskCreationResult result = await creating;

    expect(store.task(result.task.id), same(result.task));
    expect(store.environment(result.environment.id), same(result.environment));
    expect(
      store.primaryEnvironmentFor(result.task.id),
      same(result.environment),
    );
    expect(result.environment.taskId, result.task.id);
    expect(result.environment.providerId, providerId);
    expect(result.environment.providerState, <String, Object?>{
      'schemaVersion': 1,
      'worktree': '/tmp/worktree',
    });
  });

  test('failed establishment publishes neither Task nor Environment', () async {
    final InMemoryProductStore store = InMemoryProductStore();
    final CapabilityRegistry registry = CapabilityRegistry();
    final _FailingProvider provider = _FailingProvider(providerId);
    registry.register(
      provider: _descriptor(providerId),
      endpoint: _ProviderEndpoint(provider),
    );
    final ProductLifecycleCoordinator coordinator = ProductLifecycleCoordinator(
      store: store,
      registry: registry,
      ids: _FixedIds(),
      providerForBinding: (ProviderBinding binding) =>
          binding.endpointAs<_ProviderEndpoint>().provider,
    );
    final Project project = coordinator.createProject(
      Uri.parse('file:///tmp/source'),
    );

    await expectLater(
      coordinator.createTask(
        projectId: project.id,
        title: 'Fail establishment',
      ),
      throwsA(
        isA<EnvironmentFailure>().having(
          (EnvironmentFailure failure) => failure.code,
          'code',
          'fixture_failure',
        ),
      ),
    );

    expect(provider.calls, 1);
    expect(store.tasksFor(project.id), isEmpty);
    expect(store.task(TaskId('task-1')), isNull);
    expect(store.environment(EnvironmentId('environment-1')), isNull);
    expect(store.primaryEnvironmentFor(TaskId('task-1')), isNull);
  });

  test(
    'generated coordinator resolves and publishes through wire adapter',
    () async {
      final InMemoryProductStore store = InMemoryProductStore();
      final CapabilityRegistry registry = CapabilityRegistry();
      final _EstablishmentChannel channel = _EstablishmentChannel();
      registry.register(
        provider: _descriptor(providerId),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      final ProductLifecycleCoordinator coordinator =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            ids: _FixedIds(),
          );
      final Project project = coordinator.createProject(
        Uri.parse('file:///tmp/generated-source'),
      );

      final TaskCreationResult result = await coordinator.createTask(
        projectId: project.id,
        title: 'Generated provider path',
        providerId: providerId,
      );

      expect(channel.method, environmentProviderServiceEstablishId);
      expect(channel.payload!['context'], isA<Map<String, Object?>>());
      final Map<String, Object?> context =
          channel.payload!['context']! as Map<String, Object?>;
      expect(context['projectId'], project.id.value);
      expect(context['taskId'], result.task.id.value);
      expect(context['environmentId'], result.environment.id.value);
      expect(context['providerId'], providerId.value);
      expect(context['providerStateInitialized'], isFalse);
      expect(result.environment.providerState, <String, Object?>{
        'transport': 'established',
      });
      expect(store.primaryEnvironmentFor(result.task.id), result.environment);
    },
  );
}

ProviderDescriptor _descriptor(ProviderId id) => ProviderDescriptor(
  id: id,
  capability: environmentProviderCapability,
  pluginId: 'dev.adele.plugin.lifecycle-fixture',
  displayName: 'Lifecycle Fixture',
  serviceId: environmentProviderServiceId,
);

final class _ProviderEndpoint implements CapabilityEndpoint {
  const _ProviderEndpoint(this.provider);

  final EnvironmentProvider provider;

  @override
  bool get isAvailable => true;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _FixedIds implements ProductIdSource {
  @override
  EnvironmentId nextEnvironmentId() => EnvironmentId('environment-1');

  @override
  ProjectId nextProjectId() => ProjectId('project-1');

  @override
  TaskId nextTaskId() => TaskId('task-1');
}

final class _EstablishmentChannel implements AdeleRequestChannel {
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    return <String, Object?>{
      'providerState': <String, Object?>{'transport': 'established'},
    };
  }
}

final class _BlockingProvider implements EnvironmentProvider {
  _BlockingProvider(this.providerId);

  @override
  final ProviderId providerId;
  final Completer<void> started = Completer<void>();
  final Completer<EnvironmentProviderResult> _result =
      Completer<EnvironmentProviderResult>();
  LocalEnvironment? environment;

  void complete(Map<String, Object?> providerState) {
    _result.complete(EnvironmentProviderResult(providerState: providerState));
  }

  @override
  Future<EnvironmentProviderResult> establish(LocalEnvironment environment) {
    this.environment = environment;
    started.complete();
    return _result.future;
  }

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
  Future<EnvironmentProviderResult> restore(LocalEnvironment environment) =>
      throw UnimplementedError();
}

final class _FailingProvider implements EnvironmentProvider {
  _FailingProvider(this.providerId);

  @override
  final ProviderId providerId;
  int calls = 0;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async {
    calls++;
    throw const EnvironmentFailure(
      code: 'fixture_failure',
      message: 'Fixture establishment failed.',
      details: <String, Object?>{},
    );
  }

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
  Future<EnvironmentProviderResult> restore(LocalEnvironment environment) =>
      throw UnimplementedError();
}
