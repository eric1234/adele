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
    final EnvironmentMaterialization materialization = coordinator
        .environmentRuntime
        .currentMaterialization(result.environment.id)!;
    expect(materialization.environment, same(result.environment));
    expect(materialization.provider, same(provider));
    expect(
      await coordinator.environmentRuntime.materialize(result.environment.id),
      same(materialization),
    );
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
    'successful establishment survives immediate generation retirement',
    () async {
      final InMemoryProductStore store = InMemoryProductStore();
      final CapabilityRegistry registry = CapabilityRegistry();
      final _BlockingProvider provider = _BlockingProvider(providerId);
      final CapabilityRegistration registration = registry.register(
        provider: _descriptor(providerId),
        endpoint: _ProviderEndpoint(provider),
      );
      final ProductLifecycleCoordinator coordinator =
          ProductLifecycleCoordinator(
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
        title: 'Retire after establishment',
        providerId: providerId,
      );
      await provider.started.future;
      await registration.close();
      provider.complete(const <String, Object?>{'durable': true});

      final TaskCreationResult created = await creating;

      expect(store.task(created.task.id), same(created.task));
      expect(
        store.environment(created.environment.id),
        same(created.environment),
      );
      expect(created.environment.providerState, const <String, Object?>{
        'durable': true,
      });
      expect(
        () => coordinator.environmentRuntime
            .currentMaterialization(created.environment.id)!
            .validateBinding(),
        throwsA(
          isA<ProviderUnavailable>().having(
            (ProviderUnavailable error) => error.stale,
            'stale',
            isTrue,
          ),
        ),
      );
    },
  );

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

  test('Session authority validates the Task and Environment graph', () {
    final InMemoryProductStore store = InMemoryProductStore();
    final Project project = Project(
      id: ProjectId('project-authority'),
      sourceLocation: Uri.parse('file:///tmp/source'),
    );
    final Task taskA = Task(
      id: TaskId('task-a'),
      projectId: project.id,
      title: 'Task A',
    );
    final Task taskB = Task(
      id: TaskId('task-b'),
      projectId: project.id,
      title: 'Task B',
    );
    final Environment environmentA = _finalEnvironment(
      id: 'environment-a',
      task: taskA,
      providerId: providerId,
    );
    final Environment environmentB = _finalEnvironment(
      id: 'environment-b',
      task: taskB,
      providerId: providerId,
    );
    store.publishProject(project);
    store.publishTaskWithPrimaryEnvironment(taskA, environmentA);
    store.publishTaskWithPrimaryEnvironment(taskB, environmentB);

    final SessionEnvironmentAuthority authority = store.associateSession(
      sessionId: SessionId('session-a'),
      taskId: taskA.id,
    );

    expect(authority.taskId, taskA.id);
    expect(authority.environmentId, environmentA.id);
    expect(
      store.associateSession(
        sessionId: authority.sessionId,
        taskId: taskA.id,
        environmentId: environmentA.id,
      ),
      same(authority),
    );
    expect(
      () => store.associateSession(
        sessionId: SessionId('unknown-task-session'),
        taskId: TaskId('unknown-task'),
      ),
      throwsStateError,
    );
    expect(
      () => store.associateSession(
        sessionId: SessionId('unknown-environment-session'),
        taskId: taskA.id,
        environmentId: EnvironmentId('unknown-environment'),
      ),
      throwsStateError,
    );
    expect(
      () => store.associateSession(
        sessionId: SessionId('cross-task-session'),
        taskId: taskA.id,
        environmentId: environmentB.id,
      ),
      throwsStateError,
    );
    expect(
      () => store.associateSession(
        sessionId: authority.sessionId,
        taskId: taskB.id,
      ),
      throwsStateError,
    );
  });

  test(
    'stale Environment materialization restores through replacement',
    () async {
      final InMemoryProductStore store = InMemoryProductStore();
      final CapabilityRegistry registry = CapabilityRegistry();
      final _RecordingProvider generationA = _RecordingProvider(
        providerId,
        text: 'generation A',
      );
      final CapabilityRegistration registrationA = registry.register(
        provider: _descriptor(providerId),
        endpoint: _ProviderEndpoint(generationA),
      );
      final ProductLifecycleCoordinator coordinator =
          ProductLifecycleCoordinator(
            store: store,
            registry: registry,
            ids: _FixedIds(),
            providerForBinding: (ProviderBinding binding) =>
                binding.endpointAs<_ProviderEndpoint>().provider,
          );
      final Project project = coordinator.createProject(
        Uri.parse('file:///tmp/source'),
      );
      final TaskCreationResult created = await coordinator.createTask(
        projectId: project.id,
        title: 'Restore Environment',
        providerId: providerId,
      );
      final EnvironmentMaterialization materializationA = coordinator
          .environmentRuntime
          .currentMaterialization(created.environment.id)!;

      expect(generationA.establishCalls, 1);
      expect(generationA.restoreCalls, 0);
      expect(
        await coordinator.environmentRuntime.materialize(
          created.environment.id,
        ),
        same(materializationA),
      );
      expect(generationA.restoreCalls, 0);

      await registrationA.close();
      final _RecordingProvider generationB = _RecordingProvider(
        providerId,
        text: 'generation B',
      );
      final CapabilityRegistration registrationB = registry.register(
        provider: _descriptor(providerId),
        endpoint: _ProviderEndpoint(generationB),
      );
      addTearDown(registrationB.close);

      final EnvironmentMaterialization materializationB = await coordinator
          .environmentRuntime
          .materialize(created.environment.id);

      expect(generationB.restoreCalls, 1);
      expect(materializationB, isNot(same(materializationA)));
      expect(materializationB.provider, same(generationB));
      expect(
        () => materializationA.validateBinding(),
        throwsA(
          isA<ProviderUnavailable>().having(
            (ProviderUnavailable error) => error.stale,
            'stale',
            isTrue,
          ),
        ),
      );
      expect(
        (await materializationB.provider.readFile(
          materializationB.environment.id,
          'source.dart',
        )).text,
        'generation B',
      );
    },
  );

  test(
    'successful restore retains refreshed state if generation retires',
    () async {
      final InMemoryProductStore store = InMemoryProductStore();
      final CapabilityRegistry registry = CapabilityRegistry();
      final _RecordingProvider generationA = _RecordingProvider(
        providerId,
        text: 'generation A',
      );
      final CapabilityRegistration registrationA = registry.register(
        provider: _descriptor(providerId),
        endpoint: _ProviderEndpoint(generationA),
      );
      final ProductLifecycleCoordinator coordinator =
          ProductLifecycleCoordinator(
            store: store,
            registry: registry,
            ids: _FixedIds(),
            providerForBinding: (ProviderBinding binding) =>
                binding.endpointAs<_ProviderEndpoint>().provider,
          );
      final Project project = coordinator.createProject(
        Uri.parse('file:///tmp/source'),
      );
      final TaskCreationResult created = await coordinator.createTask(
        projectId: project.id,
        title: 'Retain restored state',
        providerId: providerId,
      );
      await registrationA.close();
      final _BlockingRestoreProvider generationB = _BlockingRestoreProvider(
        providerId,
      );
      final CapabilityRegistration registrationB = registry.register(
        provider: _descriptor(providerId),
        endpoint: _ProviderEndpoint(generationB),
      );
      final Future<EnvironmentMaterialization> restoring = coordinator
          .environmentRuntime
          .materialize(created.environment.id);
      await generationB.started.future;
      await registrationB.close();
      generationB.complete(const <String, Object?>{
        'restoredBy': 'generation-b',
      });

      await expectLater(
        restoring,
        throwsA(
          isA<ProviderUnavailable>().having(
            (ProviderUnavailable error) => error.stale,
            'stale',
            isTrue,
          ),
        ),
      );
      expect(
        store.environment(created.environment.id)!.providerState,
        const <String, Object?>{'restoredBy': 'generation-b'},
      );

      final _RecordingProvider generationC = _RecordingProvider(
        providerId,
        text: 'generation C',
      );
      final CapabilityRegistration registrationC = registry.register(
        provider: _descriptor(providerId),
        endpoint: _ProviderEndpoint(generationC),
      );
      addTearDown(registrationC.close);
      await coordinator.environmentRuntime.materialize(created.environment.id);

      expect(generationC.restoreCalls, 1);
      expect(generationC.restoredProviderState, const <String, Object?>{
        'restoredBy': 'generation-b',
      });
    },
  );
}

