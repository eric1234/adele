# Chat Strategy

Chat is an independently activatable stock plugin. Its pure-Dart
`chat_strategy_backend` contributes `dev.adele.strategy.chat` through the public
`adele_orchestration` extension point. Its plugin identity is
`dev.adele.plugin.chat-strategy`; its registration identity is
`dev.adele.plugin.chat-strategy.orchestration`.

The plugin has three packages: pure-Dart `packages/contract`
(`chat_strategy_contract`), pure-Dart `packages/backend`
(`chat_strategy_backend`), and Flutter `packages/frontend`
(`chat_strategy_frontend`). The root implementation package is retired.
Backend and frontend depend on the contract, never on one another.

## Activation And State

The backend entrypoint `packages/backend/bin/chat_strategy_backend.dart` owns
its router and advertises only the existing orchestration strategy extension.
The plugin-internal `ChatSessionService` remains callable on that same backend
router without a capability advertisement or semantic provider discovery.
Both dispatchers share one generation-local `ChatSessionStore`. Installed Chat
receives a generated Project storage client through its required host
infrastructure context and lazily loads durable canonical state on first access.
Schema and persistence details belong to the [backend map](packages/backend/README.md).
Chat-owned `ChatRemoteOrchestrationBackend` composes the unchanged public F3f
`RemoteOrchestrationBackend`, with fresh operation-scoped host calls on start/resume.
Each exact remote execution runs the existing sequencing implementation against
an execution-local copy of canonical history and configuration. Its final
assistant entry is persisted and published only after F3f returns an acknowledged
completed advancement. While the terminal host transition or subsequent SQL
commit is pending, canonical snapshots
still contain only previously accepted history. Rejected or mismatched terminal
acknowledgements discard the candidate rather than exposing or rolling back a
fabricated final entry. The canonical Session claim spans commit or discard as
well as execution close; accepted user entries and prior history remain intact.
Storage failure after host completion leaves Chat's canonical cache unchanged
and propagates the failure; it does not pretend the already-completed Run was
rolled back. No static production activation is needed.
Backend availability is independent of the frontend and model credentials.

Create a canonical Session using the strategy selected by its presentation.
For Chat's `owningBackend` affinity, generic hosting validates and retains the
exact strategy binding from its sibling backend before Session publication.
Application core looks up that Session by `SessionId` and materializes the pinned
contribution with
`OrchestrationStrategyHostContext(session: ..., host: ...)`. Callers do not
select another strategy ID after Session creation.
The product `Session` retains its canonical identity and selected strategy;
Chat owns conversation, configuration, and Draft Request separately in its backend
store. The current Draft Request is exact plain text.
The returned execution exposes only the public `start` and `resolveApproval`
operations, not a Chat-specific loop implementation.

`ChatSessionServiceClient` and `ChatSessionServiceDispatcher` are generated from
the annotated contract through `dart tools/adele.dart generate`. The public API is:

```dart
Future<ChatSessionSnapshot> snapshot(String sessionId);
Future<ChatEntry> appendUserMessage(String sessionId, String content);
Future<void> setDraftRequest(String sessionId, String content);
Future<ChatEntry> submitDraftRequest(String sessionId);
Future<void> configureSession(
  String sessionId, String instructions, int maxModelInvocations);
```

`ChatSessionSnapshot` contains immutable `entries`, `instructions`,
`maxModelInvocations`, and `String draftRequest`. Each `ChatEntry` contains
`String id`, `String role` (`user` or `assistant`), `String content`, and required
nullable `String? runId`. The Run association can be non-null only for a user entry;
it is semantic identity, not a live execution or opaque presentation handle.
`ChatEntryId` is a plugin-owned opaque occurrence identity, transported as a string
to keep interpreted DTOs
simple. IDs are allocated at append, unique within a retained Session, and
stable across later snapshots and durable reloads even when messages have
identical content.
After successful remote materialization, Chat associates the final history entry
with that Run only when it is an unassociated user occurrence, committing before updating its caches. This can
precede terminal history and does not imply that evidence is already available.
See the [backend map](packages/backend/README.md) for association and cleanup.

