# Dependency Rules

## Layers

```text
public contracts and plugin-facing APIs
  adele_plugin_api
  adele_core_extensions
  adele_contract
  adele_plugin_backend_support
  adele_capabilities
  adele_model_provider
  adele_product
  adele_model_tool
  adele_orchestration
  adele_environment
  adele_ui (Flutter)
  future broader extension/UI APIs
  plugin-defined public extension APIs
            ^
internal host implementations
  plugin_runtime
  plugin_backend_host
  plugin_builder
  agent_kernel
            ^
desktop composition root
  adele_desktop
```

Arrows point toward dependencies. Dependencies flow toward public contracts and APIs; public packages never depend on internal host packages or the desktop application. All packages are initially private to the repository via `publish_to: none`, even when described as public or plugin-facing.

The maintained code currently implements only part of this picture. Public
`adele_orchestration` implements strategy registration/execution, read-only Run
activity, and instruction-context composition, sharing semantic values with the
internal kernel without depending on it. B1 adds tiny pure-Dart
`adele_core_extensions` for the concrete
Project selector contract, depending only on `adele_plugin_api`. Public Flutter
`adele_ui` supplies concrete Session, read-only tool Inspection, and model-native
activity presentation contracts, depending on Flutter, `adele_contract`, `adele_plugin_api`,
`adele_product`, `adele_orchestration`, and `adele_model_tool`. The latter two remain public pure-Dart
packages; neither depends on UI. A separate `adele_ui/directory_picker_bridge.dart`
library supplies only the interpreted `Future<String?> pickDirectory()` stub.
Separate own-backend request and Session execution bridge libraries expose bounded
interpreted operations; native implementations and eval declarations belong to the app.
Plugin-defined extension API packages and broader
workbench UI APIs remain architectural direction.

## Package boundaries

| Package | Surface | Allowed dependencies | Prohibited dependencies |
| --- | --- | --- | --- |
| `adele_contract` | Experimental plugin-facing | Dart SDK and `adele_plugin_api` for public identity validation and shared values | Flutter, internal host packages, application code, analyzer/compiler internals, `build_runner` |
| `adele_plugin_backend_support` | Experimental plugin-facing, pure Dart; narrowly scoped unary/server-streaming host channels | Dart SDK and `adele_contract` | Flutter, internal host packages, application code, concrete plugins |
| `adele_capabilities` | Experimental plugin-facing | Dart SDK and lightweight public contract types when required | Flutter, internal host packages, application code |
| `adele_plugin_api` | Experimental plugin-facing, pure Dart | Dart SDK and lightweight public packages when required | Flutter, internal host packages, application code |
| `adele_core_extensions` | Experimental plugin-facing, pure Dart; narrow core-owned extension contracts | Dart SDK and `adele_plugin_api` | Flutter, internal host packages, application code, concrete plugins |
| `adele_model_provider` | Experimental plugin-facing | Dart SDK, `adele_contract`, and `adele_capabilities` | Flutter, internal host packages, application code, concrete providers |
| `adele_product` | Experimental plugin-facing, pure Dart | Dart SDK and `adele_capabilities` | Flutter, internal host packages, application code, `adele_orchestration`, `adele_plugin_api`, `adele_core_extensions` |
| `adele_model_tool` | Experimental plugin-facing, pure Dart; native tool API and generated remote transport | Dart SDK, `adele_contract`, `adele_plugin_api`, and `adele_product` | Flutter, internal host packages, application code, concrete tools |
| `adele_orchestration` | Experimental plugin-facing, pure Dart; native strategy facade, generated remote transport, and native backend host proxy | Dart SDK, `adele_contract`, `adele_product`, `adele_plugin_api`, and `adele_model_tool` | Flutter, `agent_kernel`, other internal host packages, application code, concrete strategies or sources |
| `adele_environment` | Experimental plugin-facing, pure Dart; provider/facet and separate generated authorized-read/mutation/process contracts | Dart SDK, `adele_contract`, `adele_capabilities`, and `adele_product` | Flutter, internal host packages, application code, concrete providers |
| `adele_ui` | Experimental plugin-facing, Flutter; semantic presentation contracts and interpreted picker, own-backend, and Session execution bridges | Flutter, `adele_contract`, `adele_plugin_api`, `adele_product`, `adele_orchestration`, and `adele_model_tool` | Internal host packages, application code, concrete plugins |
| future broader extension/UI APIs | Experimental plugin-facing | Only lightweight public dependencies required by concrete interfaces | Internal host packages, application code, concrete plugins |
| plugin-defined public extension API | Experimental plugin-facing | Public/core APIs and other deliberately public interface packages needed by the concept | Another plugin's implementation packages, internal host packages, application code |
| `plugin_runtime` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, plugin implementations |
| `plugin_backend_host` | Internal, pure Dart; shared AOT process/isolate host | Dart SDK, public contracts, and `plugin_runtime` framing | Flutter, application code, plugin implementations |
| `plugin_builder` | Internal, pure Dart | Dart SDK, public packages, and build dependencies required by the implemented pipeline | Flutter UI, application code, plugin implementations as linked host dependencies |
| `agent_kernel` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, concrete providers, tools, editors, workflows, or plugin implementations |
| `adele_desktop` | Private Flutter application (production) | Flutter, ADELE public APIs, internal host packages, and generic third-party host libraries needed for composition | Packages under `plugins/**`, including contracts; public plugin API definitions; plugin implementation logic |

