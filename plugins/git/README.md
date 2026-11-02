# Git

The stock Git plugin (`dev.adele.plugin.git`, display name `Git`) owns Git-specific
behavior through public extension contracts. Its `git_backend` package supplies
the Git Worktree Environment provider and the Diff-owned `ChangeSetSource` and
`ReviewApprovalHandler` Capability implementations; Git is not intrinsic to core
Task or Environment semantics. The plugin has no frontend. Review presentation belongs to
[Diff Viewer](../diff_viewer/README.md), and the cross-system ownership boundary is
defined in [contracts and capabilities](../../docs/architecture/contracts-and-capabilities.md#plugin-owned-change-snapshots).

The backend library and entrypoint are `packages/backend/lib/git_backend.dart`
and `packages/backend/bin/git_backend.dart`. Maintained preparation publishes
`installations/git/backend.aot`; the separately prepared Linux x64 terminal helper
is `git/pty-helper` relative to the installation root. See
[PTY preparation](../../docs/development/toolchain.md#git-pty-preparation).

## Git Worktree Environment

The `GitWorktreeEnvironmentProvider` (`dev.adele.environment.git-worktree`)
establishes a Task-specific linked worktree and normally creates a flat Task-derived
branch. It accepts only local `file:`
Project source URIs that resolve to usable Git worktrees. If that source selects
a repository subdirectory, the live Environment remains rooted at the matching
subdirectory in the linked worktree.

### Placement and retained state

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

Provider-state schema **v2** contains exactly these fields, stored opaquely by core:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `2`; other versions are rejected. |
| `environmentId` | Exact retained Environment identity. |
| `sourceRelativePath` | Selected source relative to its Git worktree root, using forward slashes; empty for a repository-root source. |
| `worktreeRelativePath` | Project-source-relative `.adele/worktrees/<allocated-name>`, using forward slashes. |
| `branch` | Exact provider-created Task branch. |

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

Establishment captures the original full SHA-1 or SHA-256 commit once, creates the
branch/worktree at that commit, and returns an `EnvironmentInitialState` containing
the shared Git anchor v1 schema and one plain `INSERT ... VALUES` with
`expectedRows: 1`. The host commits that required anchor together with the new
Task and primary Environment before publication, including for explicit temporary
Project backing. Provisional establishment never calls `enrollForEnvironment` or
uses a reverse storage selector. The baseline exists only in Git-owned SQL, not in
provider state or the live `WorktreeEnvironment`. There is no v1 import, migration,
dual authority, or current-HEAD fallback. See
[prepared establishment state](../../docs/architecture/product-model.md#prepared-establishment-state).

### Restoration and moves

Restoration uses the **current** canonical Project source and relative v2 state.
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
directory, exact branch, and confined selected source scope
before binding a fresh `WorktreeEnvironment`. Successful restoration returns
canonical relative v2 state, normally unchanged by a move, and no initialization
plan. Baseline availability is a Task comparison concern: its absence must not
prevent ordinary Environment filesystem/process restoration or other review scopes.

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
objects in its own registry; shutdown terminates active foreground and buffered
executions and terminal resources and
clears those objects without removing Git worktrees. Failed establishment publishes
nothing and performs best-effort branch/worktree cleanup only with sufficient
ownership evidence and revalidated confined storage paths.

This supports restoration across fresh runtime generations and whole-Project moves.
Core retains the opaque state with the Task/Environment graph; reopening a Project
loads semantic records without invoking Git restoration. Explicit Environment
materialization restores the live checkout. See the
[product model](../../docs/architecture/product-model.md#environment) for the
core-owned lifecycle boundary.

## ChangeSetSource

The same stock AOT backend advertises the Diff-owned
`adele.diff.change-set-source` v1 Capability through
`diff_viewer_contract`'s zero-argument `ChangeSetSourceService.snapshotUnstaged`,
`snapshotUncommitted`, and `snapshotTaskChanges` methods.
Its unchanged `dev.adele.git.change-set-source` provider is explicitly
`environmentBound`, declares only the `bufferedProcess` Environment host-service
permission, and has no sibling provider association. The invocation-local
`GitPersistedChangeSetSourceService` receives the generated authorized buffered
process client. Its `GitTaskAnchorStore` is generation-owned and uses a generated
`ProjectStorageServiceClient` bound to the actual bootstrap
`hostInfrastructureContext`, separately from operation authority. It does not
select private live Worktree objects or require a read-service grant.
Context-free calls remain rejected. Provider-independent selection does not imply
that every Environment supplies the executable prerequisites below.

<a id="portable-unstaged-inspection"></a>

### Portable change inspection

`GitPortableUnstagedSnapshotService` supplies `snapshotUnstaged()`,
`snapshotUncommitted()` and `snapshotTaskChanges()` as the stock comparison engine.
All reuse one operation's index-to-working-tree inspection, including nonignored
untracked additions; Uncommitted also returns captured HEAD-to-index changes and a
separate conflict collection, not a net HEAD-to-working-tree diff. It
accepts `AuthorizedEnvironmentBufferedProcessService`, optional reduced
operation limits, and an optional trusted `GitTaskComparisonAnchor`. It does not
accept Session/Environment IDs or repository paths, import the Worktree provider,
resolve live provider objects, or perform host-local
filesystem/process I/O. There is one stock provider, no Worktree-specific fallback
or second implementation. This inspection service performs no approval or feedback
mutation; index mutation belongs to the separate handler below.

Portable Task comparison requires an immutable Git-owned backend setup value:
`GitTaskComparisonAnchor(baselineCommit: ..., expectedBranchRef: ...)`. It carries
only a full SHA-1/SHA-256 commit OID and full `refs/heads/...` identity, never a
repository path, Environment selector, grant or frontend payload. Task inspection
validates exact OID syntax and the selected repository's object-format width,
requires the object to exist as an actual commit (not a tag to peel), validates
the branch ref, and requires attached HEAD on that exact branch. Missing metadata,
invalid/non-commit or unavailable objects, detached HEAD and a different branch
fail explicitly. There is no current-HEAD, merge-base, initial-commit, default-branch
or primary-Environment substitution. Unstaged and Uncommitted do not require this
anchor. Later commits never advance it.

That trusted-value comparison boundary remains usable independently of storage.
`GitPersistedChangeSetSourceService` adds exact persisted lookup around it,
without moving SQL or Session identity into the Git comparison routines. For each
zero-argument Task request it observes `capturedIdentity()` through the same
authorized buffered-process client used for all commands. Session routes the
generation-scoped `ProjectStorageService` to the open Project; Environment selects
the retained anchor. Neither ID is a Diff method parameter or an authority-granting
selector. The frontend still receives only the Diff-owned generated service.

`GitTaskAnchorStore` owns one current pre-release v1 schema under backend/plugin
identity `dev.adele.plugin.git`. `git_task_anchor_schema.dart` is the single schema
source for both establishment and the store. Its `adele_git_task_anchors` table contains only
`environment_id` (non-null primary key and foreign key to
`adele_product_environments.id`), `baseline_commit`, and `expected_branch_ref`.
Lookup joins the core Session, recorded Session-to-Environment association, and
Environment, validating both exact identities and same-Task membership. An absent
exact anchor fails with `baseline_unavailable`; another Environment's anchor is
never borrowed. Broken associations and malformed anchors fail distinctly as
`baseline_association_mismatch` and `baseline_corrupt`. Repository object existence,
commit type, object-format width and expected branch remain the comparison engine's
responsibility.
Storage failures are `baseline_storage_failed`, never a reset or in-memory fallback.

The store's backend-internal `enrollForEnvironment(environmentId: ..., anchor: ...)`
is for trusted provisioning of an already canonical, published Environment, before
any Session is required. It uses Environment-addressed Project storage to initialize
the existing v1 schema and insert for that exact Environment in the routed Project;
it does not resolve a provider or request Environment read/process authority. This
is not a Diff method or EVC action. Snapshot `read()` deliberately retains the
invocation's captured Session and Environment association checks. The unique Environment
key rejects every duplicate, even an identical duplicate, as
`baseline_enrollment_failed`; conflicting concurrent insertions cannot both report
success. There is no upsert, baseline update, HEAD inference, automatic retry, or
authoritative backend cache. Ordinary snapshots only read anchors. As with other
Project writes, a lost acknowledgement after commit is an uncertain caller outcome,
not permission to overwrite or silently retry.

Storage intentionally uses `durableOrTemporary`: durable Project backing retains
anchors across close/reopen and fresh backend generations, while an explicitly
volatile Project's host-owned temporary backing survives backend replacement only
while that Project remains open. Failed durable backing never switches to temporary
storage. Schema checks are idempotent under the existing host coordinator. Plain
Unstaged and Uncommitted requests never initialize this schema. Eligible review
targets and commentable comparisons obtain captured Session and Environment
identity through the existing process grant solely to bind their opaque snapshot
identities; they do not query Task anchors.

The Task adapter includes identity, schema and SQL latency in the thirty-second
deadline. Before publishing it rereads the association and anchor, requires unchanged
values, and revalidates captured identity through the original grant. Expiry fences
later Git commands and publication, including late storage responses. These are
bounded best-effort observations, not an atomic SQL/filesystem transaction. No
per-file queries or new subprocesses are introduced.

Stock Worktree establishment uses the atomic initial-state path described above,
not this post-publication provisioning method. Independent Environment providers
can be inspected without Git lifecycle state; their Task scope needs an explicitly
provisioned anchor for that exact Environment. Missing anchors disable only Task,
not Unstaged or Uncommitted. Core Task/Session/Environment values and the public
Diff contract acquire no Git metadata.

The stock Worktree provider retains only operational checkout identity in its live
object: canonical checkout/metadata directories and the bounded direct `.git`
marker. Buffered execution checks that identity before and after each request,
including the absence of any nearer `.git` marker between the selected source
scope and checkout root. Missing, replaced, aliased, or nested markers fail with
`git_checkout_changed`; Git cannot silently rediscover the enclosing source repo
or a newly nested repo. This adds no subprocesses, baseline authority, or private
comparison lookup. Descendant repositories below the selected Environment root
remain available to intentional child-directory commands. These checks remain
best-effort path observations rather than an OS sandbox or an atomic filesystem
transaction.

Portable comparison also rejects explicit `core.worktree` configuration with
`unsupported_repository_configuration`. Per-worktree configuration can otherwise
redirect discovery into an enclosing repository without changing the linked
checkout marker, producing an incorrectly empty scoped inventory. This check uses
the already captured settings, adds no subprocesses, and is deliberately
conservative even when an explicit override happens to name the expected root.

The independent Capability must declare `environmentBound` and the separate
`bufferedProcess` host-service permission. Its consumer needs the contextual process
Capability grant, not direct process access or a combined read/process grant. The
host selects and captures the canonical Session Environment and both exact live
provider generations, authorizes each invocation, and fences retirement. The
portable Git service never supplies or substitutes those identities.

Every observation runs through the operation's captured process service, including
metadata and raw-file reads. The currently supported command environment is Linux
with `/bin/sh`, `/bin/pwd`, and `/usr/bin/{env,git,stat,head}`. These are explicit
Environment-side executable prerequisites, not paths in the ADELE host checkout.
Missing commands fail the snapshot, without a local or alternative-Environment
fallback. A fixed shell wrapper forwards literal argv to `env -i`, retaining HOME
and XDG configuration discovery while setting a fixed system PATH and locale.
It removes inherited Git routing/configuration/trace variables, disables optional
locks, replacement objects, prompts and lazy fetching, and denies Git transports.
Source commands additionally disable fsmonitor, hooks and the untracked cache.
This is command hygiene, not a sandbox against a substituted system executable or
arbitrary effects of the selected Environment's process implementation.

Discovery compares canonical absolute `pwd -P` and Git worktree/Git-directory
paths with the exact source prefix, including a worktree rooted at `/`, then pins
the discovered Git directory/worktree on source commands. Inventories
remain scoped to `.` at the selected Environment root, including a nested Project
directory, and return sorted Environment-relative paths. Cached stage/debug and
untracked inventories reuse the existing pure `git_snapshot_parsing.dart` helpers;
deleted and obstructing-path inventories are supplementary observations. NUL
framing preserves unusual filenames. Any diagnostic on stderr fails the operation:
for example, `ls-files --deleted` can report an unreadable path as deleted while
returning exit zero with an error diagnostic.

Uncommitted additionally captures `rev-parse --verify HEAD^{commit}` and
`symbolic-ref --quiet HEAD`, then uses `ls-tree -r -z <captured-commit> -- .` for
the source-scoped HEAD inventory. Detached HEAD is valid; missing/unborn HEAD
fails explicitly, while Unstaged still requires no HEAD. The shared pure tree
parser validates NUL framing, exact modes, object types and SHA-1/SHA-256 identities.
Index parsing validates all stages and rejects duplicate or contradictory stage
records before collapsing unmerged stages into one conflict. Raw stage/debug
inventory is retained so changes to any conflict side are detected on revalidation.

Staged comparison uses only captured HEAD and stage-0 index modes/blob identities.
Intent-to-add and untracked paths have no staged object. Additions, deletions,
modifications and type/mode changes are independent of working content: A/B/A and
A/B/C across HEAD/index/working retain both layers; a staged deletion with working
recreation is a staged deletion plus an unstaged addition. Renames remain separate
deletion/addition entries. Unmerged paths occur only in `conflicts` for Uncommitted,
with the stock conflicted status/detail and no ordinary approval material. Unstaged
alone retains its existing inline conflict representation.

Task captures both baseline and HEAD trees inside that same operation, then returns
the existing `TaskChangeSetSnapshot(committed, uncommitted)` shape. Committed is the
net baseline-to-HEAD tree difference, not a commit log or baseline-to-working diff.
It is built independently before index-conflict handling: committed work remains
visible on an unmerged path, with no fabricated staged/unstaged approval material.
A/B/A/A and A/B/C/A across baseline/HEAD/index/working retain every meaningful
layer; matching final working content never collapses intermediate changes.

GNU `stat` checks parent and leaf types, sizes, modes, identity and nanosecond
modification/change times in bounded batches. Parents are admitted one depth at a
time before their descendants. Each result contains the literal argv filename and
metadata in separate NUL-terminated fields; complete record count and path ordering
must match the request. Inventoried static symlinks and special files are
unsupported, not ordinary text changes. This preflight is important because Git
no-index can follow a symlink to a FIFO and report its content as a regular file.

For verified regular tracked files, `git hash-object --no-filters -- ./path ...`
computes raw SHA-1 or SHA-256 blob identities in bounded batches. Every eligible
file's content is hashed, even when index timestamps and sizes appear unchanged.
Exact hash count, framing and index hash width are checked. Metadata is rechecked
in batches immediately after hashing and again before publication. Equal raw
content is omitted before text classification; unchanged files need no individual
`head` or `stat` requests. Raw hashing at every file size is subject to the separate
observed-size verification budget. Exceeding that allowance for a file within the
rendering limit fails the snapshot; unverifiable oversized files retain explicit
oversized entries with unknown change state, never inferred clean. A failed batch
rejects the whole snapshot, even if Git or stat produced a valid prefix of output.

Each batch contains at most 128 literal path arguments, reduced further to fit
the generic 256-argument and 65,536-UTF-16-unit metadata bounds. Accounting includes
the entire shell wrapper, executable, Git options, discovered roots and path
prefixes. There is no filename interpolation into shell source. Changed text
continues through bounded `head -c` captures/rereads, per-read metadata checks, and
`cat-file -s` / `cat-file blob` index reads with size and object-identity validation.

For renderable changes, the index bytes are the single bounded stdin of
`git --git-dir=/dev/null diff --no-index ... -- - ./relative-path`, or `/dev/null`
for deletion. Detached comparison disables global/system configuration and
attributes, external diff and textconv, and fixes the diff algorithm/context.
Using no-index inside a discovered repository is deliberately avoided: disabling
external diff and textconv alone does not stop clean filters or EOL conversion.
The shared patch parser has an explicit stdin-patch mode because these patches can
omit an index header; its strict default is unchanged. Binary/invalid UTF-8,
conversion/custom diff attributes, conflicts, index flags, mode changes, submodules
and nested repositories retain explicit nontext representations. Indexed symbolic
links remain unsupported even when their target text might be unchanged. Git does
not inventory untracked FIFOs or other untrackable special files; these are outside
the Git change set rather than discovered by a separate filesystem traversal.

Staged regular-file bytes are obtained with bounded `cat-file -s` / `cat-file blob`
reads of the exact captured objects, never working-file reads. Renderable staged
patches use the same pinned source-command wrapper with:

```text
-c diff.suppressBlankEmpty=false diff --cached <captured-commit>
--patch --exit-code --no-ext-diff --no-textconv --text --no-renames
--no-color --no-prefix --no-relative --full-index --ignore-submodules=all
--ita-invisible-in-index --diff-filter=A|D|M --diff-algorithm=myers
--no-indent-heuristic --unified=3 --inter-hunk-context=0
--output-indicator-new=+ --output-indicator-old=- --output-indicator-context=" "
-- ./<literal-path>
```

The kind-specific filter isolates the exact file even in file/directory replacements,
where a literal pathspec also selects descendants. Full-index object identities
must match the captured inventory; parsed hunks must reconstruct the exact captured
index content. Patch-header path strings are never trusted for attribution. Empty
file additions/deletions remain text entries with no hunks. A missing difference,
wrong identity, incomplete patch, nonzero failure, or diagnostic rejects the entire
snapshot. Cached diff reads object content rather than cleaning the working file;
external diff and textconv are disabled explicitly, and the wrapper disables
fsmonitor/hooks. Hostile-helper tests include executable positive controls, FIFO
and missing workfiles, and unchanged Git metadata fingerprints. No temporary source
files or arbitrary filesystem writes are needed. Conversion/custom attributes,
legacy `crlf`, binary/invalid UTF-8, unsupported modes and oversized sides keep the
same conservative classification policy in both layers.

Committed comparison reuses this object comparison and hunk verification, replacing
`--cached <captured-commit>` with the two captured full OIDs
`<baseline-commit> <head-commit>`. Both sides come from their captured tree
inventories and bounded immutable blob reads. The raw object bytes determine
binary/invalid-UTF-8 classification, independently of current working-file
conversion attributes. External diff/textconv remain disabled and deterministic
patch options override configured formatting. Tests exercise configured executable
clean/process filters, external diff, textconv, fsmonitor and hooks, with positive
controls, unchanged Git metadata fingerprints and FIFO/missing working files.
Pinned identities and literal nested paths remain valid after HEAD moves; a changed
HEAD still prevents publication of the enclosing Task operation.

Defaults are 4,096 inventory entries per baseline/HEAD/index inventory and across
the union with untracked paths, at most that many distinct parent observations,
256 returned entries across committed, staged, unstaged and conflicts, 1 MiB per
rendered side, 2 MiB command stdout, 64 KiB diagnostic output,
an 8 MiB aggregate transport byte budget, 8,192 hunk lines, a conservative 6 MiB DTO
budget, and 4,096 process requests. The aggregate budget counts all transported
input/output, including raw rendered-content reads and rereads, blob bytes,
patches, metadata and hash output. Raw working-file hashing instead shares one
verification allowance across all sizes: at most 16 MiB per observed file and
64 MiB total observed sizes. Batching does not bypass either budget. Retained
parent-path text is independently capped at `totalBytes` UTF-16 code units before
metadata execution. Commands have a ten-second deadline within
the whole snapshot's thirty seconds; execution remains sequential. Generic
Environment transport limits are unchanged. Any incomplete observation, malformed
output, process/transport failure or exhausted whole-operation budget fails the
snapshot rather than returning a truncated or deceptively clean result.
All budgets belong to one captured operation, not a fresh allowance per layer.
A path returned in all three layers counts three times toward the entry limit;
object reads, raw comparisons, patch lines, commands and presentation size all share
their respective counters.

A flat clean Unstaged inventory with ordinary-length paths uses
`20 + 4 * ceil(fileCount / 128)` requests: initial metadata, hashing, post-hash
metadata and final metadata batches, plus fixed discovery/inventory/settings work.
Uncommitted adds only six fixed requests for initial/final commit, reference and
tree observations: `26 + 4 * ceil(fileCount / 128)`, with no staged process for a
clean file. Task with baseline equal to HEAD uses
`35 + 4 * ceil(fileCount / 128)` requests, adding fixed object-format, commit
identity, expected-ref and baseline-tree checks, not a process per clean tracked
file. At the 4,096-entry maximum these are 148, 154 and 163 requests respectively.
Rendered-file work, Task's required-object rechecks, parent observations and
smaller metadata-limited batches consume the same 4,096-request ceiling.
It does not promise success for every possible path layout, file size or machine;
the independent byte and thirty-second deadline bounds still apply.

Non-gating Linux Unstaged diagnostics, excluding fixture setup, observed:

| Local Process Fixture | Requests | Elapsed |
| --- | --- | --- |
| 100 clean tracked files | 24 | 1.013 seconds |
| 500 clean tracked files | 36 | 1.080 seconds |
| 900 clean tracked files | 52 | 1.606 seconds |
| 500 tracked files with three text edits | 66 | 1.937 seconds |

The real independent Environment AOT / Git AOT / compiled EVC fixture completed
500 and 900 clean files in 1.202 and 1.651 seconds with 37 and 53 requests (including
a parent directory). A modify/delete/add combination used 60 and 76 requests in
1.833 and 2.173 seconds. These are single-host observations, not timing guarantees
or CI assertions. Modest deterministic tests instead enforce batched call scaling
and fail-closed behavior. Uncommitted regression diagnostics exercise the same
100/500/900-file batch scaling, mixed staged/unstaged changes and independent
prepared execution. Task regression diagnostics exercise clean 100/500/900-file
snapshots, committed-only and three-layer changes, with bounded process-count
assertions rather than wall-clock CI assertions. Batching does not alter the
Environment's isolation guarantees.

Index/untracked/deleted/obstructing inventories, relevant configuration, rendered
file attributes, repository discovery and observed metadata are rechecked before
publication. Text working bytes are also reread around patch generation. Uncommitted
additionally revalidates HEAD commit/reference and the captured HEAD-tree inventory,
sharing the original index and working observations. Task also revalidates the
fixed baseline commit and both captured tree inventories, attached branch and HEAD,
without fresh Environment resolution. Baseline and distinct HEAD commit bytes are
hashed against their full identities; required changed-object sides are revisited
before publication. Renderable blobs must still hash to their OIDs, while oversized
sides remain bounded size/availability observations rather than raw-content claims.
These are best-effort consistency checks, not an atomic filesystem/index transaction.
External processes can replace paths after checks, grow files during a Git hash,
or change and restore content between observations. Processes retain the selected
Environment's OS-user access, including possible access outside the worktree; this
implementation promises no stronger confinement. A timeout fences later commands
and publication but does not cancel an already admitted unary process request;
the provider's process deadline and lifetime policy still apply.

`git_portable_unstaged_snapshot_test.dart` exercises real Git through an independent
process-service adapter, including hostile configuration, unusual paths, explicit
unsupported cases, limits and changed observations. `git_portable_discovery_test.dart`
uses controlled process responses for root/prefix validation without creating a
repository at the host filesystem root. The maintained `git_backend` target
discovers those, `git_portable_cached_diff_test.dart`'s staged and commit-to-commit
feasibility checks, and the extracted parser tests. Application
`prepared_portable_git_integration_test.dart` independently prepares an Environment
AOT backend that runs real processes, stock Git AOT with compiled stock Diff EVC,
and separate probe-backed adapter/consumer lanes for controlled failure tests. It checks
nonprimary Session binding, typed committed/staged/unstaged paths and hunks,
conflict entries, one semantic invocation per request, clean-repository batch
scaling, explicit process declarations and exact retirement/departure fencing.
The independent Environment backend imports neither Git nor Diff implementation.
The persisted path uses the actual Git plugin identity and exact-generation storage
grant, real Project backing, distinct primary/nonprimary anchors, replacement and
durable reopen without reenrollment. `app/test/core/git_task_anchor_store_test.dart`
covers the Git store against maintained Project storage, including association,
duplicate/concurrent enrollment, corruption, Project isolation and temporary backing.
`git_persisted_change_set_source_test.dart` covers adapter failure/deadline boundaries;
its controlled storage doubles do not stand in for persistence evidence.
`backend_host_integration_test.dart` compiles the actual shared host and stock Git
AOT, verifies the process-only advertisement and invocation route, exercises all
three scopes over generated Environment calls, and binds generated infrastructure
storage to the owning backend generation. Its storage double validates transport,
not SQL durability. Worktree tests cover exact initial SQL, SHA-1/SHA-256 capture,
strict v2 state, restoration without baseline objects, and no restore-time replay.
The application stock lifecycle and Diff/Git integration suites cover atomic
initialization with real Project SQL, backend replacement/reopen/moves, and stock
Diff's process-only grants without changing generic read/sibling contracts.

### Comment Comparison Identity

`ChangedFile.commentComparisonIdentity` is a required nullable snapshot field for
read-only comment anchoring. Git certifies verified regular UTF-8 text comparisons
with displayed source lines in all three layers, including Committed. It is
independent of hunk/file/layer approval eligibility: partially staged additions,
deletions, and literal tab/newline filenames can have comment identities without
approval revisions. Empty additions/deletions have no source lines and no comment
identity. Binary, invalid UTF-8, oversized, conflicted, unsupported, and unsafe
entries remain uncertified. Paths outside the draft contract's canonical path
bounds, including backslashes and drive-qualified names, also remain uncertified;
they are never normalized into a different comment location.
Unstaged deletions additionally require an already captured safe working-absence
proof; an inventory deletion alone does not establish absence through an unsafe
ancestor. This can remain unavailable even when the old text is displayed, and
does not require final complete-file approval eligibility. Staged and Committed
deletions instead use their captured immutable object membership, not working paths.

The distinct `git-comment-comparison-v1` domain hashes the operation's captured
Session/Environment association, discovered repository and selected source scope,
comparison layer, literal path/change kind, explicit old/new source roles,
per-side modes and full SHA-1/SHA-256 blob identities (or absence), and every
displayed hunk coordinate, line kind, exact text and final-newline marker. Both
object and working comparisons verify parsed hunks against their exact bounded
captured bytes before certification. CRLF and no-final-newline content are not
normalized. All fields are unambiguously JSON-framed before SHA-256 hashing.

An unchanged comparison retains its identity across refresh and inspection scopes.
Changed relevant content, displayed layout, layer, Session, Environment, repository
or source scope produces a different identity. Whole-tree commit IDs, unrelated
index entries, other working files, stat timestamps and approval revisions are
deliberately excluded: an unrelated commit or approval cannot make this file's
unchanged source comparison outdated. Returning to the exact original comparison
can restore its identity; this is location matching, not a monotonic revision or
mutation precondition. The value is neither authority nor an approval token.

Certification reuses captured comparison evidence and one shared authorized
identity observation with review revision generation. It adds no Git subprocess,
repository scan, storage query, clean-file work, or new inspection allowance.
`git_comment_comparison_identity_test.dart` covers native production snapshots,
per-layer/association/scope separation, SHA-1/SHA-256, partial staging,
additions/deletions, literal paths, byte preservation, unsupported entries, exact
hunk verification, stable unrelated changes, and unchanged process batching.

## ReviewApprovalHandler

`GitPortableReviewApprovalService` implements the separate Diff-owned
`adele.diff.review-approval` v1 contract. The stock backend advertises
`dev.adele.git.review-approval` through generated service
`diff.reviewApprovalHandler`, separately from ChangeSetSource and Worktree.
It declares `environmentBound: true` and only
`AdeleEnvironmentHostService.bufferedProcess`, without a same-backend association.
Its contextual dispatcher constructs the handler per admitted operation using that
operation's generated `AuthorizedEnvironmentBufferedProcessServiceClient`.
It retains neither a global authorization grant nor approval state. Hunk, file and
whole-layer approval require no Task baseline or SQL anchor and work with independent
compatible Environment providers. No Environment service, combined read/process grant,
provider registration, Worktree provider state, or Project schema is added or changed.

The stock compiled Diff frontend declares this exact Capability/major separately
from its inspection permission. It offers explicit hunk-level Approve/Unapprove
and complete-file Approve File/Unapprove File, plus **Approve All Unstaged** and
**Unapprove All Staged** for provider-certified complete layers, never raw process
authority or patch execution. Missing approval access
leaves read-only inspection available; see [Diff presentation](../diff_viewer/README.md#presentation)
for pending, snapshot freshness, safe failure and retirement behavior.
The same handler also implements `approveAllUnstaged(ReviewLayerSelection)` and
`unapproveAllStaged(ReviewLayerSelection)`, invoked by those stock Diff controls.
`ReviewLayerSelection` carries only `expectedRevision`, never a caller-supplied
path list, patch, layer/action selector or authority.

Approve takes one Unstaged hunk toward the working file; Unapprove reverses one
Staged hunk toward captured HEAD. The selected Environment's authorized buffered
process service performs every observation and mutation. The working file, HEAD,
branches, Task baseline, and unrelated staged/unstaged changes are not written.
Git creates the resulting blob and updates its index using its own index lock;
the index, not an ADELE database, is approval state. A subsequent layered snapshot
shows the new Staged/Unstaged split. A commit consumes the old staged selection.

Approve File applies every current index-to-working text hunk of one eligible
tracked modified file in a single index mutation. With HEAD A, index B and working
C, the result is index C, preserving the previously staged A-to-B changes.
Unapprove File reverses every HEAD-to-index hunk in one mutation, restoring index
A while working C remains untouched. Refreshed Unstaged may therefore include both
formerly staged and already unstaged changes. No per-hunk mutation loop or separate
approval database is used. Approve File also stages the complete exact bytes of a
nonignored untracked regular UTF-8 text file absent from HEAD and the index.
Unapprove File reverses a staged addition, removing its stage-0 entry without
deleting or rewriting the working file. This includes manually staged additions,
empty files (without fake hunks), and staged content B with later working content C:
Unapprove removes B and preserves C. Approving the additional B-to-C working
modification as a complete file remains excluded.

Approve File also stages the complete deletion of an eligible tracked regular
text file that is absent from the working tree. With HEAD A, index B and working
absence, approval removes the index entry, superseding any previously staged A-to-B
modification. Unapprove File reverses the resulting HEAD-to-absence comparison,
restoring the exact HEAD A mode and blob to stage 0, not the earlier B. Neither
operation restores, deletes or rewrites a working file: the path remains absent.
Empty tracked files use the same membership transitions without invented hunks.
Staged deletions followed by working recreation, newly staged additions followed
by deletion, file/directory replacements, unsafe ancestors and nested repositories
remain read-only. Partial hunk approval of additions or deletions is not supported.

Approve All Unstaged applies every reported change in the selected Environment's
Unstaged layer; Unapprove All Staged reverses every reported change in its Staged
layer. Both use the complete-file modification/addition/deletion semantics above,
including empty files and partially staged modifications. "All" is confined to
the selected Environment source scope, not the whole repository when that source
is nested. It never means only the eligible subset of reported changes. Committed
changes and conflicts cannot be selected; Task uses its separate uncommitted layers,
not a baseline-to-working-tree comparison. Ignored files remain outside Git's ordinary
Unstaged set. Committed work has no remaining staged approval to reverse, and
unmerged entries have no resolved stage-0 approval state.

Snapshot `ChangedFile.reviewRevision` is present only for ordinary tracked regular
text modifications with actual bounded hunks and an inspectable regular working
file. Unsupported entries remain visible without a revision: committed changes,
untracked/whole-file additions or deletions, unmerged entries, binary or invalid
UTF-8, oversized/uninspectable sides, symlinks/gitlinks, unsupported index flags,
mode changes, and content-conversion/custom-diff configurations. Plain CRLF is
byte-preserved when conversion is disabled; configured conversion remains
unsupported. The handler conservatively excludes control-character filenames (including
tabs/newlines) even though direct Git feasibility tests establish quoted support.
Spaces, quotes, backslashes, Unicode, punctuation and leading dashes remain literal.

`ChangedFile.fileReviewRevision` independently identifies eligible complete-file
operations. The complete displayed comparison must be safely inspected and bounded,
with at least one actual text hunk and an existing regular HEAD entry matching the
index mode for modifications. Complete additions instead require absence from HEAD,
either verified nonignored untracked membership or one ordinary resolved stage-0
entry, and a bounded regular text working file with supported matching mode. Empty
additions need no hunks. Intent-to-add, ignored paths, nested repositories, and
ancestor/descendant index or HEAD replacements have no addition action. Newly staged
additions with further working edits have no Unstaged file action, without
reinterpreting existing modification-hunk eligibility. Complete deletions instead
require explicit working-path absence, compatible regular HEAD/index modes,
bounded validated text blobs and no ancestor/descendant index or HEAD collision.
Approval requires one ordinary stage-0 entry; reversal requires complete index
absence, including conflict stages, and uses the captured HEAD entry. Deletions
never receive hunk revisions, and empty deletions need no hunks. The aggregate patch must fit stdin
and its resulting index blob must fit the existing file bound. A file can retain
`reviewRevision` for valid hunk actions while the aggregate patch is too large for
`fileReviewRevision`. Neither revision grants authority.

`ChangeSetSnapshot.layerReviewRevision` is a required nullable field, advertised
only for a nonempty layer when every reported file has a `fileReviewRevision` and
the combined patch, resulting index membership and verification work fit the shared
bounds. Any unsupported reported file or aggregate-limit failure makes the whole
layer unavailable rather than skipping that file or truncating the patch. Individual
file and hunk revisions remain intact when only layer eligibility fails. Empty and
Committed snapshots have no layer revision. Any conflict within the selected source
scope disables both Uncommitted/Task layer revisions and standalone Unstaged layer
review. Out-of-scope conflicts do not disable layer review; their raw index records
must remain unchanged.

The deterministic SHA-256 revision binds the layer, captured Session and
Environment identities, discovered repository/source scope, literal path, HEAD
commit and symbolic ref, the observed index inventory, selected stage-0 mode/object,
raw working-content identity and mode, attributes and relevant configuration. Both
layers conservatively bind working content and HEAD. It is a stale-state precondition,
not a credential; no backend-global approval-state map is retained. Other Sessions
or Environments, the opposite layer, changed branches/index/files, and
already-consumed selections cannot reuse it. Whole-file revisions use distinct
modification/addition/deletion domains from hunk revisions, binding index presence or absence
as well as the same observed identities and state. Untracked content identity comes
from independently verified bounded raw bytes, never a content-cleaning filter.
The `git-file-deletion-review-v1` domain additionally binds the exact HEAD entry
and the explicit working-absence proof rather than a fabricated empty-file hash.
The separate `git-layer-review-v1` domain derives a deterministic SHA-256 revision
from the selected layer and its complete ordered membership and file revisions.
It also binds the selected regular files' already-observed metadata, including
identity and modification/change times. It retains the file revisions' captured
identity, repository, HEAD, index and working-state preconditions without a second
approval-state store. A file/hunk revision or
opposite-layer revision is not a layer selection, and changes to membership or any
constituent revision require a fresh snapshot.

Deletion eligibility and mutation verification share one narrowly scoped absence
probe through the captured buffered-process grant. Fixed shell code receives only
literal argv and walks parents one component at a time. GNU `stat` does not
dereference each candidate; only verified directories are entered with physical
`cd -P`, and their canonical paths and exact metadata must agree before any
descendant inspection. This pins the current directory against later ancestor
replacement. A symlink, special file, leaf directory, recreated regular file or
nested `.git` marker is not absence. Only GNU stat's C-locale ENOENT diagnostic
for a single operand is accepted as a missing component; permission, I/O, process,
framing and other errors fail closed. A genuinely missing parent safely proves
descendant absence without traversing the missing suffix. Existing parent metadata
and the first missing component form a bounded NUL-framed proof, rechecked before
snapshot publication and around mutation. These physical-path observations cannot
provide an atomic no-follow filesystem transaction against hostile concurrent
renames or substitutions; they reject observed mismatches rather than continuing
into a different tree. No generic Environment filesystem service is added.

The handler reuses portable discovery, bounded inventories, parsers, classification
and consistency checks, focusing content inspection on the selected validated path
for hunk/file actions or inspecting the complete selected layer for layer actions.
Whole-layer review uses one captured operation, not repeated file-handler invocations.
It never accepts patch text. It reconstructs the exact expected index bytes from
the selected parsed hunk or verifies each complete comparison's expected blob, and
quotes repository-relative patch paths derived from
the captured source prefix and inventory, not caller-supplied patch headers.
It then executes, through the existing sanitized wrapper:

```text
-c apply.ignoreWhitespace=false apply --cached --whitespace=nowarn
--no-ignore-whitespace -p1 [--reverse] [--unidiff-zero] --check -- -
-c apply.ignoreWhitespace=false apply --cached --whitespace=nowarn
--no-ignore-whitespace -p1 [--reverse] [--unidiff-zero] -- -
```

`--reverse` is used only for Unapprove; `--unidiff-zero` is used when a selected
hunk has no context lines. Complete-file patches have one file header and retain
every original comparison hunk's old/new coordinates, including line-count shifts
from earlier hunks; they do not concatenate independently reanchored hunk patches.
Addition patches carry `new file mode` (`100644` or `100755`), a full-width zero old
OID, the exact new blob OID, and `/dev/null` as the old side. Empty additions use a
mode-only patch; reversal removes membership rather than creating an empty entry.
Deletion patches instead carry `deleted file mode`, the captured index blob OID
for approval or HEAD blob OID for unapproval, a full-width zero new OID, and
`/dev/null` as the new side. They retain complete deletion hunks and exact
no-final-newline markers; empty deletions use mode-only metadata. Applying the
HEAD-derived deletion patch with `--reverse` recreates only index membership,
never the working file. SHA-1 and SHA-256 object identities retain their full widths.
Whole-layer review combines the complete per-file patches into one bounded stdin
payload, preserving each file's headers, coordinates, modes, OIDs and newline markers.
It runs one combined cached `--check`, then exactly one cached apply or reverse
write. It does not apply a valid prefix, loop over file writes, use `git add` or
`reset`, or stage through a temporary index.
Both check and write receive bounded backend-derived stdin. Each successful action
issues exactly one index-mutating apply request. The wrapper retains literal argv,
`env -i`, pinned repository routing, no optional locks/replacements/lazy fetch,
fixed locale/PATH, no transports, and disabled hooks/fsmonitor/external diff.
Observation commands retain `--no-filters`, `--no-ext-diff` and `--no-textconv`
where applicable. Real Git tests use executable positive-control traps for clean
and process filters, external diff, textconv, hooks and fsmonitor. None runs during
the tested apply/check/reverse operations, even under hostile attributes.

Preflight revalidates the selected state after `--check`. Postflight verifies exact
index membership, stage-0 mode/object identity and hash-checked created blob bytes
for every selected path, or complete selected-entry absence after removal. It also
preserves the raw unrelated index stage/debug records, including flags, stat records,
conflict sides and entries outside a nested selected source scope, rather than
comparing only a collapsed display map. Verification includes selected working
bytes/metadata and parents or the explicit working-absence proof, HEAD/ref,
attributes/configuration, repository scope and captured
identity. Git's lock prevents concurrent index writers from corrupting the index,
but neither `--check` nor a text patch's full-index OID header is compare-and-swap.
An external writer can race between checks and apply, or after verification.
There is no atomic filesystem/index transaction. A raced postcondition or lost
acknowledgement is uncertain, never fabricated success or permission to roll back
unrelated index state. The handler never rolls back an attempted mutation.

One thirty-second operation envelope includes preflight, construction, check,
write and verification, with the existing ten-second process cap and aggregate
snapshot limits shared across all selected files, not renewed per file or layer.
The handler reserves known verification traffic and process count
before the write. File sides retain the 1 MiB limit, hunk lines the 8,192 bound,
stdin the existing 1 MiB bound, inventory 4,096 entries, aggregate traffic 8 MiB,
stdout 2 MiB and stderr 64 KiB. Resource exhaustion before the write is rejection;
exhaustion or transport/deadline/revocation after attempting it is uncertain. No
generic transport limit is raised, no clean file gets a separate process, and no
mutation is retried automatically.
Absence requests, their transported proofs and retained parent-path text share
these same budgets. Index insertion by addition approval or deletion unapproval
also reserves inventory and output growth before advertising eligibility, including
the combined growth of all insertions in a layer.
Layer eligibility conservatively estimates combined patch size, index growth and
working-inventory output growth, plus pre/post-verification traffic and process
counts from existing observations; deriving
the layer revision adds no scan or subprocess. Whole-layer mutations additionally
support at most 16 changed files. Sequential complete-operation measurements motivate
this conservative cap, leaving headroom for both verification passes inside the
thirty-second envelope; it is not a timing guarantee for arbitrary providers or
repository layouts. Larger layers remain inspectable with individual file/hunk
actions, but no layer revision. All changed entries still share the 256-entry
snapshot limit and 4,096-process ceiling, without renewing budgets per file.

For actionable nested-source snapshots, the review index inventory is bounded
across the whole repository so unrelated entries outside the displayed scope are
also bound and verified. Unstaged file eligibility lazily observes the captured
HEAD tree; neither check adds per-clean-file subprocesses.

Declared `ReviewApprovalFailure` codes are `invalid_selection`, `stale_selection`,
`unsupported_target`, `hunk_unavailable`, `inspection_failed`, `operation_timeout`,
`mutation_failed`, and `outcome_uncertain`. The first six reject before mutation;
`mutation_failed` additionally requires Git's nonzero result and verified unchanged
state. `outcome_uncertain` requires a fresh snapshot before another action.
Transport retirement can suppress the failure response itself and never implies
rollback. Success is returned only after the intended index result is confirmed.

`git_hunk_apply_feasibility_test.dart` establishes single- and multi-hunk Git apply,
complete-file and combined multi-file all-or-none rejection and the mechanism's
non-CAS limits; `git_portable_review_approval_test.dart` exercises the production
handler, exact per-path object/working-byte evidence, mixed multi-file operations,
aggregate eligibility, stale targets, races and uncertainty.
Non-gating file diagnostics report complete approval and
unapproval process counts and elapsed times for one, several and many hunks;
process-count assertions retain one write regardless of hunk count.
Representative Linux whole-layer diagnostics, including fresh inspection,
construction, check, one write and full verification, measured:

| Layer | Approve requests / elapsed | Unapprove requests / elapsed |
| --- | --- | --- |
| Two modified files | 100 / 3.079 s | 94 / 2.876 s |
| Six mixed files, including empty additions/deletions | 173 / 5.362 s | 160 / 5.293 s |
| Sixteen modified files | 352 / 10.584 s | 304 / 9.875 s |
| Four files rejected by combined patch bounds | 70 / 2.877 s | 58 / 2.347 s |

Each admitted case uses exactly one index-writing request; rejected aggregates use
none. The 16-file cap leaves measured headroom rather than promising that the
256-entry inspection limit is whole-layer mutation capacity. CI checks deterministic
request/mutation bounds, not these host-dependent elapsed times. Clean 100/500/900-file
snapshots retain the existing batch-scaling model; revision calculation adds no requests.
The existing `prepared_portable_git_integration_test.dart` adds independent
Environment AOT, production-handler Capability AOT, and generated-client EVC proof.
Its layer selections exercise the same generated Capability without adding stock
frontend controls or a new grant.
`prepared_diff_git_integration_test.dart` exercises the production advertisement and
actual stock Diff controls against selected nonprimary Git indices, independently of
the isolated frontend state tests. Inspection and approval continue to have separate
semantic resolution and operation grants.

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
required timeouts from 1 through 1800 seconds, and a resolved cwd confined to the
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

## Buffered binary processes

The same selected provider implements the optional
`EnvironmentBufferedProcessProvider.runBufferedProcess` facet through the generated
Environment service. This is generic one-shot execution, not a Git command parser
or an alternate snapshot implementation. It uses only the selected live
Environment's process cwd resolver; it does not inspect Git index/object storage,
stage files, or infer another Environment. Unknown/non-live identities fail.
Absolute or traversing cwd inputs and symlink escapes are rejected, while a
resolved in-root directory alias follows the existing process policy.

Unlike `runForegroundProcess`, buffered execution never decodes output as text or
publishes intermediate observations. The request carries exact stdin followed by
EOF; success requires complete input delivery, the actual exit code, and complete
settlement of both concurrently read pipes. Nonzero exit is ordinary result data.
NUL, invalid UTF-8, CRLF, and other control bytes remain unchanged, and stdout and
stderr stay separate without a claimed total ordering between them.

The [public contract](../../packages/environment/README.md) uses strict canonical
Base64 strings over JSON, bounded to 1 MiB decoded stdin, 2 MiB stdout, and 256 KiB
stderr. Both transport decoding and native collection enforce the corresponding
bounds before additional payload allocation/retention. Oversized output terminates
execution with a declared failure instead of returning a truncated result. There
is no disk spool. The encoded output fits in approximately 3 MiB, comfortably
below the backend-host 8 MiB frame ceiling; runtime pipe buffers and child-process
memory are separate from these provider-owned payload bounds.

Buffered execution preserves the executable resolution, allowlisted child
environment, literal argv, and util-linux `setsid` process-group policy described
above. Its required 1..600-second deadline covers setup, spawn, input, execution,
and output settlement, not just the process leader. Failure and provider shutdown
fence publication and clean up owned processes, including late startup completion.
Termination retains the 250 ms TERM-to-KILL grace. Failure/shutdown joins cleanup
for at most one second; unresolved native startup or cleanup remains owned by its
continuation and fails explicitly rather than becoming success. Failure details
mark `cleanupIncomplete` when cleanup cannot yet be confirmed. Abrupt backend/host
termination can preempt that continuation and is not an OS-child cleanup guarantee.
The generated service retains its existing serialized unary admission: other
requests, including terminal controls, can queue behind a buffered invocation.
The execution deadline starts when the provider admits execution, not while a
request waits in that transport queue. Provider shutdown bypasses the queue; this
facet promises no parallel admission.
Only Linux x64 is supported; other platforms fail explicitly. Ordinary process
groups cannot contain deliberately daemonized descendants, and cwd confinement is
not an OS sandbox or protection against every same-user pathname replacement race.

This facet adds no operation to `AuthorizedEnvironmentReadService` or the existing
authorized streamed process service. Independent Capability backends require the
separate explicit Environment-bound buffered-process grant described by the public
Environment contract. Interpreted consumers invoke semantic Capabilities, not a
generic process API. The stock Git ChangeSetSource uses that explicit grant for
all three snapshot scopes; it neither inherits read authority nor exposes process
execution directly to Diff.

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
from the prepared native terminal fixture. Other operating systems remain
unvalidated. Stock [Terminal](../terminal/README.md) owns the frontend and controls.

## Current limitations

Stock snapshots use the selected Environment's authorized buffered processes,
including independent providers that supply the documented executable prerequisites.
Task comparison requires the selected Environment's retained Git-owned SQL anchor,
never caller-selected history. Snapshot operations remain read-only. The separate,
authorized review handler and stock Diff controls support individual hunks and
complete tracked regular text modifications. Addition, deletion, untracked-file,
binary, type-replacement, conflict, whole-layer and commit actions remain outside
review mutation. This does not change execution-policy or model-tool approval.
The detailed platform, confinement, process, and snapshot limits above still apply;
the plugin name supplies no additional portability or sandboxing guarantee.
