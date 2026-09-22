# Contracts and Capabilities

Role: Canonical architecture

Implementation status: Partial

This document owns the cross-system semantic boundary between typed transport,
callable provider selection, exact live bindings, and host invocation authority.
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
a second semantic contract; the current eval projection supports a narrower,
unary-only surface rather than all native transport shapes.

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

## Own-backend frontend requests

Prepared frontends can use generated unary clients to call explicitly allowlisted
services on their captured owning backend. This is direct routing to one exact
backend generation and configuration context, not Capability provider discovery.
The prepared descriptor constrains allowed services; interpreted frontend code
cannot select an arbitrary PluginId, configuration context, or service.

The host validates captured ownership and presentation lifetime before dispatch
and after settlement. Where owning-backend strategy affinity is required, it must
prove the strategy's exact registration origin, not merely matching semantic IDs.
Missing, retired, or mismatched ownership fails explicitly, without retargeting or
native/in-process fallback. Same-plugin identity alone grants no arbitrary service
access.

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
and the [Local Directory plugin](../../plugins/local_directory_project_selector/README.md).

## Operation-scoped host calls

Backend-to-host access is explicitly supplied for one authorized operation:

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
| App-side remote adapters | [`remote_inference_context_host.dart`](../../app/lib/core/remote_inference_context_host.dart), [`remote_model_tool_host.dart`](../../app/lib/core/remote_model_tool_host.dart), [`remote_orchestration_host.dart`](../../app/lib/core/remote_orchestration_host.dart) |
| Canonical local authority and Environment facets | [`product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), [`model_tool_host.dart`](../../app/lib/core/model_tool_host.dart), [`inference_context_host.dart`](../../app/lib/core/inference_context_host.dart) |
| Prepared frontend ownership and bridges | [`packages/ui/`](../../packages/ui/), [`app/lib/frontend/`](../../app/lib/frontend/) |
