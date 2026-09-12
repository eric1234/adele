# Chat Strategy

`chat_strategy_plugin` is an independently activatable, pure-Dart stock plugin.
It contributes `dev.adele.strategy.chat` through the public
`adele_orchestration` extension point. Its plugin identity is
`dev.adele.plugin.chat-strategy`; its registration identity is
`dev.adele.plugin.chat-strategy.orchestration`.

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

Chat submits `StrategyInferenceMaterial` with its instructions and ordered history
projection plus Run-local replay. It neither registers nor discovers context
sources in production. The host's `InferenceContextComposer` discovers current
sources through the existing `ExtensionRegistry` on every new inference,
including Chat continuation, and captures instruction material without changing
Chat's semantic input. Only development/self-hosting composition activates the
independent stock [`agents_md_plugin`](../agents_md/README.md), which rereads root
`AGENTS.md` through the Session-authorized Environment read facet each snapshot.
Chat remains AGENTS-unaware and activates no source; zero-source provider
instructions retain their exact bytes.

Context-source freshness belongs to each source, not Chat. Chat still owns only
its conversation/instructions, Run-local replay, and bounded sequencing; tool
availability, policy, model controls, and Environment authority retain their
existing owners. The host captures context before allocating model invocation
identity or recording model-start evidence. A required source failure stops
composition; an optional failure omits that source with diagnostics. Safely
captured data survives later source retirement, unlike the unchanged exact-binding
requirements on executable strategies and tools.

## Deferred Work

The current context projection deliberately preserves the development loop's
simple conversation-plus-Run-items behavior. Rich context selection, context
truncation and summarization, context sources beyond root AGENTS.md, provider-aware
projection/cache planning, token budgets, Chat UI, persistence,
profiles, child Sessions, state migration, and concurrent conversation editing
are not implemented. State retention is
in-memory and scoped to the supplied store, not durable product Session storage.
