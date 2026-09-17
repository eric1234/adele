# ADELE Architecture Overview

## Status

ADELE's maintained Linux x64 foundation includes source compilation, generated unary and server-streaming/cancellation transport, interpreted frontend execution, active capability routing, configured provider contexts, bounded agent/source-inspection, conditional Environment mutation, foreground-process execution, and create/delete tooling. It includes the real OpenAI `ModelProvider`, an explicitly experimental ChatGPT configured instance, initial Project/Task/Environment lifecycle, canonical strategy-bound Session creation with separate Environment authority, generic extension/model-tool composition, executable strategy contributions, a Git Environment provider, and independent stock Filesystem Tools, Search Tools, and Command Tools that own Session-authorized `read_file`, `apply_patch`, `create_file`, `delete_file`, `search`, and `run_command`. Headless stock Chat owns conversation state and sequencing through a narrow public execution facade backed internally by the kernel.

The maintained source-inspection topology routes the canonical Session through core strategy resolution and Chat materialization, generic model-tool extension composition, plugin-owned Search, Session-authorized Environment access, plugin-owned Read File, maintained ADELE source, and model continuation. Search is bounded native Dart traversal over authorized Environment directory/file reads, not an Environment provider method. Focused deterministic validation passes for public orchestration, kernel model/run/tool mechanics, Chat, and maintained application lifecycle, model-tool hosting, self-hosting, Environment, OpenAI fixture, and provider-adapter integration. This implements neither ADELE's complete product/domain model nor the general recursive extension system.

Environment exposes provider-neutral opaque file revisions and conditional replacement of existing bounded UTF-8 text files. The Git Worktree provider serializes ADELE replacements within each live Environment and detects practical out-of-band changes immediately before promotion, but cannot provide portable atomic compare-and-replace against arbitrary external processes. Coherent read and mutation facets share one Session-authorized filesystem authority. Filesystem Tools' exact-unique `apply_patch` lowers localized model edits to complete-file conditional replacement. Deterministic real-Git integration covers Read-to-Revision-to-Patch continuation. Opt-in OpenAI API-key and experimental ChatGPT tests cover real-model revision flow, Task-worktree-only mutation, post-write observation, and continuation; recorded live results remain bounded interoperability evidence rather than a stable contract.

Filesystem Tools owns the model patch grammar, not `EnvironmentProvider`. It
preflights the original opaque revision once and applies the non-empty `edits`
array of `{search, replace}` objects in list order to a working string. Each
non-empty search must be an exact, case-sensitive, literal unique match,
including overlapping candidate starts; replacement text may be empty. Later
edits see earlier replacements. A failed edit reports its zero-based
`failedEditIndex` and total `editCount` with no writes; a final result identical
to the original reports `no_change` with no writes. Only after all edits pass
does the tool request one conditional whole-file replacement using the unchanged
original expected revision.

The Environment provider contract supports foreground process execution through one Session-authorized process view over the existing Environment authority. The stock Git Worktree provider supplies bounded stdout/stderr streaming, timeout and cancellation cleanup, confined cwd resolution, direct argv execution, and practical Linux x64 process-group ownership. Stock `run_command` projects that surface through structured stdout/stderr progress, bounded terminal model output, and the allow/deny/ask policy path. Deterministic real-Git integration covers source edit -> direct `git diff --check` -> model continuation in the Task worktree. Opt-in OpenAI API-key and experimental ChatGPT tests cover the same real-model sequence with revision provenance and Task/Project/checkout isolation. Fine-grained command classification, implicit shell syntax, background process resources, general build/test success, sandboxing, and complete self-hosting remain unproven.

The Environment mutation facet and generated transport also support create-new and revision-conditional delete operations. Filesystem Tools projects them as `create_file` and `delete_file` with exact `sourceMutation` targets. The Git provider serializes create/replace/delete together, rejects indirect paths, never intentionally overwrites on create, and rechecks revisions immediately before delete. Deterministic real-Git integration covers model-visible create -> read -> delete revision provenance, policy/effect ordering, and final Task/Project/checkout isolation. General whole-file overwrite, directory/move/copy/binary mutation, portable filesystem transactions, and full self-hosting remain unimplemented.

The following remain largely or entirely unimplemented:

- Project/Task/Session/Environment disk persistence and complete lifecycle;
- rich Chat/workbench UI and persistent strategy-specific state;
- context sources beyond root AGENTS.md, broader Reference/Observation material, provider-aware projection/cache planning, compaction, and token budgets;
- parent/child Session lifecycle;
- plugin-defined extension ecosystems beyond registration, model tools, executable strategies, and instruction-context composition;
- broader plugin-facing workbench UI composition beyond Session, tool Inspection, and model-native activity presentation;
- application Command/Command Palette/keybinding infrastructure;
- profile-aware provider preference and general configuration services;
- additional Environment providers, process modes beyond the foreground surface, and broader mutable source tooling such as whole-file overwrite, directory/move/copy, and binary operations;
- the expected stock plugin topology;
- cross-platform release, packaging, and sandboxing.

Public plugin-facing APIs remain experimental.

F2 extends F1's prepared startup snapshot and backend-owned ready capability
advertisements with independently optional frontend components and metadata-driven
presentation registration. F3a adds ready extension advertisements, generic host
adapters, and narrow unary host calls, moving AGENTS.md into an AOT backend while
five other plugins remain static. These slices are not an installer, production
packaging, profile/enable-disable manager, version solver, filesystem watcher,
general symmetric RPC, reverse-streaming, or hot-upgrade path. Existing registries,
isolate ports/framing, prepared EVC execution, and per-view decoding are reused.

The normal shell supports Project opening, title-only Task creation with a real
Git primary Environment, and one stock Chat Session with sequential approval-gated
Runs through the experimental ChatGPT subscription-backed ModelProvider. A narrow
public Flutter Session presentation contract hosts the stock Chat plugin's
evaluated mixed message/activity timeline and composer; common execution status
and approvals remain host-owned. Compact Chat tool/native activity groups open one
window-local Inspection, with common ordered group composition and separate
interpreted Apply Patch, Run Command, and OpenAI reasoning-summary presentations.
These reuse prepared frontend hosting without a native presentation fallback or
a general workbench UI framework.

## System shape

ADELE has one Flutter desktop application, `adele_desktop`, under `app/`. The application owns the current shell, theme, private widgets, desktop integration, and composition of host systems. It is a composition root rather than the primary home of core logic.

`app/lib/core/adele_runtime.dart` defines the application-lifetime `AdeleRuntime`.
It owns one `CapabilityRegistry`, `ExtensionRegistry`, `InMemoryProductStore`,
`ProductLifecycleCoordinator.generated` wired to those same registries and store,
`InferenceContextComposer` over the same extension registry, and retained
`ChatStrategyPlugin`. By default it statically activates Chat,
Filesystem Tools, Search Tools, Command Tools, and Local Directory Project
Selector in process, all on the same extension registry. The selector is the
fifth owned activation; the reduced composition omits only Command Tools. This
is an implicit in-process composition, outside installed-component discovery and
not a profile/configuration API. Construction is synchronous and provider-free. The
runtime also owns pure-Dart `ApplicationPluginBootstrap` on those same capability
and extension registries, without starting backend work in its constructor.
AGENTS.md has no direct app dependency/import or static activation; its prepared
backend supplies the source through generic remote extension activation.

The normal Stateful `AdeleApplication` constructs its runtime once synchronously
in `initState`, not during rebuilds, then explicitly calls async
`ApplicationPluginBootstrap.start`. Inputs are only the installation root, shared
runtime/host locations, and optional generic startup argv. There are no stock
activator callbacks or required-Git/additional-OpenAI tiers.

