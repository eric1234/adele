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

  Project? project(ProjectId id) => _projects[id];

  Task? task(TaskId id) => _tasks[id];

  Environment? environment(EnvironmentId id) => _environments[id];

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
  }) : _registry = registry,
       _ids = ids,
       _providerForBinding = providerForBinding;

  factory ProductLifecycleCoordinator.generated({
    required InMemoryProductStore store,
    required CapabilityRegistry registry,
    ProductIdSource? ids,
  }) => ProductLifecycleCoordinator(
    store: store,
    registry: registry,
    ids: ids ?? MonotonicProductIdSource(),
    providerForBinding: (ProviderBinding binding) =>
        GeneratedEnvironmentProvider(
          providerId: binding.provider.id,
          service: EnvironmentProviderServiceClient(binding.requestChannel),
        ),
  );

  final InMemoryProductStore store;
  final CapabilityRegistry _registry;
  final ProductIdSource _ids;
  final EnvironmentProviderForBinding _providerForBinding;

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
    final ProviderBinding binding = _registry.resolve(
      environmentProviderCapability,
      providerId: providerId,
    );
    final EnvironmentProvider provider = _providerForBinding(binding);
    if (provider.providerId != binding.provider.id) {
      throw StateError('The Environment provider adapter changed identity.');
    }
    final Task task = Task(
      id: _ids.nextTaskId(),
      projectId: project.id,
      title: title,
    );
    final Environment provisional = Environment(
      id: _ids.nextEnvironmentId(),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: binding.provider.id,
      providerState: null,
    );
    final EnvironmentProviderResult established = await provider.establish(
      LocalEnvironment(project: project, task: task, value: provisional),
    );
    final Environment finalized = Environment(
      id: provisional.id,
      taskId: provisional.taskId,
      role: provisional.role,
      providerId: provisional.providerId,
      providerState: established.providerState,
    );
    store.publishTaskWithPrimaryEnvironment(task, finalized);
    return TaskCreationResult(task: task, environment: finalized);
  }
}
