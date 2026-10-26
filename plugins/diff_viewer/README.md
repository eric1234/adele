# Diff Viewer

Diff Viewer is a stock plugin with a shared, pure-Dart public contract, an
independent pending-comment storage backend, and one `Diff` Main Content pane for
any canonical Session, at order 200 between stock Chat and Source. It does not
require Chat, a strategy frontend, or a Run. The current pane does not acquire the
draft backend: missing or failed comment storage leaves change snapshots, review
approval, and Source navigation available through their existing providers.

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
`approveFile(ReviewFileSelection)`, `unapproveFile(ReviewFileSelection)`,
`approveAllUnstaged(ReviewLayerSelection)` and
`unapproveAllStaged(ReviewLayerSelection)` return `Future<void>`. Its unchanged
`reviewApprovalCapability` is `adele.diff.review-approval`, major 1; the generated
service is `diff.reviewApprovalHandler`. These mutations are not methods of the
read-only `ChangeSetSourceService`.

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

`ReviewLayerSelection` contains only `expectedRevision`, with the same printable
ASCII revision bound. It carries no paths, hunk indices, layer/action selector,
patch or authority fields. The method selects the complete Unstaged or Staged
layer, not an arbitrary subset of files. Committed changes and conflicts cannot
be selected by either method.

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
displayed file change. It is another required nullable wire field, with a distinct
revision domain. Whole-file modification eligibility requires complete, safely
inspected tracked regular UTF-8 text modifications, an actual changed hunk, and a
complete patch and resulting index blob within the provider's bounds. An aggregate
patch can be too large while every individual hunk remains eligible: in that case
`fileReviewRevision` is null while `reviewRevision` remains available.

