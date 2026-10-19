# Git

The stock Git plugin (`dev.adele.plugin.git`, display name `Git`) owns Git-specific
behavior through public extension contracts. Its `git_backend` package supplies
both the Git Worktree Environment provider and the Diff-owned `ChangeSetSource`
Capability implementation; Git is not intrinsic to core Task or Environment
semantics. The plugin has no frontend. Review presentation belongs to
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

### Restoration and moves

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
Its separate `dev.adele.git.change-set-source` provider is explicitly associated
with this generation's actual Git Worktree Environment provider in the same backend.
The contextual dispatcher uses `AuthorizedEnvironmentReadService.authority()`
to select only an existing
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
Custom conversion/diff attributes, including legacy `crlf` and `crlf=input`, and
effective `core.autocrlf`/`core.eol` conversion are unsupported placeholders;
unspecified or disabled `-crlf` alone does not require conversion. `-diff`
attributes are binary placeholders. Binary data, invalid
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
Both snapshot implementations preserve Git's distinction between implicit boolean
true and explicitly empty false, alongside the ordinary true/yes/on/1 and
false/no/off/0 spellings for `core.filemode` and `core.autocrlf`.

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
and stock Git AOT, checks both ready advertisements and their exact association,
and exercises generated contextual requests for independent live Environments.
The `git_backend` maintained target discovers both files.

<a id="portable-unstaged-inspection"></a>

### Portable change inspection

`GitPortableUnstagedSnapshotService` supplies `snapshotUnstaged()`,
`snapshotUncommitted()` and `snapshotTaskChanges()` as a separate implementation.
All reuse one operation's index-to-working-tree inspection, including nonignored untracked
additions; Uncommitted also returns captured HEAD-to-index changes and a separate
conflict collection, not a net HEAD-to-working-tree diff. It
accepts `AuthorizedEnvironmentBufferedProcessService`, optional reduced
operation limits, and an optional trusted `GitTaskComparisonAnchor`. It does not
accept Session/Environment IDs or repository paths, import the Worktree provider,
resolve live provider objects, or perform host-local
filesystem/process I/O. The existing stock `git_backend.dart` advertisement,
provider ID, association, read grant, and all three scope methods remain unchanged.
The portable service is not advertised as another stock provider. Production stock
Diff still uses the Worktree-specific implementation described above, including its
existing retained Worktree baseline and provider-state v1. Portable baseline
establishment, durable ownership/persistence, migration and production activation
remain deferred; no staging, approvals, or feedback mutation is implemented.

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

The current independent integration fixture provisions this fixed anchor inside
the Git Capability backend before invocation. It demonstrates comparison semantics,
not durable per-Environment baseline ownership across arbitrary Sessions. A future
Git-owned lifecycle must establish, associate, retain and restore trusted baselines
before a separately reviewed production cutover; core Task/Session/Environment
values and the public Diff contract acquire no Git metadata in this implementation.

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
`head` or `stat` requests. Oversized hashing remains subject to the separate
observed-size verification budget, and unverifiable files remain explicit
oversized entries with unknown change state. A failed batch rejects the whole
snapshot, even if Git or stat produced a valid prefix of output.

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
omit an index header; its legacy strict default is unchanged. Binary/invalid UTF-8,
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
an 8 MiB aggregate byte budget, 8,192 hunk lines, a conservative 6 MiB DTO
budget, and 4,096 process requests. The aggregate budget counts all transported
input/output plus observed small-file bytes hashed outside transport, so batching
does not bypass the content-work limit. Retained parent-path text is independently
capped at `totalBytes` UTF-16 code units before metadata execution. Oversized
verification admits at most 16 MiB per observed file and 64 MiB total observed
sizes. Commands have a ten-second deadline within
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
assertions rather than wall-clock CI assertions. Production activation remains
deferred; batching does not alter the Environment's isolation guarantees.

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
AOT backend that runs real processes, a separate AOT adapter over this production
service, and a compiled EVC consumer of the generated Diff contract. It checks
nonprimary Session binding, typed committed/staged/unstaged paths and hunks,
conflict entries, one semantic invocation per request, clean-repository batch
scaling, explicit process
declarations and exact retirement/departure fencing. Neither backend imports the
other's implementation. The stock Diff frontend is not changed by this proof.

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
generic process API. The stock Git ChangeSetSource advertisement remains unchanged;
the portable Unstaged service above consumes that separate grant only when supplied.

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

The broader plugin identity does not make its stock `ChangeSetSource`
implementation portable across arbitrary Environment providers. It still resolves
only this backend generation's associated live `WorktreeEnvironment`; it does not
use the generic buffered-process grant to inspect another provider. The separately
tested portable Unstaged service is not yet selected by production Diff.
Task / Branch review still obtains its baseline and branch from the Environment provider's
retained state, not a core Task baseline or caller-selected comparison.

Change snapshots are read-only. Staging, unstaging, review approval/unapproval,
commit operations, and review-triggered mutation are not implemented. This does
not change the host's existing execution-policy and tool-approval boundaries.
The detailed platform, confinement, process, and snapshot limits above still apply;
the plugin name supplies no additional portability or sandboxing guarantee.
