import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  final Project project = Project(
    id: ProjectId('project-1'),
    sourceLocation: Uri.parse('file:///tmp/source'),
  );
  final Task task = Task(
    id: TaskId('task-1'),
    projectId: project.id,
    title: 'Implement the environment spine',
  );
  final ProviderId providerId = ProviderId(
    'dev.adele.environment.git-worktree',
  );

  test('Project represents its source as a file URI', () {
    expect(project.sourceLocation.scheme, 'file');
    expect(project.sourceLocation.path, '/tmp/source');
  });

  test('Task and Environment store each relationship once', () {
    final Environment environment = Environment(
      id: EnvironmentId('environment-1'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: providerId,
      providerState: null,
    );

    expect(task.projectId, project.id);
    expect(environment.taskId, task.id);
    expect(environment.role, EnvironmentRole.primary);
  });

  test('Session identity is canonical without defining Session lifecycle', () {
    final SessionId first = SessionId('session-1');
    final SessionId same = SessionId('session-1');

    expect(first, same);
    expect(first.value, 'session-1');
    expect(() => SessionId(' session-1'), throwsFormatException);
  });

  test('strategy identity has typed value equality and matching hashes', () {
    final OrchestrationStrategyId first = OrchestrationStrategyId('strategy-1');
    final OrchestrationStrategyId same = OrchestrationStrategyId('strategy-1');
    final OrchestrationStrategyId other = OrchestrationStrategyId('strategy-2');

    expect(first, first);
    expect(first, same);
    expect(same, first);
    expect(first.hashCode, same.hashCode);
    expect(<OrchestrationStrategyId>{first, same, other}, hasLength(2));
    expect(first, isNot(other));
    expect(first, isNot(SessionId('strategy-1')));
    expect(first, isNot('strategy-1'));
    expect(first.value, 'strategy-1');
    expect(first.toString(), 'strategy-1');
  });

  test(
    'strategy identity follows product ID validation without normalizing',
    () {
      for (final String value in <String>[
        '',
        ' ',
        '\t\n',
        ' strategy-1',
        'strategy-1 ',
        '\tstrategy-1',
        'strategy-1\n',
      ]) {
        expect(() => OrchestrationStrategyId(value), throwsFormatException);
      }

      expect(OrchestrationStrategyId('strategy 1').value, 'strategy 1');
      expect(
        OrchestrationStrategyId('Strategy-1'),
        isNot(OrchestrationStrategyId('strategy-1')),
      );
    },
  );

  test('Session retains only its identity, Task, and semantic strategy', () {
    final SessionId id = SessionId('session-1');
    final OrchestrationStrategyId strategyId = OrchestrationStrategyId(
      'strategy-1',
    );
    final Session session = Session(
      id: id,
      taskId: task.id,
      strategyId: strategyId,
    );

    expect(session.id, same(id));
    expect(session.taskId, same(task.id));
    expect(session.strategyId, same(strategyId));
  });

  test('provisional Environment has absent provider state', () {
    final Environment provisional = Environment(
      id: EnvironmentId('environment-1'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: providerId,
      providerState: null,
    );

    expect(provisional.providerState, isNull);
  });

  test('final Environment snapshots opaque provider state', () {
    final List<Object?> retained = <Object?>['baseline'];
    final Map<String, Object?> supplied = <String, Object?>{
      'schemaVersion': 1,
      'retained': retained,
    };
    final Environment provisional = Environment(
      id: EnvironmentId('environment-1'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: providerId,
      providerState: null,
    );
    final Environment finalized = Environment(
      id: provisional.id,
      taskId: provisional.taskId,
      role: provisional.role,
      providerId: provisional.providerId,
      providerState: supplied,
    );

    retained.add('provider mutation');
    supplied['schemaVersion'] = 2;

    expect(finalized.providerId, providerId);
    expect(finalized.providerState, <String, Object?>{
      'schemaVersion': 1,
      'retained': <Object?>['baseline'],
    });
    expect(
      () => finalized.providerState!['schemaVersion'] = 3,
      throwsUnsupportedError,
    );
    expect(
      () => (finalized.providerState!['retained']! as List<Object?>).add('x'),
      throwsUnsupportedError,
    );
    expect(provisional.providerState, isNull);
  });
}
