# Chat Strategy

`chat_strategy_plugin` is an independently activatable, pure-Dart stock plugin.
It contributes `dev.adele.strategy.chat` through the public
`adele_orchestration` extension point. Its plugin identity is
`dev.adele.plugin.chat-strategy`; its registration identity is
`dev.adele.plugin.chat-strategy.orchestration`.

The plugin also has a separate Flutter package at `packages/frontend`, named
`chat_strategy_frontend`, for the minimal evaluated history/composer. The root
`chat_strategy_plugin` package remains headless and pure Dart; neither package
depends on the other's implementation.

## Activation And State

Create `ChatStrategyPlugin` and activate it with an `ExtensionRegistry` before
creating a canonical Session bound to `chatStrategyId`. Application core looks
up that Session by `SessionId`, resolves its stored strategy once per Run, and
materializes the exact contribution with
`OrchestrationStrategyHostContext(session: ..., host: ...)`. Callers do not
select another strategy ID after Session creation.
The product `Session` retains its canonical identity and selected strategy;
Chat owns conversation state separately in `plugin.sessions.obtain(session.id)`.
The returned execution exposes only the public `start` and `resolveApproval`
operations, not a Chat-specific loop implementation.

`ChatSessionStore` retains one `ChatSessionState` per Session ID. A store can be
injected into a plugin instance. Standalone `ChatSessionState(id)` instances are
also available for fixtures. Append `ChatUserMessage` before a Run; Chat appends
`ChatAssistantMessage` only for a nonblank final answer or refusal. Messages
reject blank content without trimming valid content. `snapshot()` returns an
immutable copy of the canonical entries. No native items, tool proposals,
intermediate assistant text, or tool results enter this conversation history.

Configure `instructions` and positive `maxModelInvocations` on the state before
materialization. Each execution captures those two settings. The default budget
is eight model invocations.

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
appending final assistant output and completing. This package has no kernel,
provider, Flutter, or runtime dependency. Tests exercise activation, resolver
materialization, conversation state, and sequencing through a fake public host;
internal execution-evidence checks belong to the host adapter's tests.

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

`app/lib/plugins/stock_chat_frontend.dart` is the provisional activation proxy and
adapter to `ChatController`, which intentionally remains in `app/lib/ui/chat`.
Immutable primitive message/activity snapshots, composer-enabled state,
string submission with synchronous boolean acceptance, and a host-built activity
widget slot for emitted opaque IDs cross the eval bridge. That native wrapper
owns inspect interaction and hosts compact plugin UI in its own prepared runtime,
without giving Chat plugin-specific fields or arbitrary identity construction.
The canonical store and controller are not shared by identity with the frontend.
Plugin frontend generations and individual presentation instances are distinct;
view resources follow widget lifecycle and exact registration liveness.

The controller observes the Run through public `adele_orchestration`'s read-only
`RunActivitySource`, not by passing a journal to the frontend. Each successfully
completed model invocation counts its proposals and native
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
Completed activity and its structured evidence
are retained separately from Chat history for the controller lifetime, including
follow-up prompts. Reconstructing a Session cannot restore historical activity
until persistence exists. Raw native model output remains ordered and opaque in
the read model, separate from immutable backend-supplied `ModelNativePresentation`.
`adele_ui` contributions supply rich Inspection by exact safe presentation kind,
not raw-output projection. Missing rich presentation leaves safe activity intact.
Generic Chat escapes compact display controls and retains the compact bound after
escaping; the provider frontend escapes full text. Generic Chat never parses
OpenAI envelopes or replays safe presentation. The common Inspection host
interleaves compact tool/native rows by exact `output.sequence`. Common clicks
prepend group or individual cards to a retained newest-first stack; each card
independently collapses/expands or dismisses without changing other cards.
See [model-native activity presentation](../../docs/architecture/overview.md#model-native-activity-presentation).
Subscriptions detach on close; the bridge coalesces frontend updates post-frame
and rejects late updates after disposal.

Common Run status, `PendingToolApproval`, approval cards, and display safety belong
to `app/lib/ui/execution`, outside the evaluated widget. No execution or approval
objects or approval decisions cross the Chat bridge. Host policy and exact
invocation authorization remain the security authority. Missing or failed
presentation does not invalidate the Session or backend execution.

## Deferred Work

The current context projection deliberately preserves the development loop's
simple conversation-plus-Run-items behavior. Rich context selection, context
truncation and summarization, context sources beyond root AGENTS.md, provider-aware
projection/cache planning, token budgets, richer Chat UI, broader tool/provider
activity presentation, reasoning deltas, arbitrary plugin drill-down, persistence, profiles,
child Sessions, state migration, and concurrent
conversation editing are not implemented. State retention is in-memory and scoped
to the supplied store, not durable product Session storage.
Prepared frontend discovery and activation are implemented; installation/update
management and artifact caching remain deferred. Checkout preparation stands in
for future installation/update compilation, separate from activation consuming
prepared artifacts. The current SDK/eval pin does not establish a broad third-party
UI API; eval modernization remains necessary for that wider surface.
