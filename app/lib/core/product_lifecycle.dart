import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

typedef EnvironmentProviderForBinding =
    EnvironmentProvider Function(ProviderBinding binding);

abstract interface class ProductIdSource {
  ProjectId nextProjectId();

  TaskId nextTaskId();

  EnvironmentId nextEnvironmentId();
}

final class MonotonicProductIdSource implements ProductIdSource {
  MonotonicProductIdSource({String? seed})
    : _seed = seed ?? DateTime.now().microsecondsSinceEpoch.toString();

  final String _seed;
  int _nextProject = 1;
  int _nextTask = 1;
  int _nextEnvironment = 1;

  @override
  ProjectId nextProjectId() => ProjectId('project-$_seed-${_nextProject++}');

  @override
  TaskId nextTaskId() => TaskId('task-$_seed-${_nextTask++}');

  @override
  EnvironmentId nextEnvironmentId() =>
      EnvironmentId('environment-$_seed-${_nextEnvironment++}');
}

final class InMemoryProductStore {
  final Map<ProjectId, Project> _projects = <ProjectId, Project>{};
  final Map<TaskId, Task> _tasks = <TaskId, Task>{};
  final Map<EnvironmentId, Environment> _environments =
      <EnvironmentId, Environment>{};
  final Map<SessionId, SessionEnvironmentAuthority> _sessionAuthorities =
      <SessionId, SessionEnvironmentAuthority>{};

  Project? project(ProjectId id) => _projects[id];

  Task? task(TaskId id) => _tasks[id];

  Environment? environment(EnvironmentId id) => _environments[id];

  SessionEnvironmentAuthority? sessionAuthority(SessionId id) =>
      _sessionAuthorities[id];

  Environment? primaryEnvironmentFor(TaskId taskId) {
    for (final Environment environment in _environments.values) {
      if (environment.taskId == taskId &&
          environment.role == EnvironmentRole.primary) {
        return environment;
      }
    }
    return null;
  }

  List<Task> tasksFor(ProjectId projectId) => List<Task>.unmodifiable(
    _tasks.values.where((Task task) => task.projectId == projectId),
  );

  void publishProject(Project project) {
    if (_projects.containsKey(project.id)) {
      throw StateError('Project ${project.id} is already published.');
    }
    _projects[project.id] = project;
  }

  void publishTaskWithPrimaryEnvironment(Task task, Environment environment) {
    if (!_projects.containsKey(task.projectId)) {
      throw StateError('Project ${task.projectId} is not published.');
    }
    if (environment.taskId != task.id ||
        environment.role != EnvironmentRole.primary ||
        environment.providerState == null) {
      throw StateError(
        'A published Task requires its finalized primary Environment.',
      );
    }
    if (_tasks.containsKey(task.id)) {
      throw StateError('Task ${task.id} is already published.');
    }
    if (_environments.containsKey(environment.id)) {
      throw StateError('Environment ${environment.id} is already published.');
    }
    if (primaryEnvironmentFor(task.id) != null) {
      throw StateError('Task ${task.id} already has a primary Environment.');
    }

    _tasks[task.id] = task;
    _environments[environment.id] = environment;
  }

  SessionEnvironmentAuthority associateSession({
    required SessionId sessionId,
    required TaskId taskId,
    EnvironmentId? environmentId,
  }) {
    final Task? task = _tasks[taskId];
    if (task == null) {
      throw StateError('Task $taskId is not published.');
    }
    final Environment? environment = environmentId == null
        ? primaryEnvironmentFor(task.id)
        : _environments[environmentId];
    if (environment == null) {
      throw StateError(
        environmentId == null
            ? 'Task $taskId does not have a primary Environment.'
            : 'Environment $environmentId is not published.',
      );
    }
    if (environment.taskId != task.id) {
      throw StateError(
        'Environment ${environment.id} does not belong to Task ${task.id}.',
      );
    }
    final SessionEnvironmentAuthority authority = SessionEnvironmentAuthority._(
      sessionId: sessionId,
      taskId: task.id,
      environmentId: environment.id,
    );
    final SessionEnvironmentAuthority? existing =
        _sessionAuthorities[sessionId];
    if (existing != null) {
      if (existing.taskId == authority.taskId &&
          existing.environmentId == authority.environmentId) {
        return existing;
      }
      throw StateError(
        'Session $sessionId already has conflicting Environment authority.',
      );
    }
    _sessionAuthorities[sessionId] = authority;
    return authority;
  }

