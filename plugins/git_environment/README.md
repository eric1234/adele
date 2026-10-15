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

Establishment and restoration copy the exact retained `baselineCommit` and `branch`
into that live object alongside its canonical filesystem and Git roots. Later
commits do not advance this baseline. Independent Environments, including ones in
the same Task, retain their own baselines; no Task-wide registry or current-Project
HEAD lookup supplies change review authority. This metadata changes neither the
provider-state schema nor ordinary filesystem, execution, or terminal operations.

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

## Change snapshots

The same stock AOT backend advertises the Diff-owned
`adele.diff.change-set-source` v1 Capability through
`diff_viewer_contract`'s zero-argument `ChangeSetSourceService.snapshotUnstaged`,
`snapshotUncommitted`, and `snapshotTaskChanges` methods.
Its separate `dev.adele.git.change-set-source` provider is explicitly associated
with this generation's actual Git Environment provider. The contextual dispatcher
uses `AuthorizedEnvironmentReadService.authority()` to select only an existing
live `WorktreeEnvironment`; it never accepts caller-selected Environment IDs,
repository paths, or a fallback to the Task's primary Environment. Ordinary
context-free calls are rejected. The host read grant is revalidated before success.
Establish/restore also bind the canonical Git directory and actual worktree root to
that live object. Inspection supplies both explicitly to Git, so a newly created
nested `.git` or `core.worktree` setting cannot substitute another repository.

For Unstaged, `git ls-files --cached --stage --debug -z` supplies the bounded index
inventory, not HEAD; `git ls-files --others --exclude-standard -z` adds nonignored
untracked files. Direct bounded reads are hashed as Git blobs (SHA-1 or SHA-256
according to the index identity), omitting byte-equal tracked files without Git
subprocesses per clean file. Staged-only ordinary files are absent. Both commands
are scoped to the live root, including a nested Project source. Returned paths are Environment-relative,
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

Uncommitted captures the current HEAD commit/tree and compares its bounded,
source-scoped tree inventory with the same resolved stage-0 index used for
Unstaged. Bounded immutable HEAD and index blobs supply staged hunks through the
same private patch mechanism. Index-to-working-file comparisons supply the
unstaged layer, including nonignored untracked additions. This is a layered union,
not HEAD-to-working-tree: A-to-B staging and B-to-A working edits both remain
visible. A staged deletion recreated on disk is a staged deletion and an unstaged
addition. Intent-to-add is not fully staged. Unmerged stage-1/2/3 paths appear only
in the separate conflicts collection, never as ordinary staged approval or
unstaged changes. Existing unsupported index flags and modes remain conservative
placeholders rather than fabricated hunks.

Task / Branch adds the net retained-baseline-tree to captured-HEAD-tree comparison
as a separate committed layer, using the same bounded source-scoped tree enumeration,
immutable blob reads, classification, and private patch generation as staged changes.
It is not a log or a baseline-to-working-tree patch. Committed additions/deletions,
mode changes and nontext placeholders remain distinct from later index and working
edits, including changes that reverse earlier layers. Conflict paths are excluded
from ordinary staged/unstaged layers without erasing independent committed changes.

All selected layers are computed inside one contextual operation with one captured
live Environment and repository identity, not independently resolved calls. Task
requires an exact, available baseline commit from that live object and an attached
HEAD matching its retained provider branch. Missing/invalid baseline information,
missing objects, detached HEAD and unexpected checkout fail explicitly; there is
no HEAD substitution, merge-base inference, repair or branch switching. Unstaged
and Uncommitted remain available without Task metadata. Uncommitted and Task require
a valid current HEAD. HEAD, baseline availability for Task, index, configuration,
observed files, exact live binding and authority are revalidated before settlement.

Text patches are actual deterministic Git unified hunks over bounded
baseline/HEAD/index blobs and direct working-file snapshots. A private temporary
directory outside the worktree supplies `git diff --no-index` with fixed literal
filenames; Git does not
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
suppresses working-file executable-bit-only differences; actual HEAD/index mode
differences and baseline-to-HEAD mode differences remain visible in their layers.
Repository settings override lower configuration scopes. Git executable state
uses only the owner-execute bit.

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

