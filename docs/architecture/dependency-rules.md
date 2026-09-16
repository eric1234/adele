# Dependency Rules

## Layers

```text
public contracts and plugin-facing APIs
  adele_plugin_api
  adele_core_extensions
  adele_contract
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
activity presentation contracts, depending on Flutter, `adele_plugin_api`,
`adele_product`, `adele_orchestration`, and `adele_model_tool`. The latter two remain public pure-Dart
packages; neither depends on UI. Plugin-defined extension API packages and broader
workbench UI APIs remain architectural direction.

## Package boundaries

| Package | Surface | Allowed dependencies | Prohibited dependencies |
| --- | --- | --- | --- |
| `adele_contract` | Experimental plugin-facing | Dart SDK and `adele_plugin_api` for public identity validation and shared values | Flutter, internal host packages, application code, analyzer/compiler internals, `build_runner` |
| `adele_capabilities` | Experimental plugin-facing | Dart SDK and lightweight public contract types when required | Flutter, internal host packages, application code |
| `adele_plugin_api` | Experimental plugin-facing, pure Dart | Dart SDK and lightweight public packages when required | Flutter, internal host packages, application code |
| `adele_core_extensions` | Experimental plugin-facing, pure Dart; narrow core-owned extension contracts | Dart SDK and `adele_plugin_api` | Flutter, internal host packages, application code, concrete plugins |
| `adele_model_provider` | Experimental plugin-facing | Dart SDK, `adele_contract`, and `adele_capabilities` | Flutter, internal host packages, application code, concrete providers |
| `adele_product` | Experimental plugin-facing, pure Dart | Dart SDK and `adele_capabilities` | Flutter, internal host packages, application code, `adele_orchestration`, `adele_plugin_api`, `adele_core_extensions` |
| `adele_model_tool` | Experimental plugin-facing, pure Dart | Dart SDK, `adele_plugin_api`, and `adele_product` | Flutter, internal host packages, application code, concrete tools |
| `adele_orchestration` | Experimental plugin-facing, pure Dart | Dart SDK, `adele_product`, `adele_plugin_api`, and `adele_model_tool` | Flutter, `agent_kernel`, other internal host packages, application code, concrete strategies or sources |
| `adele_ui` | Experimental plugin-facing, Flutter; semantic Session, tool Inspection, and model-native activity presentation | Flutter, `adele_plugin_api`, `adele_product`, `adele_orchestration`, and `adele_model_tool` | Internal host packages, application code, concrete plugins |
| future broader extension/UI APIs | Experimental plugin-facing | Only lightweight public dependencies required by concrete interfaces | Internal host packages, application code, concrete plugins |
| plugin-defined public extension API | Experimental plugin-facing | Public/core APIs and other deliberately public interface packages needed by the concept | Another plugin's implementation packages, internal host packages, application code |
| `plugin_runtime` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, plugin implementations |
| `plugin_builder` | Internal, pure Dart | Dart SDK, public packages, and build dependencies required by the implemented pipeline | Flutter UI, application code, plugin implementations as linked host dependencies |
| `agent_kernel` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, concrete providers, tools, editors, workflows, or plugin implementations |
| `adele_desktop` | Private Flutter application | Flutter and any host package needed for composition | Definitions intended as public plugin APIs; plugin implementation logic |

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
- Product identities and immutable values belong to `adele_product`.
- Strategy contracts, execution, read-only Run activity, and inference-context composition belong to `adele_orchestration`.
- Model-tool contracts belong to `adele_model_tool`.
- Environment provider contracts belong to `adele_environment`.
- Flutter Session, tool Inspection, and model-native activity presentation contracts belong to `adele_ui`; product, orchestration, and model tools do not depend on UI.
- Plugin-defined ecosystems keep their contracts with their deliberately public plugin/component API owners.

### Application backend composition

`AdeleRuntime()` synchronously registers six in-process stock contributions and
remains provider-free. Its pure-Dart `ApplicationPluginBootstrap` owns
application-lifetime backend resources on the same `CapabilityRegistry` used by
lifecycle. Normal `AdeleApplication` explicitly calls `start` with an installation
root, shared runtime/host paths, and optional generic startup argv. There is no
stock callback table, required Git backend, or additional-OpenAI activation tier.

`plugin_runtime` owns `PreparedPluginCatalog.discover(rootPath)`, a deterministic
startup snapshot of immediate child installed manifests. It uses public
`PluginMetadata`, not builder source manifests or plugin implementations. Installed
metadata contains identity and prepared component locations, not exposures,
configuration, activation, or source paths. Discovery precedes host creation;
zero valid backends needs no process even with invalid host paths. Child issues
and duplicate-ID exclusion are catalog concerns; root I/O failure becomes generic
bootstrap failure without disabling the in-process core. See
[`plugin-layout.md`](plugin-layout.md#prepared-installation-snapshot).

The app attempts all valid backend installations independently. A local startup,
advertisement, or registration failure releases only that attempt's resources;
termination retires only its exact generation. Shared-host failure is global.
Read-only per-backend states and catalog issues do not imply a management UI.
Close retires all registrations before generations, then the host, then in-process
activations. Generic Task presentation submits through product lifecycle and never
parses opaque `providerState`; Environment providers own source validation.

Backend entrypoints, including Git and OpenAI, own ready `capabilityExposures`.
Public `adele_contract` owns the lightweight advertisement value/validation; the
existing isolate-ready/host-`pluginReady` path transfers it to the exact connection.
`PluginCapabilityActivation.registerAdvertised` delegates to existing `register`:
plugin identity comes from installation/connection and registry validation,
configuration-context routing, and exact-generation liveness stay unchanged.
Plugins need no internal host imports, second registry, or reverse RPC to advertise.

Source selection/compilation and stock installation assembly belong to repository
tooling and `plugin_builder`, outside the app startup import graph. The launcher
still knows Git/OpenAI source paths; stock source layouts need not use
`adele_plugin.yaml`. Its separate temporary JSON file maps PluginId to string argv
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

`app/lib/plugins/temporary_chatgpt_selection.dart` retains selected provider
identity and model-only configuration, not startup or exposures. `fromEnvironment`
always returns the model default/override without inspecting credential presence
or startup OAuth configuration. Provider availability comes from the active
registry. General provider/model configuration remains deferred. Operational details
live in [`app/README.md`](../../app/README.md#normal-backend-startup) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).
Self-hosting uses generic `registerAdvertised` but keeps its explicit
artifact/host/profile topology without requiring normal discovery or configuration.
Its own profile environment configures the backend; it registers all advertised
contexts, potentially both OpenAI contexts, then explicitly resolves the selected
profile's provider ID without filtering advertisements.
Frontend EVC activation and in-process plugins remain unchanged. These boundaries
add no public API package, profile/enable-disable system, version solving, watching,
frontend discovery, hot upgrade, or production packaging mechanism.

The normal model adapter lives
in `app/lib/core/model_provider_host.dart`, separate from development-only resource
adapters. Session lifecycle remains strategy-neutral and Run hosting remains
provider-neutral; normal Chat presentation composes each Run's model, tools, and
approval-gated policy without adding plugin-specific behavior to those generic
owners. Approval cards are window-local presentation over existing Run
interruptions, not new public APIs or Chat-owned canonical history. Policy and
exact-invocation authorization remain host-owned; tools and Environment providers
retain their execution and revision guarantees.

### Session presentation and frontend composition

`packages/ui` (`adele_ui`) owns `SessionPresentationContribution` with
`strategyId: OrchestrationStrategyId` and
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

`app/lib/frontend` owns generic prepared frontend generation/runtime hosting,
not source discovery, compilation, stock selection, or Chat state.
`app/lib/plugins/stock_chat_frontend.dart` is the provisional stock activation
proxy/controller adapter. `ChatController` intentionally remains in
`app/lib/ui/chat` as provisional composition. Common `RunExecutionStatus`,
`PendingToolApproval`, and approval display safety belong in `app/lib/ui/execution`;
the stock adapter connects the controller without making those components Chat
APIs. Host policy and exact-invocation approval remain the security authority.

The separate `chat_strategy_frontend` Flutter package renders history/composer
from prepared EVC, without importing the headless Chat implementation, app, or
kernel. Its eval bridge carries only immutable primitive message/activity timeline
snapshots, composer-enabled state, string submission returning synchronous
boolean acceptance, and an opaque host-built activity-widget slot for IDs emitted
to that presentation. The native slot owns inspect interaction and hosts a
plugin-owned compact widget in its own prepared runtime. The stock adapter
resolves only exact retained Run/model/output identities; no
execution, kernel, controller, or approval objects cross it. The native
Session presentation factory is distinct from this narrow eval bridge.

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
`app/lib/plugins/stock_tool_inspection_frontends.dart` imports the owning headless
packages' public `applyPatchToolId` and `runCommandToolId` only for stock
registration. This composition-edge identity knowledge is not permission for
generic hosts or other plugins to depend on tool implementations.

The generic tool eval bridge transports immutable structured maps and latest
common lifecycle/terminal data without semantic tool-field switches or flattened
progress history. Independent stock activations reuse `PreparedFrontend`;
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

`app/lib/plugins/stock_openai_activity_frontend.dart` imports Contract identity
only for stock registration: it loads prepared EVC, registers the factory, and
retires registration/resources through `PreparedFrontend`. It owns no OpenAI
algorithms. This composition edge is explicitly provisional until frontend
discovery and profiles replace hard-coded selection. Activation is independent of
model backend readiness and other frontends. Malformed safe payload and factory/EVC failures
leave rich presentation unavailable without failing Runs or selecting a native
fallback. Summary requests remain provider-local; generic inference and UI code
neither assert all-model support nor select reasoning options. See the
[backend README](../../plugins/openai/packages/backend/README.md).

Flutter build-time tooling compiles frontend source; normal runtime activation
only consumes prepared artifacts. Checkout preparation is a stand-in for future
installation/update compilation, not a cache or implemented plugin management
system. Flutter/eval dependencies do not enter the shared headless runtime or
the pure-Dart `plugin_builder` package.

## Plugin dependencies

A plugin may depend on public surfaces as needed:

```text
adele_plugin_api
adele_core_extensions
adele_contract
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
plugin_builder
agent_kernel
adele_desktop
```

Stock `local_directory_project_selector_plugin` depends on the public selector
and registry APIs, not product lifecycle or app state. Its `file_selector ^1.1.0`
native picker is behind a conditional Flutter-only import and an injected narrow
function. This preserves the real plain-Dart self-hosting CLI import graph through
shared `AdeleRuntime`: activation performs no OS call, and headless default picker
invocation explicitly throws `UnsupportedError`. This is a platform implementation
boundary, not permission to add Flutter to `adele_core_extensions` or product.

This prohibition includes orchestration-strategy plugins. A Chat or Goal strategy may need Run/model/tool execution semantics, but it must obtain those through a narrow public provider-neutral orchestration/execution API backed by core. It must not import `agent_kernel` merely because the kernel implements those semantics internally.

Within a source plugin, dependencies have this shape:

```text
          plugin contract/API (pure Dart where possible)
             ^                 ^
             |                 |
         backend            frontend
```

The backend and frontend depend on shared contract/API packages as needed. They do not depend on one another. Transport contracts do not depend on Flutter. A frontend may depend on Flutter and deliberately public UI APIs such as `adele_ui`. The same implementation split applies to the in-process headless Chat, Filesystem Tools, and Command Tools plugins and their separate Flutter frontends. A backend may use full Dart capabilities subject to the runtime and eventual security model.

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