An allowed dependency is not a requirement. New edges must have an immediate, concrete use, remain acyclic, and preserve pure-Dart testability where Flutter is unnecessary.

Contract declarations and contract generation are separate concerns. `adele_contract` stays lightweight; generation belongs to the internal `contract_codegen` package and does not add analyzer/compiler dependencies to the public contract package.

### Core extension contract ownership

`packages/core_extensions` (`adele_core_extensions`) owns only **core-owned
extension contracts with no natural existing public domain package**. It is not
a catch-all for public APIs or all extension points. Its B1 surface is
`ProjectSelectorContribution` (`String displayName`,
`Future<Uri?> Function() selectProject`) and the typed
`projectSelectorContributions` point (`dev.adele.extension.project-selectors`).
Returning only a URI keeps `adele_product` unchanged and independent; canonical
Project creation remains a host lifecycle operation.

Existing ownership remains singular:

- Generic registry, registration, and binding liveness belong to `adele_plugin_api`.
- Ready advertisement values belong to `adele_contract`; the narrow backend host-request multiplexer belongs to `adele_plugin_backend_support`, not internal runtime imports in plugins.
- Product identities and immutable values belong to `adele_product`.
- Strategy contracts, execution, read-only Run activity, and inference-context composition belong to `adele_orchestration`.
- Model-tool contracts belong to `adele_model_tool`.
- Environment provider contracts belong to `adele_environment`.
- Flutter Session, tool Inspection, and model-native activity presentation contracts belong to `adele_ui`; product, orchestration, and model tools do not depend on UI.
- Plugin-defined ecosystems keep their contracts with their deliberately public plugin/component API owners.

### Application backend composition

