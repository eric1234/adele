import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';

/// Canonical lifecycle for execution fixtures that do not access an Environment.
final class ChatTestTopology {
  ChatTestTopology(SessionId sessionId) {
    final ExtensionRegistry extensions = ExtensionRegistry();
    _activation = chat.activate(extensions);
    final InMemoryProductStore store = InMemoryProductStore();
    lifecycle = ProductLifecycleCoordinator.generated(
      store: store,
      registry: CapabilityRegistry(),
      extensions: extensions,
      ids: _Ids(sessionId),
    );
    final Project project = lifecycle.createProject(
      Uri.parse('file:///fixture'),
    );
    final Task task = Task(
      id: TaskId('task-${sessionId.value}'),
      projectId: project.id,
      title: 'Chat execution fixture',
    );
    store.publishTaskWithPrimaryEnvironment(
      task,
      Environment(
        id: EnvironmentId('environment-${sessionId.value}'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('dev.adele.environment.fixture'),
        providerState: const <String, Object?>{},
      ),
    );
    session = lifecycle.createSession(
      taskId: task.id,
      strategyId: chatStrategyId,
    );
  }

  final ChatStrategyPlugin chat = ChatStrategyPlugin();
  late final ProductLifecycleCoordinator lifecycle;
  late final Session session;
  late final ExtensionRegistration _activation;

  Future<void> close() => _activation.close();
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