  SessionEnvironmentAuthority requireSessionAuthority(SessionId sessionId) {
    final SessionEnvironmentAuthority? authority =
        _sessionAuthorities[sessionId];
    if (authority == null) {
      throw StateError(
        'Session $sessionId does not have Environment authority.',
      );
    }
    return authority;
  }

  void replaceEnvironment(Environment environment) {
    final Environment? current = _environments[environment.id];
    if (current == null) {
      throw StateError('Environment ${environment.id} is not published.');
    }
    if (environment.taskId != current.taskId ||
        environment.role != current.role ||
        environment.providerId != current.providerId ||
        environment.providerState == null) {
      throw StateError(
        'A restored Environment must preserve its durable authority.',
      );
    }
    _environments[environment.id] = environment;
  }
}

final class SessionEnvironmentAuthority {
  const SessionEnvironmentAuthority._({
    required this.sessionId,
    required this.taskId,
    required this.environmentId,
  });

  final SessionId sessionId;
  final TaskId taskId;
  final EnvironmentId environmentId;
}

final class ResolvedEnvironmentProvider {
  const ResolvedEnvironmentProvider({
    required this.binding,
    required this.provider,
  });

  final ProviderBinding binding;
  final EnvironmentProvider provider;
}

final class EnvironmentMaterialization {
  const EnvironmentMaterialization._({
    required this.environment,
    required this.binding,
    required this.provider,
  });

  final Environment environment;
  final ProviderBinding binding;
  final EnvironmentProvider provider;

  ProviderDescriptor get providerDescriptor => binding.provider;

  void validateBinding() {
    binding.endpointAs<CapabilityEndpoint>();
  }
}

final class EnvironmentRuntime {
  EnvironmentRuntime({
    required this.store,
    required CapabilityRegistry registry,
    required EnvironmentProviderForBinding providerForBinding,
  }) : _registry = registry,
       _providerForBinding = providerForBinding;

  factory EnvironmentRuntime.generated({
    required InMemoryProductStore store,
    required CapabilityRegistry registry,
  }) => EnvironmentRuntime(
    store: store,
    registry: registry,
    providerForBinding: _generatedProviderForBinding,
  );

  final InMemoryProductStore store;
  final CapabilityRegistry _registry;
  final EnvironmentProviderForBinding _providerForBinding;
  final Map<EnvironmentId, EnvironmentMaterialization> _materializations =
      <EnvironmentId, EnvironmentMaterialization>{};
  final Map<EnvironmentId, Future<EnvironmentMaterialization>> _restorations =
      <EnvironmentId, Future<EnvironmentMaterialization>>{};

  EnvironmentMaterialization? currentMaterialization(EnvironmentId id) =>
      _materializations[id];

  ResolvedEnvironmentProvider resolveProvider({ProviderId? providerId}) {
    final ProviderBinding binding = _registry.resolve(
      environmentProviderCapability,
      providerId: providerId,
    );
    final EnvironmentProvider provider = _providerForBinding(binding);
    if (provider.providerId != binding.provider.id) {
      throw StateError('The Environment provider adapter changed identity.');
    }
    return ResolvedEnvironmentProvider(binding: binding, provider: provider);
  }

  void publishEstablishedTask({
    required Task task,
    required Environment environment,
    required ResolvedEnvironmentProvider resolvedProvider,
  }) {
    final EnvironmentMaterialization materialization = _materialization(
      environment,
      resolvedProvider,
    );
    if (_materializations.containsKey(environment.id)) {
      throw StateError(
        'Environment ${environment.id} is already materialized.',
      );
    }
    store.publishTaskWithPrimaryEnvironment(task, environment);
    _materializations[environment.id] = materialization;
  }

  Future<EnvironmentMaterialization> materialize(EnvironmentId id) async {
    final EnvironmentMaterialization? current = _materializations[id];
    if (current != null) {
      try {
        current.validateBinding();
        return current;
      } on ProviderUnavailable catch (error) {
        if (!error.stale) rethrow;
      }
    }
    final Future<EnvironmentMaterialization>? restoring = _restorations[id];
    if (restoring != null) return restoring;
    final Future<EnvironmentMaterialization> started = _restore(id);
    _restorations[id] = started;
    try {
      return await started;
    } finally {
      if (identical(_restorations[id], started)) {
        _restorations.remove(id);
      }
    }
  }

