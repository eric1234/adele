# ADELE Capabilities

`adele_capabilities` is an experimental public, pure-Dart package for concepts
used to select which provider handles inter-plugin work. It includes capability
and provider identities, descriptors, active registrations, exact-generation
bindings, structured resolution failures, and the in-memory active registry.

## Semantics

Actions are brokered one-shot request/response operations, such as
`EditResource`, `ViewResource`, `ShowDiff`, and `OpenTerminal`. Services are
sustained typed capabilities, such as `WorkspaceService`,
`SourceControlService`, `ModelProvider`, and `ToolProvider`. Events report facts
that occurred, such as `ResourceChanged`, `EditorOpened`, and `PluginStarted`.

Several plugins may provide one action or service. For example,
`EditResource` may be handled by an ADELE in-app editor plugin or an external
editor launcher plugin. Current callers can detect availability, enumerate
compatible active providers, invoke the deterministic default, and explicitly
select an alternative. Providers cannot declare themselves globally primary.

A single plugin runtime may expose several configured instances of one
capability. The OpenAI plugin proves this with separately routed API-key and
experimental ChatGPT model-provider contexts in one generation; other examples
include accounts, clusters, connections, endpoints, MCP servers, editors, and
devices. These are not extra plugin installations or extra backend copies.

Temporary browser sessions, terminals, open documents, processes, connections,
and active tool executions are runtime resources, not configured capability
instances. They will use runtime handles or session objects rather than
persistent provider configuration.

## Dependencies

It may depend only on lightweight public plugin-facing packages when required.
Flutter and internal packages (`plugin_runtime`, `plugin_builder`,
`agent_kernel`, and `adele_desktop`) are prohibited.

## Deferred

Persistent preferences, generic configured-instance discovery/management,
message buses, profile-aware routing, richer compatibility negotiation,
dynamic suitability, and durable handles remain deferred. The current registry
implements deterministic rank/ID ordering, exact-major resolution, explicit or
default binding; generated clients consume the resulting endpoint elsewhere.
The registry is not a production preference engine. Provider-selection
precedence beyond that deterministic fallback is deliberately undecided.