Default per-operation limits are 4,096 retained inventory paths
(baseline/HEAD trees, index records and their union with untracked paths are bounded),
256 returned entries across all selected layers and conflicts,
1 MiB per rendered file side, 2 MiB collected stdout per command/patch, 64 KiB
stderr counted without retaining diagnostics,
8 MiB total compared inputs plus patches, 8,192 hunk lines, and a conservative 6 MiB
escaped-text/DTO transport budget below the host frame limit. Each Git process has
a 10-second deadline including pipe completion; the entire operation has a
30-second deadline. Output is bounded during collection, not after an unbounded
`Process.run`. Per-file size/patch excess is an oversized placeholder; enumeration,
file-count, content/patch aggregate, process, and malformed-output failures reject
the whole snapshot rather than returning a deceptively complete truncated result.
Ordinary oversized tracked regular files have a separate streamed verification
budget: 16 MiB per file and 64 MiB across the operation. A reusable 64 KiB buffer
feeds the raw Git blob header and bytes into SHA-1 or SHA-256 according to the
indexed OID, without retaining the file or executing Git conversions/filters.
Only a complete matching identity with consistent metadata and indexed mode is
confirmed unchanged and omitted. Raw mismatches remain oversized entries without
hunks; untracked oversized files likewise remain explicit additions. A file beyond
either verification budget, or whose read fails, remains oversized with explicitly
unknown change state (`unsupported`), never an inferred clean result. Detected
size/metadata changes reject the snapshot. Verification checks operation liveness
between bounded reads and retains omitted files in the final observation checks.
These scan budgets do not consume content/patch or DTO budgets. Equal inspected
files do not consume the changed-result byte budget.
For Uncommitted and Task these are shared operation limits, not fresh allowances
for each layer. A path appearing in committed, staged, and unstaged layers counts
three times toward the returned-entry limit. Nontext file sides collected within
the rendering limit are also charged by both layered scopes;
Unstaged retains its existing text-result accounting. Content/patch aggregate
overflow rejects the whole result, not just one section.

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
and stock Git AOT, checks ready advertisements and their exact associations,
and exercises generated contextual requests for independent live Environments.
The existing `git_environment_backend` maintained target discovers both files.

## Review Approval

The backend independently advertises `adele.diff.review-approval` v1 as
`dev.adele.git.review-approval`, explicitly associated with the same exact Git
Environment provider as the snapshot service. Diff's public `ReviewApprovalService`
is implemented by `GitReviewApprovalService`; `git_review_approval.dart` shares the
private bounded snapshot machinery rather than introducing a general Git command
service. Approve means stage, Unapprove means unstage. Working files and HEAD are
never written, and committed changes are never direct targets.

The contextual-only dispatcher requires an operation-scoped
`AuthorizedEnvironmentReviewService.authority()` proof in addition to the ordinary
authorized read identity. Both must name the same captured Session/Environment.
This proof is granted only by explicit review admission: context-free access or
putting the approval Capability in a read-only declaration cannot authorize a
mutation. The backend selects only the existing live object from its own generation
and revalidates proof, identity and liveness before index publication. Missing or
ambiguous review-provider access does not disable snapshots.

### Revisions And Eligibility

Reviewable staged/unstaged snapshots carry an opaque HMAC-SHA-256 revision keyed to
the provider generation and exact live Environment generation. Its input includes
the bound source/worktree identity, captured HEAD and branch, complete raw index
identity, layer, ordered files/hunks/lines, relevant attribute/ignore sources and
observed working content identities. No filesystem paths or authority are exposed
in the token, and no snapshot registry is retained. A hunk selector is only an index into that
exact ordered revision. Reobservation under the index lock must produce the same
revision; stale requests return `stale` without publishing an index. Changes outside
the selected hunk, or unrelated index updates, can conservatively require Refresh.
That includes a Git stat-cache refresh even when its blob IDs are unchanged.
Directory membership checks respect Git ignores, skip symlinks and nested
repositories, and retain tracked-parent checks without traversing ignored build
artifacts. This is bounded observation, not a filesystem watcher.

Review metadata is optional for inspection, but mandatory for mutation. A complete
index beyond the 16 MiB review-metadata bound, an indirect index, or unsupported
index/reference storage disables review revisions and displayed eligibility,
not otherwise-supported scoped read-only snapshots. Scoped inventory, consistency,
content and transport limits still apply; no entries or hunks are omitted to fit
the review policy. Unstaged remains an index-to-working-tree comparison on an
unborn HEAD, including nonignored additions, without approval. Uncommitted and
Task/Branch retain their valid-HEAD requirements; no substitute empty tree is used.

Approve reconstructs only the Unstaged layer, matching `snapshotUnstaged()`, while
retaining complete HEAD/index identity and revision checks. Unrelated staged hunks
do not consume its rendering budgets. Unapprove still reconstructs Staged changes;
Uncommitted and Task snapshots retain their existing layered rendering limits.

Symbolic HEAD is reviewable only when its captured Git-written header directly
names the resolved terminal reference. Chained or noncanonical symbolic headers
remain inspectable but receive no approval revision; no recursive ref monitoring
or branch substitution is performed. Detached HEAD can still support Unstaged and
Uncommitted review, while Task/Branch retains its branch/baseline requirements.

