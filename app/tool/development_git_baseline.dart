import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_product/adele_product.dart';

/// Passive stock Git diagnostics over the current Project's existing backing.
/// This never prepares storage/schema, enrolls an anchor, or observes Git HEAD.
String developmentGitBaselineCommit(
  ProductLifecycleCoordinator lifecycle,
  Environment environment, {
  required String branch,
  Session? session,
}) {
  final store = lifecycle.store;
  final task = store.task(environment.taskId);
  final project = task == null ? null : store.project(task.projectId);
  if (!identical(store.environment(environment.id), environment) ||
      task == null ||
      project == null) {
    throw ArgumentError(
      'Git diagnostics require a canonical Environment graph.',
    );
  }
  if (session != null) {
    final authority = store.sessionAuthority(session.id);
    if (!identical(store.session(session.id), session) ||
        session.taskId != task.id ||
        authority == null ||
        authority.sessionId != session.id ||
        authority.taskId != task.id ||
        authority.environmentId != environment.id) {
      throw ArgumentError(
        'Git diagnostics require the exact Session Environment.',
      );
    }
  }
  final database = lifecycle.existingDatabaseForProject(project);
  if (database == null) throw StateError('No existing Project backing.');
  final versions = database.queryPluginRows(
    'SELECT version FROM adele_schema_versions WHERE owner_id=:owner',
    {':owner': 'dev.adele.plugin.git'},
  );
  if (versions.length != 1 || versions.single.values['version'] != 1) {
    throw StateError('No supported retained Git anchor schema.');
  }
  final rows = database.queryPluginRows(
    '''SELECT g.baseline_commit, g.expected_branch_ref
       FROM adele_git_task_anchors g
       JOIN adele_product_environments e ON e.id=g.environment_id
       JOIN adele_product_tasks t ON t.id=e.task_id
       JOIN adele_product_projects p ON p.id=t.project_id
       WHERE e.id=:environment AND e.task_id=:task AND p.id=:project
       ${session == null ? '' : '''AND EXISTS (
         SELECT 1 FROM adele_product_sessions s
         JOIN adele_product_session_environment_authority a ON a.session_id=s.id
         WHERE s.id=:session AND s.task_id=e.task_id AND a.environment_id=e.id
       )'''}''',
    {
      ':environment': environment.id.value,
      ':task': task.id.value,
      ':project': project.id.value,
      if (session != null) ':session': session.id.value,
    },
  );
  if (rows.length != 1) throw StateError('No exact retained Git anchor.');
  final row = rows.single.values;
  final baseline = row['baseline_commit'];
  if (baseline is! String ||
      !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(baseline) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(baseline) ||
      row['expected_branch_ref'] != 'refs/heads/$branch') {
    throw StateError('Invalid retained Git anchor.');
  }
  return baseline;
}
