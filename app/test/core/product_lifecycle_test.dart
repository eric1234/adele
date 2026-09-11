import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
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
      extensions: ExtensionRegistry(),
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
      extensions: ExtensionRegistry(),
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
            extensions: ExtensionRegistry(),
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
            extensions: ExtensionRegistry(),
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

  group('canonical Session lifecycle', () {
    final OrchestrationStrategyId strategyId = OrchestrationStrategyId(
      'dev.adele.strategy.fixture',
    );
    final OrchestrationStrategyId otherStrategyId = OrchestrationStrategyId(
      'dev.adele.strategy.other',
    );
    final ExtensionId extensionId = ExtensionId('dev.adele.fixture.strategy');
    late InMemoryProductStore store;
    late ExtensionRegistry extensions;
    late ProductLifecycleCoordinator coordinator;
    late ExtensionRegistration registration;
    late Task taskA;
    late Task taskB;
    late Environment environmentA;
    late Environment environmentB;

    setUp(() {
      store = InMemoryProductStore();
      extensions = ExtensionRegistry();
      registration = extensions.register(
        point: orchestrationStrategyContributions,
        id: extensionId,
        value: OrchestrationStrategyContribution(strategyId: strategyId),
      );
      addTearDown(registration.close);
      coordinator = ProductLifecycleCoordinator.generated(
        store: store,
        registry: CapabilityRegistry(),
        extensions: extensions,
        ids: MonotonicProductIdSource(seed: 'test'),
      );
      final Project project = coordinator.createProject(
        Uri.parse('file:///tmp/source'),
      );
      taskA = Task(
        id: TaskId('task-a'),
        projectId: project.id,
        title: 'Task A',
      );
      taskB = Task(
        id: TaskId('task-b'),
        projectId: project.id,
        title: 'Task B',
      );
      environmentA = _finalEnvironment(
        id: 'environment-a',
        task: taskA,
        providerId: providerId,
      );
      environmentB = _finalEnvironment(
        id: 'environment-b',
        task: taskB,
        providerId: providerId,
      );
      store.publishTaskWithPrimaryEnvironment(taskA, environmentA);
      store.publishTaskWithPrimaryEnvironment(taskB, environmentB);
    });

    test(
      'publishes strategy-bound Session with primary or explicit authority',
      () {
        final Session session = coordinator.createSession(
          taskId: taskA.id,
          strategyId: strategyId,
        );
        final SessionEnvironmentAuthority authority = store
            .requireSessionAuthority(session.id);
        expect(session.id, SessionId('session-test-1'));
        expect(store.session(session.id), same(session));
        expect(session.taskId, taskA.id);
        expect(session.strategyId, strategyId);
        expect(authority.sessionId, session.id);
        expect(authority.taskId, session.taskId);
        expect(authority.environmentId, environmentA.id);
        expect(store.sessionAuthority(session.id), same(authority));
        expect(
          store.environment(authority.environmentId)!.taskId,
          session.taskId,
        );

        final Session explicit = coordinator.createSession(
          taskId: taskB.id,
          strategyId: strategyId,
          environmentId: environmentB.id,
        );
        expect(explicit.id, SessionId('session-test-2'));
        expect(
          store.requireSessionAuthority(explicit.id).environmentId,
          environmentB.id,
        );
        expect(
          store.requireSessionAuthority(explicit.id).taskId,
          explicit.taskId,
        );
      },
    );

    test(
      'invalid Task or Environment publishes neither Session nor authority',
      () {
        for (final ({TaskId taskId, EnvironmentId? environmentId}) request in [
          (taskId: TaskId('unknown-task'), environmentId: null),
          (
            taskId: taskA.id,
            environmentId: EnvironmentId('unknown-environment'),
          ),
          (taskId: taskA.id, environmentId: environmentB.id),
        ]) {
          expect(
            () => coordinator.createSession(
              taskId: request.taskId,
              strategyId: strategyId,
              environmentId: request.environmentId,
            ),
            throwsStateError,
          );
          expect(store.session(SessionId('session-test-1')), isNull);
          expect(store.sessionAuthority(SessionId('session-test-1')), isNull);
        }
        expect(
          () => store.requireSessionAuthority(SessionId('session-test-1')),
          throwsStateError,
        );
        expect(
          () => coordinator.resolveSessionStrategy(SessionId('session-test-1')),
          throwsStateError,
        );
        expect(
          coordinator
              .createSession(taskId: taskA.id, strategyId: strategyId)
              .id,
          SessionId('session-test-1'),
        );
      },
    );

    test(
      'unavailable or ambiguous strategy cannot publish a Session',
      () async {
        expect(
          () => coordinator.createSession(
            taskId: taskA.id,
            strategyId: otherStrategyId,
          ),
          throwsA(isA<OrchestrationStrategyUnavailable>()),
        );
        final ExtensionRegistration duplicate = extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.adele.fixture.duplicate'),
          value: OrchestrationStrategyContribution(strategyId: strategyId),
        );
        expect(
          () => coordinator.createSession(
            taskId: taskA.id,
            strategyId: strategyId,
          ),
          throwsA(isA<AmbiguousOrchestrationStrategy>()),
        );
        await duplicate.close();
        await registration.close();
        expect(
          () => coordinator.createSession(
            taskId: taskA.id,
            strategyId: strategyId,
          ),
          throwsA(isA<OrchestrationStrategyUnavailable>()),
        );
        expect(store.session(SessionId('session-test-1')), isNull);
        expect(store.sessionAuthority(SessionId('session-test-1')), isNull);
      },
    );

    test(
      'another strategy requires another Session; identity cannot be overwritten',
      () {
        final ExtensionRegistration other = extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.adele.fixture.other'),
          value: OrchestrationStrategyContribution(strategyId: otherStrategyId),
        );
        addTearDown(other.close);
        final Session original = coordinator.createSession(
          taskId: taskA.id,
          strategyId: strategyId,
        );
        final Session changed = coordinator.createSession(
          taskId: taskA.id,
          strategyId: otherStrategyId,
        );
        expect(changed.id, isNot(original.id));
        expect(changed.strategyId, otherStrategyId);
        expect(store.session(original.id)!.strategyId, strategyId);

        final ProductLifecycleCoordinator fixedIds =
            ProductLifecycleCoordinator.generated(
              store: store,
              registry: CapabilityRegistry(),
              extensions: extensions,
              ids: _FixedIds(),
            );
        final Session fixed = fixedIds.createSession(
          taskId: taskA.id,
          strategyId: strategyId,
        );
        final SessionEnvironmentAuthority authority = store
            .requireSessionAuthority(fixed.id);
        expect(
          () => fixedIds.createSession(
            taskId: taskB.id,
            strategyId: otherStrategyId,
          ),
          throwsStateError,
        );
        expect(store.session(fixed.id), same(fixed));
        expect(store.session(fixed.id)!.strategyId, strategyId);
        expect(store.requireSessionAuthority(fixed.id), same(authority));
      },
    );

    test(
      'stored identity survives retirement; old resolution never migrates',
      () async {
        final Session session = coordinator.createSession(
          taskId: taskA.id,
          strategyId: strategyId,
        );
        final ResolvedOrchestrationStrategy old = coordinator
            .resolveSessionStrategy(session.id);
        final OrchestrationStrategyContribution original = old.contribution;
        await registration.close();
        expect(old.validateBinding, throwsA(isA<StaleExtensionBinding>()));
        expect(
          () => coordinator.resolveSessionStrategy(session.id),
          throwsA(isA<OrchestrationStrategyUnavailable>()),
        );
        expect(store.session(session.id), same(session));
        expect(store.session(session.id)!.strategyId, strategyId);
        expect(
          store.requireSessionAuthority(session.id).environmentId,
          environmentA.id,
        );

        final OrchestrationStrategyContribution replacement =
            OrchestrationStrategyContribution(strategyId: strategyId);
        final ExtensionRegistration next = extensions.register(
          point: orchestrationStrategyContributions,
          id: extensionId,
          value: replacement,
        );
        addTearDown(next.close);
        final ResolvedOrchestrationStrategy fresh = coordinator
            .resolveSessionStrategy(session.id);
        expect(fresh.contribution, same(replacement));
        expect(fresh.contribution, isNot(same(original)));
        expect(fresh.binding.id, old.binding.id);
        fresh.validateBinding();
        expect(old.validateBinding, throwsA(isA<StaleExtensionBinding>()));
        expect(() => old.contribution, throwsA(isA<StaleExtensionBinding>()));
        expect(store.session(session.id), same(session));
      },
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
            extensions: ExtensionRegistry(),
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
            extensions: ExtensionRegistry(),
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

  @override
  SessionId nextSessionId() => SessionId('session-1');
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
    revision: 'fixture-revision',
  );

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
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
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
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => throw UnimplementedError();
}
