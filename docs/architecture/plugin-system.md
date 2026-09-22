# ADELE Plugin System

Role: Canonical architecture

Implementation status: Partial

This document defines plugin ownership, identity, lifecycle, and recursive typed
composition. ADELE implements generic registration/discovery/liveness and several
concrete extension-point families. The broader recursive ecosystem, general
profile/activation management, Commands/keybindings, and full plugin-management
and productization remain incomplete. Public plugin APIs remain experimental.
Source/tests establish current behavior; [ADR 0030](../adr/0030-recursive-typed-plugin-extension-model.md)
records the recursive extension decision and its rationale.

## Core and plugin ownership

A plugin is an independently identified unit of product behavior whose active
components participate through public typed interfaces. ADELE is not a fixed
application with plugins confined to its edges: plugins can introduce more
specific concepts and deliberately public extension APIs of their own.

Core owns stable concepts and generic infrastructure needed by unrelated plugins:
shared product identities, registration/discovery/liveness, host lifecycle and
routing, final authorization, and generic hosting/composition. Plugins own concrete
behavior where no shared core semantic owner is required. For example, Chat owns
its strategy state, while Git supplies an Environment implementation; neither
behavior belongs in the universal product schema.

A valid application can exist with zero installed plugins. Core/application code
must not require concrete stock implementations; missing plugin behavior stays
unavailable rather than acquiring a built-in substitute. Plugins cooperate through
deliberately public typed APIs, not dependencies on one another's implementation
packages. Exact package and application boundaries, including the temporary
provider-selection identity exception, belong to [dependency rules](dependency-rules.md).
The [product model](product-model.md) owns shared product semantics.

## Identity and lifecycle distinctions

These concepts must not be inferred from one another:

| Concept | Meaning |
| --- | --- |
| Plugin semantic identity | `PluginId` names the plugin independently of its implementation packaging and live generations. |
| Dart/package/source identity | Package names, source directories, repositories, and artifact locations organize implementation and preparation, not plugin semantics. |
| Installation | Makes an implementation available to ADELE; does not establish contextual participation or live readiness. |
| Activation context | The host context in which an installed plugin participates. Activation is contextual, not an intrinsic installed-metadata flag. |
| Runtime generation | One live activation/component generation and its owned registrations/resources. A replacement is not the same executable object even if all semantic IDs match. |
| Configured capability instance | A named account/provider/endpoint or similar configuration exposed by a runtime, not another installation or necessarily another runtime. |
| Temporary runtime resource | A process, terminal/browser session, open document, active connection, or other temporary object created and disposed during operation. |

`PluginId` is not a Dart package name, repository directory, artifact filename,
display name, Capability ID, Extension ID, or configured instance ID.
[ADR 0010](../adr/0010-plugin-identity-differs-from-dart-package-identity.md)
records why plugin and package identities are separate.

Installation does not activate a plugin in every context. Deactivation ends its
participation in that context without uninstalling it or deleting dormant
persisted configuration. The intended default is one plugin runtime per activation
context; one runtime may expose multiple configured capability/provider instances.
Generation-bound configuration routing handles are not persistent instance records.

Complete installation/update management and profile-aware activation are not
implemented. Current prepared startup composition does not establish those
systems. [Profiles and configuration](profiles-and-configuration.md) owns the
deeper activation, configured-instance, configuration, and runtime-state model.

## Source and prepared components

Plugin source is the canonical distribution form. A source plugin may contain
independently relevant shared contract, backend, and frontend components; it need
not supply both an executable backend and frontend to be useful.

Frontend and backend implementations do not depend directly on one another.
Shared typed declarations belong in deliberate contract/public API packages.
Shared transport contracts are pure Dart and depend on neither implementation nor
Flutter. The separation follows [ADR 0003](../adr/0003-separate-contract-frontend-and-backend-packages.md),
without requiring every plugin to implement all three roles.

Source/build preparation and runtime activation are separate concerns. Normal
activation consumes prepared artifacts, not source compilation. Prepared frontend
and backend availability, failure, and retirement can be independent; an operation
that needs both still requires its exact live counterparts. See
[plugin layout](plugin-layout.md) for current source/prepared structure and
[development documentation](../development/README.md) for the build workflow.

## Recursive typed extension points

An **Extension Point** is a typed place where active components may register
participation. Its semantic owner may be core or a plugin/domain package:

```text
core typed extension point
    -> plugin behavior
        -> deliberately public plugin-owned extension point
            -> other plugin contributions
```

An owner defines the public semantic contract, not a required implementation.
Another plugin may depend on that API without requiring one particular
implementation plugin to be active:

| Dependency | Meaning |
| --- | --- |
| Interface/API dependency | Knowledge of a deliberately public semantic contract. |
| Implementation/activation dependency | Requiring one concrete implementation plugin to be active. |

