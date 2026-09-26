# Chat Frontend

`chat_strategy_frontend` is the installed Chat Session EVC. It depends on Flutter,
the plugin-owned Chat contract, and public `adele_ui` bridges, not the application,
kernel, or Chat backend implementation.

The generated `ChatSessionServiceClient` loads canonical snapshots, saves the
plain-text Draft Request, and submits it over `OwningBackendRequestChannel`.
The prepared Session descriptor explicitly allowlists the generated service ID
and requires `owningBackend`
strategy affinity. Generic hosting captures the exact sibling backend connection
and pins execution to its strategy binding. Neither service requests nor later
Runs silently select a replacement generation.

The backend owns the durable Draft Request; the frontend restores its exact text
on initial load and owns immediate local edits, asynchronous save/acceptance/start
state, history rendering, and a presentation-local mapping from accepted entry IDs
to opaque Run handles. Saves are sequential with one in flight and only the latest
pending edit retained. A newer queued edit gets its own attempt even if the older
write fails. Failure of the latest value remains visible without erasing text or
automatically retrying that revision; another edit, Retry save, or Send can retry.
Failed initial snapshot loading remains explicitly retryable, and later history reads cannot
overwrite newer local edits. Disposal detaches subscriptions and rejects late
settlements without issuing queued saves or starting a Run. Unacknowledged or
coalesced pending edits are not guaranteed durable when the presentation closes.

Send disables duplicate submission, flushes the latest local draft, then asks the
backend to atomically accept and clear it. Save or submission failure preserves
the composer and starts no Run. Acceptance clears the composer before scheduling;
if scheduling fails, Send retries only that accepted entry's Run, even with the
empty composer. Successful scheduling retains the entry/activity mapping. Editing
remains disabled while submitting, awaiting an accepted entry's Run retry, or
during active Runs. Execution settlement, including approval resume, triggers a
fresh canonical history snapshot; failure never synthesizes an answer. There is
no cross-window draft conflict resolution or rich-document editor in this slice.

The existing evaluated `TextField` remains single-line. Storage and initial
restoration retain line breaks exactly, but Flutter's single-line input formatter
filters them on editing. Multiline composition requires extending the pinned
evaluator's `TextField` bridge, which currently exposes no `maxLines` option.

Chat decides which completed model activities appear between messages and whether
to show a single compact output or a narrated group. The generic Session bridge
supplies immutable activity and validated handles for compact widgets and
Inspection. Common Run status and approval controls remain in core native UI.
Activity placement is not persisted with canonical history.

Preparation uses `app/tool/chat_frontend_compiler.dart` and generic contract-codegen
eval projection from the annotated Chat contract. The pinned evaluator's rejected
Future limitation is handled by a generic settlement bridge, not Chat RPC codecs
in the host. Missing frontend artifacts have no native Chat fallback; backend
absence leaves backend-backed actions unavailable. See the
[plugin overview](../../README.md) for maintained semantics.
