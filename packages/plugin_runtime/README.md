# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package for the shared backend host.
It owns the semantic process-host connection, deterministic framed
IPC, request correlation, plugin routing, structured remote failures,
exit/stderr monitoring, and shutdown cleanup. It also owns the prepared installation
catalog, active capability/extension registration adapters, and explicitly scoped
unary and server-streaming host-call routing. Process and framing objects
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

This section maps the current installed schema and catalog behavior. The
[catalog parser and prepared types](lib/src/prepared_plugin_catalog.dart) define
the exact JSON fields, defaults, descriptor variants, and validation rules;
[catalog tests](test/prepared_plugin_catalog_test.dart) exercise schema, path,
identity-conflict, and failure behavior. Source/tests are authoritative for those
implementation details. The architectural source/prepared/live boundaries belong
to [plugin layout](../../docs/architecture/plugin-layout.md#prepared-installation-snapshot).

[`PreparedPluginCatalog.discover(rootPath)`](lib/src/prepared_plugin_catalog.dart)
reads a deterministic startup snapshot of immediate child directories'
`adele_plugin.installation.json` files, not source `adele_plugin.yaml` manifests.
The version-1 envelope contains `manifestVersion`, `metadata`, and `components`.
`metadata` supplies `PluginMetadata`; the required `components` object may be
empty, retaining an inert metadata-only installation. A backend component supplies
an `artifact` path; a frontend supplies an `artifact` path and descriptors.
The in-memory catalog captures parsed metadata and validated locations, not an
atomic filesystem snapshot or artifact bytes. Later component loading can fail
even after discovery succeeds.
Discovery validates metadata and independently optional backend/frontend components
with confined prepared files, without starting processes, compiling source, loading
EVC, or watching for changes. `PreparedPluginInstallation` retains optional
`backendArtifactUri` and `frontend`; `PreparedFrontendComponent` contains the
artifact URI and separate immutable presentation and behavioral extension
descriptor lists. The sealed, data-only
`PreparedPresentationDescriptor` variants are `PreparedMainContentPresentation`,
`PreparedConsolePresentation`, `PreparedTaskBrowserPresentation`,
`PreparedToolActivityPresentation`, and `PreparedModelNativeActivityPresentation`.
The separate sealed `PreparedFrontendExtension` includes
`PreparedProjectSelectorExtension`, with `kind: 'projectSelector'` and required
`extensionId`, `projectProviderId`, `displayName`, `library`, and `entrypoint`.
Its optional `frontend.extensions` list defaults to empty and can coexist with the
required, possibly empty `presentations` list. Manifest version remains 1.

`PreparedCommandExtension` uses `kind: 'command'` and exactly these required fields:

| Field | Meaning |
| --- | --- |
| `extensionId` | Public `ExtensionId` registration identity. |
| `commandId` | Stable semantic `CommandId`, validated by the public Command contract. |
| `label` | Public Command display label: nonblank, at most 160 UTF-16 code units, without controls or line breaks. |
| `library` | Canonical `package:` Dart library URI, without traversal. |
| `entrypoint` | Single top-level identifier for a no-argument finite operation returning void/null. |

Unknown, missing, extra, or wrongly typed fields invalidate the frontend component,
not a healthy backend sibling. The pure-Dart `adele_core_extensions` dependency
keeps Command identity and label validation singular; descriptors contain no
executable callback or evaluator object. The catalog validates data, while the
application validates EVC operation existence before registration. Commands require
neither presentations nor an owning backend. Their invocation receives no native
bridge operations, host context, or authority; declaration is not a grant. Local
availability and generation-owned execution belong to the
[application adapter](../../app/README.md#prepared-frontend-activation), not this catalog.

`PreparedConsoleActionCommandExtension` is an additive behavioral descriptor with
exactly these required fields:

```json
{
  "kind": "consoleActionCommand",
  "extensionId": "dev.adele.plugin.terminal.command.new-terminal",
  "commandId": "dev.adele.plugin.terminal.new-terminal",
  "consoleExtensionId": "dev.adele.plugin.terminal.console",
  "actionId": "new-terminal"
}
```

The catalog validates public registration/Command identities and the same bounded
local action-ID grammar used by prepared Console actions. No `library`,
`entrypoint`, `label`, backend service, Session, or Environment field is accepted.
Unlike operation descriptors, this variant executes no independent EVC operation.
Frontend activation validates the target before publishing any registrations:
exactly one action-based Console presentation in this same prepared component must
declare that local action. A global ID match cannot authorize a foreign
installation/generation. The app captures that sibling's exact live registration
and action, derives the Command label from the action, and delegates creation to
the Console owner. Context and lifetime belong to the
[application adapter](../../app/README.md#session-console), not catalog parsing.

`PreparedMainContentActionCommandExtension` is another additive behavioral
descriptor under the same version-1 `frontend.extensions` list, with exactly these
required fields:

```json
{
  "kind": "mainContentActionCommand",
  "extensionId": "dev.adele.source-editor.command.open-source",
  "commandId": "dev.adele.source-editor.open-source",
  "mainContentExtensionId": "dev.adele.source-editor.main-content",
  "actionId": "open"
}
```

Registration and Command identities use their public identity types. `actionId`
uses the owning `PreparedMainContentAction.id` semantics: a nonblank string,
preserved without trimming, with no additional ASCII grammar or length bound.
Missing, extra, or wrongly typed fields invalidate only the frontend component.
There is no `label`, `library`, `entrypoint`, context, or authority field, including
Session, Environment, backend-service, execution, retained-data, or file grants.
The catalog validates this descriptor's own syntax, not its target relationship.
Frontend activation requires exactly one Main Content presentation in the same
prepared component with the named `mainContentExtensionId` and local `actionId`,
before publishing any registrations. Another role, installation, or generation
with a matching ID cannot satisfy the reference. The app captures the exact live
sibling registration and action, derives the label from that action, and opens its
existing input presentation rather than executing a separate operation. Input
context, admission, and lifetime remain with the
[Main Content host](../../app/README.md#grouped-main-content); declaration creates
no authority and captured targets never migrate to replacement registrations.

Main Content descriptors use `role: 'mainContent'` with required `extensionId`,
integer `order`, `library`, `initialize`, and `entrypoint`. Optional
`sessionExecution` defaults to false, `backendServices` is a duplicate-free
service-ID allowlist defaulting to empty, and `strategyAffinity` is `independent`
by default or `owningBackend`. There is no strategy selector, role-level `displayName`, or
stock pane-kind enum. `library` is a canonical `package:` Dart URI; `initialize`
and `entrypoint` are top-level identifiers. `PreparedMainContentPresentation` is
data-only and remains Flutter/eval-independent. The initializer reads captured
Session/Environment identity data and may open an initial collection; it receives
no execution, backend, or file services, including when the descriptor requests
them. Identity context is independent of descriptor grants and provider readiness;
its API belongs to the [UI bridge map](../ui/README.md#interpreted-bridges).
The content entrypoint renders each admitted pane in its own runtime.

Additional Main Content fields are explicit opt-ins:

| Field | Meaning / default |
| --- | --- |
| `actions` | Empty by default; unique local `id`, `label`, and widget `entrypoint` for each host-chrome input action. |
| `operations` | Empty by default; finite operation keys mapped to top-level entrypoints in the same `library`. |
| `closeOperation`, `exitOperation`, `displaySourceFileOperation` | Optional keys naming declared operations for pane close, reversible application-exit preflight, and public source-file display. |
| `retainedData` | False by default; requests copied contribution-owned records retained independently of attachment. |
| `nativeCodeEditor` | False by default; requires `retainedData` and requests supplied-text native editor ownership, not filesystem access. |
| `environmentTextFiles` | False by default; requires nonempty `operations` and requests the separate Environment read/replace bridge only for finite operations with captured Session context. |

Hooks cannot name undeclared operations. Actions and operations are immutable
metadata, not stored evaluator callbacks. Exit operations need no mounted pane and
receive no Session context or Environment grant. These fields do not imply Session
execution or owning-backend services, and the host still validates each scoped
grant. Manifest version remains 1.

Normal frontend bootstrap validates initializer, pane, action, and operation
entrypoints, then registers through the existing catalog/extension-registry path.
Discovery and registration do not open
panes or acquire native editors. The role requires no backend process by default.
Requested services are pane-scoped and require an actual host binder, exact live
registration/installation ownership, and validation of any captured execution
controller and owning-backend strategy origin. Metadata alone grants no authority.
Missing required services fail that pane without blocking independent groups or
canonical navigation. Optional native bindings and short-lived initialization
belong to the [application host](../../app/README.md#grouped-main-content), while the public
[UI contract](../ui/README.md#grouped-main-content) owns collection operations.

Console descriptors use `role: 'console'` with required `extensionId`, `library`,
`entrypoint` (content presentation), and `actions`. Each action has `id`, `label`,
and its own operation `entrypoint`; action IDs must be unique within the descriptor.
Libraries are canonical `package:` Dart URIs and entrypoints are top-level
identifiers. Strategy/backend-affinity fields and role-level `displayName` are
not part of this role. Optional `readOnly` defaults to false. With `readOnly: true`,
`actions` must be empty and optional `backendServices` declares a duplicate-free
service-ID allowlist; a nonempty backend allowlist is rejected for action-based
console descriptors. Optional `keepAlive` defaults to false and is accepted only
for the read-only prepared path when true. It opts visited content into the host's
bounded current-Session presentation working set, not continuing foreground
interaction authority. Read-only content is admitted through declared presentation
targets, not a creation action or implicit execution grant.

A frontend-only installation can contribute independently to the shared host
console, without an owning backend. App activation validates
both operation and content entrypoint presence before registering the contribution;
actual invocation/rendering may still fail. Content/resources are not created by
discovery or activation. The public [console contract](../ui/README.md#shared-console)
owns composition and lifetime; this package supplies data-only metadata, not UI or
terminal policy. Manifest version remains 1.

Task Browser descriptors use `role: 'taskBrowser'` and require only `extensionId`,
`displayName`, `library`, and `entrypoint`. They have no strategy or backend
affinity: `strategyId`, `strategyAffinity`, `backendServices`, and `hostAdapter`
are rejected for this role. A frontend-only installation needs no backend or shared
host process to register the contribution. Project-scoped browser actions are
mediated by the app's public-UI bridge implementation, not runtime backend routing.

Stock Chat uses `mainContent`, ordinary order 100, explicit `sessionExecution: true`,
an allowlisted Chat service, and `owningBackend` affinity. Its initializer decides
applicability; runtime does not know Chat identities or service semantics. There is
no separate Session presentation descriptor or reserved strategy slot.

Stock [Source Editor](../../plugins/source_editor/README.md) is a frontend-only
`mainContent` installation with retained data, native editor, and finite Environment
operations explicitly enabled, without execution or owning-backend grants. Its
`mainContentActionCommand` references its existing `open` input action; it does not
invoke `display` directly or duplicate the action label/entrypoint. Its descriptors
remain in the build-side
[`stock_frontend_descriptors.dart`](../../tools/stock_frontend_descriptors.dart),
not a runtime Source policy table.

Tool activity descriptors use `role: 'toolActivity'` with `toolId`, `library`,
`inspectionExtensionId`, `compactExtensionId`, `inspectionEntrypoint`, and
`compactEntrypoint`. Optional `backendServices` and `consoleExtensions` default
to empty immutable lists and reject duplicates. They contain service IDs and
console Extension IDs respectively. These allowlists apply only to rich Inspection:
compact hosting receives neither owning-backend access nor console-opening access.
An allowed console target must additionally belong to the same exact installation
and frontend generation as the requesting presentation; an ID in metadata is not
proof of a live binding. Tool activity descriptors have no strategy affinity.

These descriptor families use existing public identity types without importing
Flutter, `adele_ui`, eval, or concrete plugins. Strict role/kind-specific fields describe executable
ABI/preparation data, not profile or activation state.

Unconfigured, missing, or empty roots succeed empty. Malformed/unreadable
installation envelopes produce installation-wide issues and are excluded. An
invalid component instead records `PreparedPluginCatalogIssue.component` as
`PreparedPluginComponent.backend` or `.frontend`, omitting only that component
while retaining the installation and healthy sibling. Invalid roles, kinds, or
descriptors invalidate the frontend component. Readable valid identities are reserved before
the remaining validation; duplicate PluginIds exclude all conflict members,
including otherwise invalid manifests, without version selection. Root I/O
failures propagate instead of looking empty.

File confinement and existence do not establish executable EVC correctness.
Flutter-side `PreparedFrontend.load` reads immutable bytes once per generation.
The Flutter bootstrap then validates behavioral bytecode and descriptor entrypoint
presence before registration, intercepting runtime execution before initializers
or plugin code run and installing no native picker authority. Invalid behavioral
code fails only that frontend attempt. Console and Main Content descriptors also
receive the entrypoint validation described above. For other presentation-only roles,
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

Project selector descriptors name the provider for backing preparation, not a
capability advertisement. Every prepared selector requires a capability
registration from its exact ready owning backend; there is no optional affinity
enum. The app joins frontend and backend through the same
`PreparedPluginInstallation` and exact registration ownership, not `PluginId`
matching. Activation can still be independent while an opening operation needs
both components. See [selector ownership](../../docs/architecture/plugin-system.md#project-selector-ownership).

Local Directory combines an interpreted selector and an AOT Project provider.
Its app-native picker bridge remains distinct from generated provider RPC,
backend host-invocation contexts, and Session/Environment authority. Headless
durable callers supply a known source and exact provider binding without a
selector. Development callers may explicitly use volatile Project construction;
neither path makes `AdeleRuntime` statically activate a stock plugin.

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

Standalone capability/extension registration failure rolls back only that attempt's
registrations, preserving infrastructure and other owners on the same connection.
Their `retire()` methods likewise remain registration-local. Their `close()` methods
instead synchronously revoke generation infrastructure before invoking retirement
or awaiting cleanup, then close the connection.
Capability and composite activation close also attempt connection shutdown after
[grouped retirement](../capabilities/README.md#semantics) failure. Cleanup reports
the first failure with its original stack; a later cleanup failure does not replace
it. Their rollback handlers retain the triggering activation failure rather than
replacing it with secondary cleanup failures. Repeated retirement does not rerun observers or affect
replacement registrations.

`PluginBackendActivation.registerAdvertised` coherently owns both capability and
extension phases. It passes `beforeRollback: connection.revokeInfrastructureContext`
to both helpers so fatal generation rollback revokes before helper cleanup starts.
Failure rolls back both phases and closes that attempt's connection;
retirement synchronously revokes generation infrastructure and removes both sets
before awaiting adapter cleanup or connection close. Local failure and later
termination do not remove unrelated registrations or replacements. The app supplies
the context-free Command, inference-source, model-tool, and orchestration-strategy
adapters; runtime owns none of those points' metadata or composition rules.

The [Command adapter](../core_extensions/README.md#remote-commands) uses local
`RemoteExtensionContext.validate` for synchronous availability and its captured
`channel` for generated invocation, not `RemoteExtensionContext.invoke` or an
operation-scoped grant.
There is no availability RPC or late registration-liveness check after admission.
Backend-only installations register through this same activation path without
prepared frontend descriptors; the application palette consumes the ordinary
registry and its membership changes.

`PluginBackendActivation.ownsProvider` delegates to
`PluginCapabilityActivation.owns` and generic capability registration `.owns`
checks. This proves the binding belongs to that activation's exact registration;
semantic provider/plugin IDs alone cannot establish ownership. Liveness is
validated separately from registration identity. The application uses this for
prepared Project selector/provider pairing, without adding a stock-provider table
or another registry to runtime.

`RemoteExtensionContext.onRetire` registers adapter-owned async resource cleanup
and returns a detach callback. Retirement immediately revokes invocation authority
and removes registrations, then drains all registered cleanup. A resource detaches
only after its cleanup settles, so concurrent retirement joins an already-started
release. Cleanup must use captured authority-free routes, not open new invocations
through a stale context. Explicit retirement retains cleanup failures; termination
observers do not create unhandled asynchronous errors.

The runtime knows no Git/OpenAI/Chat/AGENTS.md/Search/Filesystem/Command source paths, credential
schemas, or stock exposure tables. Startup argv is opaque plugin input. Profiles/enable-disable
management, version solving, watching, and hot upgrade remain deferred.

## Own-Backend Requests

`OwningBackendChannel` is a presentation-local unary/server-streaming channel over
one captured `PluginBackendConnection`, `ConfigurationContextId`, and explicit `backendServices`
allowlist. It validates the presentation and owning activation before dispatch
and after asynchronous settlement, snapshots request/response data, and rejects
undeclared services. It exposes no PluginId or configuration selector and never
re-resolves a replacement connection. Missing, retired, or mismatched ownership
fails explicitly; this is not capability-provider selection or general symmetric RPC.

`PluginBackendActivation.extensionOrigin` obtains a remote contribution's origin
from exact registration ownership, not extension IDs, contribution value identity,
or discovery-wrapper identity. The host uses that internal provenance to enforce
`strategyAffinity: 'owningBackend'` when binding services for a contributed pane.
The service binder validates the Session strategy and any retained controller's
captured binding against the installation's actual backend registration; Run
materialization retains the selected exact binding. Core Session creation instead
uses the orchestration registry independently of frontend metadata.
Matching semantic IDs alone cannot join one backend's Session state to another
backend's execution. Origins and connection objects are not plugin-facing metadata.

The public interpreted adapter lives in `adele_ui/owning_backend_bridge.dart`;
generated plugin clients use it without importing this internal package. Frontend
startup remains independent of backend startup. Registration availability does not
promise that a view's own-backend service is ready, and failure has no native or
in-process fallback.

Generic Inspection and read-only console composition captures the exact
installation's backend and its default configuration context without resolving a
strategy. A Main Content pane with explicit owning-backend affinity supplies the
validated strategy origin described above. Neither route creates host-invocation
authority. A rich Inspection retains canonical facts when backend observation is
unavailable. A retained read-only console keeps its captured channel across view
remounts; each fresh view gets a new revocable adapter, never a new backend lookup
for the old content. These lifetimes are app-owned; this package supplies the
exact channel and metadata, not console state, plugin DTOs, or rendering.

`stream` is lazy and single-subscription, snapshots data, revalidates on delivery,
and forwards pause/resume/cancel to the captured transport. Owners with a lifetime
narrower than the connection supply `observeOwnerRetirement`; composite backend
activation provides detachable `onRetire` observation. Retirement cancels even an
idle or paused stream before awaiting bounded cancellation. The app bridge owns
presentation-local cancellation/fencing, independently of backend work. Capturing
a channel does not require a Session strategy or create execution authority.

## Operation-Scoped Host Calls

Both host and plugin-backend protocols are version 1 with exact protocol-version
matching. Before the first release, unstable wire changes may retain that version;
rebuild prepared artifacts as a coherent set, without compatibility for prior
development artifacts. See the
[transport version policy](../../docs/architecture/contracts-and-capabilities.md#transport-version-policy).
`PluginBackendConnection.openHostInvocation` grants an opaque secure
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
Owned reverse streams are cancelled when their invocation is revoked. Revocation
is immediate; bounded cleanup cannot prolong authority while producer cancellation
is pending.

`hostRequest`/`hostResponse` reuse the same isolate ports and framed shared host.
Unary requests and stream openings require `hostContextKind: 'invocation'` and
opaque `hostContext` in the generic reverse envelope. Semantic operation payloads
still use `hostInvocationContext`; those domain fields are not renamed.
The shared host stamps connection generation and plugin identity from the owning
isolate, and the runtime validates generation, invocation liveness, and the service
allowlist before dispatch and after settlement. Late responses cannot migrate to
a replacement. Semantic Session/Run identifiers do not confer authority.
Generated dispatchers preserve declared failures; the app captures canonical
inference-source context or a materialized tool's coherent Session-bound
read/mutation/process facets. The unchanged authorized read service's no-argument authority
query and file/directory reads cannot select a different Environment. Separate
generated `AuthorizedEnvironmentMutationService` supplies only create-new,
conditional replacement, and conditional deletion, with no authority query,
authority-selection IDs, or process methods.

Reverse server streams reuse the same ports and framing with exact-generation
routing, lazy opening, and one-item credit. Pause/resume controls further producer
advancement; cancellation reaches the producer without granting new authority.
The allowlist and invocation liveness are checked for streaming as well as unary
calls. Separate generated `AuthorizedEnvironmentProcessService` supplies exactly
`runForegroundProcess(EnvironmentForegroundProcessRequest request) ->
Stream<EnvironmentProcessEvent>` over the captured process facet, with no authority
query or authority-selection IDs. Process DTOs and declared failures remain owned
by `adele_environment`.

For remote model tools, exposure `hostServices` declares maximum captured
dependencies; each descriptor's required `executionHostServices` must be an exact
allowed subset. The app adapter validates these point-specific declarations and
all captured exact bindings, not this package. Materialize/validation receive no
token and description receives pure identity data. Only execution after
policy/approval receives a fresh stream-lifetime token whose allowlist contains
exactly that descriptor's services. Filesystem read execution cannot acquire
mutation or process authority through the contribution's broader dependency list;
Search execution is read-only and Command execution is process-only. Captured
facets must share Session/Environment identity, with no re-resolution or authority
chosen by transported IDs. Revocation does not roll back in-flight effects.
See [the host-call contract](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).

Remote orchestration uses only unary calls. The app opens a fresh invocation per
start/resume with the orchestration execution-host service as its sole allowlist
entry. Execution-scoped snapshot/proposal handles may survive an approval pause
as data identity, never as invocation authority. Approval is captured by the host
for one resume. The app adapter owns handle tables, native lifecycle settlement,
and draining admitted host mechanics after revocation; runtime adds no strategy
semantics or general object-handle facility. Materialization and release have no
host invocation. See
[remote orchestration](../../docs/architecture/contracts-and-capabilities.md#remote-orchestration-strategies).

Plugins use public `adele_plugin_backend_support`, not this package, for their
request/stream-channel multiplexer. This is operation-scoped unary and server-streaming
access, not general symmetric RPC, client/bidirectional streaming, ambient callbacks,
cancellation of arbitrary host code, or a sandbox. Installed manifests remain version 1.

## Generation Infrastructure

`PluginBackendHost.startPlugin(createInfrastructureServices: ...)` optionally
accepts a synchronous factory from the actual `PluginBackendConnection` to an
explicit `Map<String, AdeleBackendDispatcher>` allowlist. The runtime snapshots
that map and issues one fresh opaque `hostInfrastructureContext` in the shared-host
start frame and backend bootstrap message, even for an empty allowlist or zero
advertised contributions. The bootstrap field is required and nonempty on the
current protocol-v1 wire; there is no missing-field compatibility path.

Infrastructure calls use the same reverse transport, correlation, pending-call,
and streaming machinery with `hostContextKind: 'infrastructure'` and `hostContext`.
The infrastructure grant and operation grants have separate lifetime stores:
cross-kind tokens, foreign generations, and undeclared services fail closed.
There are no default services, implicit execution/model/tool/Environment grants,
domain-specific dispatchers, or provider discovery in this package.

Capture `connection.validateInfrastructureContext` in each supplied service and
call it at service entry, not just in transport routing: generated dispatchers may
queue an admitted call behind an earlier one until after revocation. Services own
any additional domain and asynchronous-settlement validation. Dispatchers and their
cleanup remain factory-caller-owned; revocation is not rollback of started effects.

`connection.revokeInfrastructureContext()` is synchronous and permanent. Composite
backend activation retirement and fatal rollback revoke before asynchronous cleanup;
standalone activation close, startup failure, stop/close, termination, and host close
also revoke. Standalone registration-local rollback and `retire()` do not revoke
the generation grant. Pending unary calls and streams settle without waiting for
arbitrary service cleanup. Completing
an operation or retiring an individual extension does not revoke infrastructure.
A replacement connection receives a new token; retained tokens/channels never
retarget. Tokens are live authority, not serializable durable identity or reusable
configuration, and must not be persisted. Plugins bind them through
`AdeleHostRequestMultiplexer.bindInfrastructure`, not a symmetric RPC or ambient
callback system.

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
