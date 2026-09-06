# Agent Kernel

`agent_kernel` is ADELE's internal, pure-Dart, provider-neutral execution
substrate. Phase IV establishes Run separation, context assembly,
streaming-shaped model invocation, immutable tool materialization, proposal
resolution, invocation-specific effects, policy, interruptions, structured tool
execution outcomes, and typed execution observation.

The maintained Phase IV proof uses a chat-shaped Session port with canonical
user/assistant snapshots. ADR 0031 subsequently defines the long-term product
Session as a core container permanently bound to one orchestration strategy;
strategy-specific state determines the Session's semantic contents. The current
chat-shaped port therefore remains implementation evidence rather than the
universal Session definition. The kernel consumes and re-exports the canonical
`adele_product` `SessionId`; it does not define a competing identity.

## Dependencies

It may depend on public typed contracts and small pure-Dart implementation
packages required by proven execution mechanics. Flutter, `adele_desktop`,
plugin implementations, and provider-specific SDKs or formats are prohibited.
Plugins must not depend on this package.

## Ownership

Runs own execution identity, a small lifecycle, interruptions, terminal failure,
and a deterministic in-memory journal. Runs do not own durable strategy state,
models, tool catalogs, context policy, or workflow sequencing.

The bound orchestration strategy and broader product/domain layer own durable
Session meaning. For the current Chat-like proof, the adapter exposes canonical
conversation snapshots to context assembly; future strategies may provide a
different state model.

Model ports return semantic event streams. The maintained common ModelProvider
application path consumes generated server streaming and cancellation; the
scripted fixture's unary method remains regression/reference infrastructure.
Tools have semantic IDs independent from model aliases and retain exact
executable objects in immutable per-model-invocation materializations.

Concrete model providers, concrete tools, editors, Git, terminals, Environment
implementations, coding-agent orchestration strategies, profile management, and
provider account management do not belong here.

## Environment

The kernel may execute in the context of a Task-associated Environment but does
not implement Environment lifecycle or filesystem/process behavior. The generic
tool context still identifies only Run and Session; application composition now
uses authoritative Session association to construct an Environment-bound host
context for plugin-contributed `read_file`, `apply_patch`, and `search`. Tool
policy remains kernel-owned; Filesystem Tools owns patch interpretation and the
host supplies only the authorized Environment facets.
Environment is the accepted practical filesystem/source + process context; a
separate first-class Workspace concept is not required architecture unless
future concrete needs justify it.

The retired DevelopmentSource capability was the bounded Phase IV source-root
proof; Phase V-A replaced its current consumers with Session-authorized
Environment tooling.

## Journal

`RunJournal` is deterministic observation for tests and inspection. It is not
durable storage, replay, recovery, or an event-sourcing decision.

## Deferred

Persistent product Session/Run storage, strategy registration and binding,
production orchestration extensions, parent/child Session lifecycle, parallel
execution, complete effect/content taxonomies, durable approval, broader
Environment/runtime-resource integration, artifacts, recovery, and multi-agent
abstractions remain deferred.

See `docs/architecture/agent-kernel-semantic-model.md` and ADRs 0022/0031 for
the detailed implemented-versus-directional boundary.
