# Git Worktree Environment

The stock Git Environment backend establishes a Task-specific linked worktree
and normally creates a flat Task-derived branch. It accepts only local `file:`
Project source URIs that resolve to usable Git worktrees. If that source selects
a repository subdirectory, the live Environment remains rooted at the matching
subdirectory in the linked worktree.

Provider state is versioned and retains the canonical selected source,
repository/common-Git paths, source-relative prefix, worktree path, branch, and
baseline commit needed for validation and restore. Core stores that map
opaquely. Provider Git processes retain the ordinary host environment while
repository-local Git routing variables are removed. Each backend generation
reconstructs `WorktreeEnvironment` objects in its own generic live-object
registry; shutting down a generation clears those objects but does not remove
durable Git worktrees.

The current filesystem surface is strict UTF-8 bounded `readFile` plus a
bounded deterministic direct-child `readDirectory`. Search is intentionally
not a provider method: Search Tools currently composes these operations and may
later use generic Environment process execution. Mutation, command execution,
release/destruction, and remote cloning are absent.

Path canonicalization, symlink checks, and post-read validation provide
application-level confinement equivalent to the maintained DevelopmentSource
proof. They are not an operating-system sandbox and cannot eliminate every
pathname replacement race against another local process.
