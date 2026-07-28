# ADELE Plugin API

`adele_plugin_api` is an experimental public package for plugin authors. Phase
0 provides only `PluginId`, `PluginMetadata`, and `ResourceRef`. These APIs are
not stable.

## Dependencies

It may depend only on lightweight public plugin-facing packages when a concrete
need exists. It must not depend on Flutter or internal packages such as
`plugin_runtime`, `plugin_builder`, `agent_kernel`, or `adele_desktop`.

## Boundaries

`PluginId` is distinct from a Dart package name, display name, repository name,
capability ID, and future profile ID. Plugin versions are opaque strings in
Phase 0; parsing, comparison, and ranges are intentionally absent. A future
phase will likely use a semantic-version implementation such as
`package:pub_semver` rather than adding a dedicated version value wrapper.

`PluginMetadata` does not contain activation, global enablement, configuration,
profile state, runtime-instance state, or configured provider instances.
Resources use `Uri` so identity is not tied to local filesystem paths.
Installation, build, activation, and runtime state remain separate future
concerns. They should be modeled only when implementation requirements exist.

## Deferred

Lifecycle contracts, plugin context and registration APIs, host-service access,
contribution declarations, activation contexts, manifest handling, and resource
schemes are deferred until runtime experiments establish their requirements.