Environment _finalEnvironment({
  required String id,
  required Task task,
  required ProviderId providerId,
}) => Environment(
  id: EnvironmentId(id),
  taskId: task.id,
  role: EnvironmentRole.primary,
  providerId: providerId,
  providerState: const <String, Object?>{'established': true},
);

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

final class _RecordingProvider implements EnvironmentProvider {
  _RecordingProvider(this.providerId, {required this.text});

  @override
  final ProviderId providerId;
  final String text;
  int establishCalls = 0;
  int restoreCalls = 0;
  Map<String, Object?>? restoredProviderState;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async {
    establishCalls++;
    return EnvironmentProviderResult(
      providerState: <String, Object?>{'environmentId': environment.id.value},
    );
  }

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restoreCalls++;
    restoredProviderState = environment.providerState;
    return EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async => EnvironmentTextFile(
    relativePath: relativePath,
    text: text,
    sizeBytes: text.length,
  );

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();
}

final class _BlockingRestoreProvider implements EnvironmentProvider {
  _BlockingRestoreProvider(this.providerId);

  @override
  final ProviderId providerId;
  final Completer<void> started = Completer<void>();
  final Completer<EnvironmentProviderResult> _result =
      Completer<EnvironmentProviderResult>();

  void complete(Map<String, Object?> providerState) {
    _result.complete(EnvironmentProviderResult(providerState: providerState));
  }

  @override
  Future<EnvironmentProviderResult> restore(LocalEnvironment environment) {
    started.complete();
    return _result.future;
  }

  @override
  Future<EnvironmentProviderResult> establish(LocalEnvironment environment) =>
      throw UnimplementedError();

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();
}
