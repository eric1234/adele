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
registry; shutting down a generation first terminates active foreground
executions and then clears those objects, but does not remove durable Git
worktrees.

The current filesystem surface is bounded UTF-8 `readFile` with opaque
provider-produced revisions, conditional replacement of an existing text file
using its expected revision, and bounded deterministic direct-child
`readDirectory`. Search and patch semantics are intentionally not provider
methods: stock tool plugins compose lower-level Environment operations. Current
text-file reads and replacements require direct confined paths and reject a
symbolic link in either the terminal file or any parent component.

On Linux x64, the provider also implements the Environment foreground-process
stream with direct `program` plus `arguments` execution, no implicit shell,
required timeouts from 1 through 600 seconds, and a resolved cwd confined to the
Environment root. A cwd may use an in-Environment directory symlink when its
resolved target remains confined. stdout and stderr are incrementally decoded
as UTF-8 with malformed sequences replaced and are emitted as separately tagged
text chunks. Each stream retains/emits at most 1 MiB using an immediate head and
a bounded tail; discarded middle output is still drained, and independent
truncation flags accompany completion.

Foreground execution uses the trusted system `setsid` supplied by util-linux.
The provider owns the resulting process group and uses SIGTERM followed by a
short SIGKILL escalation for timeout, stream cancellation, normal leader exit,
and provider shutdown. This prevents ordinary descendants from accidentally
outliving the invocation. A deliberately daemonizing process can escape an
ordinary process group, so this is practical lifetime ownership rather than an
OS sandbox or cgroup/pidfd-strength containment.

The provider rejects missing and non-executable programs before spawn. The
stock Dart process API confirms the internal `setsid` launch rather than the
subsequent `exec` handoff, so a rare post-check handoff failure (for example a
concurrent executable replacement) can surface as launcher exit 126/127. ADELE
does not reinterpret all 126/127 results because those are also valid program
exit codes.

Environment child processes use `includeParentEnvironment: false`. The current
allowlist retains `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `LANGUAGE`,
`TZ`, temporary-directory variables, selected `XDG_*` directory variables, and
all `LC_*` variables. The provider sets canonical `PWD` and `TERM=dumb`. Other
variables, including every inherited `ADELE_*`, `OPENAI_API_KEY`, `GIT_*`, and
`SSH_AUTH_SOCK`, are omitted. This reduces accidental backend credential and
Git-routing leakage, but same-user filesystem, process, credential-helper, and
network access remain outside this hygiene boundary.

Conditional replacements are serialized within each live Environment, staged
beside the direct confined target, and rechecked immediately before
promotion. POSIX rwx permission bits are preserved during promotion. Other
metadata such as ownership, ACLs, extended attributes, and Windows-specific
attributes is not guaranteed to survive replacement. This mechanism prevents
stale writes among ADELE-coordinated callers and detects practical external
changes, but it does not promise portable atomic compare-and-replace against an
arbitrary external writer or crash/power-loss transactional durability.

New-file creation, deletion, command-specific policy/classification, background
or persistent processes, stdin/PTY support, release/destruction, and remote
cloning remain absent. The separate stock Command Tools plugin now projects this
provider-neutral foreground surface as model-facing `run_command`; that does not
move tool or policy semantics into this provider.

Path canonicalization, direct-component symlink rejection for file access,
resolved-directory confinement for process cwd, and post-resolution validation
provide application-level confinement equivalent to the historical
DevelopmentSource proof. They are not an operating-system sandbox and cannot
eliminate every pathname replacement race against another local process.
