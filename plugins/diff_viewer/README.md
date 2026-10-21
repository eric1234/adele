# Diff Viewer

Diff Viewer is a frontend-only stock plugin with a shared, pure-Dart public
contract. It contributes one `Diff` Main Content pane for any canonical
Session, at order 200 between stock Chat and Source. It has no backend and does
not require Chat, a strategy frontend, or a Run.

## Ownership

`packages/contract/lib/diff_viewer_contract.dart` owns
`ChangeSetSourceService.snapshotUnstaged()`, `snapshotUncommitted()`,
`snapshotTaskChanges()`, and the structured immutable snapshot values. All methods
take no arguments: Session and Environment authority is captured by the host, not
supplied in a request payload.
The native library exports `changeSetSourceCapability`
(`adele.diff.change-set-source`, major 1);
the generator owns `changeSetSourceServiceId` and native/eval transport.

Snapshots contain changed files, explicit change/content status, numeric hunk
ranges, and context/addition/deletion lines with no-newline markers. They are not
opaque patches. All DTO list constructors copy into unmodifiable lists. Bounded
semantic strings keep the contract compatible with the pinned evaluator.
`ChangeSetFailure` has `code`, `message`, and the generator-required `details`
map, defaulting to empty. Native clients reconstruct declared failures; the
frontend's safe settlement path shows a local error state, not native diagnostics.

