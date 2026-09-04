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

The current filesystem surface is bounded UTF-8 `readFile` with opaque
provider-produced revisions, conditional replacement of an existing text file
using its expected revision, and bounded deterministic direct-child
`readDirectory`. Search and patch semantics are intentionally not provider
methods: stock tool plugins compose lower-level Environment operations.

Conditional replacements are serialized within each live Environment, staged
beside the resolved confined target, and rechecked immediately before
promotion. POSIX rwx permission bits are preserved during promotion. Other
metadata such as ownership, ACLs, extended attributes, and Windows-specific
attributes is not guaranteed to survive replacement. This mechanism prevents
stale writes among ADELE-coordinated callers and detects practical external
changes, but it does not promise portable atomic compare-and-replace against an
arbitrary external writer or crash/power-loss transactional durability.

New-file creation, deletion, model-facing mutation tools, command execution,
release/destruction, and remote cloning remain absent.

Path canonicalization, symlink checks, and post-read validation provide
application-level confinement equivalent to the historical DevelopmentSource
proof. They are not an operating-system sandbox and cannot eliminate every
pathname replacement race against another local process.
