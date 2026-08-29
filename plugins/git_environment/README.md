# Git Worktree Environment

The stock Git Environment backend establishes a Task-specific linked worktree
and normally creates a Task-derived branch. It accepts only local `file:`
Project source URIs that resolve to usable Git worktrees.

Provider state is versioned and retains the canonical source/common-Git paths,
worktree path, branch, and baseline commit needed for validation and restore.
Core stores that map opaquely. Each backend generation reconstructs
`WorktreeEnvironment` objects in its own generic live-object registry; shutting
down a generation clears those objects but does not remove durable Git
worktrees.

The current filesystem surface is strict UTF-8 bounded `readFile` plus a
bounded deterministic direct-child `readDirectory`. Mutation, search, command
execution, release/destruction, and remote cloning are intentionally absent.

Path canonicalization, symlink checks, and post-read validation provide
application-level confinement equivalent to the maintained DevelopmentSource
proof. They are not an operating-system sandbox and cannot eliminate every
pathname replacement race against another local process.