`snapshotUnstaged()` returns the existing `ChangeSetSnapshot`.
`snapshotUncommitted()` returns `UncommittedChangeSetSnapshot` with separate
`staged` and `unstaged` `ChangeSetSnapshot` values and an immutable `conflicts`
list of `ChangedFile`. Uncommitted is a layered union, not a net comparison:
HEAD A, index B, working file A produces both staged A-to-B and unstaged B-to-A
hunks for the same path. Unresolved paths belong to `conflicts`, not ordinary
staged or unstaged entries. The original Unstaged operation retains its conflict
placeholders. The service/Capability identities remain unchanged; native and EVC
artifacts must be rebuilt together under the
[pre-release policy](../../docs/architecture/contracts-and-capabilities.md#transport-version-policy).

`snapshotTaskChanges()` returns `TaskChangeSetSnapshot`, composing `committed`
(`ChangeSetSnapshot`) and `uncommitted` (`UncommittedChangeSetSnapshot`). Committed
changes are the net change from the Git-owned retained Environment baseline to
current committed state, not a history of individual commits. The stock Git
provider uses the exact baseline established for the selected Environment, which
can differ between Environments within one Task. Committed, staged, unstaged, and
conflict entries stay separate; a path may occur in multiple layers even when its
working content matches the baseline. No Git identities or baseline selector enter
the public contract.

The [stock Git plugin](../git/README.md#changesetsource)
implements this deliberately public contract through authorized buffered processes
on the exact selected Environment, including independent compatible providers.
Git owns comparison/index semantics and inspection bounds; the selected Environment
provider owns process execution, and the host owns authorization and exact bindings.
The Diff frontend imports neither Git nor application/native-host implementation.
Other providers can implement the same contract without becoming dependencies
of the frontend.

## Review Approval

The public contract separately defines `ReviewApprovalHandlerService`:
`approveHunk(ReviewHunkSelection)`, `unapproveHunk(ReviewHunkSelection)`,
`approveFile(ReviewFileSelection)` and `unapproveFile(ReviewFileSelection)` return
`Future<void>`. Its `reviewApprovalCapability` is `adele.diff.review-approval`,
major 1; the generated service is `diff.reviewApprovalHandler`. These mutations
are not methods of the read-only `ChangeSetSourceService`.

`ReviewHunkSelection` contains only `relativePath`, zero-based `hunkIndex`, and
`expectedRevision`. Bounds are 4,096 UTF-16 path units, hunk indices 0 through
8,191, and 1 through 256 printable ASCII revision characters. Paths must be
relative with no empty, dot, parent, or `.git` component and no NUL. Native
construction and generated request decoding enforce these bounds. No field
selects authority, a repository, a branch, a baseline, process arguments, or patch
text. The method selects the layer: Approve consumes an Unstaged revision;
Unapprove consumes a Staged revision.

`ReviewFileSelection` contains only `relativePath` and `expectedRevision`, with
the same path/revision bounds. It is a distinct value, not a sentinel hunk index.
Approve File consumes an Unstaged complete-file revision; Unapprove File consumes
a Staged complete-file revision.

`ChangedFile.reviewRevision` is nullable opaque snapshot data, not an authority
token. A null revision means there is no supported hunk action for that entry.
It is a required nullable wire field under the coherent generated-schema policy;
native and EVC consumers must be rebuilt together. Git advertises revisions only
for its supported tracked regular text modifications with actual bounded hunks.
Committed changes, conflicts, untracked or whole-file additions/deletions,
binary/invalid/oversized/uninspectable content, symlinks/gitlinks, unsupported
modes/flags/conversions, mode-only changes, and control-character filenames have
no revision. These entries remain visible in snapshots.

`ChangedFile.fileReviewRevision` separately advertises eligibility of the complete
displayed file modification. It is another required nullable wire field, with a
distinct revision domain. Whole-file eligibility requires complete, safely inspected
tracked regular UTF-8 text modifications, an actual changed hunk, and a complete
patch and resulting index blob within the provider's bounds. An aggregate patch
can be too large while every individual hunk remains eligible: in that case only
`fileReviewRevision` is null. The frontend never computes either revision or infers
whole-file eligibility from rendered lines. Additions, deletions and untracked
files remain outside review mutation.

The Git handler applies one backend-derived hunk, or one complete multi-hunk file
patch, to the index; Unapprove reverses that selected staged comparison. Each
action uses exactly one index-mutating Git operation, never a per-hunk write loop.
Approve File preserves already staged changes while incorporating all current
unstaged text hunks. Unapprove File restores that file's index content to HEAD,
leaving all working changes visible in the refreshed Unstaged layer. Neither writes
working files, HEAD or the retained Task baseline. Git's
index remains the approval source of truth; there is no approval database.
Changed revisions and consumed selections require a fresh snapshot, not a
different hunk chosen at the old index. `ReviewApprovalFailure` declares stable
pre-mutation rejection codes, `mutation_failed` for a verified unchanged index
after Git rejects a write, and `outcome_uncertain` when an attempted effect cannot
be confirmed. Lost transport or retirement can prevent any semantic response;
consumers must not infer rollback or automatically retry. See the
[Git handler](../git/README.md#reviewapprovalhandler) for exact limits and races.

Stock Git advertises this handler independently of ChangeSetSource. The compiled
Diff pane resolves it through the provider-neutral contextual Capability bridge,
not a Git provider ID. Missing, ambiguous, denied, retired or incompatible approval
access leaves snapshots, manual Refresh and independent Source navigation usable.
It never substitutes another provider or Environment behind a captured handle.

## Presentation

`packages/frontend/lib/main.dart` supplies `initializeDiff()` and
`buildDiffPane()`. Initialization opens only local pane ID `diff`; reinitializing
does not duplicate it. The descriptor declares `environmentBufferedProcessCapabilities`
for both `adele.diff.change-set-source` v1 and `adele.diff.review-approval` v1,
separately, and `canRequestSourceDisplay` for pane-only requests
through the public source-display point. There is no context-free capability
grant, own-backend service, direct file access, process, terminal, editor, or
execution grant. The host grants buffered-process access only to the selected
Capability backend for each invocation, never to the interpreted pane.

The mounted pane initially selects **Unstaged changes**. A minimal selector also
offers **Uncommitted changes** and **Task / Branch** without persisting a preference.
Refresh occupies a separate row so scope controls remain usable in narrow panes.
Each scope calls its specific generated method; layered scopes each use one
contextual operation, not independent frontend requests concatenated together.
Task's lazy rows distinguish **Committed changes**, **Staged changes**,
**Unstaged changes**, and **Conflicts**, retaining paths and hunks in each layer.
Task is clean only when all four categories are empty; committed work stays visible
after Uncommitted becomes clean. Committed entries have no staging or Unapprove
affordance.

The mounted pane requests a snapshot immediately. Each scope change, Refresh or
Retry performs fresh contextual resolution, then invokes the typed generated
client over `EnvironmentCapabilityRequestChannel` through
`settleEnvironmentCapabilityOperation`. Each snapshot releases its provider
handle. Scope changes, superseding refresh, departure preparation, and disposal
invalidate the local request revision and release pending access; a late resolution
releases its unused handle and an older result cannot replace a newer presentation.
Departure does not wait for independently owned backend work. If another pane refuses
navigation, Diff remains manually refreshable.

Eligible file headers offer **Approve File** in Unstaged layers and
**Unapprove File** in Staged layers, retaining the literal typed path and exact
`fileReviewRevision` in `ReviewFileSelection`. Actions sit immediately below the
header in a narrow-safe column, preserving the independent **Open in Source** action.
Eligible hunk headers continue to offer **Approve** in Unstaged layers and
**Unapprove** in Staged layers. Uncommitted and Task retain both actions in their
respective layers; Committed and Conflicts remain read-only. Each hunk action
retains the original typed
`ReviewHunkSelection` with the literal file path, zero-based index in that file's
displayed layer, and exact opaque `reviewRevision`. This identity is separate from
rendered labels and Source paths. File eligibility is independent of individual
hunk eligibility. A committed entry stays read-only even when the same path has an
actionable staged or unstaged entry.

Only a direct button invocation starts a mutation. One pane-wide pending operation
suppresses duplicate and all other file/hunk submissions while showing neutral
pending text.
Approval handles capture eligibility, not a standing process grant: every generated
request receives fresh host admission. Scope changes, Refresh, departure and disposal
discard old selections and release retained access. Late responses cannot refresh a
superseded pane, and release does not cancel or roll back an already-started Git write.
Snapshots requested while a review is pending remain read-only even if the old
request settles first; another explicit Refresh is required before reviewing them.
Semantic settlement is not proof that a revoked process has stopped.

Confirmed success triggers one fresh snapshot of the selected scope; rows are never
optimistically moved between layers. If that read fails, Retry repeats only the read,
not the confirmed mutation. Unconfirmed settlement shows only
`Review change not confirmed. Refresh before trying again.` and disables the old
selections until a fresh snapshot. Native exception details and process diagnostics
do not cross the interpreted settlement boundary. Failure does not establish that
the index stayed unchanged, and writes are never automatically retried.

The pane distinguishes loading, unavailable, clean, and error states. Unified
rows are rendered lazily with file names, change kinds, hunk ranges, both line
numbers, addition/deletion prefixes and no-newline markers. Binary, conflicted,
oversized, and unsupported content remains explicit rather than an empty text
diff. An `unsupported` change kind can indicate uninspected change state, not a
confirmed modification: for example a provider may decline recursive submodule
inspection and supply that explanation in `detail`. Such a snapshot is not a
claim that the entire Environment was inspected or clean.

Eligible unstaged current-working-file headers offer **Open in Source** through
the public
[`main_content_bridge.dart` source-display API](../../packages/ui/README.md#source-file-display),
not a Source implementation import. Eligibility requires existing text content:
`contentStatus: 'text'` with `added`, `modified`, or a text-bearing `typeChanged`
change. Deleted, binary, oversized, unsupported, conflicted, and type-only entries
without text offer no action. The raw `relativePath` is retained separately from
the displayed header and forwarded unchanged, including spaces and punctuation;
Diff neither parses its label nor normalizes the path. Committed, staged, and
conflict headers offer no Source action: Source opens the actual working file,
not a historical baseline/commit or index blob. A path occurring in multiple
layers can still open from its unstaged header.

One pane-wide pending request suppresses duplicate openings. Missing or ambiguous
Source providers remain explicit, and failed display shows a safe, nonfatal error
without discarding the Diff. Refresh does not open Source; refresh/departure
invalidate old callbacks and feedback, not an admitted provider operation.
Source owns document normalization, deduplication, dirty text, and native undo
through its [existing document model](../source_editor/README.md#ownership).
The host owns [captured authority and late presentation fencing](../../docs/architecture/plugin-system.md#main-content-source-display).
Index-only approval does not change Source working-file bytes, dirty buffers or undo.
There is no automatic refresh watcher, addition/deletion staging, whole-layer
action, discard/revert, editing within Diff, commit, review feedback submission,
or side-by-side mode.

## Preparation And Tests

`app/tool/diff_viewer_frontend_compiler.dart` compiles the actual frontend source
with a generated eval projection of the same authored contract. Its build harness
is `app/tool/compile_diff_viewer_frontend.dart`, selected by the maintained
frontend artifact builder using `ADELE_DIFF_VIEWER_FRONTEND_OUTPUT`. Stock
descriptors and frontend-only installation publication live in `tools/`.

Run the maintained targets from the repository root with the
[pinned toolchain](../../docs/development/toolchain.md):

```sh
dart tools/adele.dart test --target diff_viewer_contract
dart tools/adele.dart test --target diff_viewer_frontend
dart tools/adele.dart test --target adele_tools
```

The contract suite checks native and interpreted nested transport for all scopes,
strict decoding, empty request payloads, declared failures, and list immutability.
The frontend suite compiles and mounts real EVC with generated native/eval codecs
through a test-only contextual port, covering states, manual recovery, handle
cleanup, held operation races, scope switching, separate
committed/staged/unstaged/conflict rows, cancellation,
selected-scope Refresh/Retry, lazy display, and Source action eligibility, raw
paths, pending suppression, safe failures, and stale callbacks. Its separate review
dispatcher covers typed hunk indices and file selections/revisions, independent
complete-file eligibility, narrow headers, layer-specific actions, unavailable
approval, single pending mutation, success refresh, unconfirmed failures and lifecycle
fencing. It does not substitute for authority validation:
`app/test/main_content_source_display_test.dart` owns focused native and compiled
consumer authority checks. `app/test/prepared_diff_git_integration_test.dart` owns
real stock Git AOT plus independently prepared Diff and Source EVC through normal
catalog/Main Content hosting, including committed-only work, exact independently
established baselines, staged-only and layered partial/cancelling changes,
source confinement, selected-scope Refresh after commits, canonical
nonprimary content, deduplication, dirty text/undo, focus, and gated
retirement/navigation. Hunk and atomic file mutation acceptance checks real selected
index objects, unchanged working bytes and HEAD, nonprimary isolation, stale selections, lock
rejection and retirement after an index effect. That cross-plugin suite requires
the native CodeForge library; the isolated Diff frontend suite does not.
The existing Source host suite remains the owner of Source document/operation
behavior. See [focused Diff checks](../../docs/development/testing.md#focused-diff-checks)
for prerequisites and test ownership, not recorded passing outcomes.

Global boundaries belong to the [plugin architecture](../../docs/architecture/plugin-system.md),
[contracts and capabilities](../../docs/architecture/contracts-and-capabilities.md),
and [dependency rules](../../docs/architecture/dependency-rules.md).
