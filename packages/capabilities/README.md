# ADELE Capabilities

`adele_capabilities` is an experimental public, pure-Dart package for concepts
used to select which provider handles callable inter-plugin work. It includes
`CapabilityId`, `ProviderId`, `CapabilityKey`, `ProviderDescriptor`,
`CapabilityEndpoint`, active registrations, exact registration-bound
`ProviderBinding`s, structured resolution failures, and the in-memory
`CapabilityRegistry`. The public entrypoint is
[`adele_capabilities.dart`](lib/adele_capabilities.dart).

Capabilities are one callable specialization within ADELE's
[Extension Point architecture](../../docs/architecture/plugin-system.md).
Generic typed registration/discovery and binding liveness are implemented in
[`adele_plugin_api`](../plugin_api/README.md) and used by maintained domain extension
points. `adele_capabilities` owns specialized Action/Service provider selection,
not that generic registry or universal composition for UI, strategies, or Events.

## Semantics

Actions are brokered one-shot operations. Services are sustained typed
capabilities, such as model providers and the implemented Environment provider
capability. [`adele_environment`](../environment/README.md) owns Environment
establishment/restoration and filesystem/process semantics. Session-authorized
read, mutation, and process facets and their generated host services are not
separately selected Capability providers: they are captured operation
authorities/services over the selected Environment. See
[operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).

Events report facts that occurred. They are semantically read-only
notifications: subscribers do not change whether the fact occurred, and a
subscriber failure normally does not retroactively fail the producer. Generic
public Event publication/subscription is not yet implemented and Events do not
imply a durable replay log.

A `CapabilityKey` matches a capability ID and exact positive major version.
`CapabilityRegistry.providersFor` returns an unmodifiable snapshot of zero, one,
or many currently available providers, ordered by descending rank and then
ascending lexical provider ID. Default resolution chooses the first; explicit
provider selection fails rather than silently falling back to another provider.

Resolution captures one exact registration in a `ProviderBinding`.
`endpointAs<T>()` checks registration liveness, endpoint availability, and type.
Closing its `CapabilityRegistration` makes the binding stale even if the same
provider ID is registered again. `CapabilityRegistrationGroup` supports grouped
retirement. Closing a registration does not dispose its endpoint or universally
revoke already extracted channels; consumers/adapters must retain and validate
the exact binding at invocation and relevant asynchronous settlement boundaries.
See the [registry source](lib/src/capability_registry.dart) and
[tests](test/capability_registry_test.dart) for exact failure distinctions.

Rank/ID ordering is the current deterministic default, not the final preference
model or a provider declaration of global primacy. Default selection remains
host-owned; future user/Profile/Project preferences belong to
[profiles and configuration](../../docs/architecture/profiles-and-configuration.md).

A single plugin runtime may expose several configured instances of one
capability. The OpenAI plugin proves this with separately routed API-key and
experimental ChatGPT model-provider contexts in one generation; other examples
include accounts, clusters, connections, endpoints, MCP servers, and devices.
These are not extra plugin installations or backend copies.

Temporary browser sessions, terminals, open documents, processes, connections,
and active tool executions are runtime resources, not configured capability
instances. They may use runtime handles or resource objects rather than
persistent provider configuration.

## Dependencies

It may depend only on lightweight public plugin-facing packages when required.
Flutter and internal packages (`plugin_runtime`, `plugin_builder`,
`agent_kernel`, and `adele_desktop`) are prohibited.

Plugins may also cooperate through deliberately public extension interfaces
defined by core or another plugin/component. Depending on such an interface is
not the same as depending on one specific implementation plugin being active.
See [dependency rules](../../docs/architecture/dependency-rules.md) and the
[plugin system](../../docs/architecture/plugin-system.md).

## Deferred

Persistent preferences, generic configured-instance discovery/management,
generic Event subscription, profile-aware routing, richer compatibility
negotiation, dynamic suitability, and durable handles remain deferred. Not every
proposed extension point or composition policy is implemented; non-capability
composition belongs to its point/domain, not a generalized provider-selection
mechanism here.

The current registry implements deterministic rank/ID ordering, exact-major
resolution, and explicit/default generation-bound binding; generated clients
consume the resulting endpoint elsewhere. The registry is not a production
preference engine or the complete ADELE extension system.
