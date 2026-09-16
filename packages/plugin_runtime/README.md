# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package for the shared backend host.
It owns the semantic process-host connection, deterministic framed
IPC, request correlation, plugin routing, structured remote failures,
exit/stderr monitoring, and shutdown cleanup. It also owns the prepared installation
catalog and active capability registration adapters. Process and framing objects
do not escape its API.

## Dependencies

It may depend on ADELE's public plugin-facing packages and small pure-Dart host
packages when implementation requires them. It must not depend on Flutter,
plugin implementations, `adele_desktop`, or `plugin_builder`. Plugins must never
depend on this package.

## Runtime Model

The intended default remains one plugin runtime instance per activation
context; activation-context lifecycle is not implemented. The maintained
runtime proves that one plugin generation can expose several configured
capability instances under separate configuration contexts and that
context/service routing fails closed. Additional runtimes for isolation or
concurrency may be considered after evidence exists.

The maintained semantic surface is `PluginBackendHost` plus per-plugin
`PluginBackendConnection`. It intentionally hides `Process`, framing, ports,
and request IDs.

Stopping a plugin fails its outstanding requests. Malformed host output closes
all connections and kills and reaps the child process.
`PluginBackendConnection.close()` has one supported behavior: bounded semantic
plugin shutdown.

## Startup Arguments

[`PluginBackendHost.startPlugin`](lib/src/backend_connection.dart) accepts
`bool startupArgumentsOnly = false`, forwarded through the shared host to the
backend startup message alongside opaque argv. Normal application bootstrap always
sets it to `true`, including when no startup-arguments file or plugin entry exists.
Direct and self-hosting callers retain the default `false` and their existing
environment-based configuration behavior.

This temporary argv-only deployment mode carries no plugin-specific configuration
schema, PluginId switch, or credential interpretation in generic runtime code.
The owning backend honors the mode; it is not process-environment scrubbing,
sandboxing, or general settings/profile/credential infrastructure. See
[`app/README.md`](../../app/README.md#chatgpt-source-checkout-configuration) for
OpenAI's no-fallback and empty-configuration behavior.

## Prepared Catalog

[`PreparedPluginCatalog.discover(rootPath)`](lib/src/prepared_plugin_catalog.dart)
reads a deterministic startup snapshot of immediate child directories'
`adele_plugin.installation.json` files, not source `adele_plugin.yaml` manifests.
It validates metadata and independently optional backend/frontend components with
confined prepared files, without starting processes, compiling source, loading
EVC, or watching for changes. `PreparedPluginInstallation` retains optional
`backendArtifactUri` and `frontend`; `PreparedFrontendComponent` contains the
artifact URI and immutable presentation descriptors. The sealed, data-only
`PreparedPresentationDescriptor` variants are `PreparedSessionPresentation`,
`PreparedToolActivityPresentation`, and `PreparedModelNativeActivityPresentation`.
They use existing public identity types without importing Flutter, `adele_ui`,
eval, or concrete plugins. Strict role-specific fields describe executable
ABI/preparation data, not profile or activation state. The schema and failure rules
live in
[`plugin-layout.md`](../../docs/architecture/plugin-layout.md#prepared-installation-snapshot).

Unconfigured, missing, or empty roots succeed empty. Malformed/unreadable
installation envelopes produce installation-wide issues and are excluded. An
invalid component instead records `PreparedPluginCatalogIssue.component` as
`PreparedPluginComponent.backend` or `.frontend`, omitting only that component
while retaining the installation and healthy sibling. Invalid roles/descriptors
invalidate the frontend component. Readable valid identities are reserved before
the remaining validation; duplicate PluginIds exclude all conflict members,
including otherwise invalid manifests, without version selection. Root I/O
failures propagate instead of looking empty.

File confinement and existence do not establish executable EVC correctness.
Flutter-side `PreparedFrontend.load` reads immutable bytes once per generation;
decoding/entrypoint failures, including readable corrupt bytecode, stay per-view.
The pure-Dart catalog neither decodes nor links frontend code.

The app separately owns the policy of attempting all discovered valid components.
Its backend bootstrap publishes this same catalog before backend startup, and
window-owned `ApplicationFrontendBootstrap` consumes it on the existing extension
registry. There is no second discovery root/catalog or registry. No valid backend
components means no host process, even with invalid host paths; frontends remain
independently activatable. Profiles are unimplemented participation policy, not
descriptor metadata. See
[`app/README.md`](../../app/README.md#normal-backend-startup) for bootstrap ownership.

## Ready Capabilities

Backend-owned `capabilityExposures` travel on the existing isolate-ready and host
`pluginReady` path and are retained on the exact connection. Omission means zero
capabilities.
[`PluginCapabilityActivation.registerAdvertised`](lib/src/capability_runtime.dart)
delegates to existing `register`, using connection-owned plugin identity and
generation-bound contexts.
Registry validation, partial-registration rollback, termination retirement, and
stale-binding semantics remain unchanged; installed metadata never registers a
provider. See
[`contracts-and-capabilities.md`](../../docs/architecture/contracts-and-capabilities.md#backend-ready-advertisements).

The runtime knows no Git/OpenAI source paths, credential schemas, or stock exposure
tables. Startup argv is opaque plugin input. Prepared frontend discovery adds no
profile/enable-disable management, version solving, reverse RPC, or hot upgrade.

## Validated Scope

Direct Flutter `Isolate.spawnUri` remains disproven. The continuation starts one
shared child `dartaotruntime` host, which successfully loads plugin snapshots in
separate isolate groups under Linux profile mode. Generated unary and streaming
requests retain exact generation, configuration-context, and service routing;
the protocol handshake and shutdown/cancellation paths have existing validation.
That evidence does not establish validation of every F1 catalog/advertisement or
F2 frontend-discovery/activation path.
The prepared startup catalog is narrower than an installer, profiles, packaging,
or production lifecycle, which remain deferred.