Production `dependencies` in `app/pubspec.yaml` contain no packages under
`plugins/**`, and `app/lib` must not import concrete plugin packages, including
their contracts. Generic host libraries such as `file_selector`, `dart_eval`,
`flutter_eval`, and `crypto` remain allowed. Plugin-aware tests and development
tooling stay outside `app/lib` and use `dev_dependencies`; `plugin_builder` is
likewise development-only. See [app dependencies](../../app/README.md#dependencies)
for the maintained development package and support-file boundaries.

`AdeleRuntime()` synchronously constructs a provider-free host graph with no static
stock activation. Its pure-Dart `ApplicationPluginBootstrap` owns
application-lifetime backend resources on the same capability and extension
registries used by lifecycle/composition. The runtime has no `includeCommandTools`
option or selector dependency. Local Directory Project Selector is a prepared
frontend-only contribution owned by the window's Flutter bootstrap. Chat, AGENTS.md, Search,
Filesystem Tools, and Command Tools are AOT backends, with
no production app dependency/import, static activation, or in-process fallback.
With zero installed plugins, runtime construction and shell mount/close still
succeed; missing plugin functionality remains unavailable without built-in
fallbacks. Plugin-specific self-hosting code under `app/tool/self_hosting/` consumes
Chat Contract as a development dependency and calls the same remote backend.
Normal `AdeleApplication` explicitly calls `start` with an installation
root, shared runtime/host paths, and optional generic startup argv. There is no
stock callback table, required Git backend, or additional-OpenAI activation tier.

`plugin_runtime` owns `PreparedPluginCatalog.discover(rootPath)`, a deterministic
startup snapshot of immediate child installed manifests. It uses public
`PluginMetadata` and existing extension/strategy/tool identity types, not builder
source manifests, Flutter/eval, or plugin implementations. Installed metadata
contains identity, independently optional backend/frontend locations, and sealed
data-only presentation and behavioral extension descriptors, not backend exposures,
configuration, activation, or source paths. Descriptors identify executable
ABI/preparation data, not profile state. Discovery precedes host creation; zero valid backends needs no process even
with invalid host paths. Invalid envelopes exclude installations; invalid components
record typed issues and retain healthy siblings. Readable valid identities remain
reserved for duplicate-ID exclusion even if the rest is invalid. Root I/O failure
becomes generic bootstrap failure without disabling the in-process core. See
[catalog validation and failure behavior](../../packages/plugin_runtime/README.md#prepared-catalog).

The app attempts all valid backend installations independently. A local startup,
advertisement, or registration failure releases only that attempt's resources;
termination retires only its exact generation. Shared-host failure is global.
Read-only per-backend states and catalog issues do not imply a management UI.
Close retires all registrations before generations, then the host. Generic Task
presentation submits through product lifecycle and never
parses opaque `providerState`; Environment providers own source validation.

Backend entrypoints own ready `capabilityExposures` and `extensionExposures`.
Public `adele_contract` owns the lightweight advertisement values/validation;
the existing readiness path transfers them to the exact connection.
Plugin identity comes from installation/connection, not an advertisement.

Internal `plugin_runtime` owns `PluginExtensionActivation`,
`RemoteExtensionAdapterRegistry`, and coherent `PluginBackendActivation` capability
plus extension rollback/retirement. Adapters are host implementations of known
public contracts, not another contribution registry or public plugin API.
Contributions still enter the existing `ExtensionRegistry` with exact liveness.
The app owns `RemoteInferenceContextSourceAdapter`, `RemoteModelToolAdapter`,
`RemoteOrchestrationStrategyAdapter`, and
their point-specific metadata validation; runtime has no Chat, AGENTS.md, Search,
Filesystem, or Command tool logic.

Orchestration's `remote_orchestration.dart` owns generated data-only execution
transport separately from the native semantic facade.
`remote_orchestration_backend.dart` stays in that existing public pure-Dart package
and adapts native strategy contributions to generated services with operation-local
host proxies. Generic `adele_plugin_backend_support` does not depend on
orchestration. The app alone retains exact host snapshot/proposal objects and
captured approval authorization; opaque execution-scoped handles contain no host
authority. Runtime supplies immediate invocation revocation and adapter retirement
cleanup, not orchestration semantics. Chat's canonical
`plugins/chat_strategy/packages/{contract,backend,frontend}` split replaces the
root semantic package. Contract owns identities, immutable entry/configuration
snapshots, and generated `ChatSessionService` transport. Backend owns canonical history,
stable entry occurrence IDs, default instructions, the eight-invocation default,
and sequencing. Its Session service and `RemoteOrchestrationBackend` share one
store, with external mutations blocked from materialization through close.
Frontend depends on Contract, never Backend; neither imports host implementations.

Public `adele_orchestration` owns generated `RemoteInferenceContextSourceService`
and `RemoteInferenceInstruction`; public `adele_model_tool/remote_model_tool.dart`
owns generated remote tool materialize/validation/description/execution transport
and immutable descriptor/event/outcome snapshots, without exception causes.
Public `adele_environment` owns generated `AuthorizedEnvironmentReadService`, its
already-bound Session/Environment identity, and separate
`AuthorizedEnvironmentMutationService` for create-new, conditional replacement, and
conditional deletion. Separate `AuthorizedEnvironmentProcessService` supplies exactly
`runForegroundProcess(EnvironmentForegroundProcessRequest request) ->
Stream<EnvironmentProcessEvent>`. These reuse existing DTOs and declared failures.
Mutation and process services have no authority query or selectors; the read service
remains unchanged. The app
captures canonical `InferenceContextSourceContext` and supplies only its authorized
read facet. Model-tool exposure `hostServices` instead declares maximum dependencies
from read/mutation/process services. Materialization captures coherent facets for the same
Session and Environment; each descriptor's required `executionHostServices` is an
exact allowed subset, never a grant or Profile.

Materialize/validation receive no token; description receives only pure identity
and argument data. Only execution after policy/approval receives an operation token
allowlisting the descriptor's services. The adapter retains exact remote and
Environment bindings, not reusable tokens, and synchronously checks every captured
facet without re-resolution. Transported Session/Run/Environment IDs never select
authority.
Internal runtime/host code owns exact-generation routing and operation-scoped
service authorization/revocation, including execute-stream lifetime, not domain
composition or source/tool semantics. Reverse read/mutation host calls remain
unary; process calls use reverse server streaming with one-item credit and
cancellation. Revocation is immediate and precedes bounded cleanup of owned
streams. Both transport protocols are version 1 under the
[pre-release transport policy](contracts-and-capabilities.md#transport-version-policy);
installed manifests remain version 1. Host-service authority is not an OS sandbox
or rollback of already-started effects.
The cross-system advertisement and host-authority model is in
[`contracts-and-capabilities.md`](contracts-and-capabilities.md#backend-ready-advertisements).
Exact exposure fields belong to [`contract`](../../packages/contract/README.md),
and host-call mechanics to [`plugin_runtime`](../../packages/plugin_runtime/README.md#operation-scoped-host-calls).

`packages/plugin_backend_support` supplies public pure-Dart
`AdeleHostRequestMultiplexer`, whose `bind` returns an `AdeleStreamChannel` supporting
unary and server-streaming clients, using only `adele_contract`, with no internal
host or Flutter dependency. `plugins/agents_md` remains the semantic `agents_md_plugin`;
its own `packages/backend` (`agents_md_backend`) reuses those semantics and the
public generated contracts/support package. Likewise, `search_tools_backend` under
`plugins/search_tools/packages/backend` reuses the pure-Dart root Search semantics,
without duplicating validation/traversal algorithms or importing host packages.
`filesystem_tools_backend` under `plugins/filesystem_tools/packages/backend` reuses
its root semantics through the same public transport/support boundary. Its exposure
captures read and mutation; `read_file` executes with read only, `apply_patch` and
`delete_file` with both, and `create_file` with mutation only. Search describes from
pure identity and executes with read only. Filesystem's backend and frontend do not
depend on one another. `command_tools_backend` under
`plugins/command_tools/packages/backend` likewise reuses root Command semantics
through public generated transport/support, capturing and executing with process
only. It is independent of the Command frontend and imports no host implementations.
This is same-plugin implementation reuse, not permission for other plugins to
import their internals.

Source selection/compilation and stock installation assembly belong to repository
tooling and `plugin_builder`, outside the app startup import graph. The launcher
still knows Git/OpenAI/Chat/AGENTS.md/Search/Filesystem/Command source paths; stock source layouts
need not use `adele_plugin.yaml`. Its separate temporary JSON file maps PluginId to string argv
lists, outside installed manifests. The launcher derives OpenAI credential-file
references and public OAuth/endpoint options, never tokens, and always uses
`--chatgpt-only`, adding a configuration JSON argument only when configured. The
app forwards argv without interpreting it and always sets
`startupArgumentsOnly: true`. The shared host forwards the flag without a PluginId
switch; OpenAI owns parsing, credentials, and advertisements. In this mode OpenAI
never falls back to environment configuration: empty argv or an absent configuration
document advertises zero capabilities, including root-only normal activation
without the launcher's map. Direct/self-hosting callers keep the flag's default
`false` and existing environment configuration path. This is temporary deployment
plumbing intended to disappear with general configuration/profiles, not a settings
schema, environment scrubber, or sandbox.

`app/lib/plugins/temporary_chatgpt_selection.dart` is an intentional exception for
concrete provider/model selection: `dev.adele.openai.chatgpt-experimental`, default
`gpt-6-astra`, and the `ADELE_OPENAI_CHATGPT_MODEL` override. It permits no plugin
imports or production plugin dependencies and owns neither startup nor exposures.
`fromEnvironment` always returns the model default/override without inspecting credential presence
or startup OAuth configuration. Provider availability comes from the active
registry. General provider/model configuration remains deferred. Operational details
live in [`app/README.md`](../../app/README.md#normal-backend-startup) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).
Self-hosting uses generic `registerAdvertised` but keeps its explicit
artifact/host/profile topology, including Chat, `agentsMdArtifact`, `searchToolsArtifact`,
`filesystemToolsArtifact`, and `commandToolsArtifact` on the same host via the same generic remote adapter
activation, without a normal
installation root. Its `includeCommandTools` switch controls explicit Command
backend start/registration, not runtime construction.
Its own profile environment configures the backend; it registers all advertised
contexts, potentially both OpenAI contexts, then explicitly resolves the selected
profile's provider ID without filtering advertisements.
Self-hosting is selector-free and creates its Project from its explicitly known
isolated source URI, with no frontend bootstrap or native picker import.
The frontend owner consumes the normal catalog, as described below; no stock
activation remains outside installed-component discovery in the normal runtime.
These boundaries add no profile/enable-disable system, version solving, watching,
client/bidirectional streaming, ambient callbacks, general symmetric RPC, hot upgrade, or production packaging.
Normal startup attempts all discovered valid components. Profiles remain a separate,
unimplemented policy for activation participation, not installed descriptor state.

The normal model adapter lives
in `app/lib/core/model_provider_host.dart`, separate from development-only resource
adapters. Session lifecycle remains strategy-neutral and Run hosting remains
provider-neutral; generic Session execution composes each Run's model, tools, and
approval-gated policy without adding Chat-specific behavior to those generic
owners. Approval cards are window-local presentation over existing Run
interruptions, not new public APIs or Chat-owned canonical history. Policy and
exact-invocation authorization remain host-owned; tools and Environment providers
retain their execution and revision guarantees.

### Session presentation and frontend composition

`packages/ui` (`adele_ui`) owns `SessionPresentationContribution` with
`strategyId: OrchestrationStrategyId`, `displayName: String`, and
`createPresentation: Widget Function(Session)`, plus typed
`sessionPresentationContributions`. It reuses `ExtensionRegistry`, not a second
registry or Flutter additions to the pure-Dart registry/product packages. Exact
strategy matching has explicit unavailable/one/ambiguous outcomes; there is no
priority or fallback to another strategy.

The generic `app/lib/ui/session/session_presentation_host.dart` consumes that
public contract and existing registry liveness without knowing Chat identities,
history, or controllers. It retains exact bindings and removes retired widgets
so their resources dispose. Session lifecycle and backend validity do not depend
on presentation availability or successful loading.

`app/lib/frontend/application_frontend_bootstrap.dart` owns Flutter-side
`ApplicationFrontendBootstrap`. It consumes the catalog snapshot notified by the
pure-Dart backend bootstrap before backend startup, on the runtime's existing
`ExtensionRegistry`. It must not introduce another root/catalog, registry, or
parallel frontend runtime. The pure-Dart catalog validates confined files and
strict presentation-role and behavioral-kind descriptors, not executable EVC
correctness. `frontend.extensions` is separate from the `presentations`
list; both can coexist under manifest version 1. The Flutter owner reads each
frontend's immutable bytes once per generation through `PreparedFrontend.load`.
It validates behavioral bytecode and descriptor entrypoint presence before
registration, using a runtime that intercepts execution before initializers or
plugin code run, without installing a picker bridge. Behavioral validation failure
is frontend-attempt-local. Presentation-only decoding and execution remain per-view,
so their readable corrupt EVC stays presentation-local rather than a catalog or
backend failure.

The generic owner registers Session, tool activity, and model-native activity
roles and `projectSelector` behavioral extensions from prepared metadata. It owns
exact registration rollback, retirement, and close. Role retirement closes only captured registrations; generation close
settles pending loads and invalidates late/retired resources without removing
replacement registrations. `app/lib/frontend` owns activation and
prepared-generation/runtime hosting, not source discovery, compilation, stock
selection, or Chat state. Frontend readiness is independent of backend readiness
and credentials.

The selector adapter registers native `ProjectSelectorContribution` proxies but
imports no selector implementation. Internal `PreparedFrontend.invoke<T>` accepts
a descriptor-selected no-argument entrypoint, a bridge factory, and a result
decoder; each invocation uses a fresh eval `Runtime` and revokes its bridge in
`finally`. It is not a public arbitrary-evaluation API or a parallel runtime owner.
The app's `DirectoryPickerDeclarations` supplies compile-only ABI, while an
operation-scoped `DirectoryPickerBridge` asynchronously wraps
`file_selector.getDirectoryPath` with `$Future.wrap`, permitting one native call
per operation. `file_selector` is an app dependency, not a public API or selector
implementation dependency.

EVC owns platform-path validation and normalization into an absolute `file:` URI
string or `null`. The generic adapter validates URI shape and exact contribution
liveness, not filesystem or local-directory semantics. The application validates
its retained binding and window lifetime before Project creation. Retirement
rejects late native results without forcibly closing a dialog; semantic failures
stay operation-local. No backend RPC, authority token, Session/Environment access,
or AOT selector is involved.

Session descriptors include `displayName`, `strategyId`, `extensionId`, `library`,
and `entrypoint`, with optional `backendServices` and `strategyAffinity` under
manifest version 1. `hostAdapter` and stock Chat adapters are removed. Public
`adele_ui/owning_backend_bridge.dart` binds generated clients to a generic unary
request bridge. Internal runtime captures the exact sibling backend connection
and configuration context and enforces the explicit service allowlist. EVC cannot
select a PluginId/configuration or retarget a stale channel.

For `strategyAffinity: 'owningBackend'`, the host proves the strategy's origin from
exact registration ownership, not IDs, contribution value identity, or a discovery
wrapper. Origin remains host-internal. `createSession` validates before publication;
Run hosting receives and retains that same resolved strategy, while checking its
canonical registry membership. Affinity cannot bypass unavailable/ambiguous or
stale-binding errors. Backend and frontend startup remain independent.

The separate `chat_strategy_frontend` uses Contract-generated `ChatSessionService` calls
for asynchronous append and history refresh; configuration uses that same Contract
service, not a generic core history API. It owns composer
acceptance, grouping, and stable accepted-entry-to-opaque-Run association, never
matching message text or array positions. The separate generic Session execution
bridge exposes scheduling, immutable execution/activity reads, subscriptions, and
inspectable widget slots for emitted handles. Core retains model/tools/policy,
approval, activity evidence, and Inspection, not canonical Chat history or grouping.
Common `RunExecutionStatus`, `PendingToolApproval`, and approval display safety
remain in `app/lib/ui/execution`. No executable, kernel, controller, or approval
objects cross these bridges. The native Session factory is a distinct boundary.

The public Run activity source and immutable read model live in pure-Dart
`adele_orchestration`. The application host translates internal journal evidence
into those values. No public activity consumer needs `agent_kernel`; the source
is a separate read-only facade, not a Run object with a restricted static type.
Chat's tool/native activity grouping is presentation policy, not a universal Run
invariant. Opaque native output and structured tool outcome data are retained
without forwarding executable authority or arbitrary exception objects.

`adele_ui` also owns `ToolActivityInspectionContribution(toolId,
createPresentation)` and typed `toolActivityInspectionContributions`. The factory
is `Widget Function(ToolActivityInspectionSource)`; the source is a read-only
`Listenable` exposing an immutable public `ToolInvocationActivity` snapshot.
Resolution matches exact `ToolId` with unavailable/one/ambiguous outcomes and uses
existing registry binding liveness. Widgets/resources retire with their exact
registration; only fresh resolution may select a replacement.

`adele_ui` separately owns tool/native Compact Presentation contributions and
resolvers, receiving the same read-only tool source or safe native presentation.
Compact is a semantic role, not rich Inspection resized for Chat. Exact matching
and binding liveness are unchanged; zero/many/failure/retirement preserve common
bounded identity or safe-text fallback without parsing plugin fields.

Application State owns the newest-first window-local Inspection card stack.
`app/lib/ui/inspection/inspection_host.dart` owns card identity/chrome, independent
collapse/dismiss state, common inspect interaction, and compact group rows in
exact `output.sequence`, including unprepared/rejected tool placeholders.
Group-row selection prepends an individual output card, whose body uses the
existing rich presenter. Plugins receive no navigation or approval authority.
Chat owns grouping/timeline placement; Run/core owns evidence identity and
lifecycle. This adds no public physical panel API or
Session history; see [`overview.md`](overview.md#activity-inspection).

The separate Flutter `filesystem_tools_frontend` and `command_tools_frontend`
packages own `apply_patch` and `run_command` compact and rich field interpretation. They
depend only on Flutter and `adele_ui`, not headless implementations, app, or kernel.
Prepared `toolActivity` descriptors supply tool identities, registration IDs,
libraries, and compact/rich entrypoints to generic frontend bootstrap. Stock tool
activation files are removed; app runtime activation must not import stock tool
identities or implementations for this routing. `tools/stock_frontend_descriptors.dart`
is the singular stock build-side descriptor table, outside the runtime import graph.

The generic tool eval bridge transports immutable structured maps and latest
common lifecycle/terminal data without semantic tool-field switches or flattened
progress history. Independent catalog-driven activations reuse `PreparedFrontend`;
presentation failure/retirement neither fails backend execution nor substitutes
native tool cards. Tool cards show read-only status; only common host approval UI
offers Allow/Deny for the exact retained interruption.

`adele_model_provider` owns generated
`ModelProviderNativePresentation(kind, compactText, data)` and required nullable
`ModelProviderOutput.nativePresentation`. Null means no safe presentation; generated
keys remain required under the coherent-schema convention. Pure-Dart
`adele_orchestration` owns immutable `ModelNativePresentation` with the same fields
and optional `ModelNativeOutput.presentation`. The app capability adapter maps
these fields generically, without provider interpretation or a dependency between
the two public domain packages solely for this mapping.

`adele_ui` owns
`ModelNativeActivityPresentationContribution(presentationKind, createInspection)`,
`modelNativeActivityPresentationContributions`, and
`ModelNativeActivityPresentationResolver`. Its factory is
`Widget Function(ModelNativePresentation)`, not a raw-output projector; there is
no UI projection DTO or callback. Exact safe presentation kind resolution gives
zero rich-unavailable, one retained binding, or explicit ambiguity for many, with
no priority. Registry liveness removes exact-generation views; replacement needs
fresh resolution and never retargets stale resources. Safe activity survives
missing/retired frontends. Chat derives presence from `output.presentation != null`,
not registry activation, and needs no negative projection cache or registry retry.

OpenAI follows `plugins/openai/packages/{contract,backend,frontend}`:

- Pure-Dart `openai_contract` owns only shared identities and payload schema. The raw kind remains `openai.responses.item.v1`, version 1; safe presentation uses `openai.responses.reasoning-summary.v1`, version 1. Contract contains no classification, projection, bounds-processing, or escaping algorithms and depends on neither implementation nor Flutter/app/kernel.
- `openai_model_provider_backend` owns raw Responses classification, bounded reasoning-summary projection, and exact native preservation, using public ModelProvider transport and Contract identities/schema. It does not depend on Frontend or UI/orchestration projection APIs.
- Flutter `openai_frontend` renders the safe payload using public `adele_ui` and shared Contract schema as needed. It does not import Backend, app, kernel, or raw native metadata. Generic Chat escapes compact text; the OpenAI frontend escapes full text.

The generic `app/lib/frontend/model_native_activity_bridge.dart` carries only
immutable safe display data. For OpenAI, that is exactly `summaryParts` and
`truncated`, never raw envelopes, compatibility metadata, encrypted content, or
execution/approval authority. Raw `nativeMetadata` stays exact and is the only
native replay source; safe presentation is never replayed. Display filtering and
bounds do not alter canonical history or add persistence.

OpenAI's one installation contains backend and frontend components; its prepared
`modelNativeActivity` descriptor supplies kind and compact/rich entrypoints to
generic frontend bootstrap. The stock OpenAI frontend activator is removed;
runtime activation must not import OpenAI identity or algorithms for this routing.
Activation is independent of model backend readiness and other frontends.
Malformed safe payload and factory/EVC failures
leave rich presentation unavailable without failing Runs or selecting a native
fallback. Summary requests remain provider-local; generic inference and UI code
neither assert all-model support nor select reasoning options. See the
[backend README](../../plugins/openai/packages/backend/README.md).

Flutter build-time tooling compiles frontend source; normal runtime activation
only consumes prepared artifacts. Checkout preparation is a stand-in for future
installation/update compilation, not a cache or implemented plugin management
system. The Linux launcher assembles eight installations in one root: frontend-only
Local Directory Project Selector, backend-only Git, AGENTS.md, and Search,
and combined Chat, Filesystem Tools, Command Tools, and OpenAI. It prepares seven backend
snapshots plus the host and five EVCs. Local Directory uses
`app/tool/local_directory_frontend_compiler.dart`
through `app/tool/compile_local_directory_frontend.dart`.
It supplies only the four generic root/host/runtime/startup-argv defines, not
per-stock frontend artifact fields/defines or Chat-/AGENTS-/Search-/Filesystem-/Command-specific
startup configuration.
Flutter/eval dependencies do not enter the shared headless runtime or the pure-Dart
`plugin_builder` package.

## Plugin dependencies

A plugin may depend on public surfaces as needed:

```text
adele_plugin_api
adele_core_extensions
adele_contract
adele_plugin_backend_support
adele_capabilities
adele_model_provider
adele_product
adele_model_tool
adele_orchestration
adele_environment
adele_ui (Flutter frontends)
future broader plugin-facing extension/UI APIs
public extension API packages defined by other plugins/components
```

A plugin must not depend on host implementations or application code:

```text
plugin_runtime
plugin_backend_host
plugin_builder
agent_kernel
adele_desktop
```

Stock `local_directory_project_selector_frontend` under
`plugins/local_directory_project_selector/packages/frontend` replaces the retired
root selector package in workspace membership and maintained analysis/test
discovery. It depends on public `adele_ui`, not `file_selector`, product lifecycle,
app state, or host implementations. Its interpreted picker stub has no native
implementation; only the app's operation bridge supplies native access. The
frontend-only `local-directory-project-selector` installation is not linked into
`AdeleRuntime`. Shared runtime and self-hosting therefore remain pure Dart and
selector-free, without a conditional native-picker import. This adds no Flutter
dependency to `adele_core_extensions` or product.

This prohibition includes orchestration-strategy plugins. A Chat or Goal strategy may need Run/model/tool execution semantics, but it must obtain those through a narrow public provider-neutral orchestration/execution API backed by core. It must not import `agent_kernel` merely because the kernel implements those semantics internally.

Within a source plugin, dependencies have this shape:

```text
          plugin contract/API (pure Dart where possible)
             ^                 ^
             |                 |
         backend            frontend
```

The backend and frontend depend on shared contract/API packages as needed. They do not depend on one another. Transport contracts do not depend on Flutter. A frontend may depend on Flutter and deliberately public UI APIs such as `adele_ui`. The same implementation split applies to installed Chat, Filesystem, and Command backends, each independent of its separate Flutter frontend. A backend may use full Dart capabilities subject to the runtime and eventual security model.

Plugin tests may use internal host packages as development-only dependencies to exercise integration boundaries. Those dependencies must remain under `dev_dependencies` and must not be imported by plugin production libraries or entrypoints. The `workspace_demo_backend` host integration test uses `plugin_runtime` on this basis; the backend's production dependency graph does not include it.

## Interface dependency versus implementation dependency

Plugins may cooperate through interfaces defined by core or another plugin/component. This is intentionally different from a runtime activation dependency on a specific implementation.

For example:

```text
Diff plugin
    depends at build time on DisplaySourceFile API
    does NOT depend on Internal Source Editor implementation

Agent-control plugin
    may depend at build time on ChatPromptAccessory API
    does NOT require Chat to be active

Chat strategy plugin
    depends at build time on core orchestration/execution API
    does NOT depend on agent_kernel implementation
```

At runtime, compatible registrations are discovered dynamically. If no implementation is active, the relevant affordance or integration is unavailable; ADELE should not silently enable another plugin merely to satisfy it.

A plugin-defined extension API must be deliberately public. Plugins must not import another plugin's frontend, backend, private library, or other implementation package merely because the code is accessible in the repository.

This enables recursive plugin-defined extension ecosystems while avoiding a complex implementation-level dependency/activation graph.

## Repository rules

- Keep the application as the composition root.
- Keep internal core packages pure Dart unless Flutter is intrinsically required.
- Avoid dependency cycles at every layer.
- Prefer typed runtime discovery over dependencies on implementation identities.
- Keep `agent_kernel` internal; expose only concrete plugin-needed execution semantics through deliberately public APIs.
- Do not create packages solely for hypothetical reuse.
- Require a concrete responsibility and dependency boundary for every new package.
- Keep public surfaces small and experimental through the proof-of-concept stages.
- Do not create a plugin-defined API package until at least one concrete interface needs to be shared.
- Do not introduce a profile package, provider-instance package, separate application UI package, or generic extension package without a concrete implemented need.
