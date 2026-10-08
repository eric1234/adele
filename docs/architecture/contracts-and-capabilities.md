# Contracts and Capabilities

Role: Canonical architecture

Implementation status: Partial

This document owns the cross-system semantic boundary between typed transport,
callable provider selection, exact live bindings, and host access contexts.
Local packages own exact APIs, schemas, generator grammar, and runtime framing;
source/tests establish current behavior. This is not an IDL reference, protocol
manual, remote-extension implementation guide, or stock-provider inventory.

## Distinct concepts

| Concept | Question |
| --- | --- |
| Contract | How do typed values and operations cross a runtime boundary? |
| Capability | Which compatible provider handles callable semantic work? |
| Extension Point | Where and how may components participate in typed composition? |
| Live binding | Which exact active generation is this resolved operation bound to? |
| Host invocation authority | Which host services may this exact remote operation call right now? |
| Host infrastructure access | Which explicit non-execution services may this exact backend generation call? |

Transport does not choose semantic provider identity, and provider identity does
not grant host authority. Extension registration does not imply Capability
semantics. A generated callable service can be directly routed without being an
advertised Capability. The [plugin system](plugin-system.md) owns broader typed
composition and each extension point's selection/composition rules.

## Contracts

Authored annotated declarations are the semantic source of truth for transported
values and operations. Values received across a runtime boundary are reconstructed
values, not shared Dart object identity or transparent remote objects. Prefer
immutable snapshot-style values; reconstruction alone does not guarantee deep
immutability of every authored value.

Generated clients, dispatchers, and codecs hide ports, framing, request IDs,
subscriptions, and serialization from normal plugin code. Declaration packages
remain lightweight and separate from compiler/generation tooling, following
[ADR 0004](../adr/0004-generated-typed-asynchronous-contracts.md) and
[ADR 0013](../adr/0013-contract-declarations-and-generation-are-separate.md).

Current native transport supports unary request/response and server streaming.
Streams open on listen, preserve item order, propagate subscription cancellation,
and apply backpressure: pausing limits producer advancement without retracting
work already admitted. Unary requests do not acquire a general cancellation API
merely because streaming supports cancellation. Transport completion and domain
settlement remain distinct; a domain contract may require an explicit semantic
terminal result rather than interpreting stream EOF as success.

Native dispatchers serialize ordinary admission by default. A service owner may
explicitly opt into concurrent admission when it enforces the necessary
per-Session or per-execution guards. This is a local admission policy, not a wire
change, general scheduler, or authority grant. Stream credit/cancellation bypass
ordinary admission in either mode. Dispatcher close fences new admission and
drains all admitted operations; it does not interrupt unary service work or replace
the owner's domain shutdown and dependency settlement.

ADELE does not currently provide general symmetric RPC, client streaming,
bidirectional streaming, ambient arbitrary callbacks, or general transparent remote
objects. Calls in both directions through explicitly scoped channels do not imply
those mechanisms. Exact declaration restrictions and generated behavior belong to
[`contract`](../../packages/contract/README.md) and
[`contract_codegen`](../../packages/contract_codegen/README.md), not this document.

### Generated artifacts

```text
authored contract declaration
    -> generated local transport implementation
    -> native/eval consumers
```

Declaration and generated implementation are separate concerns. Native generated
parts are derived, ignored local artifacts, not authoritative or committed source.
Frontend eval clients can be derived from the same declarations without creating
a second semantic contract. The bounded eval projection supports unary and server
streaming operations with scalar, nullable, JSON, list, and value DTO transport,
not every native contract shape.