Revisions are issued only after their bounded verification prerequisites are
available. Ordinary observed-file verification and oversized-file streaming have
independent 64 MiB aggregate allowances, each retaining the 16 MiB per-file bound.
Final synchronous publication uses the same independent accounting and still
rechecks every captured content digest. These allowances do not increase the
existing rendering, patch, inventory or transport budgets.

Eligible observation captures bounded contents and state for relevant worktree
`.gitattributes` files, from the worktree root through the selected file's parent
(including ancestors outside a nested Project source), and the common Git
`info/attributes` file. Git-discovered system/global attributes and system/global,
repository and per-worktree configuration sources are captured too. Source-content
fingerprints participate in each file's revision. Attribute, ignore and configuration
source contents share the 16 MiB aggregate metadata allowance and the existing
inventory-path bound.
Configuration includes, `attr.tree`, indirect/nonregular sources, or source
discovery that cannot be verified safely make approval unavailable while retaining
inspection.
Git versions without the optional attribute/configuration discovery variables
likewise retain read-only inspection without approval. Relative configured attribute
paths are resolved against Git's bound worktree root, not a nested Project source.
This is a deliberately bounded review policy, not a general configuration watcher.

Ignore inputs are captured before Git relies on them to enumerate or prune the
review set: the bound common Git directory's `info/exclude`, relevant worktree
`.gitignore` files and ancestors above a nested Project source, and the configured
or normal global excludes file together with its governing configuration. Missing
source paths are retained so appearance is detectable. Git still interprets all
patterns; the provider does not implement ignore matching or traverse ignored
subtrees merely to watch them. Stable ordered source fingerprints participate in
the review revision. Snapshot settlement and final synchronous publication both
check source bytes and state, so changing exclusions cannot turn an acknowledged
whole-layer operation into a partial selection. Unverifiable or over-budget review
sources make approval unavailable without hiding the original read-only snapshot.

Supported targets are fully inspected ordinary UTF-8 text modifications, additions
(including nonignored untracked files), and deletions. Empty additions/deletions
have file/layer support without invented hunks. Hunk reconstruction uses exact
provider-retained bytes and validated coordinates, preserving CRLF and missing
final newline; no frontend patch, fuzzy application or automatic rebase is used.
Approving one hunk starts from the index version; unapproving one starts from the
staged version and reverses only that HEAD-relative hunk. Unrelated hunks remain.

Binary/invalid UTF-8, incomplete or oversized inspection, conversion/diff attributes,
mode/type transitions, symlinks, gitlinks, unresolved stages, intent/unsupported
index flags, ambiguous directory/file replacements and unsupported index storage
cannot be reviewed. Ordinary file modes
are preserved; arbitrary mode or binary staging is not supplied. Whole-layer
operations require all targets to be eligible and no unresolved conflicts; they
never silently skip unsupported files. Read-only snapshot placeholders remain
available even when review is unavailable. A complete current HEAD and supported
file-based reference storage are required for review revisions.

### Index Transaction

Every hunk, file or whole-layer request uses one mechanism:

1. Exclusively create the bound linked-worktree Git directory's actual `index.lock`
   using Git's cooperative lockfile protocol. Lock contention fails without retry.
2. Reobserve HEAD, the complete index and scoped working content while holding that
   lock, validate the expected revision and resolve every selected target.
3. Copy the complete original index to a private temporary index. Verify and protect
   every selected nondeletion blob as described below, then update that private
   index with one NUL-framed `update-index --index-info` request against an empty
   scratch worktree.
   Paths and data are not shell text. Check the prospective index preserves every
   unselected entry; Git's implicit directory/file replacement is not permission
   to alter an unselected path.
4. Flush the prospective bytes to the held lockfile, revalidate source observations,
   HEAD/index identity, canonical authority and live generation, then recheck the
   captured attribute/ignore/configuration source bytes and state synchronously.
   Appearance, disappearance, replacement and same-length edits are checked without trusting
   metadata alone. The earlier effective-attribute validation is retained. Atomically
   rename the lockfile over the actual index without another asynchronous suspension.

Preparation failure leaves the authoritative index unchanged. Object-store writes
may remain as unreachable prepared objects; those are not a successful approval.
Git writers honoring `index.lock` cannot be overwritten. The copied index preserves
unrelated entries, modes and flags; Git maintains supported `TREE` and `REUC`
extensions. Index versions 2 through 4 and SHA-1/SHA-256 are supported; split/sparse,
fsmonitor, untracked-cache and unknown extensions are explicitly unavailable rather
than discarded. A successful operation acknowledges only the single publication,
not intermediate object or temporary-index writes. There is no sequential
multi-file partial-success path.