`plugin_runtime.PreparedPluginCatalog.discover(rootPath)` reads a deterministic
startup snapshot from immediate child directories' `adele_plugin.installation.json`
files before host creation. The version-1 JSON schema contains `PluginMetadata`
(`id`, opaque `version`, `displayName`, optional `description`) and `components`,
with independently optional backend and frontend components. Backend supplies an
artifact such as `backend.aot`; frontend supplies an artifact such as `frontend.evc`
and strict presentation descriptors with roles `session`, `toolActivity`, or
`modelNativeActivity`. Artifact paths must be relative, confined, and existing.
Descriptors are data-only executable ABI/preparation metadata, not profile state.
There are no source paths, capability/extension exposures, configuration, or activation state
in this manifest; the source/build
`adele_plugin.yaml` has a different purpose. Stock source layouts are not normalized
to it. See [`plugin-layout.md`](plugin-layout.md#prepared-installation-snapshot).

An unconfigured, missing, or empty root succeeds with an empty catalog. Invalid
installation envelopes are reported and excluded. Invalid components record typed
backend/frontend issues and omit only the failed component while retaining the
installation and healthy sibling. Readable valid identities are reserved before
remaining validation, so duplicate IDs exclude all conflict members, including
otherwise invalid manifests, without selecting a version winner. Root I/O failure
reports generic bootstrap failure, not successful emptiness; core in-process functionality
and Project opening remain usable. There is no watching or rescan lifecycle.

The backend bootstrap publishes the catalog through its existing snapshot change
notification before backend startup. Window-owned Flutter
`ApplicationFrontendBootstrap` in `app/lib/frontend` consumes that same snapshot
and the runtime's existing `ExtensionRegistry`. It loads each frontend once per
generation through `PreparedFrontend` and registers the descriptor-selected public
UI roles, with no second root, catalog, registry, or frontend runtime mechanism.
Local load/registration failure rolls back only that attempt's exact registrations
and generation; frontend readiness does not depend on a backend, credentials, or
another frontend. Retirement closes only captured exact registrations, not sibling
roles or replacements. Generation close settles pending loads, retires its
registrations, and invalidates its view resources, including late loads after close.

Catalog validation establishes strict descriptors and confined existing files,
not executable EVC correctness. `PreparedFrontend.load` retains immutable bytes;
decoding and entrypoint execution stay per-view. Readable corrupt bytecode can
therefore pass discovery and byte loading yet fail only when a view is created,
without failing a Run or retiring healthy presentations.

With no valid backend components, bootstrap succeeds without spawning a host even
if runtime/host paths are invalid. Otherwise it starts one shared
`PluginBackendHost` and independently attempts every valid backend. Local start,
advertisement, or registration failure cleans up only that attempt's partial
resources. Later termination retires only its own exact generation; shared-host
failure invalidates all backends. The bootstrap exposes read-only per-backend
states and catalog issues, not a plugin-management UI. Overall `ready` means
startup settled, not that every backend succeeded or a model is usable.

Git and OpenAI entrypoints own their ready capability advertisements; AGENTS.md
owns its ready extension advertisement. Generic
`PluginBackendActivation.registerAdvertised` coherently owns both capability and
extension registration, rollback, and retirement through the existing registries.
Internal `RemoteExtensionAdapterRegistry` selects host adapters for known public
extension points; it is not another contribution registry or PluginId switch.
Unsupported points and malformed metadata fail that backend attempt. There is no
app-owned backend exposure table. `app/lib/plugins/temporary_chatgpt_selection.dart`
retains the selected provider identity and model-only `StockChatGptConfiguration`.
`fromEnvironment` always supplies a model default or override, with no credential
field or presence gate. Provider availability comes from the active registry;
the app does not inspect startup OAuth/credential configuration. The helper owns
neither backend startup nor exposures. The launcher supplies OpenAI's credential-file
reference and public OAuth/endpoint options through a separate temporary generic
argv file, never token contents. It always selects `--chatgpt-only`: no configured
reference means successful zero capabilities, not inherited API-key activation.
Normal bootstrap independently sets `startupArgumentsOnly: true` on every
`startPlugin` call; the shared host forwards it to the backend startup message.
OpenAI disables environment fallback in this mode and advertises zero capabilities
for empty argv or an absent configuration document, so root-only normal activation
cannot inherit an API-key exposure even without the launcher map. Generic code
uses no PluginId switch. This temporary mode is not environment scrubbing or
settings/profile/credential infrastructure.
General provider/model configuration remains deferred; this seam is intended
to disappear with general plugin configuration/profiles. Runtime and shared host
remain OpenAI-unaware. This is ownership separation, not process sandboxing.

Application close synchronously blocks window actions and notifications and drains
in-flight Task establishment and only the currently advancing Run start/resume
before `runtime.close`, even on failure. A quiescent waiting Run is abandoned with
runtime teardown, without resolving or executing its pending invocation or waiting
indefinitely for approval. Draining is not cancellation or rollback. Desktop exit
awaits the complete close; detach/dispose initiate the same cleanup and report
runtime cleanup failures through `FlutterError`. Frontend cleanup runs even if
runtime cleanup fails, retiring exact registrations and invalidating bridges after
pending activation settles. Runtime close shares one completion across
callers: all backend capability and extension registrations retire before their
connections close, then the host closes, then in-process activations retire in reverse order.
`app/lib/core/resource_cleanup.dart` supplies `closeResources`, shared with
development teardown: every action is attempted before the first error is
rethrown with its stack.

The minimal themed shell retains its ADELE header. In B1, `AdeleApplication.build`
discovers `projectSelectorContributions` and displays `No Project is open` with
one button per contribution in deterministic registry registration order. Zero
selectors is an explicit unavailable state; one or multiple contributions are
independent actions, not a chooser/default-provider framework.

Normal activation consumes one catalog of prepared backend/frontend installations,
not source paths or a compiler. No active Environment capability leaves Task
Environment support unavailable; missing Chat, Filesystem Tools, Command
Tools, or OpenAI activity EVC leaves the corresponding presentation unavailable
independently of the other frontends and model backend support.
Artifact preparation belongs to repository/build-time tooling, not app startup;
deployment inputs and source-checkout limitations are documented in
[`app/README.md`](../../app/README.md#normal-backend-startup) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).
Checkout preparation stands in for future installation/update-time compilation;
activation only consumes prepared artifacts. Caching, plugin management,
production packaging, and profiles remain deferred. Linux tooling prepares six
installations in one `.dart_tool/adele/desktop-plugins/build-*/installations/` root:
frontend-only Chat, Filesystem Tools, and Command Tools, backend-only Git and
AGENTS.md (`agents-md/backend.aot`), and one combined OpenAI. Preparation produces
three backend snapshots plus the host and four EVCs, with no AGENTS-specific
configuration. `tools/stock_frontend_descriptors.dart` is the singular stock
build-side descriptor table; app runtime activation has no stock tool/native
identity table. Only the four generic root/host/runtime/startup-argv defines remain.

Flutter bootstrap reads and forwards only generic plugin argv; configuration
interpretation and credential loading belong to the owning backend. Startup
creates no Project, Task, Environment, or Session, builds no tool catalog, and
starts no Run. Explicit user actions enter product lifecycle and Run composition.
General provider/model configuration,
Task Browser, persistence, and richer workbench UI remain deferred.

Development/self-hosting owns an `AdeleRuntime` instance instead of duplicating
these registries, lifecycle, composer, Chat, and activations. Its surrounding
topology/runner retains its independent AOT artifacts and host ownership, provider
activation, isolated Git source, Project/Task/Environment/Session establishment,
tool catalog, model selection, development IDs, execution, and evidence. The generic
model capability adapter lives in `app/lib/core/model_provider_host.dart`; normal
composition has no dependency on development code. Self-hosting uses generic
`registerAdvertised` for backend-owned exposures but keeps its explicit
artifact/host/profile topology, adding `agentsMdArtifact` on the same shared host
through `PluginBackendActivation` and the same remote-source adapter. It does not
require a normal installation root or catalog discovery,
consume normal bootstrap configuration, or start its backend owner. Its own
profile environment configures the backend with the default
`startupArgumentsOnly: false`; registration includes all advertised
online contexts, potentially both OpenAI contexts. It then explicitly resolves
the selected profile's provider ID rather than filtering registrations by profile.

The selector's native picker uses a conditional Flutter-only import so shared
runtime composition preserves the real plain-Dart self-hosting CLI import graph.
Registration makes no OS call; invoking the default picker headlessly throws
`UnsupportedError`, not cancellation or a fallback.

Host implementations are split into small pure-Dart packages where Flutter is not required:

| Package | Maintained/planned responsibility |
| --- | --- |
| `plugin_runtime` | Prepared installation catalog, backend connections, capability/extension activation adapters, and operation-scoped unary host routing |
| `plugin_builder` | Source resolution, contract checks/generation coordination, backend/frontend builds, diagnostics, provenance, and caching |
| `plugin_backend_host` | Shared child-process entrypoint and one external AOT isolate group per active plugin backend |
| `agent_kernel` | Provider-neutral Run/model/tool semantics, interruptions, policy boundary, structured outcomes, and typed execution observation |

These are internal packages. Plugins must not import them.

Public pure-Dart `adele_plugin_backend_support` is separate: its only production
dependency is `adele_contract`, and its reusable `AdeleHostRequestMultiplexer`
provides generated unary request channels without internal host or Flutter imports.

The source-plugin runtime shape is:

```text
Flutter desktop host (main Flutter isolate)
  |
  +-- interpreted frontend from flutter_eval/dart_eval bytecode
  |
  +-- generated typed asynchronous transport
  |
  +-- one shared child dartaotruntime process
        |
        +-- one native Dart AOT isolate group per active plugin backend
```

This shape is proven only on Linux x64 Flutter profile mode. Direct external AOT loading inside stock Flutter failed. Backend process/isolate separation is not a security sandbox.

Contract source can be shared by plugin frontend/backend packages. Generated transport hides ports, serialization, request IDs, stream protocol, cancellation, dispatch, and structured transport errors behind typed proxies/dispatchers. Values crossing runtime boundaries are reconstructed rather than shared by identity and should normally be immutable snapshots.

## Recursive plugin extension direction

ADELE's accepted long-term model is recursively extensible:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

The broad rules are recorded in [`plugin-extension-model.md`](plugin-extension-model.md) and ADR 0030.

Core owns durable shared identities/invariants and host infrastructure. Plugins provide much of the concrete product behavior. Plugins may publish deliberately public extension APIs for concepts they own, and other plugins may implement those interfaces without depending on one specific implementation plugin being active.

Runtime composition should prefer typed interface discovery over hidden activation dependencies. Zero/one/many compatible registrations may be valid depending on the extension contract.

Capabilities remain the implemented callable-provider mechanism for Actions and Services. Events are read-only fact notifications. Other extension points may collect UI fragments or structured operation contributions without being callable capabilities.

The generic `ExtensionRegistry` supports typed registration/discovery, change notifications, retirement, and exact binding liveness. Current model-tool, orchestration-strategy, inference-context-source, Project selector, Session presentation, tool Inspection, and model-native activity presentation points reuse it with their own composition semantics; already-resolved bindings do not migrate to replacement generations. Instruction-source data becomes independent of binding liveness after safe capture, unlike executable work.

Tiny pure-Dart `adele_core_extensions` imports only `adele_plugin_api` and owns
core extension contracts with no natural existing public domain package, not all
extension APIs. Product values, orchestration strategies/context, model tools,
Environment providers, generic registry mechanics, and plugin-defined ecosystems
keep their existing owners; see [`dependency-rules.md`](dependency-rules.md).

Public Flutter `adele_ui` owns the concrete Session, tool Inspection, and
model-native activity presentation contracts, depending on public
`adele_orchestration` and `adele_model_tool` without adding Flutter to those
packages, product, or the registry. Broader recursive composition,
plugin-defined UI ecosystems, generic Event subscription,
Commands/keybindings, and inference composition beyond instruction material remain
direction rather than implemented production systems. Registry change
notifications are not a general domain Event subscription system.

## Contracts, capabilities, and providers

Contracts answer how typed communication crosses a runtime boundary. Capabilities answer which compatible provider handles a callable semantic request. Extension points are the broader architecture for typed plugin participation.

Implemented capability resolution is one-to-many. Several plugins may provide the same Action/Service, and one plugin runtime may expose multiple configured instances. The host-owned active registry implements provider discovery/enumeration, deterministic rank-based default resolution, explicit selection, exact-major matching, and exact generation-bound routing.

The rank-based default is a deterministic development fallback, not the final preference system. ADELE owns preferred-provider selection; future profile/project/user policy may select contextual defaults and expose explicit alternatives.

Configured capability instances such as `OpenAI Work` and `OpenAI Personal` are distinct from plugin installations/runtime instances. Temporary documents, terminals, browser sessions, and processes are runtime resources rather than configured providers.

Backend startup carries optional `capabilityExposures` from isolate `ready` through
host `pluginReady` to the exact connection. Each advertisement has `providerId`,
`capabilityId`, `capabilityMajorVersion`, `serviceId`, `displayName`,
`configurationContext`, and optional `rank` (default zero). Plugin identity comes
authoritatively from installation/connection, never the advertisement. An omitted
list is zero capabilities. `registerAdvertised` maps this metadata into existing
`PluginCapabilityActivation.register`, not a new registry or RPC mechanism.
Installed metadata does not establish readiness; only active registrations enter
provider resolution. ADRs 0015, 0021, 0027, and 0028 retain the distinctions between
installation, activation, active provider selection, generation-bound contexts,
and plugin-owned credentials.

F3a adds independent optional `extensionExposures` with exactly `extensionPointId`,
`extensionId`, `serviceId`, `configurationContext`, and recursively immutable JSON
`metadata`. Unknown keys fail, omission means zero extensions, and there is no
PluginId or priority in the exposure. `PluginExtensionActivation` adapts known
points into the existing `ExtensionRegistry`; `PluginBackendActivation` rolls back
capabilities and extensions together when either registration phase fails.

The app's `RemoteInferenceContextSourceAdapter` implements the first remote point.
Generated orchestration `RemoteInferenceContextSourceService.snapshot(sessionId,
runId, hostInvocationContext)` returns `RemoteInferenceInstruction` values with
key, text, and required nullable revision. Metadata accepts only `failureMode`
with `required`/`optional`, leaving composition policy with the public composer.
Generated Environment `AuthorizedEnvironmentReadService.readFile(relativePath)`
returns `EnvironmentTextFile` and preserves declared `EnvironmentFailure`, with no
authority-ID parameters, directory reads, mutation, or process operations.

The app captures canonical `InferenceContextSourceContext` to obtain its read
facet, never reconstructing authority from transported Session/Run IDs. Secure
opaque per-operation contexts allowlist services on the exact connection.
Unary `hostRequest`/`hostResponse` reuse existing isolate ports and framed shared
host, which stamps the owning generation; liveness checks bracket asynchronous
dispatch. `finally`, retirement, shutdown, and termination revoke contexts and
settle pending calls. Late results cannot migrate to replacements. Host and plugin
protocol versions are both 2, requiring coherent artifact rebuilds. This is narrow
host-read access, not reverse streaming, general symmetric RPC, or a sandbox.

See [`contracts-and-capabilities.md`](contracts-and-capabilities.md).

## Core product-domain direction

ADR 0031 accepts the following long-term shared domain identities:

```text
Project
└── Task
    ├── Environment(s)
    └── Session(s)
        ├── Run(s)
        └── child Session(s)
```

### Project

Project is an abstract core identity/lifecycle concept, not intrinsically a local
directory. B1 implements `ProjectSelectorContribution` in
`packages/core_extensions` (`adele_core_extensions`) with only
`String displayName` and `Future<Uri?> Function() selectProject`. The typed
`projectSelectorContributions` point has ID `dev.adele.extension.project-selectors`
and permits zero, one, or multiple independent contributions, without priorities,
defaults, categories, or applicability rules.

Stock `local_directory_project_selector_plugin` provides `Open Local Directory...`
through an injected narrow native picker using `file_selector ^1.1.0`. It returns
an absolute `file:` directory URI with lexical dot normalization, without
Git/filesystem validation or symlink resolution. The registration boundary is
recorded in the [selector README](../../plugins/local_directory_project_selector/README.md).

Only the app invokes the contribution and passes a selected URI to
`runtime.lifecycle.createProject`, which publishes and returns the canonical
Project. `_project` in application State is window-local presentation, never
`runtime.currentProject`. Buttons are disabled during selection. `null` is
cancellation and creates nothing; selector/lifecycle failure is an inline error
without fallback or changing the presented Project. The app validates the exact
retained binding after asynchronous selection and before creation; late results
after disposal/exit are ignored.

The opened shell derives a leaf name from the URI, falling back to host or URI,
and shows the source URI, `Project is open`, and initially `No Tasks yet`. No
derived metadata is added to Project; `adele_product` stays unchanged and
independent.
Opening adds no Task, Environment, Session, model, tool catalog, or Run and does
not trigger backend activation, which belongs to async application bootstrap.
Project persistence, catalogs, deduplication, and GitHub/cloud
or other selectors are not implemented. Command surfacing and Task Browser remain
deferred; the buttons are temporary presentation, not a plugin-facing UI framework.

### Task

Task is the durable ADELE-owned unit of user intent. Plugins may attach state and behavior without owning Task identity. Task workflow category/status remains user/domain-owned rather than being inferred automatically from execution success.

Task presentation submits a title through
`runtime.lifecycle.createTask(projectId: ..., title: ...)` without a provider ID.
Resolution retains the capability registry's descending-rank/ascending-identity
default, not a Git-specific route or multiple-provider ambiguity rule. The
selected provider owns source validation, including non-Git rejection; Project
opening remains provider-independent.

Only successful lifecycle completion presents the new canonical Task and primary
Environment. Selection remains window-local, with no replacement on failure and
no late updates after disposal/exit. Task Browser, a provider chooser, and Commands
remain deferred.

### Environment

Environment is initially the practical filesystem/source + process context used by Task work. A Git worktree-backed Environment may isolate source changes without isolating ports/databases/caches/etc.; Docker or remote providers may have different properties. ADELE does not claim stronger isolation than the selected provider actually supplies.

A separate first-class Workspace concept is not currently required architecture. It may return later if concrete requirements demonstrate an independent semantic identity.

A Task normally has one primary Environment and may own additional Environments for delegated child Session work.

Lifecycle publishes Task and finalized primary Environment together
only after provider establishment succeeds and records the exact establishment
materialization. Successful provider state is intentionally retained even if the
generation retires immediately afterward. Presentation checks live exact-binding
readiness without parsing opaque `providerState` or restoring/migrating to another
generation. Retained product state and live readiness are distinct; exposing them
does not change lifecycle settlement or generation semantics.

### Session and Run

Session is a core identity/lifecycle container permanently bound to one orchestration strategy. Core does not assume every Session is chat history; strategy-specific state defines the Session's semantic contents.

The implemented `adele_product` value is final and immutable:
`Session(id, taskId, strategyId)`. The semantic `OrchestrationStrategyId` also lives
in product so product does not depend on orchestration. Public pure-Dart
`adele_orchestration` defines
`OrchestrationStrategyContribution(strategyId, materialize)`, the typed
`orchestrationStrategyContributions` extension point, and thin
`OrchestrationStrategyResolver.resolve(id)` over the existing `ExtensionRegistry`.
It also supplies the narrow public execution facade, not a second registry or a
new public package. Canonical Session contains no live binding, Environment
authority, or Chat history.

`ProductLifecycleCoordinator.createSession` requires `taskId` and `strategyId`
and accepts an optional `environmentId`. It validates the existing Task, exactly
one current strategy contribution, and the Task's primary or explicitly selected
same-Task Environment. It then allocates `SessionId`, atomically publishes the
canonical Session and separate Task/Environment authority, and returns `Session`.
Failed validation publishes neither value. Publication is private; there is no
public `associateSession` operation. `store.session(id)` reads the canonical value,
while `requireSessionAuthority` remains the tool-host authority read path.

`coordinator.resolveSessionStrategy(sessionId)` resolves the canonical Session's
stored strategy ID. Zero matches produce an explicit unavailable error; multiple
matches produce an explicit ambiguous error even under different `ExtensionId`
values.
`ResolvedOrchestrationStrategy` retains the exact `ExtensionBinding`; retirement
makes it fail with generic `StaleExtensionBinding`. Only fresh resolution may use
a replacement registration, with no fallback or rewrite of the stored strategy
ID. The permanent semantic binding is not a lifetime activation-generation pin.

Run remains the core unit of execution inside a Session. Stock Chat owns
`ChatSessionStore.obtain(SessionId)` and retained in-memory `ChatSessionState`.
Immutable snapshots contain `ChatEntry` values (`ChatUserMessage` and
`ChatAssistantMessage`); only user/final assistant messages are canonical and
reused across Runs. Intermediate model/native output, proposals, and tool
results are Run-local replay. Instructions and a positive invocation budget are
Chat-owned configuration snapshotted per materialized Run, not product Session
fields. Normal stock presentation explicitly creates Chat through canonical
lifecycle with `chatStrategyId`; it introduces no universal default strategy.
Session validity is independent of model availability. The current Session and
its presentation controller remain window-local, never runtime navigation state.

Each accepted prompt appends a canonical user entry and allocates a fresh Run ID.
The application freshly resolves the exact selected ModelProvider and constructs
its adapter, builds the Session-authorized tool catalog, and snapshots the normal
approval-gated policy for that Run. Existing per-inference context composition
supplies root AGENTS.md instructions from the Task Environment. Chat appends only the final
assistant entry; failures preserve accepted user/history state separately from
Run failure. A later prompt starts a new Run, not a reused execution object.
Persistence, strategy defaults/profiles, and multi-Session navigation remain deferred.

The accepted direction allows child Sessions for delegated work. They may share an Environment or use another Task-associated Environment and are primarily surfaced through the parent Session/orchestration experience. Child Session lifecycle remains deferred.

### Session presentation

`packages/ui` (`adele_ui`) defines `SessionPresentationContribution` with
`strategyId: OrchestrationStrategyId` and
`createPresentation: Widget Function(Session)`. Typed
`sessionPresentationContributions` uses the existing extension registry. The
canonical Session's stored strategy ID is matched exactly: no match is
unavailable, one match provides presentation, and multiple matches are explicitly
ambiguous. Presentation selection neither supplies a default strategy nor changes
Session lifecycle or execution resolution.

The generic `app/lib/ui/session/session_presentation_host.dart` hosts an existing
Session without Chat identities or controller knowledge. It observes registry
changes, validates its retained exact binding, and removes retired presentation
widgets so their resources dispose. Only fresh resolution can select a replacement.
Absent presentation or a factory/load failure does not invalidate the Session or
backend execution; there is no native Chat fallback.

The separate Flutter `chat_strategy_frontend` package under
`plugins/chat_strategy/packages/frontend` owns evaluated history/composer UI. It
does not import the headless Chat implementation, app, or kernel.
`app/lib/frontend` owns generic catalog-driven activation and prepared hosting.
`app/lib/plugins/stock_chat_frontend.dart` remains only the bounded native adapter
to `ChatController`, intentionally retained in `app/lib/ui/chat`. Prepared Session
metadata selects `hostAdapter: 'stock-chat-controller-v1'`, and the adapter validates
the strategy. It does not load EVC, register contributions, or own activation.
Unsupported adapter/strategy combinations fail explicitly. This is neither a
PluginId switch nor a public universal Session-controller seam or reverse-call API.
Frontend activation generations and presentation instances are distinct; widget
lifecycle does not define a permanent one-runtime-per-view architecture.

The eval bridge carries immutable primitive message/activity timeline snapshots,
composer-enabled state, submission of a string returning synchronous boolean
acceptance, and an opaque activity-widget slot for previously emitted activity
IDs. The native slot wraps plugin-owned compact presentation in common inspect
interaction. It returns a native widget wrapper, not a foreign runtime's eval
object; each plugin presentation keeps its own prepared runtime and read-only
bridge. Session, controller, execution, and approval objects do not cross it.
Native slot actions are bound to that Chat presentation's bridge liveness and
mounted context. Parent presentation failure revokes them immediately, without
revoking sibling presentations or treating a compact child failure as Chat failure.
Common `RunExecutionStatus`, `PendingToolApproval`, and display safety live under
`app/lib/ui/execution`, with stock controller adaptation at the composition edge.
Host policy and exact-invocation approval remain the security authority. Activity
summaries are lightweight interpreted Chat content, not actionable approval UI.
Richer workbench composition and broad third-party UI APIs remain deferred.

### Activity Inspection

One `WindowInspection` owned by application State retains newest-first cards, not
activity copies or canonical history. Each card has a window-local
`InspectionCardId` distinct from its semantic target: an
`ActivityGroupInspectionTarget(SessionId, RunId, ModelInvocationId)` or a
`ModelOutputInspectionTarget` additionally identifying exact output sequence.
Opening always prepends a new card, including repeated targets. Existing cards
keep their position and independent collapsed state. Collapse hides the body but
retains the target; dismiss removes only that card. Stale card callbacks cannot
act on another card. Changing the presented Session or disposing the window
clears the stack; Run completion, follow-up prompts, and frontend retirement do
not. The stock Chat adapter validates opaque IDs against exact activity emitted
to that presentation, with current-Session and lifetime checks.

Chat owns the single-versus-group decision separately for each completed model
invocation. A presentable occurrence is one tool proposal or one native output
with non-null safe presentation. Text narration and opaque native outputs do not
count. One occurrence appears directly; two or more produce one group. Group
headings prefer nonblank tool-batch narration when tools exist, then the first
safe native compact text, then the presentable operation count. A single tool
never falls back to a group count.

`app/lib/ui/inspection/inspection_host.dart` owns card chrome and composes group
rows in exact `output.sequence` order. Rows use compact presentations, never rich
bodies. Common row interaction prepends an exact individual-output card without
changing its group. Individual headers reuse compact presentation; expanded
bodies use existing rich presenters. Unprepared and rejected proposals retain
factual, inspectable placeholders, including proposals left unprocessed at Run
termination. Exact output targets survive preparation and resolve to their tool
invocation without replacing the card or duplicating the Chat entry. Retained
cards reread live evidence; progress never inserts or reorders cards.
Each prepared invocation has a read-only
`ToolActivityInspectionSource`: a `Listenable` with an immutable
`ToolInvocationActivity` snapshot and fixed invocation/tool identities.
If a Run ends without a terminal result for a prepared invocation, the host
explicitly labels its retained presentation as last-observed activity. It does
not imply a current approval wait or manufacture a tool completion.

Public Flutter `adele_ui` separately defines
`ToolActivityCompactPresentationContribution(toolId, createPresentation)` and
`ModelNativeActivityCompactPresentationContribution(presentationKind,
createPresentation)`. Factories return bespoke Flutter widgets over the same
read-only tool source or safe `ModelNativePresentation`, not a host visual-card
DTO. Exact semantic identity resolution has zero/one/many outcomes: no presenter
uses factual common fallback, one uses its exact binding, and many report
ambiguity with fallback rather than choosing by order. Missing/failed/retired
compact tool presentation retains a bounded model-visible alias; native fallback
retains provider-approved `compactText`. Common code never parses tool arguments.
Retirement removes only the custom view; replacement needs fresh exact resolution.

Ownership is deliberately separate: Chat strategy owns grouping and timeline
placement; common host/workbench owns inspect interaction and card stack/chrome;
tool/provider plugins own compact and rich read-only bodies; Run/core owns
evidence identity, order, and lifecycle; the approval host owns authorization.
Compact factories receive no inspect, navigation, execution, or approval callback.

Public Flutter `adele_ui` defines
`ToolActivityInspectionContribution(toolId, createPresentation)` with a
`Widget Function(ToolActivityInspectionSource)` factory and typed
`toolActivityInspectionContributions`. Its resolver matches exact `ToolId`: zero
is unavailable, one returns the existing registry binding, and multiple are
ambiguous. The generic tool host retains the same source/view across updates,
validates exact liveness, and removes retired widgets and resources. Only fresh
resolution may select a replacement. Missing, failed, or retired presentation
does not fail headless execution and has no native tool-card fallback.

Filesystem Tools and Command Tools own separate interpreted frontend packages
for `apply_patch` and `run_command`. Their widgets interpret plugin fields;
`app/lib/frontend/tool_activity_inspection_bridge.dart` transports recursively
immutable structured argument/terminal maps, latest non-progress common lifecycle,
and outcome data, without tool-specific field switches or progress-history
flattening. Coalesced snapshot notifications update the retained interpreted
runtime/view. Command output previews are bounded terminal data, not a console.
Prepared `toolActivity` descriptors supply identities and entrypoints to generic
`ApplicationFrontendBootstrap` over the existing `PreparedFrontend` lifecycle;
there is no stock tool activator or runtime tool identity table for activation.
The same prepared artifacts expose compact entrypoints: Filesystem shows the
relative patch target and canonical edit count, not invented Git line statistics;
Command shows a bounded direct-argv representation without shell reconstruction.

The prepared host contains decoding/entrypoint and Tool change-callback failures.
Runtime-local guards also cover the current eval pin's interpreted `createState`,
`initState`, `build`, and `dispose` calls, including native cast failures within
those calls. A failure revokes observation and unmounts only that presentation;
interpreted cleanup receives one attempt and native State disposal still completes.
This is not a general Flutter error boundary: native Flutter errors outside those
calls (including layout/paint) and arbitrary asynchronous callbacks are not
intercepted. No global Flutter error handler is replaced.

Inspection appears to the right on wide windows and below on narrow windows;
placement is private app layout, not a public physical panel API. Tool and native
cards are simultaneously accessible through an independent scroll area and are
read-only; only common host approval UI offers Allow/Deny for the exact
interruption. Arbitrary plugin drill-down beyond group-to-individual activity,
Source/Diff/Console navigation, terminal/PTY and
full-output views and persistence remain deferred.

### Model-native activity presentation

The provider backend supplies safe presentation alongside, never inside or instead
of, exact raw native metadata. The source-of-truth common contract in
`packages/model_provider/lib/adele_model_provider.dart` defines generated
`ModelProviderNativePresentation(kind, compactText, data)`, with `String` identity
and compact text and recursively immutable JSON-like `Map<String, Object?>` data.
`ModelProviderOutput.nativePresentation` is a required nullable field, non-null
only for native outputs. Nullability means semantic absence; the constructor
argument and generated map key remain
required under the existing coherent-schema convention. This is not mixed-schema
wire compatibility or permission to hand-edit generated output.

Public pure-Dart `adele_orchestration` owns immutable
`ModelNativePresentation(kind, compactText, data)` in
`packages/orchestration/lib/src/model.dart` and optional
`ModelNativeOutput.presentation`. The adapter in
`app/lib/core/model_provider_host.dart` maps the common DTO fields generically,
without provider imports, classification, or redaction. Safe field selection and
bounds are backend responsibilities; immutable containers validate/copy data but
do not determine whether provider fields are safe. Raw `nativeMetadata` remains
exact and the only native replay source. Safe presentation never enters replay,
canonical Chat history, or a new persistence model.

Public Flutter `adele_ui` defines
`ModelNativeActivityPresentationContribution(presentationKind, createInspection)`
at typed `modelNativeActivityPresentationContributions`. The factory has type
`Widget Function(ModelNativePresentation)` and receives no raw envelope. There is
no UI-owned projection type or projector callback.
`ModelNativeActivityPresentationResolver` matches exact safe presentation kind
through the existing registry: zero makes rich Inspection unavailable while safe
activity still exists, one returns a retained binding, and many are explicitly
ambiguous. There is no priority, applicability probing, or fallback. Retained views
use exact-generation liveness; only fresh resolution can choose a replacement.

OpenAI has only `plugins/openai/packages/{contract,backend,frontend}`. Pure-Dart
`openai_contract` owns identities and payload schema, with no algorithms. It keeps
`openAiResponsesItemKind = 'openai.responses.item.v1'` and
`openAiResponsesItemVersion = 1` unchanged. Contract's
`openAiReasoningSummaryPresentationKind` is
`openai.responses.reasoning-summary.v1`, with
`openAiReasoningSummaryPresentationVersion = 1`. Backend's
`lib/src/openai_native_presentation.dart` owns
`projectOpenAiReasoningSummary(ModelProviderNativeEnvelope)`; its output is attached
in `lib/openai_model_provider_backend.dart` while raw native metadata is preserved.
It emits only `{'summaryParts': List<String>, 'truncated': bool}` as safe data.
Unsupported, malformed, empty, or oversized summary input produces no safe
presentation without changing the raw item, decoding encrypted data, or treating
compaction as reasoning-summary content.

Before text processing, input is bounded to 1,024 parts and 262,144 aggregate UTF-16
code units; all parts within that budget are validated, including discarded
suffixes. Full presentation retains at most 32,768 Unicode code points across 128
trimmed nonblank parts. `truncated` signals full-text loss, not merely compact
shortening. Compact text is capped at 160 code points including its ellipsis.
Generic Chat escapes unsafe display controls and reapplies the compact cap after
escaping; the OpenAI frontend separately escapes full text. None of these display
limits or escapes changes replay.

The separate Flutter `openai_frontend` package under
`plugins/openai/packages/frontend` supplies `buildOpenAiReasoningInspection` in
`lib/openai_frontend.dart`. The common Inspection host preserves `output.sequence`
order and passes only `ModelNativePresentation` to
`app/lib/ui/inspection/model_native_activity_inspection_host.dart`. Only its safe
`data` map crosses `app/lib/frontend/model_native_activity_bridge.dart`: no raw
envelope, compatibility metadata, encrypted content, or
execution/approval authority. Exact native/encrypted replay remains untouched in
the backend and full Run evidence. Display projection is neither replay state nor
a new canonical Chat entry, and summaries are not hidden chain of thought.

OpenAI's one installation contains both backend and frontend components. Its
`modelNativeActivity` descriptor supplies the safe kind and compact/rich entrypoints
to generic `ApplicationFrontendBootstrap`, which loads, registers, and retires
exact resources using existing `PreparedFrontend` hosting. There is no stock OpenAI
frontend activator or identity switch; generic activation performs no projection,
raw interpretation, or display escaping. The `app/tool` compile harness remains
checkout tooling standing in for future installation/update-time preparation, not
runtime activation.
Frontend readiness is independent of the model backend and other frontends.
Missing/corrupt artifacts, malformed safe data, factory failures, and contained EVC
failures remain presentation-local without failing the Run, compiling source, or
substituting a native card. Retirement removes the old view and resources but not
captured safe activity; fresh resolution cannot retarget stale resources. See
[`app/README.md`](../../app/README.md#model-native-activity-presentation) for
composition and bridge ownership.

OpenAI summary requests are a narrow provider-local `reasoning.summary: 'auto'`
policy, not a common inference option or all-model support claim. Exact guarded
model IDs and external evidence belong in the
[OpenAI backend README](../../plugins/openai/packages/backend/README.md).
Hidden chain-of-thought and encrypted reasoning are never user-presented.
Reasoning deltas, compaction UI, and general
provider/model configuration UI remain deferred.

## Agent execution

`agent_kernel` remains an internal provider-neutral execution substrate. Concrete models, tools, editors, SCM integrations, terminals, orchestration strategies, and presentation belong outside the kernel.

`plugins/chat_strategy` contains the first executable stock strategy,
`chat_strategy_plugin`. `ChatStrategyPlugin.activate` follows the in-process
stock tool convention with semantic ID `dev.adele.strategy.chat`, distinct from
plugin ID `dev.adele.plugin.chat-strategy` and extension ID
`dev.adele.plugin.chat-strategy.orchestration`. The private Chat loop owns bounded
sequential proposal batches, approval/rejection continuation, and invocation
budget behavior. A final-slot proposal batch fails before preparation/execution
because it has no continuation slot. This is not concurrent tool execution or a
general workflow system.

`createSessionOrchestrationRun` in `app/lib/core/orchestration_host.dart` looks up
the canonical Session, resolves its exact contribution once for the Run, and
materializes against `KernelOrchestrationHost` via
`OrchestrationStrategyHostContext(session, host)`. The callback returns
`OrchestrationExecution` with `start` and `resolveApproval`.
`SessionOrchestrationRun` retains that exact binding/execution and exposes
internal Run/tool/journal evidence only to application callers.

The same host exposes a separate read-only activity source whose immutable public
values belong to pure-Dart `adele_orchestration`. The application projects internal
journal evidence; neither the journal nor the Run/executable authority reaches
public consumers. Asynchronous coalesced journal invalidation supports live reads
during model/tool work, with initial and terminal snapshots and detachable
subscriptions. This is in-memory observation, not persistence or a public copy of
kernel execution events.

Model invocations retain their exact `ModelInvocationId`, ordered output
occurrences, settlement, and opaque native metadata. Each prepared tool retains
its `ToolInvocationId` through policy, approval, execution, progress, and outcome,
with explicit provenance to its originating model proposal. Arguments, effects,
and structured outcome `hostData` remain data, without executable bindings,
approval callbacks, or arbitrary exception objects. Evidence order follows the
internal journal rather than reconstructed alias/provider-call matching.

Chat decides direct compact activity versus a group per successfully completed
model invocation, not per Run. One tool proposal or safe native output is one
occurrence; one appears directly and two or more form one group. Presence is
independent of frontend activation. Group heading precedence and compact fallback
are defined in [Activity Inspection](#activity-inspection). A reasoning-only
activity precedes the canonical assistant response; proposal-free final text is
not repurposed as batch narration. Raw native items without safe presentation do
not create visible activity; unavailable rich presentation does not hide safe activity.
Stable Chat-owned inference guidance requests one brief shared-purpose statement
per related tool batch and defers to explicit user instructions. Session
instructions and independently composed sources are preserved, and guidance is
not itself history. Model narration is ordinary user-facing output, not hidden
reasoning. Raw `ModelNativeOutput` evidence is retained without generic parsing;
the provider backend supplies safe presentation and its frontend renders rich
Inspection, without changing raw replay.

The provisional `ChatController` observes the active Run and retains immutable
activity snapshots separately from canonical Chat state. Its mixed presentation
inserts activity after the initiating user entry and before the final assistant
entry, keeping completed activity through follow-up prompts for that controller's
lifetime. Snapshots are built lazily from buffered evidence; controller captures
and frontend notifications are coalesced post-frame, not repeated per progress
chunk. It detaches observation on close. Reopening/reconstructing a Session cannot restore
historical activity until persistence exists. Inspection consumes this retained
evidence separately from compact Chat narration; tool-specific fields belong to
the interpreted tool frontend and native interpretation to its owning plugin,
not a generic host-owned card schema.

The public `OrchestrationExecutionHost` exposes lifecycle operations and binding
validation, `invokeModel(StrategyInferenceMaterial)`, `processProposal` using an
opaque `StrategyToolSnapshot` and `ProviderToolProposal`, and approval resolution
returning semantic continuation. Host validation covers subsequent operations,
approval resume, and asynchronous settlement. Stale active Runs fail explicitly
and do not migrate; a later Run in the same Session can freshly resolve B under
the unchanged strategy ID. Already-started effects are not rolled back by
retirement.

`invokeModel` returns a collected `StrategyModelTurn` with ordered output,
settlement/metadata or failure, and the opaque tool snapshot. The host accepts
only unused proposals from that exact completed turn. Approval continuation
applies only the current host-supplied resolution to its retained invocation;
Chat cannot manufacture approval or substitute a tool generation.

Minimal semantic input/output, native-envelope, proposal/failure,
settlement/metadata, and approval DTOs live in public `adele_orchestration` and
are reused by the kernel. `SemanticModelRequest`, model ports/streams/collectors,
tool catalogs, policy, `AgentRun`, and the journal remain internal. Neither the
public package nor Chat depends on the kernel. The kernel has no Chat history
port or generic `ContextAssembler`; the Session/context types in ADR 0022 are
historical proof details, not current kernel APIs.

Self-hosting uses its `AdeleRuntime`'s retained Chat, obtains Session state and
appends the prompt, then routes `SessionId` through lifecycle and the core host.
The app no longer has `simple_tool_loop_strategy.dart` or
`development_strategy_registration.dart`;
`development_agent_support.dart` contains only policy.

The kernel model boundary is streaming-shaped. The common ModelProvider transport supports generated streaming/cancellation, ordered semantic input/output, live observations, terminal settlement, and provider-native item metadata. Materialized model/tool bindings remain exact-generation bound.

Tool availability, materialization, policy, optional approval interruption, execution, progress, structured outcome, and effect certainty remain distinct.

Normal `ApprovalGatedToolPolicy` allows singleton certain source reads and asks for
singleton certain source mutations. Singleton process execution requires approval
regardless of uncertainty; all other descriptions are denied. Policy, not aliases or
presentation, is the authorization boundary. Development/self-hosting policy
remains separate.

Window-local cards project immutable effect summaries, uncertainty, identity,
targets, and canonical arguments from the retained Run interruption. `Allow once`
resolves that exact interruption; object-identity checks reject stale callbacks.
User denial produces `userRejected` continuation without execution. Sequential
approvals resume the same Run, with no inference between same-batch proposals.
Cards remain outside the evaluated Chat frontend and are not canonical Chat
entries. Approval preserves revision checks and exact-generation authority and is
not sandboxing. Tool execution and Environment
authority remain outside presentation. Configurable permissions, richer
activity/console, diff/review, and steering remain deferred.

The implemented inference path starts with `StrategyInferenceMaterial`, containing
instructions and ordered `SemanticModelInputItem` values from Chat history
projection plus Run-local replay. `InferenceContextComposer` in public
`adele_orchestration` discovers `inferenceContextSources` over the same existing
`ExtensionRegistry` for every new inference, including Chat continuation. It
captures instruction-only material into immutable `InferenceContextSnapshot`
groups and source results without changing semantic input. Strategy instructions
come first, then lexicographic source `ExtensionId` order with local order
preserved; sorting is not semantic authority and there is no numeric priority.

Exact source binding validation brackets snapshot/copy/validation, including
duplicate source-local keys, before data is committed. Required failure stops
before invocation identity, model-start evidence, or provider work; optional
failure omits the entire source with original diagnostics, distinct from
successful empty output. No replacement is tried in the same capture. Captured
data survives later source retirement; source freshness is source-owned without a
generic refresh API. Executable strategy/tool binding rules are unchanged.

The fresh app source context uses canonical Session and existing typed Environment
authority. The host constructs internal
`SemanticModelRequest(context, invocationId, tools)`.
The current `ModelProviderCapabilityAdapter` calls orchestration's
`renderInferenceInstructions` to lower groups to the unchanged provider instructions
string, preserving zero-source bytes. Model/tool/policy and Environment selection
are unchanged; Chat activates no source and remains AGENTS-unaware.

The first stock source retains pure-Dart `agents_md_plugin` semantics under
`plugins/agents_md`, with `agents_md_backend` in `packages/backend` supplying AOT
execution. Normal discovery and explicit self-hosting use generic remote adapter
activation, not a static app registration. Activation alone does not read a file.
Each snapshot rereads root `AGENTS.md` through the generated authorized-read
service backed by the captured Session's `AuthorizedEnvironmentFileReadFacet`.
Missing (`not_found`) and blank files are successful empty results; other
read/service/authority errors abort the required source. Nonblank exact text and
its opaque Environment revision remain one material, separate from stable
plugin-owned semantics giving explicit user instructions and direct requests
precedence over AGENTS.md guidance. This adds no generic context infrastructure
or ownership over Skills, roles, or repository maps.

Broader inference preparation should use structured composition rather than
arbitrary request mutation. Agent policy, model routing, orchestration/history,
context, tool availability, and other plugins may contribute typed material into
provider-neutral buckets whose resolution produces a stable invocation snapshot.
These additional buckets remain deferred, as do Reference/Observation material,
other context sources, provider-aware projection/cache planning, budgets, and
compaction. Nested/scoped AGENTS.md, `AGENTS.override.md`, alternate names,
global/home files, imports, and AGENTS.md caching remain deferred.

See [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md).

## Expected stock development composition

The default development UX is expected to be produced by a stock plugin/configuration set rather than by hard-coded ADELE core behavior. Directional stock responsibilities include:

- Local Directory Project Selector (B1 native picker and minimal Project opening);
- Task Browser;
- Git/Worktree Environment provider;
- Agent Interaction + Chat strategy;
- Agent Configuration/Policy;
- Model Routing/Control;
- Context Monitoring/Compaction;
- AGENTS.md instruction source (root-only, supplied by a prepared AOT backend);
- Accounting/Usage/Quota;
- Filesystem/Search/Command/TODO/Plan tools;
- Diff/Review;
- Internal Source Editor;
- Console/Terminal;
- OpenAI provider.

The detailed, deliberately speculative decomposition is in [`stock-plugin-direction.md`](stock-plugin-direction.md). The UX manifestation is in [`../mockups/README.md`](../mockups/README.md).

Only the explicitly identified slices are implementation claims. The current app
shell remains minimal, with Project opening and Task/primary Environment
creation rather than the mockup Task Browser, and most listed plugins do not
exist yet.

## Profiles, configuration, commands, and workbench state

Profiles are accepted as sparse named composition layers. One context may eventually use an ordered stack such as `Developer + Work`. They may contribute activation decisions, ordinary configuration overrides, provider availability, and provider preferences.

Normal startup and development/self-hosting reuse the implicit in-process stock
composition and generic registration of backend-owned advertisements, while owning
separate backend topologies. Normal startup attempts all discovered valid backend
and frontend components; self-hosting retains explicit artifact/host/profile
selection. Profiles are unimplemented activation-participation policy, separate
from executable ABI/preparation descriptors. Prepared locations and the temporary
generic argv file are deployment inputs, not a profile API.
ChatGPT is provisional normal ModelProvider selection; general profile/configuration
persistence, UI, and provider preference resolution are not implemented.

Activation, ordinary configuration, provider preference, security/policy, workbench state, configured capability instances, and runtime state remain distinct domains.

An effectively disabled plugin should remove its normal product/settings surface without deleting dormant persisted configuration.

Core is expected to own application Commands, Command Palette/search, keybinding resolution, plugin-suggested defaults, and user rebinding. Those systems are architectural direction and are not yet a maintained production subsystem.

Workbench extension APIs should be semantic rather than physical. Concepts such as Main Content, Session Status, Inspection, Navigation, and Stream/Console presentation should remain stable if the physical layout moves or becomes configurable.

See [`profiles-and-configuration.md`](profiles-and-configuration.md) and [`plugin-extension-model.md`](plugin-extension-model.md).

## Maintained self-inspection vertical

`dev.adele.openai` implements the public OpenAI API-key Responses HTTP/SSE route with `store:false` canonical ordered replay. The same plugin generation exposes API-key and ChatGPT configured instances through separate generation-bound contexts. The ChatGPT subscription-backed route remains explicitly experimental interoperability evidence.

The stock Search Tools plugin contributes literal `search` and composes only the Session-authorized Environment filesystem's read facet; Filesystem Tools independently contributes revision-bearing `read_file`, exact-unique `apply_patch`, create-new-only `create_file`, and revision-conditional `delete_file` over coherent read and mutation facets. Command Tools contributes direct-argv `run_command` over only the Session-authorized process facet. The OpenAI API-key and experimental ChatGPT source-coding consumers use the read/search tools rather than the retired Phase IV DevelopmentSource capability, and a separate API-key smoke exercises `read_file` and `apply_patch` without relying on Search.

Deterministic inspection integration uses the real shared AOT host, OpenAI
plugin, Git Environment provider, Project/Task/Environment lifecycle, Session
authority, generic extension/model-tool composition, stock tools, and
Session-routed Chat. Only remote model responses come from a local fake Responses
endpoint. Coverage exercises recursive source discovery, model-visible
Search-to-Read flow, and continuation. Separate deterministic sequences exercise
Read-to-Patch mutation, direct `git diff --check` validation through
`run_command`, and `create_file` -> `read_file` -> `delete_file` with model-visible
revision provenance and final Task/Project/checkout isolation. Generation
coverage checks that fresh tools replace retired Search-tool and
Environment-provider bindings while old tools remain stale.

The normal product regression scope uses real host/Git/OpenAI artifacts, now with
the AGENTS.md backend, and prepared frontend EVCs against local fake Responses: direct reasoning
activity followed by mixed groups, retained newest-first cards, compact group rows,
individual rich cards, independent collapse/dismiss, and separate tool approvals.
It checks live evidence and safe display projection
without changing exact native/encrypted replay. This deterministic validation
boundary does not establish live-provider summary support.

Recorded opt-in live API-key and experimental ChatGPT evidence covers read/search,
real-model existing-file edit, direct-argv command validation, continuation, and
isolation. Paid live services have not been rerun against the current
deterministically validated Chat path. No paid create/delete smoke is claimed.

The bounded vertical covers self-inspection, conditional mutation, and
command-backed validation. It does not establish stable ChatGPT/OpenAI
third-party support, general filesystem mutation, production readiness, or full
self-hosting.

## Remaining runtime validation

| Risk | Current status |
| --- | --- |
| Local backend AOT compilation | Proven with the temporary matched SDK. |
| Shared process-host loading | Proven on Linux x64 profile mode. |
| Eval compilation/rendering | Proven with pinned eval dependencies and documented workarounds. |
| Generated typed communication | Proven across maintained unary and streaming plugin contracts. |
| Typed streaming/cancellation | Proven through generated transport and ModelProvider with one-item flow control. |
| Active capability/configuration routing | Proven for deterministic discovery, explicit selection, exact generations, and separate OpenAI configuration contexts. |
| Real OpenAI provider | Deterministic HTTP/SSE/shared-AOT integration proven; live network tests remain opt-in. |
| Experimental ChatGPT configured instance | Auth/routing tests, an opt-in read/search smoke, and an opt-in subscription-backed mutation/command/continuation smoke using the maintained classic Responses fallback provide interoperability evidence only. |
| Model-to-source continuation | Read/search is proven through deterministic OpenAI integration and opt-in live API-key/experimental ChatGPT evidence. Deterministic integration and opt-in API-key plus experimental ChatGPT validation smokes prove model-visible `read_file` opaque-revision-to-`apply_patch` continuation for conditional existing-file mutation in the Task worktree, direct-argv `run_command` validation, continuation from its model-visible exit result, and Task/Project/checkout isolation. Deterministic integration also proves model-visible create/read/delete revision flow and final filesystem isolation. Broader filesystem administration remains unproven. |
| Rebuild/reload | Proven for three cycles without orphan host processes. |
| General recursive extension system | Accepted architecture; not implemented. |
| B1 Project opening/native picker | Typed selector composition, cancellation/failure handling, canonical Project opening, and window lifetime are tested. Native picker adapters use fakes in CI. The recorded B1 Linux profile build passed with generated native registration; the minimum macOS `com.apple.security.files.user-selected.read-only` entitlement is present. Interactive OS picking and macOS/Windows builds remain unvalidated. The maintained tooling target guards the plain-Dart self-hosting import graph with CLI `--help`, without provider calls. |
| Normal plugin bootstrap and Task creation | F2 supplies independently optional backend/frontend components and generic presentation activation; F3a adds backend extension activation and the AGENTS.md AOT source. The Linux profile build passed with the shared host, three backend snapshots, and four EVCs. This is build/preparation evidence, not full behavioral or live-runtime validation. Task lifecycle still uses live capability resolution; operational setup is maintained in [`app/README.md`](../../app/README.md#normal-backend-startup). |
| Project/Task/Environment product model | Initial values, Task establishment, Git Environment materialization/restoration, Session-authorized read/mutation/process facets, bounded create/patch/delete text-file mutation, and generated foreground process streaming through the Git provider are proven; persistence and complete lifecycle remain unimplemented. |
| Session-bound strategy execution | Canonical immutable Session creation, atomic publication with separate Environment authority, executable contributions, explicit unavailable/ambiguous resolution, and exact binding validation across Run operations/resume/settlement are implemented and deterministically validated. Headless Chat uses the public facade with validated state, sequencing, and application integration. Persistent strategy state, child Sessions, and disk persistence remain deferred. |
| Inference context | Instruction-only source discovery, exact-binding capture, immutable snapshots, and adapter rendering are implemented. F3a supplies root AGENTS.md through remote source activation and scoped generated host reads. The confirmed profile build includes its backend but does not establish behavioral validation of every host-call path or live-provider execution. Other sources, broader material, provider-aware projection/cache planning, budgets, and compaction remain deferred. |
| Production orchestration/UI/Commands | Stock Chat, minimal Project/Task/Environment presentation, prepared mixed Chat timeline/composer, plugin-owned compact activity, retained window-local Inspection cards with group-to-individual drill-down, interpreted Apply Patch/Run Command/OpenAI bodies, and host-owned approval-gated Runs are implemented; configurable permissions, reasoning deltas, compaction UI, arbitrary plugin drill-down, Source/Diff/Console and terminal/PTY/full-output views, Task Browser, rich workbench UI, and Commands remain directional. Hidden chain-of-thought and encrypted reasoning are never user-presented. |
| Cross-platform/release | Unproven on Windows, macOS, and release mode. |
| Packaging/sandboxing | Unproven; process isolation is not a sandbox. |

The long-term goal remains for ADELE to develop ADELE itself. That goal does not change the preference for small working boundaries over speculative framework implementation.
