# ADELE Capabilities

`adele_capabilities` is an experimental public, pure-Dart package for concepts
used to select which provider handles inter-plugin work. Phase 0 implements only
the value-based `CapabilityId`.

## Semantics

Actions are brokered one-shot request/response operations, such as
`EditResource`, `ViewResource`, `ShowDiff`, and `OpenTerminal`. Services are
sustained typed capabilities, such as `WorkspaceService`,
`SourceControlService`, `ModelProvider`, and `ToolProvider`. Events report facts
that occurred, such as `ResourceChanged`, `EditorOpened`, and `PluginStarted`.

Several plugins may provide one action or service. For example,
`EditResource` may be handled by an ADELE in-app editor plugin or an external
editor launcher plugin. Future callers must be able to detect availability,
enumerate compatible providers, invoke ADELE's preferred provider, and
explicitly select an alternative. Providers cannot declare themselves globally
primary.

A single plugin runtime may expose several configured instances of one
capability. An OpenAI plugin runtime might expose Work and Personal model
provider configurations; other examples include accounts, clusters,
connections, endpoints, MCP servers, editors, and devices. These are not extra
plugin installations or extra backend copies.

Temporary browser sessions, terminals, open documents, processes, connections,
and active tool executions are runtime resources, not configured capability
instances. They will use runtime handles or session objects rather than
persistent provider configuration.

## Dependencies

It may depend only on lightweight public plugin-facing packages when required.
Flutter and internal packages (`plugin_runtime`, `plugin_builder`,
`agent_kernel`, and `adele_desktop`) are prohibited.

## Deferred

Registry, discovery, ranking, configured-instance discovery, preferences,
message buses, transport, profile-aware routing, compatibility, suitability,
and the conceptual invocation API are all deferred. Provider-selection
precedence is deliberately undecided.
