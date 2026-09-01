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
