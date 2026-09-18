# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package for the shared backend host.
It owns the semantic process-host connection, deterministic framed
IPC, request correlation, plugin routing, structured remote failures,
exit/stderr monitoring, and shutdown cleanup. It also owns the prepared installation
catalog, active capability/extension registration adapters, and operation-scoped
unary host-call routing. Process and framing objects
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
The PluginId remains reserved until that stop completes; a concurrent same-ID
start fails explicitly instead of racing old-generation cleanup.

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

## Ready Registrations

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

`extensionExposures` follows the same path using public `AdeleExtensionExposure`;
omission means zero extensions. `PluginExtensionActivation.registerAdvertised`
selects a host `RemoteExtensionAdapter` by extension-point ID and registers its
exact-generation proxy in the existing `ExtensionRegistry`.
`RemoteExtensionAdapterRegistry` is an internal host adapter facility, not another
contribution registry or a plugin-facing API. Unsupported points, invalid
point-specific metadata, and collisions fail activation with exact rollback.

`PluginBackendActivation.registerAdvertised` coherently owns both capability and
extension phases. Failure rolls back both and closes that attempt's connection;
retirement removes both sets before connection close. Local failure and later
termination do not remove unrelated registrations or replacements. The app supplies
the inference-source and model-tool adapters; runtime owns neither point's metadata
or composition rules.

The runtime knows no Git/OpenAI/AGENTS.md/Search/Filesystem source paths, credential
schemas, or stock exposure tables. Startup argv is opaque plugin input. Profiles/enable-disable
management, version solving, watching, and hot upgrade remain deferred.

## Unary Host Calls

Both host and plugin-backend protocols are version 2; rebuild prepared artifacts
together. `PluginBackendConnection.openHostInvocation` grants an opaque secure
per-operation context with an explicit service-dispatcher allowlist on that exact
connection. `RemoteExtensionContext.invoke` brackets the operation and revokes it
in `finally`, on registration retirement, and on connection shutdown/termination.
Revocation settles pending host calls without awaiting arbitrary service code.

`RemoteExtensionContext.invokeStream` supplies the same operation ownership for a
host-to-backend stream. It is single-subscription and lazy: neither the context nor
the operation starts before listen. Authority is revoked on done, first error,
cancellation, or exact registration/connection retirement, before awaiting producer
cancellation. Retirement also fails idle or paused streams. Pause/resume propagates
to the producer; late events cannot revive authority or migrate to a replacement.
This adds no wire messages or protocol-version change and does not make reverse
host calls streaming.

`hostRequest`/`hostResponse` reuse the same isolate ports and framed shared host.
The shared host stamps connection generation and plugin identity from the owning
isolate, and the runtime validates generation, invocation liveness, and the service
allowlist before dispatch and after settlement. Late responses cannot migrate to
a replacement. Semantic Session/Run identifiers do not confer authority.
Generated dispatchers preserve declared failures; the app captures canonical
inference-source context or a materialized tool's coherent Session-bound
read/mutation facets. The unchanged authorized read service's no-argument authority
query and file/directory reads cannot select a different Environment. Separate
generated `AuthorizedEnvironmentMutationService` supplies only create-new,
conditional replacement, and conditional deletion, with no authority query,
authority-selection IDs, or process methods.

For remote model tools, exposure `hostServices` declares maximum captured
dependencies; each descriptor's required `executionHostServices` must be an exact
allowed subset. The app adapter validates these point-specific declarations and
all captured exact bindings, not this package. Materialize/validation receive no
token and description receives pure identity data. Only execution after
policy/approval receives a fresh stream-lifetime token whose allowlist contains
exactly that descriptor's services. Filesystem read execution cannot acquire
mutation through the contribution's broader dependency list; Search execution is
read-only. Captured facets must share Session/Environment identity, with no
re-resolution or authority chosen by transported IDs. These services add no transport
message kinds or protocol bump. Revocation does not roll back in-flight mutations.
See [the host-call contract](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).

Plugins use public `adele_plugin_backend_support`, not this package, for their
request-channel multiplexer. This is unary operation-scoped access, not general
symmetric RPC, reverse streaming, cancellation of arbitrary host code, or a sandbox.

## Maintenance And Limits

Backend AOT snapshots run in separate isolate groups within one shared child
`dartaotruntime` host, not directly in Flutter. Generated unary and server-streaming
requests retain exact connection-generation, configuration-context, and service
routing.

Maintained [package tests](test/) cover framing, connection lifecycle, prepared
catalog validation, and capability/extension activation and retirement. The app's
[real-AOT remote inference suite](../../app/test/core/remote_inference_context_integration_test.dart)
covers scoped authority, declared failures, pending-call cleanup, and
exact-generation source retirement. See
[inference hosting](../../app/README.md#orchestration-hosting) for the integration
boundary and focused maintenance command.

The prepared startup catalog is narrower than an installer, profiles, packaging,
or production lifecycle, which remain deferred.
