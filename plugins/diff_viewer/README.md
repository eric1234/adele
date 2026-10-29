# Diff Viewer

Diff Viewer is a stock plugin with a shared, pure-Dart public contract, an
independent pending-comment storage backend, and one `Diff` Main Content pane for
any canonical Session, at order 200 between stock Chat and Source. It does not
require Chat, a strategy frontend, or a Run. The pane acquires its draft service
through an optional, exact-owning-backend grant: missing or failed comment storage
leaves change snapshots, review approval, and Source navigation available through
their existing providers.

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
| `snapshot(sessionId)` | Complete immutable pending collection in creation order, authoritative SQL `revision`, and nullable small `currentReview` summary. |
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
an Environment. Stock Git certifies supported text comparisons with the required
nullable `ChangedFile.commentComparisonIdentity`, including Committed comparisons
and read-only comparisons that have no approval action. Identity uses captured
Session/Environment and repository/source scope, the layer, literal path and
change kind, relevant source/object identities, and exact displayed hunk/line
evidence in a separate digest domain. It is not a whole-repository revision:
unrelated file changes do not invalidate a comment. Binary, oversized, conflicted,
unsupported or unverified comparisons and comparisons without source lines do
not advertise comment eligibility. Editing never changes the original anchor, including its
captured excerpt, when working files or selected Session/Environment change.
Environment IDs are retained data, not source-read or execution authority; there
is no absolute checkout path, Project selector, storage owner, or database path in
the service. The host validates Session membership in the current open Project.

`packages/backend/lib/diff_viewer_backend.dart` owns the v1 draft baseline and a
CREATE-only v2 handoff migration:

| Table | Retained data |
| --- | --- |
| `adele_diff_review_sessions` | Core Session foreign key, next sequence, mutation revision, comment count and aggregate size charge. |
| `adele_diff_review_comments` | Composite Session/comment ID key, unique Session/sequence, version, ordinary columns for each anchor field, exact text and size charge; foreign key to the draft Session row. |
| `adele_diff_review_allocators` | Separate monotonic Session-local submission allocator, retained independently of the current payload. |
| `adele_diff_review_handoffs` | One current immutable canonical payload, original preparation revision/count, delivery/scheduling state, monotonic scheduling attempt, and confirmed occurrence/Run IDs. |

IDs are Session-local `comment-N` values with positive monotonic creation
sequences. Deletion retains the counter, so IDs are never reused. Identical
anchors and text create distinct comments, never deduplicated records. A fresh
snapshot queries committed SQL rather than a retained comment cache. A bounded
generation-local last-Session schema guard avoids repeated initialization during
ordinary use. The v2 migration adds tables without rewriting the v1 draft header
or comments; no compatibility reader for other development schemas is supplied.

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
bounds structural keys/numbers. This bounds pending-comment content at
512 KiB and leaves room for the small handoff summary and SQL query's repeated header/Session fields below
the host's 1 MiB/1,000-row bounds. Count and charge are checked atomically with
writes and verified on reads. Oversize or corrupt data fails explicitly; nothing
is silently trimmed or returned as a partial collection. These conservative bounds
keep ordinary feedback cheap without a retained history cache.

Pending comments are not submitted feedback, Chat entries, model outputs, tool
proposals, Run activity, or Git approval state. Saving/deleting a comment never
approves, unapproves, discards, or reverts source. There is no universal Session-input
or Inspection framework in this service.

### Durable Review Handoff

The same generated service owns the data-only submission lifecycle. All handoff
operations require durable Project storage, unlike pending-comment CRUD's explicit
temporary-storage support. Failed durable access never reports a volatile success.

