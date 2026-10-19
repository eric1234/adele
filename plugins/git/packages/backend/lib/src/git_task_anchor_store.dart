import 'package:adele_environment/adele_environment.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

import 'git_portable_unstaged_snapshot.dart';

/// Git-owned historical anchors. SQL, not a backend-local cache, retains state.
/// The infrastructure connection must belong to dev.adele.plugin.git.
final class GitTaskAnchorStore {
  GitTaskAnchorStore(this.storage);

  final ProjectStorageService storage;
  static const _access = ProjectStorageAccessMode.durableOrTemporary;
  static const _schema = '''
    CREATE TABLE adele_git_task_anchors (
      environment_id TEXT NOT NULL PRIMARY KEY,
      baseline_commit TEXT NOT NULL,
      expected_branch_ref TEXT NOT NULL,
      FOREIGN KEY (environment_id) REFERENCES adele_product_environments(id)
    )
  ''';

  /// [identity] is observed from the invocation's process grant, not its payload.
  Future<GitTaskComparisonAnchor> read(
    AuthorizedEnvironmentIdentity identity, {
    void Function()? checkActive,
  }) async {
    try {
      checkActive?.call();
      await storage.ensureSchemaForSession(identity.sessionId, [
        _schema,
      ], _access);
      checkActive?.call();
      final rows = await storage.queryForSession(
        identity.sessionId,
        '''SELECT s.id AS session_id, s.task_id AS session_task_id,
          a.environment_id AS selected_environment_id,
          e.id AS environment_id, e.task_id AS environment_task_id,
          g.environment_id AS anchor_environment_id,
          g.baseline_commit, g.expected_branch_ref
        FROM adele_product_sessions s
        LEFT JOIN adele_product_session_environment_authority a ON a.session_id=s.id
        LEFT JOIN adele_product_environments e ON e.id=a.environment_id
        LEFT JOIN adele_git_task_anchors g ON g.environment_id=e.id
        WHERE s.id=:session''',
        {':session': identity.sessionId},
        _access,
      );
      checkActive?.call();
      // Left joins distinguish absent anchor state from broken core association.
      if (rows.length != 1) throw _associationFailure();
      final row = rows.single.values;
      if (row['session_id'] != identity.sessionId ||
          row['selected_environment_id'] != identity.environmentId ||
          row['environment_id'] != identity.environmentId ||
          row['session_task_id'] is! String ||
          (row['session_task_id']! as String).isEmpty ||
          row['session_task_id'] != row['environment_task_id']) {
        throw _associationFailure();
      }
      if (row['anchor_environment_id'] == null) {
        throw _failure(
          'baseline_unavailable',
          'Task changes require a retained comparison baseline.',
        );
      }
      if (row['anchor_environment_id'] != identity.environmentId ||
          row['baseline_commit'] is! String ||
          row['expected_branch_ref'] is! String) {
        throw _corrupt();
      }
      final anchor = GitTaskComparisonAnchor(
        baselineCommit: row['baseline_commit']! as String,
        expectedBranchRef: row['expected_branch_ref']! as String,
      );
      _validateAnchor(anchor);
      return anchor;
    } on ChangeSetFailure {
      rethrow;
    } on Object {
      throw _failure(
        'baseline_storage_failed',
        'The Git baseline could not be read.',
      );
    }
  }

  /// Trusted provisioning only: explicitly known existing Environment and anchor.
  /// Not a Diff service method or an interpreted action. Even identical duplicate
  /// enrollment fails; concurrent writers cannot acknowledge competing anchors.
  Future<void> enrollForEnvironment({
    required String environmentId,
    required GitTaskComparisonAnchor anchor,
  }) async {
    _validateAnchor(anchor);
    try {
      await storage.ensureSchemaForEnvironment(environmentId, [
        _schema,
      ], _access);
      await storage.transactionForEnvironment(environmentId, [
        RelationalStatement(
          sql: '''INSERT INTO adele_git_task_anchors
            (environment_id,baseline_commit,expected_branch_ref)
            SELECT e.id,:baseline,:branch
            FROM adele_product_environments e
            WHERE e.id=:environment''',
          parameters: {
            ':environment': environmentId,
            ':baseline': anchor.baselineCommit,
            ':branch': anchor.expectedBranchRef,
          },
          expectedRows: 1,
        ),
      ], _access);
    } on Object {
      throw _failure(
        'baseline_enrollment_failed',
        'The Git baseline could not be enrolled; existing anchors cannot be replaced.',
      );
    }
  }
}

void _validateAnchor(GitTaskComparisonAnchor anchor) {
  final ref = anchor.expectedBranchRef;
  if (!const {40, 64}.contains(anchor.baselineCommit.length) ||
      RegExp(r'[^0-9a-f]').hasMatch(anchor.baselineCommit) ||
      !ref.startsWith('refs/heads/') ||
      ref.endsWith('.') ||
      ref.contains('..') ||
      ref.contains('@{') ||
      ref.contains(RegExp(r'[\x00-\x20\x7f~^:?*\[\\]')) ||
      ref
          .split('/')
          .any(
            (part) =>
                part.isEmpty || part.startsWith('.') || part.endsWith('.lock'),
          )) {
    throw _corrupt();
  }
}

ChangeSetFailure _associationFailure() => _failure(
  'baseline_association_mismatch',
  'The stored Session and Environment association does not match this invocation.',
);

ChangeSetFailure _corrupt() => _failure(
  'baseline_corrupt',
  'The retained Git comparison anchor is invalid.',
);

ChangeSetFailure _failure(String code, String message) =>
    ChangeSetFailure(code: code, message: message, details: const {});
