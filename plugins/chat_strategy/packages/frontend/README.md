# Chat Frontend

`chat_strategy_frontend` is the installed Chat Main Content EVC. It depends on Flutter,
the plugin-owned Chat contract, and public `adele_ui` bridges, not the application,
kernel, or Chat backend implementation.

The generated `ChatSessionServiceClient` loads canonical snapshots, saves the
plain-text Draft Request, and submits it over `OwningBackendRequestChannel`.
Its `mainContent` descriptor uses ordinary order 100, requests `sessionExecution`,
explicitly allowlists the generated service ID, and requires `owningBackend`
strategy affinity. `initializeChatMainContent` reads only
`readMainContentContext()` (`sessionId`, `strategyId`, `taskId`) and opens local pane
`chat` only when the strategy matches the public `chatStrategyId`. A mismatch opens
nothing and acquires no execution controller or backend service. The host neither
injects Chat nor reserves its order value.

For an admitted pane, generic hosting validates and captures the exact sibling
backend connection and pins execution to its strategy binding. Neither service
requests nor later Runs silently select a replacement generation.

The backend owns the durable Draft Request; the frontend restores its exact text
on initial load and owns immediate local edits, asynchronous save/acceptance/start
state, history rendering, and a presentation-local mapping from accepted entry IDs
to opaque Run handles. Saves are sequential with one in flight and only the latest
pending edit retained. A newer queued edit gets its own attempt even if the older
write fails. Failure of the latest value remains visible without erasing text or
automatically retrying that revision; another edit, Retry save, Send, or a new
deactivation attempt can retry.
Failed initial snapshot loading remains explicitly retryable, and later history reads cannot
overwrite newer local edits. Disposal detaches subscriptions and rejects late
settlements without issuing queued saves or starting a Run.

The contributed pane registers a `Future<bool>` deactivation callback through
the public Session presentation lifecycle bridge and unregisters it on disposal.
Before actual Session departure, the host suppresses input and aggregates this
hook with those of other contributed panes while the view and its backend channel
remain live. Chat joins the sequential save queue
until the latest local draft is acknowledged. A failed save returns false, keeping
the view, text, and error available for retry; an in-flight Send also refuses
deactivation rather than allowing partial acceptance/navigation. The hook neither
submits a message nor starts a Run. Forced disposal or generation retirement still
cannot guarantee durability of unacknowledged edits. Title/order/width changes and
pane focus do not invoke Session departure. Frontend retirement revokes the pane's
services and callbacks, not the independently owned Run.

Send disables duplicate submission, flushes the latest local draft, then asks the
backend to atomically accept and clear it. Save or submission failure preserves
the composer and starts no Run. Acceptance clears the composer before scheduling;
if scheduling fails, Send retries only that accepted entry's Run, even with the
empty composer. Successful scheduling retains the entry/activity mapping. Editing
remains disabled while submitting, awaiting an accepted entry's Run retry, or
during active Runs. The host's semantic `sessionStateRevision` changes after
strategy materialization and terminal settlement. Chat captures it before initial
hydration, checks it after subscribing, and rechecks asynchronous history reads.
This discovers a late Run association and a final answer committed during loading
without polling or reloading history on ordinary activity notifications. Failure
never synthesizes an answer. There is
no cross-window draft conflict resolution or rich-document editor in this slice.

The existing evaluated `TextField` remains single-line. Storage and initial
restoration retain line breaks exactly, but Flutter's single-line input formatter
filters them on editing. Multiline composition requires extending the pinned
evaluator's `TextField` bridge, which currently exposes no `maxLines` option.

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

Preparation uses `app/tool/chat_frontend_compiler.dart` and generic contract-codegen
eval projection from the annotated Chat contract. The pinned evaluator's rejected
Future limitation is handled by a generic settlement bridge, not Chat RPC codecs
in the host. Missing frontend artifacts have no native Chat fallback; backend
absence leaves backend-backed actions unavailable. See the
[plugin overview](../../README.md) for maintained semantics.