| Method | Result / precondition |
| --- | --- |
| `prepareReview(sessionId, expectedRevision)` | Returns `ReviewPreparationResult`: either the committed immutable submission of every saved pending comment at the displayed authoritative revision, or a definite pre-write rejection. |
| `readReview(sessionId)` | Nullable complete current handoff; does not deliver feedback or start a Run. |
| `markDeliveryAttempted(sessionId, submissionId)` | One admission from `prepared` to durable `deliveryPending`, before cross-plugin dispatch. |
| `confirmAcceptance(sessionId, submissionId, receiptSessionId, occurrenceId)` | Atomically records a confirmed receipt and deletes only original comment IDs, sequences and versions. |
| `markSchedulingAttempted(sessionId, submissionId, occurrenceId)` | One admission from `accepted` to durable `schedulingPending`, incrementing `schedulingAttempt` before host dispatch. |
| `confirmRunScheduled(sessionId, submissionId, occurrenceId, expectedAttempt, runId)` | Records the exact confirmed occurrence/attempt/Run association; identical confirmation is idempotent. |
| `confirmRunNotStarted(sessionId, submissionId, occurrenceId, expectedAttempt)` | Restores `accepted` only on positive host proof that this exact scheduling attempt did not start. |

`PreparedReviewSubmission` carries Session/submission IDs, exact `canonicalPayload`,
typed `ReviewSubmissionStatus`, original comment count, scheduling attempt, and
nullable occurrence/Run IDs. `ReviewSubmissionSummary` omits the payload and Session
ID. Full payload reads are separate so a snapshot never repeats a 128 KiB payload
on every SQL comment row. Backend mapping uses explicit enum switches to the public
`SessionFeedbackSubmission` values and only `encodeSessionFeedbackSubmission` /
`decodeSessionFeedbackSubmission`, not another JSON protocol. The public 128 KiB
UTF-8 payload bound applies before any allocator or draft write. Strategy-owned
model-content projection and its separate bound remain with the accepting strategy.

`ReviewPreparationResult` has required nullable `submission` and `rejectionCode`
fields, exactly one nonnull. Its fixed rejection codes are `stale_draft`,
`empty_review`, `submission_too_large`, `review_conflict`, and `counter_exhausted`.
Only complete-payload admission reports `submission_too_large`; revision and
submission allocator exhaustion report `counter_exhausted`. These typed pre-write
results let interpreted presentation show a safe specific rejection without
inspecting native exceptions. Storage/schema/read failures and attempted SQL writes,
including CAS conflicts and lost commit acknowledgements, still throw failures;
they are never converted into definite preparation rejection. A success carries
the exact committed prepared DTO and a null rejection code.

Preparation rejects empty, stale or oversized batches unchanged; it never selects
only comments in the current Diff scope. The separate `review-N` allocator is
transactional and survives removal of completed payloads. Preparation reserves both
its own and acceptance's draft-revision increments before freezing. CRUD rejects
`prepared` and `deliveryPending` both before writing and in the SQL header CAS, so
an independently loaded backend cannot mutate the batch. Acceptance preserves the
comment creation counter, permits new pending comments, and leaves the unscheduled
handoff retained. Only `scheduled` permits another preparation; replacement prunes
the previous row atomically, bounding retention to one immutable payload per Session.

Receipt confirmation requires the same Session, submission, and occurrence; Run
confirmation also requires the captured scheduling attempt. Repeated attempt
markers reject rather than authorize another dispatch. A delayed not-started reply
cannot reset a newer attempt. SQL failure, lost acknowledgement, backend retirement,
and missing read-only association evidence never establish rollback. Reopen reads
retained state without replay; an uncertain `schedulingPending` handoff stays pending
until positive reconciliation. The backend stores no live controller, binding or
execution authority and does not itself accept feedback or schedule Runs.

### Comment Workflow

Each eligible source line offers a compact **Comment** action. An addition anchors
the new side, a deletion the old side, and context the new side only when that side
exists. Numeric hunk ranges and actual line kinds determine source positions, never
the rendered label. The anchor retains the captured Environment, original path,
typed layer/side, equal inclusive line endpoints, comparison identity, exact line
excerpt, and zero-based hunk/line indices. CRLF and missing-final-newline semantics
are preserved. Lines whose exact excerpt or coordinates exceed the draft bounds
have no actionable control; excerpts are never truncated to make them eligible.

