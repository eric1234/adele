# Chat Frontend

`chat_strategy_frontend` is the installed Chat Session EVC. It depends on Flutter,
the plugin-owned Chat contract, and public `adele_ui` bridges, not the application,
kernel, or Chat backend implementation.

The generated `ChatSessionServiceClient` loads canonical snapshots and appends
user messages over `OwningBackendRequestChannel`. The prepared Session descriptor
explicitly allowlists the generated service ID and requires `owningBackend`
strategy affinity. Generic hosting captures the exact sibling backend connection
and pins execution to its strategy binding. Neither service requests nor later
Runs silently select a replacement generation.

The frontend owns composer text, asynchronous acceptance/start state, history
rendering, and a presentation-local mapping from accepted entry IDs to opaque Run
handles. Duplicate submission is disabled while acceptance or scheduling is
pending. Append failure preserves the draft. Successful scheduling clears it
without waiting for the Run to finish. Execution settlement, including approval
resume, triggers a fresh canonical snapshot; failure never synthesizes an answer.

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
