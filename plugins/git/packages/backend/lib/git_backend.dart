/// Stock Git backend with Worktree Environments and change snapshots.
library;

export 'package:adele_environment/adele_environment.dart'
    show EnvironmentProviderServiceDispatcher;
export 'src/git_change_set_source.dart' show GitChangeSetSourceService;
export 'src/git_persisted_change_set_source.dart';
export 'src/git_portable_unstaged_snapshot.dart';
export 'src/git_task_anchor_store.dart';
export 'src/git_worktree_environment_provider.dart';
export 'src/ids.dart';
export 'src/worktree_environment.dart';