One inline editor's controller belongs to the pane rather than a lazy row. The
editor, controls and comparison share a scrollable list so Save/Cancel remain
reachable in short panes; explicit selection reveals the editor at the top.
Selection does not write. **Save comment** creates or updates through the generated draft client;
**Cancel editing** explicitly discards the local draft. Refresh, scope switching,
scrolling and rebuilding retain the controller and text. The pinned evaluated
TextField supports only this slice's single-line editing. Existing multiline
comments remain fully readable and deletable, but cannot be edited through a lossy
single-line control. No saved text or line breaks are normalized or truncated.

**Pending review comments** shows the complete backend collection in creation
sequence, including comments outside the selected scope or on a now-clean Diff.
Items retain their original location and excerpt, full text, and **Edit**/**Delete**
controls. Editing sends the original ID and version and cannot change the anchor.
Duplicate comments on the same line remain distinct records. A confirmed mutation
applies the backend's authoritative returned comment or confirmed deletion, never
optimistic editor text. Loading comments requires no Git snapshot or index write;
**Reload comments** reads only the draft, while **Refresh** reads both independently.

Location status is **Current location** only when Environment, path, layer, side,
comparison identity, hunk/line coordinates, source line range and exact excerpt all
match. **Outside current scope / not inspected** covers scope exclusion, failed
snapshots and uncertified working/index comparisons, including unresolved paths
reported in a separate Conflicts group. Working conflicts do not mask independently
certified Committed history. **Outdated location** requires positive
changed-comparison evidence or absence from a successfully inspected scope. Scope
switching or Git read failure alone never proves obsolescence. Comments are never
re-anchored and remain inspectable, editable and deletable when outdated.

The optional owning-backend grant captures the exact installation, configuration
context and generation. Missing/failed storage produces an inert channel, not an
empty authoritative draft or local-only replacement. Reads fail independently of
Git; the pane retains any last confirmed collection and disables comment mutations
until a successful explicit read. Retired channels never retarget another backend
with the same PluginId. A pane-local write gate prevents duplicate comment writes
and overlapping comment/approval mutations without changing Git's approval gate.

Failed or uncertain writes show **Comment change not confirmed. Reload comments
before trying again.** The editor text is retained but its mutation selection is
invalidated; a fresh snapshot and explicit reselection are required. There is no
automatic retry or text/location deduplication: an unacknowledged create may already
have committed. Unsaved text or a pending write refuses Session departure with an
explicit save/cancel instruction. Disposal and presentation retirement fence late
publication, not already admitted backend effects. Remounts read saved state from
the backend, including after durable Project close/reopen.

## Presentation

`packages/frontend/lib/main.dart` supplies `initializeDiff()` and
`buildDiffPane()`. Initialization opens only local pane ID `diff`; reinitializing
does not duplicate it. The descriptor declares `environmentBufferedProcessCapabilities`
for both `adele.diff.change-set-source` v1 and `adele.diff.review-approval` v1,
separately, and `canRequestSourceDisplay` for pane-only requests
through the public source-display point. There is no context-free capability
grant, direct file access, process, terminal, editor, or
execution grant. The host grants buffered-process access only to the selected
Capability backend for each invocation, never to the interpreted pane.
The independent `optionalBackendServices: ['diff.reviewDraft']` declaration grants
only its own draft service and never makes the whole Diff presentation require it.

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
discard/revert, source editing within Diff, commit, or
side-by-side mode. Addition/deletion review is bounded complete-file
approval, not general staging of arbitrary untracked content or unsupported deletions.

## Preparation And Tests

`app/tool/diff_viewer_frontend_compiler.dart` compiles the actual frontend source
with a generated eval projection of the same authored contract. Its build harness
is `app/tool/compile_diff_viewer_frontend.dart`, selected by the maintained
frontend artifact builder using `ADELE_DIFF_VIEWER_FRONTEND_OUTPUT`. Stock
descriptors and installation publication live in `tools/`. The same stock
installation independently prepares `diff-viewer/backend.aot` from
`packages/backend/bin/diff_viewer_backend.dart`; it adds no provider advertisement.
The compiler consumes separate generated eval projections for the snapshot and
draft declarations, including the actual draft client, DTOs, comparison enums and
normal owning-backend channel. UI limits project the authoritative scalar bounds,
not handwritten DTOs or a separate codec.

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
