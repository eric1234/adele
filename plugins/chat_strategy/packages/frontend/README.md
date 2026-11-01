# Chat Frontend

`chat_strategy_frontend` is the installed Chat Main Content and accepted-feedback
Inspection EVC. It depends on Flutter,
the plugin-owned Chat contract, and public `adele_ui` bridges, not the application,
kernel, or Chat backend implementation.

The generated `ChatSessionServiceClient` loads canonical snapshots, saves the
Markdown String Draft Request, and submits it over `OwningBackendRequestChannel`.
Its `mainContent` descriptor uses ordinary order 100, requests `sessionExecution`,
explicitly allowlists the generated service ID, and requires `owningBackend`
strategy affinity, and opts into `richDocumentEditor`. Only its admitted mounted
pane receives that native bridge; initialization receives no editor authority.
`initializeChatMainContent` reads only
`readMainContentContext()` (`sessionId`, `strategyId`, `taskId`) and opens local pane
`chat` only when the strategy matches the public `chatStrategyId`. A mismatch opens
nothing and acquires no execution controller or backend service. The host neither
injects Chat nor reserves its order value.

For an admitted pane, generic hosting validates and captures the exact sibling
backend connection and pins execution to its strategy binding. Neither service
requests nor later Runs silently select a replacement generation.

The backend owns the durable Draft Request; the frontend restores its exact Markdown
on initial load and owns immediate local edits, asynchronous save/acceptance/start
state, history rendering, and a presentation-local mapping from accepted entry IDs
to opaque Run handles. Saves are sequential with one in flight and only the latest
pending edit retained. A newer queued edit gets its own attempt even if the older
write fails. Failure of the latest value remains visible without erasing text or
automatically retrying that revision; another edit, Retry save, Send, or a new
deactivation attempt can retry.
Failed initial snapshot loading remains explicitly retryable, and later history reads cannot
overwrite newer local edits. The native editor is created only after a successful
canonical snapshot; hydration itself issues no save. Disposal releases its editor
handle, detaches subscriptions and rejects late
settlements without issuing queued saves or starting a Run.

The contributed pane registers a `Future<bool>` deactivation callback through
the public Session presentation lifecycle bridge and unregisters it on disposal.
Before actual Session departure, the host suppresses input and aggregates this
hook with those of other contributed panes while the view and its backend channel
remain live. Chat joins the sequential save queue
until the latest local draft is acknowledged. A failed save returns false, keeping
the view, native document/undo, and error available for retry; an in-flight Send also refuses
deactivation rather than allowing partial acceptance/navigation. The hook neither
submits a message nor starts a Run. Forced disposal or generation retirement still
cannot guarantee durability of unacknowledged edits. Title/order/width changes and
pane focus do not invoke Session departure. Frontend retirement revokes the pane's
services and callbacks, not the independently owned Run.

Send takes a safe current Markdown snapshot, disables duplicate submission,
flushes the latest local draft, then asks the
backend to atomically accept and clear it. Save or submission failure preserves
the same composer and undo history and starts no Run. Acceptance releases the old
handle/subscription and creates a new empty owner before scheduling. This is a
fresh undo boundary: Undo cannot restore a submitted request as an unsent draft.
Delayed old-owner callbacks cannot repopulate it. If
scheduling fails, Send retries only that accepted entry's Run, even with the
empty composer. Successful scheduling retains the entry/activity mapping. Editing
remains disabled while submitting, awaiting an accepted entry's Run retry, or
during active Runs. The host's semantic `sessionStateRevision` changes after
strategy materialization and terminal settlement. Chat captures it before initial
hydration, checks it after subscribing, and rechecks asynchronous history reads.
This discovers a late Run association and a final answer committed during loading
without polling or reloading history on ordinary activity notifications. Failure
never synthesizes an answer. There is no cross-window draft conflict resolution.

## Rich Composer

The shared native editor owns formatting, selection, input, document serialization,
and undo/redo; Chat owns persistence and submission. Ordinary history refresh,
Run updates, and layout rebuilding retain the same native document. Session
departure flushes through the existing deactivation protocol; a later presentation
hydrates a fresh owner from persisted Markdown. No AppFlowy types or JSON cross
the production plugin boundary, and core never reads Chat state to build a document.

Document invalidations carry no content. Chat takes explicit Markdown snapshots
when saving or finalizing; while a backend write is in flight it coalesces native
changes until that write settles. Native revision is distinct from Chat's local
draft revision and save acknowledgement. Selection/focus alone do not write drafts.
An `unsupported_serialization` result never saves null, stale, or degraded content:
the native document stays available for correction/Undo, an explicit error appears,
and Send and ordinary departure are refused. Previously acknowledged content
remains persisted, without claiming to include the failed local edit.

Unfinished IME composition likewise blocks snapshots, saving, Send, and departure
with feedback until composition safely completes. Disabling input is not treated
as a composition commit. Native editability follows Chat's existing `canStart`,
submission, and accepted-entry retry restrictions, including execution changes
during asynchronous settlement, without replacing the owner or its undo history.