ADELE favors interface discovery over hidden activation dependency chains. An
unconsumed contribution or an unavailable integration can be valid; the host must
not silently activate another plugin to manufacture availability. One plugin may
contribute to several independent extension points without multiplying runtimes.

Where core must authoritatively validate or route a shared product identity, core
owns the minimal public extension contract needed to preserve that invariant.
For example, optional Session presentation cannot own the strategy-binding contract
required by Session lifecycle. More-specific plugin ecosystems retain their own
API owners. Introduce the smallest concrete typed boundary needed, not a universal
framework or new API package solely for hypothetical future reuse.

### Capability is a specialization

A **Capability** is a callable Action/Service provider-selection semantic: Actions
are brokered one-shot operations; Services expose sustained typed functionality.
It is one specialization of broader composition. UI contributions, inference
sources, strategies, Commands, and other participation must not be forced through
Capability merely because its registry already exists. A generated callable
service is not automatically an advertised Capability.

Compatible providers may number zero, one, or many. Default-provider selection is
host-owned, not a provider's declaration that it is globally primary. Provider
resolution, generated transport, and remote invocation belong to
[contracts and capabilities](contracts-and-capabilities.md).

Events remain read-only fact notifications, not provider-selected calls or mutable
lifecycle hooks. Observers cannot change whether the announced fact occurred;
subscriber failures normally do not retroactively fail its producer. Events do
not themselves imply durable history or replay.

### Composition belongs to the extension point

Each owning contract defines its zero/one/many behavior, selection/composition,
ordering, applicability, and failure semantics. The generic registry does not
prescribe exactly one implementation, numeric priority, generic before/after
ordering, fallback, or one applicability/failure policy.

Examples illustrate different contracts, not a universal rule:

