# ADELE Capabilities

`adele_capabilities` is an experimental public, pure-Dart package for concepts
used to select which provider handles callable inter-plugin work. It includes
capability/provider identities, descriptors, active registrations,
exact-generation bindings, structured resolution failures, and the in-memory
active registry.

Capabilities are one callable specialization within ADELE's broader accepted
Extension Point architecture. The current registry should remain focused on
provider selection for Actions/Services rather than become a universal registry
for UI contributions, Events, Commands, or structured operation composition.
The broader extension runtime is not yet implemented.

## Semantics

Actions are brokered one-shot request/response operations. Directional future
examples include displaying a source file or performing one review operation.
Services are sustained typed capabilities, such as `ModelProvider`, future
Environment filesystem/process access, or a future `ConsoleService`.

Events report facts that occurred. They are semantically read-only
notifications: subscribers do not change whether the fact occurred, and a
subscriber failure normally does not retroactively fail the producer. Generic
public Event publication/subscription is not yet implemented and Events do not
imply a durable replay log.

Several plugins may provide one Action or Service. For example, a future
`DisplaySourceFile` capability may be handled by ADELE's Internal Source Editor
or an external-editor launcher. Current callers can detect availability,
enumerate compatible active providers, invoke the deterministic default, and
explicitly select an alternative. Providers cannot declare themselves globally
primary.

The current default is deterministic rank/ID ordering. It is an implemented
fallback, not the final preference model. Accepted architecture keeps default
selection host-owned and allows future user/profile/Project context to choose a
preferred provider while callers may expose explicit alternatives.

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
See `docs/architecture/dependency-rules.md` and
`docs/architecture/plugin-extension-model.md`.

## Deferred

Persistent preferences, generic configured-instance discovery/management,
generic Event subscription, profile-aware routing, richer compatibility
negotiation, dynamic suitability, generalized default selection for
non-capability interfaces, and durable handles remain deferred.

The current registry implements deterministic rank/ID ordering, exact-major
resolution, and explicit/default generation-bound binding; generated clients
consume the resulting endpoint elsewhere. The registry is not a production
preference engine or the complete ADELE extension system.