The composer has a bounded 180-pixel editing viewport with native vertical scrolling;
auto-growth is a later UI refinement. Enter edits document content, and in fenced
code inserts a literal newline. The visible Send button is the submission path;
Ctrl/Cmd+Enter is not assigned in this slice. Normal selection, text clipboard,
formatting and undo/redo use the shared editor's supported subset and safeguards.
Paragraphs, headings, basic inline styles, lists, quotes, inline code, and top-level
fenced code are supported; see the [native Markdown boundary](../../../../app/README.md#markdown-boundary)
for exact limits and normalization after editing. Blank native text cannot submit
empty heading/list/code scaffolding; legitimate nonblank Markdown is not trimmed.

Normal paste of a block-marked Markdown prompt into an empty paragraph imports
supported structure rather than one literal paragraph. Existing prose/list/code
insertion stays literal, and Ctrl/Cmd+Shift+V explicitly requests literal paste.
The native editor validates the prospective document before a single undoable
transaction; Chat observes one invalidation and saves it through the same sequential
draft queue. An unsafe paste is rejected with native feedback and literal-paste
recovery guidance, without changing the document, Undo, or acknowledged draft.
The [native clipboard policy](../../../../app/README.md#native-rich-document-editor)
owns detection, normalization, cross-block restrictions and asynchronous safeguards.

Unsupported restored Markdown remains the exact original in the native read-only
representation, with an explanation and unchanged submission available. It is not
partially imported, automatically rewritten, or converted to a second plain editor.
Selections spanning code and other blocks can be selected/copied, but destructive
editing across them remains blocked; the composer displays that limitation. Edit
within one block instead. Expanded editing, raw-Markdown editing, slash commands,
and Agent document editing are not implemented.

Chat decides which completed model activities appear between messages and whether
to show a single compact output or a narrated group. The generic Session bridge
supplies immutable activity and validated handles for compact widgets and
Inspection. `buildChat` owns its scroll/layout and places
`buildSessionExecutionStatus()` below the Chat frontend. That public bridge builds
the existing native Run status and approval controls; core retains controllers,
policy, and exact approval validation while Chat chooses UI placement.
Canonical user entries carry a nullable semantic `runId` association, while opaque
handles remain presentation-local. After hydration, the frontend calls
`openSessionRunActivity` only for associated entries without an existing live
handle. The host validates the presented Session and issues a read-only handle;
the frontend then uses the same activity reads, compact widgets, and Inspection
operations for retained live/waiting Runs and terminal history. A remount receives
fresh handles; the prior view's actions and handles stay revoked. Missing evidence does not start execution or
invent activity. Fresh rendering reconstructs placement, not open cards, expansion
state, subscriptions, or other workbench state. Historical native data is never
continuation input, and the bridge still exposes only safe presentation data.

## Accepted Feedback

Canonical entries with authoritative `ChatEntry.feedback` code-review metadata
render as a compact `Review feedback` comment-count row and an explicit `Inspect`
button, never their model-facing `content`. Ordinary user/assistant entries,
activity placement, and the Draft Request retain their existing paths. Text that
resembles a feedback summary does not become a feedback occurrence. Only Chat's
stock Main Content descriptor opts into `canInspectSessionContent`; an opening
uses `dev.adele.chat.review-feedback` and the exact canonical entry ID, not the
submission ID or a Run handle. Missing/ambiguous presentation rejects that opening
without discarding the row. Snapshot refresh and remount restore metadata without
opening cards automatically; disposed or retired pane callbacks cannot reopen one.

`buildChatFeedbackInspection` receives the frozen Session/content references from
`readSessionContentInspectionContext` and reads the exact owning backend through
generated `ChatFeedbackInspectionServiceClient`. Its separate prepared descriptor
allowlists only `chat.feedbackInspection`, not mutation-capable `chat.session`,
execution, or Environment services. The host captures that backend generation (or
its absence) once per card and fences late reads on card/presenter retirement.
No strategy materialization, mutation, source navigation, or Run start is involved.

The renderer displays all retained comments in their original order, with identity,
version/sequence, complete text/excerpt, every anchor field, and a historical-location
notice. Display-only escaping makes controls, invisible formatting, and literal
backslashes distinguishable; no Markdown or source links are executed. Safe failed
retrieval remains unavailable rather than reconstructing data from canonical prose.

The actual compiled checks in `test/chat_frontend_eval_test.dart` cover metadata
selection, exact Inspect targets, missing renderers, narrow panes, refresh/remount
and late callbacks, full typed retrieval and display safety, and card/frontend/
backend retirement. They use the maintained frontend compiler and native bridges,
not a native replacement of the Chat widgets.

Preparation uses `app/tool/chat_frontend_compiler.dart` and generic contract-codegen
eval projection from the annotated Chat contract. The pinned evaluator's rejected
Future limitation is handled by a generic settlement bridge, not Chat RPC codecs
in the host. Missing frontend artifacts have no native Chat fallback; backend
absence leaves backend-backed actions unavailable. See the
[plugin overview](../../README.md) for maintained semantics.
