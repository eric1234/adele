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

## Unstaged change snapshots

The same stock AOT backend advertises the Diff-owned
`adele.diff.change-set-source` v1 Capability through
`diff_viewer_contract`'s zero-argument `ChangeSetSourceService.snapshotUnstaged`.
Its separate `dev.adele.git.change-set-source` provider is explicitly associated
with this generation's actual Git Environment provider. The contextual dispatcher
uses `AuthorizedEnvironmentReadService.authority()` to select only an existing
live `WorktreeEnvironment`; it never accepts caller-selected Environment IDs,
repository paths, or a fallback to the Task's primary Environment. Ordinary
context-free calls are rejected. The host read grant is revalidated before success.
Establish/restore also bind the canonical Git directory and actual worktree root to
that live object. Inspection supplies both explicitly to Git, so a newly created
nested `.git` or `core.worktree` setting cannot substitute another repository.

`git ls-files --cached --stage --debug -z` supplies the bounded index inventory,
not HEAD; `git ls-files --others --exclude-standard -z` adds nonignored untracked
files. Direct bounded reads are hashed as Git blobs (SHA-1 or SHA-256 according to
the index identity), omitting byte-equal tracked files without Git subprocesses
per clean file. Staged-only ordinary files are absent. Both commands are scoped
to the live root,
including a nested Project source. Returned paths are Environment-relative,
strictly decoded UTF-8, and sorted; NUL framing preserves spaces, punctuation,
tabs, and newlines without treating filenames as pathspec expressions. Renames
are represented as deletion/addition, not similarity detection.
The stage/debug parser preserves intent-to-add, including empty additions, and
rejects unexpected metadata layouts. Sparse/skip-worktree and assume-unchanged
index entries have explicit unsupported state, not fabricated deletions or clean
claims. The inventory adds every gitlink as an explicitly
unsupported entry with unknown change state, even when its submodule is clean.
Git is never asked to recurse into child repositories with independent executable
filters/hooks, and an uninspected submodule is never silently presented as clean.
Untracked nested repository directory markers are normalized to relative paths
and retained as unsupported entries; their contents are not recursively inspected.

Text patches are actual deterministic Git unified hunks over bounded index-blob
and direct working-file snapshots. A private temporary directory outside the
worktree supplies `git diff --no-index` with fixed literal filenames; Git does not
run repository clean filters, textconv, external diff, or attribute-selected diff
drivers to obtain those hunks. Neither `diff-files` nor `ls-files --modified` is
used: both can execute clean filters while checking stat-racy files, even without
requesting patches. Cached-only enumeration avoids that execution path, including
when another process adds a new filter after the snapshot has begun.
Custom conversion/diff attributes and effective `core.autocrlf`/`core.eol`
conversion are unsupported placeholders, and `-diff` attributes are binary
placeholders. Binary data, invalid
UTF-8, symbolic links, submodules, unmerged entries, type/mode changes, and oversized
files likewise have explicit status/detail and no fabricated text hunks. Equal
raw content, including binary/invalid UTF-8 with stale index stat metadata, is
omitted before content classification. Newline absence is
retained on the corresponding hunk line; line text otherwise preserves CR and LF
semantics rather than normalizing file content. Effective `core.filemode=false`
suppresses executable-bit-only differences; repository settings override lower
configuration scopes. Git executable state uses only the owner-execute bit.

The snapshot subprocess path is separate from Environment foreground execution.
`git_process_environment.dart` shares the existing placement isolation boundary,
with an explicitly stricter read-only inspection policy rather than changing the
placement/repair environment.
It starts Git directly with argument lists and `includeParentEnvironment: false`,
retains absolute PATH entries and normal HOME/XDG configuration discovery (plus
Windows profile/SystemRoot/TEMP/TMP), and rejects an empty filtered search path
rather than executing a worktree-local `git`. Source inspection preserves effective
repository/global ignore and conversion settings; private patch generation alone
disables system/global configuration and attributes. Inherited Git routing,
fsmonitor, external diff/textconv, optional index locks, replacement objects, and
lazy fetch where supported by Git are disabled. This feature never refreshes or
writes the index, edits Git configuration,
or writes the source worktree; only its temporary snapshot copies are written and
removed. Git executable selection through PATH is trusted, not sandboxed.