Exact bootstrap, generation, checking, cleaning, and filesystem procedures belong
to [`contract_codegen`](../../packages/contract_codegen/README.md) and the
[development toolchain](../development/toolchain.md#generated-contract-artifacts).

### Transport version policy

Backend-host and plugin-backend protocols currently require exact version matching
and both use version 1. Before the first release, unreleased wire changes may
retain version 1. Prepared runtime, host, and backend artifacts must be rebuilt
coherently after wire changes: matching version numbers do not make old development
artifacts compatible, and no compatibility shim is promised for them.

Increment transport versions when released artifacts establish a real
compatibility boundary. Transport protocol versions are distinct from Capability
majors and installed-manifest schema versions; changing one does not implicitly
change the others.

## Capability semantics

A Capability selects a compatible provider for callable Action/Service work. It is
one specialization of extension composition, not a registry for every kind of
participation or every generated service.

| Kind | Semantics |
| --- | --- |
| Action | One-shot callable operation. |
| Service | Sustained typed callable capability. |
| Event | Notification of a fact, not provider-selected work. |

These describe semantic roles, not transport shapes. Events are not Capabilities
merely because they may later share registration or transport infrastructure.
Observers cannot change whether an announced fact occurred; generic Event
publication/subscription remains unimplemented. See
[ADR 0005](../adr/0005-actions-services-and-events-have-distinct-semantics.md)
for the decision rationale.

Compatible providers may number zero, one, or many; callers cannot assume exactly
one. ADELE owns default-provider selection, and a provider cannot declare itself
globally primary. Where the domain exposes alternatives, callers can explicitly
choose one. Explicit resolution must fail rather than silently fall back.

The current registry uses exact Capability-major matching and deterministic
rank/provider-ID ordering. That implementation is not the final preference or
Profile system. Resolution captures one exact generation-bound binding, not a
standing instruction to keep finding whichever provider currently has that ID.
See [`capabilities`](../../packages/capabilities/README.md) for registry behavior
and [profiles and configuration](profiles-and-configuration.md) for the separate
configuration/preference model.

## Live discovery and exact binding

```text
current provider/extension set
    may change
fresh resolution
    can see a new generation
captured binding
    remains tied to one exact generation
retirement
    makes that binding stale
replacement
    requires fresh resolution
```

Stable semantic IDs do not make stale executable bindings live again. Consumers
retain and validate their exact bindings at invocation and relevant asynchronous
settlement boundaries; they must not silently re-resolve on continuation. This
applies to Capability providers, remote extension contributions, owning-backend
frontend calls, and execution-scoped remote operations that capture a binding.

Binding lifetime and transport-resource lifetime are not identical: registration
retirement invalidates access through a Capability binding, but is not a universal
revocation mechanism for previously extracted low-level channels. Those channels
remain tied to their captured connection, never a replacement. Consumers must
still enforce the retained binding's liveness. See the
[general registration/binding model](plugin-system.md#live-discovery-and-exact-captured-bindings)
and [`plugin_runtime`](../../packages/plugin_runtime/README.md).

## Backend-ready advertisements

```text
prepared installation
    backend artifact exists
backend starts
    -> ready handshake advertises live capability/extension exposures
host activation
    -> registers exact-generation providers/contributions
```

Installed metadata describes prepared availability, not live backend Capability
or extension exposure. Each omitted exposure list means zero contributions of
that kind, independently of the other list. `PluginId` comes from the installation
and connection, not the advertisement payload. Advertisements belong to that
exact backend generation; readiness alone is not a registry registration.

Host activation validates and adapts advertisements into the existing registries.
Invalid or unsupported exposures and registration failures fail the attempt with
coherent rollback of its partial registrations, not unrelated registrations.
Retirement removes only the owning generation's registrations, never replacements.
This is rollback across the registration attempt, not a promise of transactionally
invisible publication across registries.

Ready advertisements are neither invocation authority nor general configuration
or Profile state. Exact exposure fields belong to
[`contract`](../../packages/contract/README.md); registration, rollback, and
retirement mechanics belong to
[`plugin_runtime`](../../packages/plugin_runtime/README.md#ready-registrations).
See [plugin layout](plugin-layout.md#prepared-installation-snapshot) for the
installed-metadata boundary.

### Configuration context

A configured semantic/provider instance is a persistent/logical concept. Its live
endpoint instead routes through a `configurationContext`: an opaque backend-local
context for configured service state within one exact generation. Several
providers/services may share a context, and one plugin generation may expose
several provider instances and contexts without separate installations.

The route captures connection, configuration context, and service; semantic method
payloads do not select or override them. A routing context is not a persistent
account record, Profile state, a credential, semantic provider identity, or a
general host-authority token. General configured-instance persistence and Profile
management are not established by these live routes. See
[ADR 0027](../adr/0027-generation-bound-plugin-configuration-contexts.md),
[profiles and configuration](profiles-and-configuration.md), and
[`capabilities`](../../packages/capabilities/README.md).

### Remote Commands

Context-free backend Commands reuse `AdeleExtensionExposure` in backend readiness,
not installed frontend descriptors or a Command-specific envelope. The app adapts
the advertised semantic identity, label, and opaque implementation route into the
existing Command extension point. Generated invocation captures the exact backend,
configuration context, and service; the route payload distinguishes implementations
within that service without selecting a generation or granting authority.

The remote Command service has only unary invocation, no availability operation
and no host invocation context or host services. Availability is a local liveness
check under the [Command domain's synchronous admission rules](plugin-system.md#commands-and-input).
Registration retirement after admission does not generically cancel the operation
or invalidate successful completion; actual transport termination may fail it.
No invocation token or empty operation-scoped grant is manufactured for this call.
Separately configured backend infrastructure access is not enlarged by implementing
a Command. Exact contract and metadata shape belong to
[core extensions](../../packages/core_extensions/README.md#remote-commands).

## Own-backend frontend requests

Prepared frontends can use generated unary and server-streaming clients to call
explicitly allowlisted services on their captured owning backend. This is direct routing to one exact
backend generation and configuration context, not Capability provider discovery.
The prepared descriptor constrains allowed services; interpreted frontend code
cannot select an arbitrary PluginId, configuration context, or service.

The host validates captured ownership and presentation lifetime before dispatch
and after settlement. Streams admit on listen, validate each delivered item, and
propagate pause/resume/cancellation through the existing transport. Owner retirement
cancels active observations, including idle/paused ones; presentation retirement
fences queued callbacks and cancels subscriptions without stopping independent
backend work. Malformed stream items and safe eval error/done delivery affect the
observation, not the producer's domain outcome. Generic prepared hosting does not
require Session or strategy presentation. Where owning-backend strategy affinity
is required, it must
prove the strategy's exact registration origin, not merely matching semantic IDs.
Missing, retired, or mismatched ownership fails explicitly, without retargeting or
native/in-process fallback. Same-plugin identity alone grants no arbitrary service
access.

Rich activity Inspection and declared read-only console content reuse this routing
without resolving or materializing a Session strategy. Their Session, Run, and
tool-invocation identities select plugin-owned evidence as ordinary request data,
not host-invocation authority. The host captures the owning installation's exact
live backend/configuration route and applies that descriptor's service allowlist;
frontend code cannot promote an identity into execution, Environment, or approval
access. Compact activity presentation does not acquire an owning-backend channel.
Unavailable observation preserves independent factual presentation, not a backend
fallback. Safe interpreted Future settlement preserves success values or reports
failure without native diagnostics; it neither widens access nor changes the
producer's domain outcome.

For explicitly resident console content, the owning-backend channel and
subscriptions follow the resident lifetime, not the selected-tab interaction
epoch. A hidden resident may keep observing through its existing descriptor
allowlist and exact backend route. Deselection immediately revokes user
interaction, but does not cancel those resident reads. Eviction, working-set
departure, content removal, host close, or owner retirement revokes the resident
and its observation; neither reselecting a tab nor registering the same IDs revives
old grants. Queued actions and asynchronous user-interaction completions validate
the exact epoch captured when initiated, separately from resident liveness.
This split grants no new execution or capture authority and does not change
transport backpressure or independent backend work. See
[console lifecycle](plugin-system.md#shared-console) and the
[UI bridge map](../../packages/ui/README.md#interpreted-bridges).

Chat's `ChatSessionService` is a generated plugin-internal service reached through
direct/owning-backend routing; it is not an advertised Chat Session Capability.
Chat installs its Session dispatcher on the backend router but advertises only its
orchestration strategy through extension exposures. Explicit native consumers,
including self-hosting, likewise use the captured backend/context rather than
Capability resolution.

Exact channel and descriptor behavior belongs to
[`plugin_runtime`](../../packages/plugin_runtime/README.md#own-backend-requests)
and [`ui`](../../packages/ui/README.md#interpreted-bridges). Chat-specific ownership
belongs to the [Chat README](../../plugins/chat_strategy/README.md).

### Frontend behavioral operations

Frontend behavioral extensions can execute through host-supplied bridges without
becoming backend Capabilities or receiving backend host-invocation authority.
Their composition and prepared-component boundaries belong to the
[plugin system](plugin-system.md#backend-and-frontend-composition) and
[plugin layout](plugin-layout.md#prepared-frontend-descriptors). Bridge APIs and
the Local Directory example belong to [`ui`](../../packages/ui/README.md#interpreted-bridges)
and the [Local Directory Project plugin](../../plugins/local_directory_project/README.md).

Context-free prepared Commands use the same finite-operation evaluator path with
an empty bridge set. Their no-argument entrypoints must complete with void/null;
neither descriptor declaration nor invocation supplies product context, native
callbacks, owning-backend access, directory picking, filesystem/process services,
Session execution, or retained presentation state. Unavailable bridge calls fail
normally. The frontend generation owns operation revocation, while the
[Command domain](plugin-system.md#commands-and-input) owns exact registration and
unique enabled-state admission. This does not introduce a public Command bridge
or an authority token.

The contextual Console-action Command descriptor adds no operation or bridge.
It delegates to an exact sibling creation action, whose existing Console admission
captures canonical Session/Environment authority and supplies the existing Terminal
bridge. Availability reads native owner state without evaluating plugin code.
Neither a transported target ID nor semantic Command identity grants access to a
foreign contribution or accepts caller-selected product context. See
[Commands and input](plugin-system.md#commands-and-input) for exact binding and
asymmetric retirement, and [Shared Console](plugin-system.md#shared-console) for
creation ownership.

Explicit user file operations are another narrow frontend grant, not model-tool
execution. Session/Environment identity is separate provider-free data through the
[Main Content context](plugin-system.md#grouped-main-content), not a file grant.
For each opted-in finite operation, the host creates a fresh capture of the
canonical Session's Environment association before asynchronous work, never a
caller-supplied Environment ID or Task-primary fallback. Captures are not cached
for the contribution or Environment lifetime. Each capture retains one lazy
materialization attempt, including failure, and validates its exact provider
binding without re-resolving after navigation or provider replacement. The runtime
may reuse an already valid materialization. A failed or stale operation never
retries or migrates; a later explicit Open or Save may freshly resolve the same
captured Environment without reviving earlier access.

The separate Environment access bridge exposes only complete existing-text reads
and revision-conditional replacement. Initializers, views, and operations without
file permission or captured Session context receive no file grant. The frontend
receives no direct I/O, Run, model, process, or arbitrary Environment facet.
Declared provider failures remain structured; unknown failures do not assert
local-buffer retention or that the file was unchanged. The host forwards the
plugin's opaque expected revision unchanged, without rebasing or automatic write
retry. Revocation does not undo an admitted write, and missing acknowledgement
does not establish rollback.
See the [application adapter](../../app/README.md#source-editor-hosting) and
[public bridge](../../packages/ui/README.md#interpreted-bridges).

## Operation-scoped host calls

Execution-related backend-to-host access is explicitly supplied for one authorized
operation, separately from [infrastructure access](#generation-scoped-infrastructure-access):

```text
remote operation begins
    -> host captures canonical local authority and exact bindings
    -> host creates a fresh opaque invocation context
       + exact backend generation
       + explicit service allowlist
    -> backend may call only those host services
operation settles / cancels / retires
    -> authority is revoked
```

The host mints authority. Backend/plugin IDs do not mint it, and transported
Session, Task, Run, or Environment IDs do not select it. Domain adapters supply
services from captured canonical local authority, not by reconstructing authority
from remote identity strings. A point may acquire an authorized facet lazily from
that captured context; it must retain and validate the resulting exact binding.

| Context | Meaning |
| --- | --- |
| `configurationContext` | Backend-local live route for configured service state in one generation. |
| `hostInvocationContext` | Host-issued authority for one operation's explicit host-service allowlist. |
| `hostInfrastructureContext` | Host-issued access to an explicit infrastructure-service allowlist for one backend generation, not execution authority. |

The invocation token is opaque and operation-local. It must not be persisted or
reused as a general capability, and possessing a route or communication channel
does not grant it. Allowlisting one service does not implicitly grant other
services. Access remains tied to the exact backend generation and registration;
liveness is checked at dispatch and across asynchronous settlement.

Settlement, cancellation, registration retirement, or connection termination
revokes the invocation. Late results cannot revive it or reach a replacement.
Revocation prevents future calls; it is not rollback of effects already started.
The allowlist limits host-service access, not every possible effect of native
plugin code. Process/isolate boundaries and scoped host APIs are not an OS sandbox.
[ADR 0032](../adr/0032-remote-backend-extensions-use-operation-scoped-host-services.md)
records the authority decision and rationale.

### Reverse unary and streaming calls

Backend-to-host calls reuse the existing host/backend communication substrate.
Bounded reads, mutations, and orchestration mechanics use unary host requests;
naturally streaming operations, such as foreground process events, use server
streaming. The plugin-side channel helper does not mint authority.

Shared reverse request/open envelopes require `hostContextKind` (`invocation` or
`infrastructure`) and `hostContext`. There is no legacy reverse-envelope shape;
the invocation helper `bind(hostInvocationContext: ..., serviceId: ...)` remains
distinct from `bindInfrastructure(hostInfrastructureContext: ..., serviceId: ...)`.
Context kind and token must match the host's exact grant and service allowlist;
one kind cannot substitute for the other. Both protocols remain version 1 under
the [pre-release version policy](#transport-version-policy).

For a streaming remote operation, authority begins on listen, not merely on
construction of a stream or possession of a channel. It ends on enclosing-operation
completion, error, cancellation, or retirement, not merely delivery of a domain
terminal item. Pausing/backpressure neither expands authority nor protects it from
revocation. Cancelling an individual reverse stream stops that stream; cancelling
the enclosing operation revokes its invocation and cancels owned reverse streams.

Revocation does not wait for arbitrary producer cleanup. Bounded transport cleanup
does not promise arbitrary host-code interruption or completed OS-process
termination; already-started mechanics may still need to settle and retain their
evidence. Exact framing and cleanup behavior belong to
[`plugin_runtime`](../../packages/plugin_runtime/README.md#operation-scoped-host-calls),
[`plugin_backend_support`](../../packages/plugin_backend_support/README.md), and
[`plugin_backend_host`](../../packages/plugin_backend_host/README.md).

### Remote orchestration strategies

Materialization establishes backend-owned strategy execution state without host
invocation authority. Start and approval resume each receive fresh operation-scoped
host services over the retained exact binding/generation. Approval remains
host-captured; the backend cannot manufacture authorization from transported
approval fields or matching IDs.

Execution routes and retained snapshot/proposal handles identify state or data,
not authority. They may survive an approval wait while invocation tokens do not.
Release and retirement clean backend execution state without retargeting or
resolving approvals. Exact mechanics and lifecycle APIs belong to
[`orchestration`](../../packages/orchestration/README.md#remote-strategies).

### Remote model tools

Materialization captures the exact remote contribution and required Session-bound
Environment facets/dependencies. Declared dependencies are not permission grants.
Validation and description receive no effect authority; only execution through the
normal host policy/approval path receives the exact required host services.

Read, mutation, and process services remain separable, even when one contribution
provides tools with different needs. Transported IDs cannot choose another
Environment. Captured bindings are validated rather than re-resolved on execution
or continuation, and execution authority lasts only for the enclosing operation.
Detailed contracts and adapters belong to [`model_tool`](../../packages/model_tool/)
and [`plugin_runtime`](../../packages/plugin_runtime/README.md#operation-scoped-host-calls).
Tool-specific declarations and behavior belong to their owning plugins, for
example the [Filesystem Tools](../../plugins/filesystem_tools/README.md) and
[Command Tools](../../plugins/command_tools/README.md) READMEs.

### Remote inference sources

Remote inference sources register through the extension model, not Capability
provider selection. Snapshot execution receives only the host services authorized
by that point. The current AGENTS.md source receives read-only Session/Environment
authority; transported Session/Run IDs cannot reconstruct or redirect it.

Executable bindings are validated through capture. Safely captured immutable
material may outlive source registration according to the owning extension
contract; that does not keep the executable binding or invocation authority alive.
The next capture can discover a replacement without retrying the current capture
through it. See [`orchestration`](../../packages/orchestration/README.md#inference-context)
and the [AGENTS.md plugin](../../plugins/agents_md/README.md) for source semantics,
transport contracts, and their tests.

## Generation-scoped infrastructure access

Storage must serve Session snapshots, configuration, and lazy initialization
outside a Run operation. `PluginBackendHost.startPlugin` accepts a generic
`createInfrastructureServices` factory called with the actual connection, not a
plugin ID detached from its generation. Bootstrap carries one required opaque
`hostInfrastructureContext` string for that exact generation. Only the supplied
service allowlist is accessible; installation or readiness alone does not select
services. The context is live access metadata, never durable data or a Profile.

Infrastructure access is revoked on backend activation retirement or rollback,
stop, close, and termination, before asynchronous cleanup. Pending responses are
settled without waiting for arbitrary service code. A generated dispatcher may
have queued a call before retirement, so storage rechecks
`connection.validateInfrastructureContext` at actual service entry, immediately
before synchronous database work. Transport admission alone is insufficient.
Retired access never retargets a replacement; revocation cannot undo an SQL commit.
Registration-only retirement or rollback of a subset does not retire the whole
generation. A standalone activation's connection-ending `close` does revoke
infrastructure before awaiting registration cleanup.

The app factory `projectStorageServices(lifecycle, connection)` captures
`PluginId(connection.pluginId)` in `ProjectStorageHost`. It is generic composition,
not stock-plugin dispatch, and is supplied for every normal backend connection.
Storage is not added to operation-token allowlists. Conversely, its infrastructure
grant supplies no execution, orchestration, model/tool, Environment-facet, or
filesystem services. [ADR 0034](../adr/0034-plugin-owned-relational-session-storage.md)
narrowly amends ADR 0032's invocation-only host-access rule without widening
semantic operation authority.

### Session-scoped relational storage

Pure-Dart [`adele_project_storage`](../../packages/project_storage/lib/adele_project_storage.dart)
owns `ProjectStorageService`, a generated host service, not a provider-selected
Capability. Its narrow surface is:

| Operation | Boundary |
| --- | --- |
| `isDurableSession(sessionId)` | Resolve Session -> Task -> currently open Project. False only for a published Session in an explicitly volatile Project; missing/closed/error cases throw. |
| `ensureSchemaForSession(sessionId, migrations, accessMode)` | Validate all script statements as supported `CREATE TABLE` forms before execution, then coordinate the connection-owned plugin's schema transactionally; version is the migration list length. The [storage contract](../../packages/project_storage/README.md#service) defines the restricted script syntax. |
| `queryForSession(sessionId, sql, parameters, accessMode)` | One read-only `SELECT` statement with named parameters and bounded `RelationalRow.values` results. |
| `transactionForSession(sessionId, statements, accessMode)` | Commit a host-owned transaction of `INSERT`, `UPDATE`, or `DELETE` statements; statements carry `sql`, named `parameters`, and nullable `expectedRows`, whose mismatch rolls back the batch. |

Storage operations require an explicit `ProjectStorageAccessMode`: `durable`
retains durable-only access and rejects volatile Projects; `durableOrTemporary`
permits [host-retained temporary backing](product-model.md#project-storage) for an
already volatile Project. It does not change `isDurableSession`, replace durable
backing after failure, or extend infrastructure authority. The same exact-generation
validation and service-entry lifecycle check govern both modes. SQLite work after
those checks is synchronous, so accepted operations finish before connection
disposal; queued work not yet admitted fails after retirement or close. No grant is
kept alive for storage draining and no extra backend-shutdown dependency is added.

Parameters and row maps admit only strings, integers, and null, not arbitrary JSON
or SQLite objects. Query responses are bounded to 1000 rows and 1 MiB; excess fails
rather than truncating. This bounds each response, not total Session history.
Exact declarations and codecs remain owned by the package.

The host derives backing through its canonical live graph without resolving a
strategy or materializing an Environment. Callers supply no owner, database path,
or raw SQLite connection. Storage requires a live infrastructure grant but the
Session ID is a storage selector, not a per-Session permission token. SQL is
deliberately not a parser sandbox: the host does not enforce table prefixes or
row isolation. Stock SQL operates on its owner's tables and uses relational
foreign keys to core identities. This semantic ownership convention must not be
described as protection against arbitrary malicious plugin SQL; that sandbox is
deferred. [Plugin persistence](plugin-system.md#plugin-owned-state-and-persistence)
owns schema and state semantics, while [Project storage](product-model.md#project-storage)
owns the private database and core graph.

## Source map

| Concern | Primary anchors |
| --- | --- |
| Contract annotations, channels, and exposure values | [`packages/contract/`](../../packages/contract/) |
| Generator and generated client/dispatcher behavior | [`packages/contract_codegen/`](../../packages/contract_codegen/) |
| Capability registry and resolution | [`packages/capabilities/`](../../packages/capabilities/) |
| Backend-ready registration, adapters, and exact channels | [`packages/plugin_runtime/`](../../packages/plugin_runtime/) |
| Plugin-side reverse-call multiplexer | [`packages/plugin_backend_support/`](../../packages/plugin_backend_support/) |
| Shared backend host transport | [`packages/plugin_backend_host/`](../../packages/plugin_backend_host/) |
| Remote orchestration and inference contracts | [`packages/orchestration/`](../../packages/orchestration/) |
| Remote model-tool contract | [`packages/model_tool/`](../../packages/model_tool/) |
| Environment authorized host services | [`packages/environment/`](../../packages/environment/) |
| Relational infrastructure contract / service-entry validation | [`packages/project_storage/`](../../packages/project_storage/), [`app/lib/core/project_storage_host.dart`](../../app/lib/core/project_storage_host.dart) |
| App-side remote adapters | [`remote_command_host.dart`](../../app/lib/core/remote_command_host.dart), [`remote_inference_context_host.dart`](../../app/lib/core/remote_inference_context_host.dart), [`remote_model_tool_host.dart`](../../app/lib/core/remote_model_tool_host.dart), [`remote_orchestration_host.dart`](../../app/lib/core/remote_orchestration_host.dart) |
| Canonical local authority and Environment facets | [`product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), [`model_tool_host.dart`](../../app/lib/core/model_tool_host.dart), [`inference_context_host.dart`](../../app/lib/core/inference_context_host.dart) |
| Prepared frontend ownership and bridges | [`packages/ui/`](../../packages/ui/), [`app/lib/frontend/`](../../app/lib/frontend/) |
