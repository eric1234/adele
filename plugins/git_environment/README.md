# Git Worktree Environment

The stock Git Environment backend establishes a Task-specific linked worktree
and normally creates a flat Task-derived branch. It accepts only local `file:`
Project source URIs that resolve to usable Git worktrees. If that source selects
a repository subdirectory, the live Environment remains rooted at the matching
subdirectory in the linked worktree.

## Placement and retained state

Provider-owned Task worktrees live at
`<Project.sourceLocation>/.adele/worktrees/<allocated-name>`, alongside the stock
Local Directory Project's `.adele/data.db`. The selected Project source is resolved
canonically before allocation. This is stock Git provider policy, not a universal
Environment storage path or a dependency on application-private Project storage.
Task/Environment-derived branch and worktree names retain deterministic collision
suffixes; the parent namespace no longer includes an absolute-source-path hash.

For a source such as `repository/selected/project`, the full linked checkout is
under `repository/selected/project/.adele/worktrees/<allocated-name>`. Its live
Environment root is the corresponding `selected/project` directory inside that
checkout, not the checkout root or original Project source.

Provider-state schema **v1** contains exactly these fields, stored opaquely by core:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `1`; other versions are rejected. |
| `environmentId` | Exact retained Environment identity. |
| `sourceRelativePath` | Selected source relative to its Git worktree root, using forward slashes; empty for a repository-root source. |
| `worktreeRelativePath` | Project-source-relative `.adele/worktrees/<allocated-name>`, using forward slashes. |
| `branch` | Exact provider-created Task branch. |
| `baselineCommit` | Exact full commit identity at establishment. |

Absolute paths are not part of provider state or restoration authority.
Development reports can derive current absolute paths separately.
State validation rejects missing/extra fields, incorrect types/versions, mismatched
Environment identity, invalid Git identities, and malformed relative paths.
Storage paths cannot be absolute, traversing, URI-shaped, or backslash-separated.
Existing storage parent components and the worktree root must be direct canonical
directories beneath the selected source; symbolic links are rejected even when
they target another in-source directory. Only establishment creates storage parents.
Neither establishment nor restoration edits `.gitignore` or `.git/info/exclude`;
ignore ergonomics for local operational state remain separate policy work.

## Restoration and moves

Restoration uses the **current** canonical Project source and relative v1 state.
The selected source must still have the exact retained source-relative scope.
Git's `worktree list --porcelain -z` inventory identifies the registration for the
retained exact branch. Healthy registration at the expected path needs no repair.
If that registration points elsewhere, the expected in-Project worktree must
already exist and the old registered path must be absent before it is a relocation
candidate. An existing old path, including a symbolic link, is an explicit conflict:
the provider does not steal/repoint another live checkout or resolve Project copies.

Only a relocation candidate runs `git worktree repair <new-worktree-path>` from the
current source repository context. Before repair, the provider checks the candidate's
Git metadata identity and every other existing linked registration: Git's repair
command can also rewrite their checkout markers. Foreign, aliased, broken, or
ambiguous live registrations therefore fail closed rather than being incidentally
repaired. A stale candidate's bounded, documented checkout `.git` marker can identify
the metadata directory Git would infer; Git commands and inventory validate that
identity. Private `.git/worktrees` registration contents are not parsed.
The provider re-reads the inventory and requires
the retained branch at the expected path. Repair success alone is not authority:
the provider then validates the actual linked worktree, current common Git
directory, exact branch, exact baseline commit, and confined selected source scope
before binding a fresh `WorktreeEnvironment`. Successful restoration returns
canonical relative v1 state, normally unchanged by a move.

A missing worktree fails explicitly. Restore never creates a replacement
Environment, branch, worktree, or collision suffix. Unsupported/failed repair
returns an Environment failure with bounded Git diagnostics. There is no global
Git-version preflight: same-location restoration does not require repair support.
Creation uses ordinary linked worktrees, not `--relative-paths`,
`worktree.useRelativePaths`, or `extensions.relativeWorktrees`. Repair-based
relocation intentionally accommodates commonly shipped LTS Git versions without
requiring Git 2.48+; native relative worktrees may replace it in a later migration.

Provider Git processes retain the ordinary host environment while repository-local
Git routing variables are removed. Each backend generation reconstructs live
objects in its own registry; shutdown terminates active foreground executions and
terminal resources and
clears those objects without removing Git worktrees. Failed establishment publishes
nothing and performs best-effort branch/worktree cleanup only with sufficient
ownership evidence and revalidated confined storage paths.