Default per-operation limits are 4,096 retained tracked/untracked inventory entries
(index records are also bounded), 256 returned files,
1 MiB per file side, 2 MiB collected stdout per command/patch, 64 KiB stderr counted
without retaining diagnostics,
8 MiB total text inputs plus patches, 8,192 hunk lines, and a conservative 6 MiB
escaped-text/DTO transport budget below the host frame limit. Each Git process has
a 10-second deadline including pipe completion; the entire operation has a
30-second deadline. Output is bounded during collection, not after an unbounded
`Process.run`. Per-file size/patch excess is an oversized placeholder; enumeration,
file-count, aggregate, process, and malformed-output failures reject the whole
snapshot rather than returning a deceptively complete truncated result. An
oversized tracked working file has explicitly unknown change state because its
bytes cannot be compared within the bound, even if an external observer knows it
is unchanged. Equal inspected files do not consume the changed-result byte budget.

Line-ending configuration, enumeration and direct-path/stat observations are checked
again before publication. Inspected tracked symlinks, including clean ones omitted
from the result, are rechecked for direct-path safety, link type, and target text;
their referenced files are never opened.
Detected concurrent changes fail explicitly, but these checks are not an atomic
filesystem/index transaction or an OS sandbox: another same-user process can race
path or configuration replacement, preserve timestamps, or change and restore state
between checks.
Private copies freeze the compared bytes, not the entire repository at one instant.
Process termination kills the directly started Git process; deliberately detached
children of a substituted Git executable are not contained. Linux is the validated
platform for this snapshot path; other platforms remain unvalidated.

Focused tests live in `packages/backend/test/git_change_set_source_test.dart`.
`backend_host_integration_test.dart` additionally compiles the actual shared host
and stock Git AOT, checks both ready advertisements and their exact association,
and exercises generated contextual requests for independent live Environments.
The existing `git_environment_backend` maintained target discovers both files.

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
partial text chunks without waiting for newlines or process exit. ANSI sequences,
carriage returns, NUL, and line endings remain intact. Messages carry at most
16384 UTF-16 code units without splitting a surrogate pair. Per-pipe order and
the provider-observed combined read order are preserved; this is not a claim of
recovering a total order between independent OS pipes. There is no transcript
head/tail limit or replayed tail.

Generated transport uses one-item credit across the Git backend to host and the
authorized process service to Command backend. Pausing the consumer stops both
real pipe subscriptions; an admitted read is split only as demand resumes. The
provider's queue owns at most 8 Mi UTF-16 code units of decoded strings across
both pipes. Each complete string remains charged until its queue entry is
removed, including already-emitted prefixes; advancing its offset does not free
the retained string or admission budget. It pauses reads while draining queued
text, yields between messages, and gives the other pipe first opportunity on
resume, without repeatedly copying the remaining suffix.

This is a queue bound, not a total heap or RSS bound. The pinned Dart runtime can
aggregate 4 MiB plus one native read into each pipe callback. SDK raw-byte buffers,
UTF-8 conversion temporaries, bounded emitted-message copies, OS pipe buffers,
and child memory are outside the decoded queue allowance. Pausing prevents new
reads but cannot undo bytes already admitted by the SDK. Two maximum SDK reads
are not promised to fit within 8 Mi: every decoded admission checks the combined
full-string charge and fails explicitly on excess rather than growing a
controller queue. Supervisor-local pending and message budgets can be reduced
for focused overflow/drain tests; they are not Environment request settings.