  Future<EnvironmentMaterialization> _restore(EnvironmentId id) async {
    final Environment? durable = store.environment(id);
    if (durable == null) {
      throw StateError('Environment $id is not published.');
    }
    final Task? task = store.task(durable.taskId);
    if (task == null) {
      throw StateError('Task ${durable.taskId} is not published.');
    }
    final Project? project = store.project(task.projectId);
    if (project == null) {
      throw StateError('Project ${task.projectId} is not published.');
    }
    final ResolvedEnvironmentProvider resolved = resolveProvider(
      providerId: durable.providerId,
    );
    final EnvironmentProviderResult result = await resolved.provider.restore(
      LocalEnvironment(project: project, task: task, value: durable),
    );
    final Environment restored = Environment(
      id: durable.id,
      taskId: durable.taskId,
      role: durable.role,
      providerId: durable.providerId,
      providerState: result.providerState,
    );
    final EnvironmentMaterialization materialization = _materialization(
      restored,
      resolved,
    );
    store.replaceEnvironment(restored);
    _materializations[id] = materialization;
    materialization.validateBinding();
    return materialization;
  }

  EnvironmentMaterialization _materialization(
    Environment environment,
    ResolvedEnvironmentProvider resolved,
  ) {
    if (environment.providerState == null) {
      throw StateError('A materialized Environment requires provider state.');
    }
    if (environment.providerId != resolved.binding.provider.id ||
        environment.providerId != resolved.provider.providerId) {
      throw StateError(
        'Environment ${environment.id} targets another provider.',
      );
    }
    final EnvironmentMaterialization materialization =
        EnvironmentMaterialization._(
          environment: environment,
          binding: resolved.binding,
          provider: resolved.provider,
        );
    return materialization;
  }
}

final class TaskCreationResult {
  const TaskCreationResult({required this.task, required this.environment});

  final Task task;
  final Environment environment;
}

final class ProductLifecycleCoordinator {
  ProductLifecycleCoordinator({
    required this.store,
    required CapabilityRegistry registry,
    required ProductIdSource ids,
    required EnvironmentProviderForBinding providerForBinding,
  }) : environmentRuntime = EnvironmentRuntime(
         store: store,
         registry: registry,
         providerForBinding: providerForBinding,
       ),
       _ids = ids;

  factory ProductLifecycleCoordinator.generated({
    required InMemoryProductStore store,
    required CapabilityRegistry registry,
    ProductIdSource? ids,
  }) => ProductLifecycleCoordinator(
    store: store,
    registry: registry,
    ids: ids ?? MonotonicProductIdSource(),
    providerForBinding: _generatedProviderForBinding,
  );

  final InMemoryProductStore store;
  final EnvironmentRuntime environmentRuntime;
  final ProductIdSource _ids;

  Project createProject(Uri sourceLocation) {
    final Project project = Project(
      id: _ids.nextProjectId(),
      sourceLocation: sourceLocation,
    );
    store.publishProject(project);
    return project;
  }

  Future<TaskCreationResult> createTask({
    required ProjectId projectId,
    required String title,
    ProviderId? providerId,
  }) async {
    final Project? project = store.project(projectId);
    if (project == null) {
      throw StateError('Project $projectId is not published.');
    }
    final ResolvedEnvironmentProvider resolved = environmentRuntime
        .resolveProvider(providerId: providerId);
    final Task task = Task(
      id: _ids.nextTaskId(),
      projectId: project.id,
      title: title,
    );
    final Environment provisional = Environment(
      id: _ids.nextEnvironmentId(),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: resolved.binding.provider.id,
      providerState: null,
    );
    final EnvironmentProviderResult established = await resolved.provider
        .establish(
          LocalEnvironment(project: project, task: task, value: provisional),
        );
    final Environment finalized = Environment(
      id: provisional.id,
      taskId: provisional.taskId,
      role: provisional.role,
      providerId: provisional.providerId,
      providerState: established.providerState,
    );
    environmentRuntime.publishEstablishedTask(
      task: task,
      environment: finalized,
      resolvedProvider: resolved,
    );
    return TaskCreationResult(task: task, environment: finalized);
  }
}

EnvironmentProvider _generatedProviderForBinding(ProviderBinding binding) =>
    GeneratedEnvironmentProvider(
      providerId: binding.provider.id,
      service: EnvironmentProviderServiceClient(binding.requestChannel),
    );