Selected blobs are verified by type, exact expected OID and reconstructed bytes.
Missing blobs use `hash-object --no-filters -w --stdin`. An existing loose blob
without a retained root is freshened through that same Git operation, with its
actual loose-file freshness verified afterward; success alone does not imply Git
created a loose copy when the object is packed. Already rooted objects are reused
without gratuitous freshness writes. Root proofs use the retained original index
or captured HEAD tree/history, never unrelated mutable refs. Historical proof is
bounded by the existing Git output/deadline policy and excludes unverified grafted
history. Packed-only blobs without such a proof are explicitly ineligible; ordinary
packed repositories, including normal unapproval from HEAD, remain supported.

Per-operation loose-file or bounded pack-inventory witnesses are checked after
Git verifies contents and again at publication. Ordinary GC may move a freshly
protected loose blob into a pack. One bounded storage reobservation is allowed for
that relocation, using the same selected bytes, revision, provider, deadline and
continuously held index lock. It repeats settlement and both authority checks;
then all final local validation and rename remain synchronous. Missing objects or
further storage churn reject without publishing an index. No refs, object registry,
background collector or object-format interpreter is introduced.

Object protection relies on Git's normal freshness/reachability guarantees during
ordinary cooperative GC, not deliberately aggressive pruning such as `--prune=now`,
backdated object storage or malicious filesystem replacement. Prepared object writes
or selected-object freshness updates are not rolled back on a rejected transaction.

On POSIX, publication preserves the authoritative index's existing ordinary
permission bits (`0777`), including shared-group access under a restrictive umask.
If adjustment is needed, a unique empty payload on the same filesystem is opened
before mode preparation, so read-only modes can also be retained. Only trusted
system `chmod` paths are used, with direct arguments, a clean environment and the
remaining operation/process budgets. Exact mode is verified before writing the
prospective contents and adopting the payload as the continuously reserved
`index.lock`, before final authority checks. A delayed permission process cannot
target a subsequent writer's reused lock pathname. Final synchronous checks verify
both the original index mode and the intended lock mode before publication.
Unavailable tooling or failed preparation cannot replace the index. Special mode
bits are unsupported; ownership and ACLs are not administered. Windows retains
its existing behavior without a POSIX-mode guarantee.

The mutation process policy is separate from read-only inspection. It strips
inherited Git routing variables, uses the provider's exact Git/worktree roots and
its private index, permits only raw object/index preparation, and disables hooks,
filters, fsmonitor, external diff/textconv and lazy fetching. Neither `git add` nor
working-tree patch application is used. A nested Project source updates only its
selected paths, preserving entries elsewhere in the checkout.
The empty preparation worktree also prevents Git's index-write racy-stat checks
from reading unrelated real files or invoking their conversion filters.
The common Git directory is retained from provider establishment/restoration;
changed `commondir` routing, object alternates, dual-format object storage, indirect
object storage (including loose-object leaves and packs) and unexpected blob identities are rejected
before index publication. These storage restrictions prevent object preparation
from following symlinks or freshening objects outside the bound store.

Shutdown fences new review admissions and drains existing cleanup. Navigation or
retirement can revoke acknowledgement and prevent pre-publication admission, but
does not undo a published index. Lost acknowledgement requires authoritative
Refresh, never automatic retry through a replacement provider.

One monotonic operation deadline covers preparation and all authority waits. Each
initial or final authority call receives only the remaining budget, with active
state checked before the call and again on completion. Expiry unwinds the index
lock and temporary-file cleanup without waiting for a late authority response or
starting another authority call. A timed-out underlying Future may still complete,
but it cannot retain the lock or resume publication. Cleanup may add bounded
overhead; individual authority calls never reset the operation timeout.

Git subprocess startup likewise receives the smaller of the remaining operation
budget and the remaining per-process budget. Exhaustion prevents a new launch,
and liveness is checked again immediately when a process handle arrives. A pending
startup Future cannot keep the review index lock for another full process timeout;
late handles are killed. This does not claim to preempt or roll back operating-system
work that may already have started before its handle becomes available.

These guarantees cover cooperating Git index writers, not hostile same-user
processes that ignore locks or replace filesystem paths between checks. Working
files and HEAD have no portable joint transaction with the index; bounded content,
metadata and reference checks immediately before publication detect observed
changes, but cannot lock arbitrary external filesystem writers. Atomic publication
is not a power-loss durability claim. Linux is the validated platform.

`git_review_approval_test.dart` uses real repositories and index contents for hunk,
file and layer operations, stale revisions, deterministic competing writers and
preparation faults. The prepared product workflow and authority boundaries are
mapped in [testing](../../docs/development/testing.md#focused-diff-checks).

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