Completion requires both pipe EOFs and delivery of all admitted text. After
process-group cleanup, upstream liveness has a one-second idle budget and a
ten-second cumulative hard budget. Both clocks advance only while at least one
unfinished real pipe subscription is unpaused. Pausing for downstream credit or
to split an admitted string suspends both clocks without resetting their remaining
budgets. A pipe read or EOF refreshes only the idle budget; delivery does not
refresh either budget. Both EOFs stop these clocks, not the remaining delivery.
Consequently, finite buffered output can drain beyond either former wall-clock
interval, and a temporary downstream pause does not discard admitted text. A
genuinely unfinished escaped pipe holder still fails after one idle or ten total
readable seconds, including a writer that keeps making progress. These are not
wall-clock limits on an observer that indefinitely withholds credit: its bounded
queue remains owned until demand resumes or execution is interrupted.
`process_output_overflow`, `process_output_failed`, and
`process_output_incomplete` are declared `EnvironmentFailure` codes, not successful
completed events. Their details retain `outputIncomplete: true`, known
`termination`/`exitCode`, and per-pipe `stdoutTruncated`/`stderrTruncated` evidence.
Cancellation and provider shutdown release output independently of credit. The
execution timeout runs on wall time while the leader is alive; if it expires with
blocked delivery (or delivery pauses after timeout), output fails explicitly and
pipe cleanup does not wait for credit. Normal leader exit stops that execution
timer, not the upstream drain budgets. A paused observer sees
the bounded queued failure only when it resumes; cleanup does not depend on that.

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

Focused foreground checks live in `git_worktree_environment_provider_test.dart`
(partial text, Unicode/control preservation, multi-megabyte output, pipe fairness,
backpressure, timeout/cancellation, overflow, and truthful final drain) and
`backend_host_integration_test.dart` (the actual shared-host/generated provider
path). Run those files directly from `packages/backend` after maintained contract
generation when validating foreground changes without unrelated PTY tests.

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
therefore remains the matching directory inside the linked worktree.
`EnvironmentTerminalLaunchKind.explicitProgram` passes the requested executable
and verbatim argv directly, including explicit shell invocations such as
`/bin/bash --noprofile --norc -i`. `defaultShell` instead resolves the provider's
inherited `SHELL` as one executable path or PATH-searched name and passes exactly
`['-i']`, with cwd at the Environment root. `SHELL` is never split, trimmed,
unquoted, or expanded: spaces are valid only as part of an actual executable name.
Only an absent `SHELL` selects `/bin/sh`; a present empty, malformed, missing, or
non-executable preference fails explicitly without shell substitution. Normal
shell startup files may run according to the selected shell's own interactive,
non-login behavior; the provider does not discover profiles or add shell-specific
startup flags.
Child environment uses the foreground allowlist above, with canonical `PWD` and
`TERM=xterm-256color` instead of `dumb`. No shared-host environment/cwd mutation,
arbitrary environment override, credential forwarding, or shell-profile discovery
is added.

The provider-local `terminalEnvironment` constructor seam replaces the inherited
source for terminals only, snapshots it, and still applies the same allowlist. It
is not part of the Environment request or backend startup configuration. Focused
tests use controlled `SHELL`/`PATH` and a temporary `HOME`, not personal startup
files; Git placement and foreground-process environments are unchanged.

The provider-private `GitPtySession` uses the prepared Linux x64 C executable
described in [toolchain preparation](../../docs/development/toolchain.md#git-pty-preparation).
`--pty-helper=<absolute prepared path>` is optional backend startup configuration:
missing/unsupported preparation makes only terminal creation explicitly unavailable.
The backend remains Flutter-free. Fork, controlling-terminal setup, session/signal
changes, native descriptor operations, and reaping occur in the helper, not the
shared AOT host. The helper is not an independently selected Environment provider.
Its Linux-specific supervision is replaceable behind this isolation boundary;
the public terminal contract is provider/platform-neutral. See the
[toolchain guidance](../../docs/development/toolchain.md#git-pty-preparation) for
the required custom-versus-upstream-library comparison before another platform
backend is added. Other platforms remain unvalidated.

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