Only the strategy can append a final assistant answer or refusal; the service
exposes no assistant/history-replacement operation. Blank messages are rejected
without trimming valid content. Native items, tool proposals, intermediate
assistant text, and tool results remain outside canonical history.

`setDraftRequest` replaces the mutable plain-text draft without trimming, including
empty or whitespace-only editing states. `submitDraftRequest` rejects blank
content but otherwise retains the exact draft as one canonical user entry and
clears the draft atomically. Durable submission commits the entry, counter, and
empty draft in one SQLite transaction before publishing backend memory or
returning the accepted entry. A failed write leaves all three unchanged. Direct
`appendUserMessage` remains for already-accepted programmatic messages and never
changes the draft; configuration also leaves it intact. Draft restoration does
not start a Run. The [backend map](packages/backend/README.md) defines hydration,
the unchanged v1 baseline, and the existing storage-readability bound.

`configureSession` replaces both settings atomically. The default budget is eight
model invocations and must remain positive. Stock source-tool/approval guidance
is `chatDefaultInstructions` in the backend, not a host/frontend default.
Each execution captures configuration at materialization. Materialization claims
the Session until execution close finishes, including approval waits and terminal
host settlement. Appends, draft edits/submission, configuration, and another
materialization cannot change a claimed Session. Idle durable writes also retain
the claim through SQL acknowledgement before publishing new canonical state. Snapshots and other
Sessions remain usable.
The service returns declared `ChatSessionFailure` codes `session_busy`,
`invalid_session`, `invalid_content`, or `invalid_configuration`.
Storage and corruption failures are not translated into invalid-input failures
or hidden by volatile fallback.
The remote execution owner closes on terminal settlement or errors; explicit
release and backend shutdown also release the claim without resolving approvals.
The in-process `ChatStrategyPlugin.activate` helper is retained for backend/host
fixtures; those callers must close each execution before reconfiguring or
appending the next prompt.

The generated service ID is `chat.session` and orchestration route is `chat`.
The owning frontend uses its exact backend channel. Explicit native consumers
and remote integration tests create `ChatSessionServiceClient` from
`connection.channelFor(defaultConfigurationContext, chatSessionServiceId)` on
the captured connection/context, not through the capability registry. Generic
app activation therefore registers no semantic Chat Session service.

## Tool Narration Protocol

Chat automatically prepends the strategy-owned `chatToolNarrationGuidance` to
the captured Session instructions:

> When proposing one or more related tool operations, include one brief
> user-facing statement describing their shared purpose. Prefer one concise
> summary for the related batch rather than narrating each operation
> individually. Explicit user instructions take precedence over this guidance.

`_ChatExecution` composes this once at Run materialization, separating nonempty
Session instructions with a blank line and preserving their exact bytes. Empty
Session instructions still receive the guidance; explicit Session instructions
do not erase the protocol. Every inference receives the same composed
`StrategyInferenceMaterial.instructions`, including continuations after tool
outcomes and approval resolution, without accumulating extra copies. Later
Session instruction edits apply only to newly materialized Runs.

This is model-facing guidance, not enforced narration or synthesized assistant
output. It adds no history entry. Model narration accompanying proposals, native
items, proposals, and outcomes remain Run-local replay; final assistant text
continues to enter canonical history unchanged. Presentation and activity
rendering are outside this protocol.

## Execution Boundary

Chat projects canonical conversation entries followed by private Run-local
semantic items into each model request. It retains model output order and opaque
native metadata, drains tool proposals sequentially against the exact snapshot
returned with that model turn, and waits for each result before the next
proposal. Approval pauses the batch; resolving it appends the host's semantic
outcome and drains the remainder before another model invocation. Each later
approval remains independent.

