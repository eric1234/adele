/// Current Git-owned v1 schema, shared by establishment and published reads.
const gitTaskAnchorSchema = '''
    CREATE TABLE adele_git_task_anchors (
      environment_id TEXT NOT NULL PRIMARY KEY,
      baseline_commit TEXT NOT NULL,
      expected_branch_ref TEXT NOT NULL,
      FOREIGN KEY (environment_id) REFERENCES adele_product_environments(id)
    )
  ''';