The same file field can certify a complete new regular UTF-8 text file or a
complete tracked regular UTF-8 text deletion: an Unstaged `added` or `deleted`
entry offers **Approve File**, and a Staged entry offers **Unapprove File**.
Empty files are eligible when certified, even with no displayed hunks. Additions
and deletions have only file actions, never hunk Approve/Unapprove, even if a
provider supplies `reviewRevision`. The frontend never computes either revision
or infers eligibility from rendered lines, file size, or a change-kind label
alone. A null file revision leaves the entry read-only. Conflicted, nontext and
unsupported entries remain outside review mutation. Exact eligibility and limits,
including working-path absence proof for deletions, belong to the
[Git handler](../git/README.md#reviewapprovalhandler).

`ChangeSetSnapshot.layerReviewRevision` is a separate required nullable wire field
for the complete displayed layer. It is opaque freshness data, not authority or
an aggregation performed by the frontend. Stock Git certifies a nonempty layer only
when every reported change within the selected Environment source scope has
complete-file eligibility and the combined operation fits the shared bounds.
An unsupported entry or aggregate-limit failure withholds the layer revision,
never narrows the action to an eligible subset. Individual file and hunk revisions
remain independently available, including when Git's 16-file whole-layer cap is
exceeded. Committed snapshots and empty layers have no layer
revision; an in-scope conflict disables both Uncommitted/Task layer revisions and
the standalone Unstaged layer revision. Native and EVC artifacts must be rebuilt
together for this required nullable field, just as for the existing file revisions.

For hunk and file actions, the Git handler applies one backend-derived hunk or one
complete file patch to the index; Unapprove reverses that selected staged comparison.
Each action uses exactly one index-mutating Git operation, never a per-hunk write loop.
For tracked modifications, Approve File preserves already staged changes while
incorporating all current unstaged text hunks, and Unapprove File restores that
file's index content to HEAD. For a certified new file, Approve File creates its
complete index entry; Unapprove File removes the staged addition from the index
without deleting the working file. A successful Unapprove therefore leaves the
new file visible again as an Unstaged addition after refresh, including an empty
file. Neither operation writes working files, HEAD or the retained Task baseline.
For a certified deletion, Approve File removes the complete index entry;
Unapprove File restores its exact HEAD mode and blob in the index while leaving
the working path absent. It does not recreate the working file, and the refreshed
Unstaged deletion can be reviewed again. This includes empty tracked text files.
A staged deletion followed by working-file recreation, file/directory replacements,
and other unsupported deletion states remain visible but read-only.
Whole-layer methods combine those same complete-file changes into one
backend-derived multi-file patch and use one index-mutating operation, not repeated
file actions.
The Git handler checks the combined patch and verifies every selected result and
unrelated index state under the same bounded operation and failure semantics.
Git's index remains the approval source of truth; there is no approval database.
Revisions are freshness preconditions, not invocation authority. Changed revisions
and consumed selections require a fresh snapshot, not a
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

## Pending Comments

`packages/contract/lib/review_draft.dart`, also exported by the native contract
library, owns the generated `ReviewDraftService` (`diff.reviewDraft`),
`ReviewCommentAnchor`, `PendingReviewComment`, `ReviewDraftSnapshot`, and
`ReviewDraftFailure`. It is a directly routed backend service, not an advertised
executable Capability. Its operations are:

| Method | Result |
| --- | --- |
| `snapshot(sessionId)` | Complete immutable pending collection in creation order. |
| `createComment(sessionId, anchor, text)` | Persisted new comment with independent ID, sequence and version 1. |
| `updateComment(sessionId, commentId, expectedVersion, text)` | Authoritative body-only replacement with version incremented once. |
| `deleteComment(sessionId, commentId, expectedVersion)` | Remove exactly the matching pending record. |

An anchor retains the originating `environmentId`, canonical Environment-relative
`relativePath`, typed `ReviewComparisonLayer` (unstaged, staged, committed), typed
`ReviewComparisonSide` (oldSide, newSide), inclusive `startLine`/`endLine`, opaque
`comparisonIdentity`, exact `sourceExcerpt`, and zero-based displayed `hunkIndex`
and `lineIndex`. A single-line location has equal range endpoints. Range-capable
storage does not introduce range selection. Paths retain punctuation and Unicode;
empty/absolute/drive-qualified paths, backslashes, NUL, empty, dot, parent, and
`.git` components are rejected, never normalized into another location.

The comparison identity is authored read-only source-location data, independent
of `reviewRevision`, `fileReviewRevision`, and `layerReviewRevision`. The backend
does not verify it against current files, read source, invoke Git, or materialize
an Environment. The production Git snapshot engine does not yet produce comment
comparison identities. Editing never changes the original anchor, including its
captured excerpt, when working files or selected Session/Environment change.
Environment IDs are retained data, not source-read or execution authority; there
is no absolute checkout path, Project selector, storage owner, or database path in
the service. The host validates Session membership in the current open Project.

`packages/backend/lib/diff_viewer_backend.dart` owns the current v1 SQL baseline:

| Table | Retained data |
| --- | --- |
| `adele_diff_review_sessions` | Core Session foreign key, next sequence, mutation revision, comment count and aggregate size charge. |
| `adele_diff_review_comments` | Composite Session/comment ID key, unique Session/sequence, version, ordinary columns for each anchor field, exact text and size charge; foreign key to the draft Session row. |

IDs are Session-local `comment-N` values with positive monotonic creation
sequences. Deletion retains the counter, so IDs are never reused. Identical
anchors and text create distinct comments, never deduplicated records. A fresh
snapshot queries committed SQL rather than a retained comment cache. A bounded
generation-local last-Session schema guard avoids repeated initialization during
ordinary use. No compatibility reader or migration for older development schemas
is supplied.

The AOT entrypoint binds `ProjectStorageServiceClient` through the actual
`hostInfrastructureContext`, under PluginId `dev.adele.diff-viewer`, using
`durableOrTemporary`. Durable Projects survive backend replacement and Project
close/reopen. Explicitly volatile Projects use host-owned temporary SQLite across
Session navigation and backend replacement for that live Project lifetime; close
removes that backing. Failed durable backing never falls back to temporary or
frontend/in-memory storage.

Every mutation validates before allocating a persisted identity. One host SQL
transaction conditionally updates the Session counter/revision/count/charge and
inserts, updates, or deletes the exact comment. Expected row checks and version
preconditions roll back the entire batch on failure. The backend serializes its
own mutations; independent generations additionally compete on committed header
revision and exact row-version preconditions. It never automatically retries a
losing mutation. Success is returned only after commit acknowledgement; shutdown
fences late success. Updates preserve ID, creation order, and anchor. Text keeps
Unicode, line endings, multiline content and meaningful whitespace exactly;
empty/whitespace-only bodies and malformed Unicode are rejected.

`stale_comment` rejects missing or independently edited records before writing.
`invalid_request`, `limit_exceeded`, `corrupt_state`, `storage_unavailable`, and
`backend_closed` distinguish invalid input, bounded admission, invalid retained
data, unavailable reads/schema, and closed admission. An exception after submitting
a transaction is conservatively `outcome_uncertain`, even when the host may have
rolled it back: the acknowledgement can also be lost after commit. Transport
retirement can prevent any declared response. Neither case proves rollback or a
saved comment. Consumers must obtain a fresh authoritative snapshot before an
explicit next action, not replay create/edit/delete or move to a replacement
behind an old handle.

### Snapshot Bounds

`ReviewDraftLimits` bounds the complete pending collection, not a truncated page:

| Value | Maximum |
| --- | --- |
| Comments per Session | 128 |
| Comment text | 8,192 UTF-16 code units |
| Source excerpt / relative path | 4,096 UTF-16 code units each |
| Session, Environment or comment ID | 256 UTF-16 code units, nonblank/canonical, no controls |
| Comparison identity | 256 printable ASCII characters, nonblank |
| Inclusive line range | 1,000 lines; endpoints 1 through 2,147,483,647 |
| Display coordinates | Hunk 0 through 8,191; line 0 through 65,535 |
| Version / creation sequence | 1 through 2,147,483,647; exhaustion rejects, never wraps |
| Aggregate snapshot charge | 512 KiB |

The conservative charge is 256 bytes plus six per Session-ID code unit, and 512
bytes per comment plus six per code unit across its ID, text, and anchor strings
(including enum names). Six bounds worst-case JSON escaping, and fixed overhead
bounds structural keys/numbers. This keeps the generated full response below
512 KiB and leaves room for the SQL query's repeated header/Session fields below
the host's 1 MiB/1,000-row bounds. Count and charge are checked atomically with
writes and verified on reads. Oversize or corrupt data fails explicitly; nothing
is silently trimmed or returned as a partial collection. These conservative bounds
keep ordinary feedback cheap without a retained history cache.

Pending comments are not submitted feedback, Chat entries, model outputs, tool
proposals, Run activity, or Git approval state. Saving/deleting a comment never
approves, unapproves, discards, or reverts source. Comment buttons, editors,
indicators, optional frontend backend access, source comparison identity capture,
and the editing/navigation workflow remain the next frontend slice. Submit Review,
compatible strategy acceptance, compact strategy occurrences, and plugin-owned
content in general Inspection remain separate later work. There is no universal
Session-input or Inspection framework in this service.

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
Provider-certified added and deleted text entries use this same path, including
zero-hunk empty files; they never acquire individual hunk actions. Deleted entries
never offer **Open in Source**, independently of review eligibility.
Eligible hunk headers continue to offer **Approve** in Unstaged layers and
**Unapprove** in Staged layers. Uncommitted and Task retain both actions in their
respective layers; Committed and Conflicts remain read-only. Each hunk action
retains the original typed
`ReviewHunkSelection` with the literal file path, zero-based index in that file's
displayed layer, and exact opaque `reviewRevision`. This identity is separate from
rendered labels and Source paths. File eligibility is independent of individual
hunk eligibility. A committed entry stays read-only even when the same path has an
actionable staged or unstaged entry.

The review toolbar below Refresh offers **Approve All Unstaged** only for a
provider-certified Unstaged layer and **Unapprove All Staged** only for a
provider-certified Staged layer. Unstaged scope has only the first action;
Uncommitted and Task / Branch use their separate uncommitted layers, never
Committed changes. Each retains its own exact `layerReviewRevision` in a typed
`ReviewLayerSelection`, separately from rendered rows. No paths or patches are
constructed for these actions. A layer-only selection can resolve approval access
independently of file and hunk selections.

"All" means the entire selected layer, never just its eligible files. Unsupported,
conflicted, empty or over-limit layers have no whole-layer action; individual
file/hunk actions remain available where independently supported. Stock Git allows
at most 16 changed files in one whole-layer operation, with one combined index
mutation rather than a sequence of file mutations. Buttons are stacked vertically
for narrow panes and appear only with resolved approval access and no pending review.

Only a direct button invocation starts a mutation. One pane-wide pending operation
suppresses duplicate and all other layer/file/hunk submissions while showing one
neutral pane-level pending message, not per-file progress.
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
There is no automatic refresh watcher, addition/deletion hunk approval,
discard/revert, editing within Diff, commit, review feedback submission, or
side-by-side mode. Addition/deletion review is bounded complete-file
approval, not general staging of arbitrary untracked content or unsupported deletions.

## Preparation And Tests

`app/tool/diff_viewer_frontend_compiler.dart` compiles the actual frontend source
with a generated eval projection of the same authored contract. Its build harness
is `app/tool/compile_diff_viewer_frontend.dart`, selected by the maintained
frontend artifact builder using `ADELE_DIFF_VIEWER_FRONTEND_OUTPUT`. Stock
descriptors and installation publication live in `tools/`. The same stock
installation independently prepares `diff-viewer/backend.aot` from
`packages/backend/bin/diff_viewer_backend.dart`; it adds no provider advertisement
or frontend service grant. The separate draft declaration has its own generated
native part and evaluable DTO/client projection, without changing the current
pane's compiled UI or contract projection.

Run the maintained targets from the repository root with the
[pinned toolchain](../../docs/development/toolchain.md):

```sh
dart tools/adele.dart test --target diff_viewer_contract
dart tools/adele.dart test --target diff_viewer_backend
dart tools/adele.dart test --target diff_viewer_frontend
dart tools/adele.dart test --target adele_tools
```

The contract suite checks native and interpreted nested transport for all scopes,
strict decoding, empty snapshot request payloads, revision-only layer selections,
required nullable layer revisions, declared failures, and list immutability.
The draft contract suite additionally exercises strict anchor/range/path bounds,
exact Unicode text, immutable bounded collections, duplicate comment identity,
generated native/eval enum DTO roundtrips and declared failures. Backend tests use
real test-owned SQLite for CRUD, counters, concurrency, rollback, corruption,
limits, lost acknowledgements, shutdown, and fresh rehydration. They emit timing
diagnostics without CI wall-clock thresholds.
`app/test/core/durable_review_draft_integration_test.dart` compiles the actual Diff
and shared host AOT, uses the generated client with normal Project-storage
infrastructure, and proves durable reopen, independent Sessions, explicit volatile
lifetime, SQL-trigger rollback, postcommit lost acknowledgement, generation
retirement and Project-close rejection without Git, Environment materialization,
or a Run during comment access.
The frontend suite compiles and mounts real EVC with generated native/eval codecs
through a test-only contextual port, covering states, manual recovery, handle
cleanup, held operation races, scope switching, separate
committed/staged/unstaged/conflict rows, cancellation,
selected-scope Refresh/Retry, lazy display, and Source action eligibility, raw
paths, pending suppression, safe failures, and stale callbacks. Its separate review
dispatcher covers typed hunk indices, file selections and exact revision-only
whole-layer selections, independent complete-file eligibility, certified additions
and deletions including empty
zero-hunk files, addition/deletion hunk exclusion and deletion Source exclusion,
narrow headers, layer-specific actions, unavailable approval, shared
layer/added/deleted/modified-file/hunk pending admission, success refresh,
unconfirmed failures and lifecycle fencing. It does not substitute for authority
validation:
`app/test/main_content_source_display_test.dart` owns focused native and compiled
consumer authority checks. `app/test/prepared_diff_git_integration_test.dart` owns
real stock Git AOT plus independently prepared Diff and Source EVC through normal
catalog/Main Content hosting, including committed-only work, exact independently
established baselines, staged-only and layered partial/cancelling changes,
source confinement, selected-scope Refresh after commits, canonical
nonprimary content, deduplication, dirty text/undo, focus, and gated
retirement/navigation. Hunk, atomic file and mixed whole-layer mutation acceptance
checks real selected index objects, unchanged working bytes and HEAD, nonprimary
isolation, stale selections, lock rejection and retirement after an index effect.
That cross-plugin suite requires
the native CodeForge library; the isolated Diff frontend suite does not.
Its approval/unapproval regression also runs with a failed draft backend, while
the retained frontend-only fixtures prove the absent-backend case.
The existing Source host suite remains the owner of Source document/operation
behavior. See [focused Diff checks](../../docs/development/testing.md#focused-diff-checks)
for prerequisites and test ownership, not recorded passing outcomes.

Global boundaries belong to the [plugin architecture](../../docs/architecture/plugin-system.md),
[contracts and capabilities](../../docs/architecture/contracts-and-capabilities.md),
and [dependency rules](../../docs/architecture/dependency-rules.md).