Incomplete settlement fails with `ModelInvocationIncomplete`. Failed model turns
retain their original error. Refusal never processes observed proposals. A
completed turn without proposals requires nonblank assistant output. A proposal
batch in the final permitted model slot fails with
`ModelInvocationLimitExceeded` before any proposal is processed, leaving room
for a model continuation after every batch that does run.

The public host owns lifecycle transitions, binding validity, inference,
journaling, proposal resolution, policy, approval authorization, and tool
execution. Chat consumes semantic results only and validates the binding before
appending final assistant output and completing. Production contract/backend
packages have no kernel, concrete provider, Flutter, or internal runtime dependency.
The original state and sequencing tests are migrated, not duplicated, under
`packages/backend/test`. Standalone entrypoint tests also exercise generated
forward/reverse transport, advertisements, canonical IDs, configuration, active
mutation guards, approvals, terminal/error cleanup, and shutdown. Internal
execution-evidence checks belong to the host adapter's tests.

Chat submits `StrategyInferenceMaterial` with its composed Chat guidance and
Session instructions, ordered history projection, and Run-local replay. It
neither registers nor discovers context sources in production. The host's
`InferenceContextComposer` discovers current sources through the existing
`ExtensionRegistry` on every new inference, including Chat continuation, and
captures instruction material without changing
Chat's semantic input. Normal prepared startup and explicit development/self-hosting
activate the independent stock [`agents_md_backend`](../agents_md/README.md) through
generic remote-source adapters, reusing `agents_md_plugin` semantics. It rereads
root `AGENTS.md` through generated authorized reads backed by the captured Session's
Environment read facet each snapshot, without a direct app plugin dependency.
Chat remains AGENTS-unaware and activates no source. Independent source material
composes normally after Chat's strategy instructions; zero-source rendering
retains the exact bytes of Chat's composed instructions.

Context-source freshness belongs to each source, not Chat. Chat still owns only
its conversation/instructions, Run-local replay, and bounded sequencing; tool
availability, policy, model controls, and Environment authority retain their
existing owners. The host captures context before allocating model invocation
identity or recording model-start evidence. A required source failure stops
composition; an optional failure omits that source with diagnostics. Safely
captured data survives later source retirement, unlike the unchanged exact-binding
requirements on executable strategies and tools.

## Session Presentation

Public Flutter `adele_ui` owns `SessionPresentationContribution` with an
`OrchestrationStrategyId` and `Widget Function(Session)` factory, registered at
typed `sessionPresentationContributions` on the existing extension registry.
The generic app host matches the canonical Session's stored strategy ID exactly:
zero matches is unavailable, one supplies presentation, and multiple matches is
explicit ambiguity. Presentation is optional for Session validity and headless
execution. Retired bindings cannot silently become replacement presentations.