This supports restoration across fresh runtime generations and whole-Project moves.
Core retains the opaque state with the Task/Environment graph; reopening a Project
loads semantic records without invoking Git restoration. Explicit Environment
materialization restores the live checkout. See the
[product model](../../docs/architecture/product-model.md#environment) for the
core-owned lifecycle boundary.

## Filesystem and processes

The current filesystem surface is bounded UTF-8 `readFile` with opaque
provider-produced revisions, create-new-only `createTextFile`, conditional
replacement and deletion of existing text files using expected revisions, and
bounded deterministic direct-child `readDirectory`. Search and model-tool
semantics are intentionally not provider methods: stock tool plugins compose
lower-level Environment operations. Current text-file reads and mutations
require direct confined paths and reject a symbolic link in either the terminal
file or any parent component. Creation requires the parent directory to exist
and never creates directories implicitly.

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

Create, replace, and delete operations share one mutation serialization tail
within each live Environment. Replacement is staged beside the direct confined
target and rechecked immediately before promotion; POSIX rwx permission bits are
preserved. Creation stages complete bytes and revalidates the direct parent and
target absence. Windows uses its no-replace rename behavior directly; platforms
whose rename replaces a destination first use an exclusive empty-file
reservation. ADELE therefore never intentionally overwrites an existing target,
and coordinated duplicate creates cannot both succeed. Deletion performs
bounded direct-file reads and revision checks twice before unlinking. Dart
exposes neither a portable no-replace promotion nor atomic compare-and-delete,
so an arbitrary external process can still race the final promotion/unlink
windows. These are practical local guarantees, not filesystem transactions or
crash/power-loss durability. A rare failure after a POSIX reservation but before
promotion can leave an empty target: the provider cleans its private staging
directory but does not delete that pathname because Dart cannot prove an
external process has not replaced it.

Directory/move/copy/binary mutation, general create-or-overwrite semantics,
command-specific policy/classification, background task scheduling, persistent
processes, Environment release/destruction, and remote cloning remain absent. The
separate stock Command Tools plugin projects this provider-neutral foreground
surface as model-facing `run_command`; that does not move tool or policy
semantics into this provider.

Path canonicalization, direct-component symlink rejection for file access,
resolved-directory confinement for process cwd, and post-resolution validation
provide application-level confinement equivalent to the historical
DevelopmentSource proof. They are not an operating-system sandbox and cannot
eliminate every pathname replacement race against another local process.

## Interactive terminals

`GitTerminalSupervisor` implements the optional terminal facet of this same
Environment provider. It owns at most 16 admitted terminal resources per backend
generation and 4 per Environment, including startup and pending cleanup. Multiple
terminals remain independent. Generation-local authenticated opaque handles bind
exactly one Environment; idempotent close does not require an unbounded retained
tombstone table. Input/resize require a live resource. Terminal identity is neither
a process ID nor retained provider state.

Listening to `openTerminal` explicitly creates one terminal. The supervisor
resolves the live `WorktreeEnvironment` and its existing process-working-directory
boundary, revalidating after asynchronous preparation. Nested Project source scope
therefore remains the matching directory inside the linked worktree. An executable
and verbatim argv are passed directly; an interactive shell is an explicit request
such as `/bin/bash --noprofile --norc -i`, not implicit command-string parsing.
Child environment uses the foreground allowlist above, with canonical `PWD` and
`TERM=xterm-256color` instead of `dumb`. No shared-host environment/cwd mutation,
arbitrary environment override, credential forwarding, or shell-profile discovery
is added.

The provider-private `GitPtySession` uses the prepared Linux x64 C executable
described in [toolchain preparation](../../docs/development/toolchain.md#git-pty-preparation).
`--pty-helper=<absolute prepared path>` is optional backend startup configuration:
missing/unsupported preparation makes only terminal creation explicitly unavailable.
The backend remains Flutter-free. Fork, controlling-terminal setup, session/signal
changes, native descriptor operations, and reaping occur in the helper, not the
shared AOT host. The helper is not an independently selected Environment provider.

The stream publishes opened evidence before ordered combined PTY text, then real
exit or explicit-closure evidence. UTF-8 decoding is incremental across OS reads;
malformed bytes become replacement characters. ANSI, carriage returns, and line
endings are not normalized. Transport chunks are at most 8192 UTF-16 code units,
without splitting a surrogate pair. Normal nonzero exit is process data, not a
transport error. Infrastructure failure or missing completion evidence never
becomes successful exit.

Generated transport uses one-item credit. Pausing stops supervisor read advancement,
with bounded already-admitted data; the private helper adapter continues draining
its shared data/control pipe into at most 256 KiB of unread output. Crossing that
hard bound explicitly fails and releases that terminal rather than dropping text
or growing a queue. This is bounded failure under sustained backpressure, not an
unlimited lossless transcript. Native messages are at most 16 KiB; input is
acknowledged in order with partial writes handled, and operation deadlines bound
blocked setup/control/cleanup rather than process lifetime. Close is independent
of output credit and never waits for a paused observer to resume.

Cancelling the opening stream abandons and closes the resource. A host hides a
view by retaining its output subscription and emulator, not cancelling/reopening
the backend stream. Startup cancellation and shutdown fence admission, clean late
native resources, and never publish late live authority. Ordinary exit releases
native resources while the host may retain the completed screen. Provider shutdown
joins owned cleanup without deleting the Git worktree.

Graceful cleanup targets the shell and its ordinary foreground job-control group,
including the separate group created by an interactive shell, with TERM/CONT and
KILL escalation and helper-local reaping. A waitable leader pins session identity;
pidfds and revalidated session/group membership avoid signalling a reused process
ID. After leader death, cleanup includes remaining members of that private session,
so an ordinary foreground job is not lost when the kernel forgets the foreground
group. This is not cgroup-strength descendant containment: deliberately detached
or daemonized jobs, arbitrary background jobs, and simultaneous abrupt helper/host
death are not guaranteed.
Host pipe loss allows a surviving helper to perform best-effort cleanup; host access
is revoked and reported disconnected regardless. These limits are separate from
tested ordinary graceful-close behavior and do not constitute an OS sandbox.
Helper cleanup confirmation is separate from the child's exit status, including
child exits 125/126. Failed or unconfirmed cleanup (including forced helper kill)
makes close fail explicitly and conservatively retains its admission slot; ordinary
transport/overflow failure after confirmed cleanup does not. Repeated close keeps
the same result rather than targeting a recycled native identity.

The maintained Git backend target discovers `terminal_resources_test.dart` and
`pty_host_test.dart`. The latter independently compiles the selected native helper
and AOT backend/host, loading through normal `PluginBackendHost.startPlugin`.
The [application integration](../../app/test/environment_terminal_integration_test.dart)
additionally crosses the actual Git backend and generated Environment transport
from the prepared native terminal fixture. Other operating systems and the stock
Terminal frontend/controls remain deferred.