| Extension family | Composition owner and rule |
| --- | --- |
| Orchestration strategy | [Orchestration](../../packages/orchestration/README.md) requires exact unique resolution for an explicit strategy ID; missing and ambiguous are distinct failures. |
| Inference-context sources | [Inference context](../../packages/orchestration/README.md#inference-context) composes zero or many sources under its own capture, ordering, and required/optional failure rules. |
| Model tools | [Model-tool API](../../packages/model_tool/) defines contextual contributions; its composition has distinct tool-identity and model-alias collision semantics. |
| Project selectors | [Core extension contracts](../../packages/core_extensions/README.md) expose independent actions, not interchangeable default providers. |

Prefer structured typed contributions when an extension influences an operation,
not opaque mutation of host objects through universal `beforeX`/`afterX` hooks.
Numeric priority may suit a particular domain, but it is not a universal
extension-system concept. Deterministic ordering does not confer authority.

## Live discovery and exact captured bindings

Registration and discovery are live. A fresh operation may discover current
contributions; a discovery snapshot is not a permanent startup inventory.
Consumers must distinguish:

| Identity | Meaning |
| --- | --- |
| Semantic identity | The plugin/provider/domain behavior being named, stable across live generations. |
| Registration identity | A named contribution at a typed point, such as an `ExtensionId`; not necessarily the domain identity it implements. |
| Exact live binding | One particular registration occurrence and its generation/liveness, retained by a resolved operation. |

Where execution correctness requires a live contribution, resolution/materialization
captures that exact binding. Consumers and host adapters validate it through the
relevant invocation and asynchronous settlement boundaries. Retirement makes the
captured binding stale; replacement registration never silently retargets it.
Reusing semantic IDs, registration IDs, or even a contribution object cannot make
an old binding live again. Cleanup likewise retires only owned registrations,
not replacements. Retirement does not promise rollback of effects already started.

Immutable capture has a different lifetime from executable binding. For example,
inference-source bindings are validated through capture; safely copied and
validated immutable material can outlive source retirement. The next capture may
discover replacements, but the current capture does not silently retry through one.

The public [extension registry API](../../packages/plugin_api/lib/src/extension_registry.dart)
defines `ExtensionRegistry`, `ExtensionBinding`, and `StaleExtensionBinding`.
[Capability bindings](../../packages/capabilities/README.md),
[execution semantics](agent-kernel-semantic-model.md), and the
[product model](product-model.md) explain their domain-specific lifetimes.

## Backend and frontend composition

### Backend

Current architecture runs native Dart AOT backends outside the Flutter isolate,
in separately loaded isolate groups within a shared child Dart runtime.
[ADR 0019](../adr/0019-shared-process-hosted-plugin-backends.md) records the hosting
decision. Process/isolate separation is not a security sandbox.

A backend may advertise public capability/extension contributions once ready.
The host validates and adapts them into the existing public registries with exact
generation liveness. Host adapters implement known public contracts; their adapter
lookup is not a second registry of plugin contributions or automatic transport for
every future plugin-defined interface. Activation owns registration rollback and
retirement. A failed backend does not imply a built-in substitute implementation;
shared-host failure can affect all backends it hosts.

### Frontend and collaboration

Prepared plugin frontends execute through the interpreted Flutter path in the
maintained design, preserving the [frontend/backend split](../adr/0002-split-interpreted-frontend-and-aot-backend.md).
Frontend contribution metadata can establish semantic presentation and behavioral
roles independently of backend readiness. The frontend owner activates prepared
generations from the same installation catalog and registers contributions in the
existing extension registry. Registration does not guarantee every view will
render successfully.

When frontend and backend cooperate, they use deliberate public/shared contracts
and host-provided bridges, not implementation imports or shared runtime objects.
The host may capture exact owning-backend selection where required. Belonging to
the same plugin does not grant a frontend arbitrary backend or host authority;
missing or retired counterparts fail explicitly rather than retargeting. See
[contracts and capabilities](contracts-and-capabilities.md) for own-backend requests,
operation-scoped host calls, service allowlists, and transport mechanics.

## UI and presentation

Plugin-facing UI extension points describe semantic roles, not fixed physical
coordinates. Host-owned layout can evolve without redefining those contracts,
and plugins may define further semantic regions within their own presentation.
The host can render common structural elements while plugins supply richer views.

Rendering or invoking an operation does not make a plugin its semantic owner.
Common host lifecycle, execution authority, and approval semantics remain
host-owned. Read-only observation does not confer execution or approval power.
Rich presentation may disappear or fail without invalidating underlying safe
execution evidence where the specific contract defines that behavior; this is
not a universal fallback or failure policy.

The public [UI package](../../packages/ui/README.md) maps current semantic contracts;
the [application presentation map](../../app/README.md#activity-inspection) covers
implemented hosting. [Product direction](../product/README.md) describes intended
experiences rather than fixed extension coordinates.

Application Command registration, search, and keybinding resolution are host
infrastructure; plugins contribute Commands and suggested bindings. UI affordances
should invoke the same domain/Command behavior as other surfaces, not create
UI-only semantics. Broader Command infrastructure is not yet implemented.
Application Commands are distinct from model tools that execute external programs.

## Plugin-owned state and persistence

Plugins retain semantic ownership of their domain-specific state. Host persistence
facilities are intended to support ordinary plugin-owned state associated with
stable product identities without absorbing plugin schemas into core. Such general
persistence facilities are not implemented; this boundary defines no storage API.
Plugin state should normally survive deactivation, while domain-native external
systems may remain authoritative where that is part of the feature.

Plugin state, ordinary configuration, activation, security/policy, temporary runtime
resources, and workbench/window state are distinct concerns, not one generic state
object. See the [product model](product-model.md) and
[profiles and configuration](profiles-and-configuration.md) for their ownership
and persistence boundaries.

## Authority remains host-owned

Plugin identity, extension registration, Capability ID, Session ID, Environment ID,
and an own-backend relationship do not themselves grant authority. Plugins may
supply domain knowledge, effect descriptions, or policy input; final allow/deny/ask
authorization remains host-owned.

The host supplies only services and authority appropriate to the current operation
and exact generation. Through host APIs, plugins cannot turn stable IDs into
broader filesystem, process, or other host authority. Revocation ends that access,
not necessarily effects already in flight. These are host-service boundaries, not
claims that native backend code is OS-sandboxed. The deeper contract is
[operation-scoped host calls](contracts-and-capabilities.md#operation-scoped-host-calls),
with rationale in [ADR 0032](../adr/0032-remote-backend-extensions-use-operation-scoped-host-services.md).

## Source map

| Concern | Primary anchors |
| --- | --- |
| Plugin identity / generic extension registry | [`packages/plugin_api/`](../../packages/plugin_api/) |
| Capability provider routing | [`packages/capabilities/`](../../packages/capabilities/) |
| Core-owned extension contracts without another domain owner | [`packages/core_extensions/`](../../packages/core_extensions/) |
| Domain extension points | [`packages/orchestration/`](../../packages/orchestration/), [`packages/model_tool/`](../../packages/model_tool/), [`packages/ui/`](../../packages/ui/) |
| Prepared/backend runtime | [`packages/plugin_runtime/`](../../packages/plugin_runtime/) |
| Shared backend process host | [`packages/plugin_backend_host/`](../../packages/plugin_backend_host/) |
| Backend activation/composition | [`app/lib/core/application_plugin_bootstrap.dart`](../../app/lib/core/application_plugin_bootstrap.dart) |
| Frontend activation/composition | [`app/lib/frontend/application_frontend_bootstrap.dart`](../../app/lib/frontend/application_frontend_bootstrap.dart) |
| Source/prepared physical layout | [`plugin-layout.md`](plugin-layout.md) |
| Concrete implementations | [`plugins/`](../../plugins/) |