The frontend package owns mixed message/activity rendering and the prompt/Send composer. It uses
Flutter without importing the headless Chat implementation, application code, or
`agent_kernel`. Normal Linux checkout tooling compiles it to prepared EVC before
app run/build. Runtime activation only loads prepared bytecode; it never compiles
source or falls back to an app-owned native Chat view. Preparation and deployment
inputs are documented in [`app/README.md`](../../app/README.md#prepared-chat-frontend).

The evaluated frontend owns its generated `ChatSessionServiceClient` through the
public owning-backend bridge. It restores the composer from the canonical draft
and coalesces edits into sequential saves, retaining unsaved local text on failure.
Send flushes the latest local draft before atomic submission and then asks the
separate Session execution bridge to start a Run. Acceptance clears the composer;
if scheduling fails, Send retries the already-accepted entry even with an empty
composer, without another submission. History refresh cannot overwrite a newer
local draft. See the [frontend map](packages/frontend/README.md) for save/retry
and presentation-lifetime details.
The accepted entry ID anchors view-local activity to that exact occurrence. On
hydration, a persisted user entry's `runId` can reopen retained terminal activity
through `openSessionRunActivity` where no live handle is already present. The host
validates Session scope and issues a fresh read-only handle; Chat stores no handle
or execution authority in canonical history.
No canonical store, native Chat controller, or execution object is shared by
identity with the frontend. The owning channel is generation-bound; it does not
resolve a replacement backend or silently substitute local Chat state.

The separate Session execution bridge supplies scheduling and read-only activity,
not Chat canonical content. Host-built activity slots and inspect operations use
only opaque handles issued to that presentation. A semantic Run ID can request
Session-validated historical lookup, not arbitrary activity access or approval
authority. Plugin frontend generations and individual presentation instances are
distinct; view resources follow widget
lifecycle and exact registration liveness.

The host projects the Run through public `adele_orchestration`'s read-only
`RunActivitySource`, not by passing a journal to the frontend. Chat's interpreted
frontend counts each successfully completed model invocation's proposals and native
`output.presentation != null` occurrences, excluding narration and opaque native
items. One appears directly using plugin compact presentation or factual alias /
safe compact-text fallback. Two or more form one lightweight group keyed by exact
model invocation, independently of frontend activation. Group headings prefer
ordered explicit tool-batch narration when tools exist, then safe compact text,
then `N operations`. Reasoning-only activity precedes canonical final assistant
text, never adding an activity variant to `ChatEntry`.

The interpreted timeline places activity between the initiating user message and
the final assistant response: one direct compact body or a clickable
`ACTIVITY: ...` group summary, never rich tool bodies or execution controls.
Terminal activity and its structured evidence are retained by the host separately
from Chat history and can be reopened through the same compact/Inspection paths.
The durable association supplies placement; open cards and handles remain
view-local. Raw native model output remains ordered and opaque in
the read model, separate from immutable backend-supplied `ModelNativePresentation`.
`adele_ui` contributions supply rich Inspection by exact safe presentation kind,
not raw-output projection. Missing rich presentation leaves safe activity intact.
Chat presentation escapes compact display controls and retains the compact bound after
escaping; the provider frontend escapes full text. Chat never parses
OpenAI envelopes or replays safe presentation. Persisted native envelopes are
historical evidence only, never input to a future Chat Run. The common Inspection host
interleaves compact tool/native rows by exact `output.sequence`. Common clicks
prepend group or individual cards to a retained newest-first stack; each card
independently collapses/expands or dismisses without changing other cards.
See [model-native activity presentation](../../docs/architecture/overview.md#model-native-activity-presentation).
Subscriptions detach on close and reject late updates after disposal.

Common Run status, `PendingToolApproval`, approval cards, and display safety belong
to `app/lib/ui/execution`, outside the evaluated widget. No execution or approval
objects or approval decisions cross the generic Session bridge. Host policy and exact
invocation authorization remain the security authority. Missing or failed
presentation does not invalidate the Session or backend execution.

## Deferred Work

The current context projection deliberately preserves the development loop's
simple conversation-plus-Run-items behavior. Rich context selection, context
truncation and summarization, context sources beyond root AGENTS.md, provider-aware
projection/cache planning, token budgets, richer Chat UI, broader tool/provider
activity presentation, reasoning deltas, arbitrary plugin drill-down, active Run
recovery, profiles,
child Sessions, state migration, and concurrent
conversation editing are not implemented. Canonical Chat history, configuration,
the plain-text Draft Request, and user-entry Run associations persist for durable
Sessions; explicitly volatile fixtures remain scoped to their supplied store.
Host-owned terminal activity restores independently of Chat state. Live execution,
claims, actionable approvals, replay continuation, and workbench state are not restored.
Prepared frontend discovery and activation are implemented; installation/update
management and artifact caching remain deferred. Checkout preparation stands in
for future installation/update compilation, separate from activation consuming
prepared artifacts. The current SDK/eval pin does not establish a broad third-party
UI API; eval modernization remains necessary for that wider surface.
