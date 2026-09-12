# Agent Kernel

`agent_kernel` is ADELE's internal, pure-Dart, provider-neutral execution
substrate. It owns Run execution, streaming-shaped model invocation,
immutable tool materialization, proposal resolution, invocation-specific effects,
policy, interruptions, structured tool
execution outcomes, and typed execution observation.

The canonical product `Session` contains only `id`, `taskId`, and `strategyId`.
It is permanently bound to a semantic strategy identity, not to Chat history or
one activation generation. The kernel consumes and re-exports the canonical
`adele_product` `SessionId`; it does not define a competing identity or Session
aggregate. Stock Chat owns its in-memory conversation state outside this package.

## Dependencies

It may depend on public typed contracts and small pure-Dart implementation
packages required by proven execution mechanics. Flutter, `adele_desktop`,
plugin implementations, and provider-specific SDKs or formats are prohibited.
Plugins must not depend on this package.

`adele_orchestration` is the public strategy execution and context boundary.
Minimal semantic model input/output, native envelope, proposal/failure,
settlement/metadata, Run state, and approval-resolution values are defined there and reused/re-exported
here, not duplicated. Public orchestration and Chat do not depend on the kernel;
the kernel depends on the public values.

## Ownership

Runs own execution identity, a small lifecycle, interruptions, terminal failure,
and a deterministic in-memory journal. Runs do not own durable strategy state,
models, tool catalogs, context policy, or workflow sequencing.

The bound orchestration strategy owns Session meaning. `chat_strategy_plugin`
retains `ChatSessionState` by `SessionId`, with immutable canonical user/final
assistant snapshots reused across Runs. Intermediate model/native items,
proposals, and tool results are Chat's Run-local replay, not canonical history.
Instructions and a positive model-invocation budget are Chat-owned configuration
snapshotted for each materialized Run.

The kernel has no `session.dart` or `context.dart`, and no `SessionEntry`,
`UserSessionMessage`, `AssistantSessionMessage`, `SessionSnapshot`,
`SessionHistoryPort`, `ContextAssembler`, or `ContextAssemblyInput`. ADR 0022's
Chat-shaped Session/context types describe the historical Phase IV proof, not
the current kernel API.

Model ports return semantic event streams. The maintained common ModelProvider
application path consumes generated server streaming and cancellation; the
scripted fixture's unary method remains regression/reference infrastructure.
Tools have semantic IDs independent from model aliases and retain exact
executable objects in immutable per-model-invocation materializations.

`SemanticModelRequest`, model ports/streams/collectors, tool catalogs, policy,
`AgentRun`, and the journal stay internal. Application `KernelOrchestrationHost`
adapts public strategy operations to these mechanics. Its
`SessionOrchestrationRun` wrapper exposes internal evidence only to app callers;
Chat receives semantic turns, opaque tool-snapshot handles, and continuation
items instead. The host retains and validates the exact strategy binding on
operations, approval resume, and asynchronous settlement. Stale active Runs fail
without migrating; a new Run may resolve a replacement under the same Session's
stored strategy ID.

Chat projects history plus Run-local replay into `StrategyInferenceMaterial`
(instructions and ordered semantic input). Before model invocation identity,
model-start evidence, or provider work, the app host uses public
`InferenceContextComposer` over the existing `ExtensionRegistry` to capture an
immutable `InferenceContextSnapshot`. Internal
`SemanticModelRequest(context, invocationId, tools)` carries that snapshot and
host-owned execution mechanics; semantic input is unchanged. The current app
`ModelProviderCapabilityAdapter` calls orchestration's `renderInferenceInstructions`
to lower typed instruction groups to the unchanged common provider instructions
string, preserving zero-source bytes.

Each genuinely new inference, including Chat continuation, discovers current
instruction sources. Required capture failure stops composition; optional failure
omits the entire source with original diagnostics, distinct from successful empty
output. Safely captured data survives source retirement without weakening
executable strategy/tool binding checks. Source freshness is source-owned, without
a generic refresh API. The kernel owns neither source discovery nor Session
service authority; see `../orchestration/README.md` for the capture contract.

Concrete model providers, concrete tools, editors, Git, terminals, Environment
implementations, coding-agent orchestration strategies, profile management, and
provider account management do not belong here.

## Environment

The kernel may execute in the context of a Task-associated Environment but does
not implement Environment lifecycle or filesystem/process behavior. The generic
tool context still identifies only Run and Session; application composition now
uses authoritative Session association to construct an Environment-bound host
context for plugin-contributed `read_file`, `apply_patch`, `create_file`,
`delete_file`, `search`, and `run_command`. Application composition supplies tool
policy; the policy gates and approval mechanics remain kernel-backed.
Filesystem Tools owns file-tool interpretation, Command Tools owns command
projection and terminal retention, and the host supplies only the authorized
Environment facets.
Environment is the accepted practical filesystem/source + process context; a
separate first-class Workspace concept is not required architecture unless
future concrete needs justify it.

Source-coding consumers use Session-authorized Environment tooling, not the
retired DevelopmentSource capability.

## Journal

`RunJournal` is deterministic observation for tests and inspection. It is not
durable storage, replay, recovery, or an event-sourcing decision.

## Deferred

Production context sources, material beyond instructions (including directional
Reference/Observation concepts), provider-aware projection/cache planning,
token budgets, compaction,
persistent product/Chat/Run storage, profiles, Chat UI,
parent/child Session lifecycle, parallel tool execution, complete effect/content
taxonomies, durable approval, broader Environment/runtime-resource integration,
artifacts, recovery, and multi-agent abstractions remain deferred. Executable
strategy registration and headless stock Chat are implemented, not deferred
production UI or persistence claims.

See `docs/architecture/agent-kernel-semantic-model.md` and ADRs 0022/0031 for
the detailed implemented-versus-directional boundary.
