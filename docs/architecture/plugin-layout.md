# Plugin Source and Installation Layout

## Canonical form

Plugin source is the canonical distribution format. The development build
pipeline derives prepared frontend eval bytecode and native Dart AOT backend
artifacts from the source components a plugin supplies. A plugin need not supply
both a frontend and an AOT backend. Normal runtime activation consumes prepared
artifacts and never compiles source; future installation/update should own that
preparation. Current checkout tooling assembles fresh prepared installations for
startup discovery, not a portable installer or artifact cache.

`workspace_demo` establishes the maintained reference repository shape; its name
is historical fixture terminology and does not establish a first-class ADELE
Workspace domain concept:

```text
plugins/workspace_demo/
|-- adele_plugin.yaml
|-- pubspec.yaml
`-- packages/
    |-- contract/
    |   `-- pubspec.yaml  # workspace_demo_contract
    |-- backend/
    |   `-- pubspec.yaml  # workspace_demo_backend
    `-- frontend/
        `-- pubspec.yaml  # workspace_demo_frontend
```

The plugin directory is a small Dart workspace in the Dart package-management
sense. Its root manifest coordinates source packages; `adele_plugin.yaml` is the
draft ADELE source/build manifest, not the installed runtime manifest.

For development builds, `packages.contract` selects the plugin's transport
contract package. The builder reads its Dart package name from `pubspec.yaml`,
derives `lib/<package-name>.dart`, resolves that source to an absolute path, and
runs `contract_codegen --check --source <path>` after validating Dart but before
backend compilation. Repository-wide generator configuration is not used to
choose a requested plugin's contract.

Stock source directories have not been normalized to this fixture's
`adele_plugin.yaml` layout. In particular, the desktop launcher still knows the
Git, OpenAI, AGENTS.md, Search, Filesystem Tools, and Command Tools source entrypoints and prepares
their installations explicitly.
Source/build discovery and installed-artifact discovery are separate boundaries.

## Prepared installation snapshot

`plugin_runtime.PreparedPluginCatalog.discover(rootPath)` reads a one-time startup
snapshot of immediate child installation directories. Each child supplies
`adele_plugin.installation.json`, independently of any source/build manifest:

```json
{
  "manifestVersion": 1,
  "metadata": {
    "id": "dev.adele.plugin.git-environment",
    "version": "0.1.0",
    "displayName": "Git Worktree Environment"
  },
  "components": {
    "backend": {"artifact": "backend.aot"}
  }
}
```

`metadata` uses the existing `PluginMetadata` value: `id`, opaque `version`,
`displayName`, and optional `description`. Version is not parsed or used to select
a winner. `components` may be empty or contain independently optional `backend`
and `frontend` components. Backend has only an `artifact` relative file path.
Frontend has `artifact` (normally `frontend.evc`) and a `presentations` array;
an empty array is valid. One installation can supply both components without
duplicating its PluginId in another directory.

Each presentation is a data-only descriptor with a required `role` and exactly
the fields for that role:

| Role | Required fields besides `role` |
| --- | --- |
| `session` | `extensionId`, `strategyId`, `library`, `entrypoint`, `hostAdapter` |
| `toolActivity` | `inspectionExtensionId`, `compactExtensionId`, `toolId`, `library`, `inspectionEntrypoint`, `compactEntrypoint` |
| `modelNativeActivity` | `inspectionExtensionId`, `compactExtensionId`, `presentationKind`, `library`, `inspectionEntrypoint`, `compactEntrypoint` |

Descriptor fields are nonblank strings, with extension, strategy, and tool
identities validated by their existing public types. Unknown roles and unsupported
fields are rejected, not ignored. The activity roles each describe both compact
and rich Inspection registrations. `library` and entrypoints identify executable
EVC ABI/preparation data; `hostAdapter` selects a native Session bridge adapter.
They are not profile state, configuration, permission grants, or executable
callbacks in the manifest. Profiles remain a separate, unimplemented policy for
which installed plugins participate in an activation context.

Artifacts must exist as regular files and remain confined to their installation
after filesystem resolution; absolute paths, traversal, and escaping symlinks are
rejected. Installation directories cannot themselves be symlinks. This is file
and descriptor validation, not executable EVC validation: the catalog does not
read or decode bytecode, resolve entrypoints, or validate a host adapter's runtime
compatibility. `PreparedFrontend.load` later retains immutable bytes once per
generation; decoding and entrypoint execution remain per-view. Readable corrupt
EVC therefore fails locally when presented, not during catalog discovery.
The manifest contains no capability or extension exposures, source paths, configuration,
credentials, profiles, or activation state.

Discovery sorts child paths deterministically and does not recurse or watch for
changes. An unconfigured, missing, or empty root is a successful empty catalog.
A malformed or unreadable installation envelope produces an installation-wide
catalog issue and excludes that installation. An invalid backend or frontend
instead produces a `PreparedPluginCatalogIssue` with typed `component`
(`PreparedPluginComponent.backend` or `.frontend`), omits only that component,
and retains the installation and any healthy sibling. An invalid descriptor
invalidates its frontend component, not just that descriptor. Installation-wide
issues have no component. Duplicate PluginIds exclude every conflict member,
including conflicts whose readable valid identity belongs to an otherwise invalid
manifest; identity is reserved before envelope/component validation, and neither
discovery order nor version chooses a winner. Root I/O failure propagates to generic
application bootstrap failure rather than becoming an empty catalog. Core
in-process functionality remains usable.

Discovery activates neither component. Normal application bootstrap separately
attempts all discovered valid components from this same snapshot; metadata-only
entries start nothing. This fixed startup policy does not put activation state in
the manifest or implement profiles. Installation and activation remain distinct
as accepted in ADR 0015. Backend-ready capability/extension advertisements, not
installed metadata, supply live registrations through host adapters; see
[`contracts-and-capabilities.md`](contracts-and-capabilities.md#backend-ready-advertisements).

## Package split

| Package | Responsibility | Rules |
| --- | --- | --- |
| Contract | Shared identities, payload schemas, typed async transport declarations, and immutable values as needed | Pure Dart; no Flutter; no provider algorithms or transport/generation implementation |
| Backend | Privileged/native Dart behavior | Depends on public contract/API packages as needed; never on frontend; compiled locally to AOT and hosted in an external isolate group |
| Frontend | Plugin UI source | Depends on public contract/API packages as needed; never on backend; may use Flutter; currently interpreted with pinned `flutter_eval`/`dart_eval` |

Typed frontend/backend service communication uses shared public contracts and
generated transport. Source imports do not cross between implementation packages,
and crossing a runtime boundary never shares object identity. A narrow frontend
presentation bridge need not expose backend services or implementation objects.

A plugin may expose a deliberately public lightweight extension interface through
its Contract surface when another plugin concretely needs to implement it. This
is shared interface ownership, not an additional classification/projection role
or permission to import the owning plugin's frontend/backend implementation.
General plugin-defined extension packaging is accepted direction but not yet
implemented as a manifest or lifecycle system.

See [`dependency-rules.md`](dependency-rules.md) and
[`plugin-extension-model.md`](plugin-extension-model.md).

### Stock Chat split

`plugins/chat_strategy` keeps the pure-Dart `chat_strategy_plugin` at its root for
in-process orchestration and retained canonical history. The separate Flutter
package `packages/frontend` (`chat_strategy_frontend`) owns the evaluated
history/composer. It depends on neither the headless implementation nor app/kernel
code. Its prepared installation is frontend-only; this split does not introduce
a Chat AOT backend or discover its in-process strategy activation.

The generic app host consumes public Flutter `adele_ui` Session presentation
contributions. Generic `ApplicationFrontendBootstrap` in `app/lib/frontend`
loads and registers the prepared descriptors. `app/lib/plugins/stock_chat_frontend.dart`
is only the bounded native adapter selected by `hostAdapter: 'stock-chat-controller-v1'`;
it validates the strategy and adapts the provisional app `ChatController`, but
does not load artifacts, register contributions, or own activation. This is not
a public universal Session-controller API or a PluginId switch. Chat state,
execution objects, and approval authority stay outside the evaluated package.
The narrow primitive bridge and
host-owned execution presentation are described in
[`overview.md`](overview.md#session-presentation).

### Stock AGENTS.md split

`plugins/agents_md` retains pure-Dart `agents_md_plugin` for root-file instruction
semantics and focused tests. Its `packages/backend` package, `agents_md_backend`,
reuses those semantics and implements generated orchestration source transport.
It uses public `adele_plugin_backend_support` and generated Environment authorized
reads, not internal host or Flutter imports. The app neither imports nor directly
depends on either AGENTS.md implementation package, and it does not statically
activate the plugin.

The backend-only installation is `agents-md/backend.aot`. Its ready
`extensionExposures`, not its installed manifest, declare the source at
`inferenceContextSources` with only `failureMode: 'required'` metadata. There is
no AGENTS.md frontend, configuration, startup argv, or extra deployment define.
Normal startup and explicit self-hosting use the same generic remote extension
adapter; self-hosting supplies its own `agentsMdArtifact` on its same shared host,
without requiring a normal installation root. See [the plugin README](../../plugins/agents_md/README.md).
Advertisement and operation-scoped host-call semantics are specified in
[`contracts-and-capabilities.md`](contracts-and-capabilities.md#extension-advertisements).

### Stock Search split

`plugins/search_tools` retains pure-Dart `search_tools_plugin` semantics; its
`packages/backend` package, `search_tools_backend`, reuses that implementation
through public generated model-tool and Environment read contracts plus
`adele_plugin_backend_support`. Its entrypoint is
`packages/backend/bin/search_tools_backend.dart`. Traversal, path validation,
exclusions, bounds, and result construction stay in the root implementation.
The app has no production Search dependency/import or static activation; the
root package remains a development-only app test dependency. Both packages are
workspace members and maintained analysis/test targets.

The backend-only installation is `search-tools/backend.aot`, with no frontend,
startup argv, Search configuration, or extra deployment define. Readiness advertises
one extension at `dev.adele.extension.model-tools`, using existing registration
`dev.adele.plugin.search-tools.model-tools`, `remoteModelToolServiceId`, the default
configuration context, and exactly `hostServices: ['authorizedEnvironmentRead']`.
There are no capability exposures. Its PluginId remains
`dev.adele.plugin.search-tools`; invocation authority comes from host-captured
Session bindings, not metadata or transported IDs. The Search descriptor requires
`executionHostServices: ['authorizedEnvironmentRead']`; materialization/validation
have no token, description uses pure identity data, and execution alone receives
read authority after policy/approval. Explicit self-hosting supplies
`searchToolsArtifact` on its same host through generic adapter activation, without
a normal installation root. See [remote model tools](contracts-and-capabilities.md#remote-model-tools).

### Stock Filesystem split

`plugins/filesystem_tools` retains pure-Dart `filesystem_tools_plugin` semantics;
its `packages/backend` package, `filesystem_tools_backend`, reuses the existing
read, ordered exact-unique patch, create-new, and conditional-delete tools through
public generated model-tool/Environment contracts and `adele_plugin_backend_support`.
The entrypoint is `packages/backend/bin/filesystem_tools_backend.dart`. The app has
no production Filesystem implementation dependency/import or static activation.
The semantic and backend packages belong to the workspace and maintained tooling
discovery; frontend implementation remains independent.

One `filesystem-tools` installation contains `backend.aot` and `frontend.evc` under
the existing `dev.adele.plugin.filesystem-tools` identity. Readiness advertises its
existing `dev.adele.plugin.filesystem-tools.model-tools` extension at
`dev.adele.extension.model-tools`, with generated service ID, default configuration
context, and `hostServices` containing `authorizedEnvironmentRead` and
`authorizedEnvironmentMutation`, not capability exposures. This is a maximum
dependency declaration; descriptor `executionHostServices` grants no ambient access
and defines the exact execution subset: read for `read_file`, read/mutation for
`apply_patch` and `delete_file`, mutation only for `create_file`.

Materialize/validation carry no token and description uses pure identity data.
Only execution after policy/approval receives host-service authority. The installed
frontend/backend have independent readiness and retirement. No configuration,
startup argv, or additional deployment define is required. Self-hosting supplies
explicit `filesystemToolsArtifact` on its same shared host via generic registration,
without normal installation discovery. See [remote model tools](contracts-and-capabilities.md#remote-model-tools).

### Stock Command split

`plugins/command_tools` retains pure-Dart `command_tools_plugin` semantics; its
`packages/backend` package, `command_tools_backend`, reuses validation, effect
description, progress projection, and bounded terminal output through public
generated model-tool/Environment contracts and `adele_plugin_backend_support`.
The entrypoint is `packages/backend/bin/command_tools_backend.dart`. The app has
no production Command implementation dependency/import, static activation, or
in-process fallback. The semantic and backend packages are workspace members and
maintained analysis/test targets; the frontend is independent.

One `command-tools` installation contains `backend.aot` and `frontend.evc` under
the existing `dev.adele.plugin.command-tools` identity. Its sole ready extension
uses `dev.adele.extension.model-tools`, registration
`dev.adele.plugin.command-tools.model-tools`, generated service `modelTool`,
configuration context `default`, and exactly
`hostServices: ['authorizedEnvironmentProcess']`. It advertises no capabilities.
The `run_command` descriptor likewise requires process-only `executionHostServices`.
Materialize/validation have no token; description uses pure identity data. Only
execution after policy/approval receives authority for reverse process streaming.

Backend/frontend readiness and retirement are independent. No Command-specific
configuration, startup argv, or additional deployment define is required.
Self-hosting supplies `commandToolsArtifact` on its same host; its
`includeCommandTools` controls explicit backend start/registration, not
`AdeleRuntime` construction. See [remote model tools](contracts-and-capabilities.md#remote-model-tools).

### Stock tool frontend split

`plugins/filesystem_tools` and `plugins/command_tools` retain their pure-Dart
headless packages at the plugin root. Each has a separate Flutter
`packages/frontend`: `filesystem_tools_frontend` owns interpreted `apply_patch`
Inspection and `command_tools_frontend` owns interpreted `run_command` Inspection.
These frontends depend only on Flutter and public `adele_ui`, not their headless
implementations, app, or kernel. They are root workspace members and maintained
Flutter analysis targets, separate from backend execution.

Command Tools and Filesystem Tools each have one combined backend/frontend
installation with independent component availability. Their frontends use `toolActivity` descriptors supplying
tool identity, registration IDs, library, and both entrypoints. Stock build-side
descriptors have one source of truth in `tools/stock_frontend_descriptors.dart`;
app runtime activation has no stock tool identity table. The generic Inspection
host matches exact `ToolId` through `adele_ui`, owns group framing/order, and knows
no plugin-specific fields. The interpreted widgets own field interpretation over a read-only
structured snapshot bridge. All stock frontends reuse `PreparedFrontend`;
there is no parallel tool-specific runtime/activation framework.

### OpenAI Contract/Backend/Frontend split

The OpenAI plugin follows the canonical three roles. Native classification and
safe display projection belong to Backend, not an additional plugin component:

```text
plugins/openai/packages/
|-- contract/         # openai_contract, pure-Dart identities and payload schema
|-- backend/          # openai_model_provider_backend, raw interpretation and AOT
`-- frontend/         # openai_frontend, interpreted Flutter Inspection
```

`openai_contract` owns shared identities and payload schema only. Raw Responses
identity remains `openAiResponsesItemKind = 'openai.responses.item.v1'` with
`openAiResponsesItemVersion = 1`; safe reasoning-summary presentation has the
distinct kind `openai.responses.reasoning-summary.v1`, version 1. Contract contains
no parsing, classification, projection, truncation, or display-safety algorithms.
It does not depend on Flutter, Backend, Frontend, app, or kernel.

Backend owns raw Responses reasoning-summary classification, bounded compact/full
projection, and exact native preservation. It sends optional safe presentation
through the generated common ModelProvider DTO, separately from raw
`nativeMetadata`, the only native replay source. Frontend renders the safe payload;
neither implementation depends on the other. The generic app adapter maps the
presentation to immutable orchestration data without knowing OpenAI fields.

`openai_frontend` supplies `lib/openai_frontend.dart` entrypoint
`buildOpenAiReasoningInspection`, using public `adele_ui` rather than backend
implementation. Its EVC receives only the recursively immutable safe
`summaryParts`/`truncated` map, never the raw envelope, compatibility metadata,
encrypted content, or execution/approval authority. Exact native/encrypted replay
remains untouched in the backend and full Run evidence.

One OpenAI installation contains both `backend.aot` and `frontend.evc`. Its
`modelNativeActivity` descriptor supplies the safe presentation kind and compact/rich
entrypoints to generic `ApplicationFrontendBootstrap`, which owns loading,
registration, and exact retirement through existing `PreparedFrontend` and registry
liveness. There is no stock OpenAI frontend activator or runtime identity switch.
Frontend availability does not depend on backend readiness or credentials. Generic
Chat uses `ModelNativeOutput.presentation != null` independently of frontend activation.
Inspection resolves the exact safe presentation kind through `adele_ui`. Missing
or failed rich presentation leaves safe activity intact without disabling backend
execution or substituting a native card. The `app/tool` compile harness remains a
checkout stand-in for installation/update-time preparation, not runtime activation.

## Distinct identities

The following are independent concepts and must not be inferred from one
another:

| Identity or state | Example or meaning |
| --- | --- |
| Plugin ID | Stable globally namespaced identity such as `dev.adele.workspace-demo` |
| Display name | Human-readable `Workspace Demo` |
| Plugin version | Source/plugin release string such as `0.1.0` |
| Repository name | Checkout/catalog naming |
| Dart package name | `workspace_demo_contract`, `workspace_demo_backend`, or `workspace_demo_frontend` |
| Runtime build identity | Exact source + build/toolchain context used for an artifact |
| Installation | Source/compiled artifacts available to one ADELE installation |
| Profile activation | Whether an installed plugin participates in a context |
| Plugin runtime instance | Running plugin created for an activation context |
| Frontend activation generation | Exact active prepared frontend and its registrations, not a canonical Session identity |
| Presentation instance | One view's widget/resources, distinct from the frontend generation that supplied it |
| Configured capability instance | Persistent named provider/account/connection managed by a runtime |
| Project/Task/Session/Environment | Core product identities associated with plugin behavior, not plugin/package identity |
| Runtime resource | Temporary document, terminal, browser session, process, or similar handle |

The draft source/build manifest starts with independent plugin metadata:

```yaml
manifestVersion: 1
id: dev.adele.workspace-demo
version: 0.1.0
displayName: Workspace Demo
```

It must not embed current activation state, an active profile, or a claim that
the plugin is loaded. Installation does not imply activation.

## Runtime mapping

The intended default is one plugin runtime instance per activation context;
activation-context lifecycle is not implemented. The maintained runtime proves
that one plugin generation may expose several configured capability instances,
such as API-key and experimental ChatGPT providers, without additional
installations or backend copies.

This default is not a permanent prohibition on multiple runtimes; additional
isolation/concurrency models remain deferred.

Temporary runtime resources are created/disposed during operation. They are not
plugin instances and are not persistent provider configurations.

Session, tool Inspection, and model-native presentation retain exact extension
bindings. Retirement removes old widgets and their resources; only fresh
resolution may select a replacement.
Missing or failed presentation does not invalidate the Session or headless/backend
execution. Eval runtime allocation is an implementation detail of the pinned
stack, not a permanent one-runtime-per-presentation contract.

Future active plugins may register several independent semantic extensions from
one runtime—for example Git may provide Environment behavior, review/SCM
services, Commands, summary contributions, and model tools. Registration into
multiple extension points does not imply multiple plugin runtimes.

## Normal prepared composition

Synchronous, provider-free `AdeleRuntime()` owns two in-process stock activations
(Chat and Local Directory Project
Selector) and generic `ApplicationPluginBootstrap` on its existing capability and
extension registries. `AdeleApplication` explicitly calls `ApplicationPluginBootstrap.start`
with only an installation root, shared runtime/host paths, and optional generic
startup arguments. Discovery precedes host startup. If there are no valid backend
components, startup succeeds without a child process, even with unusable host paths.

The backend bootstrap publishes its catalog snapshot before backend startup.
Window-owned Flutter `ApplicationFrontendBootstrap` consumes that notification
and the existing `ExtensionRegistry`; it does not discover a second root/catalog,
create another registry, or add a parallel frontend runtime. Each frontend loads
one prepared generation for its descriptors. Registration failure rolls back that
attempt's exact registrations and invalidates its generation without affecting
healthy frontends or backends. Role retirement closes captured exact registrations
without retiring siblings or replacements. Generation close settles pending loads,
retires its registrations, and invalidates view resources; late loads cannot attach
to a closed owner. Decoding remains per-view, so a corrupt artifact or failed
entrypoint does not fail a Run or retire another frontend component.

When backend components exist, one shared host independently attempts them, with no
required Git or additional-OpenAI tier. A backend start, advertisement, or
registration failure cleans up only that attempt's partial resources; later
termination retires only its exact generation. Shared-host failure is global.
All backend registrations retire before backend generations close, then the host
closes, then the runtime's in-process activations retire. Read-only backend states and catalog
issues are available without a plugin-management UI.

Git/OpenAI entrypoints own capability advertisements; AGENTS.md, Search,
Filesystem, and Command own their extension advertisements. `PluginBackendActivation.registerAdvertised` owns both
capability and adapted extension registration with coherent rollback/retirement
through the existing registries. Self-hosting uses the same generic remote extension
activation but retains its explicit artifact/host/profile topology without normal discovery.

`prepareDesktopPluginDefines` in `tools/backend_artifacts.dart` selects and compiles
stock Git/OpenAI/AGENTS.md/Search/Filesystem/Command source plus the shared host and invokes
`tools/frontend_artifacts.dart` for four EVCs. In total, preparation produces six
backend snapshots, one host snapshot, and four frontend artifacts. It assembles
seven installation directories under one fresh
`.dart_tool/adele/desktop-plugins/build-*/installations/`: frontend-only
`chat-strategy`, backend-only `git-environment`, `agents-md`, and
`search-tools`, and combined `filesystem-tools`, `command-tools`, and `openai`.
The singular build-side presentation table is `tools/stock_frontend_descriptors.dart`.
Its separate startup-arguments JSON
maps PluginId to a string argv list; normal OpenAI always receives `--chatgpt-only`,
with a second JSON argument only when configured. That argument references the
credential store and public OAuth/endpoint options, never tokens. Unconfigured
ChatGPT-only mode advertises zero capabilities rather than inheriting an API key.
Normal bootstrap also sets `startupArgumentsOnly: true` for every backend,
independently of that map. OpenAI honors the forwarded flag with no environment
fallback and zero exposures for empty argv or an absent configuration document,
so root-only activation has the same protection. Direct/self-hosting callers keep
the default `false` and their existing environment-based configuration path.
The flag is temporary deployment metadata, not manifest configuration or general
settings/profile/credential infrastructure; generic code has no PluginId switch.
`app/lib/plugins/temporary_chatgpt_selection.dart` retains provisional provider
identity and model-only configuration, always supplying a default or override
without a credential-presence gate. Availability comes from the active registry;
the app inspects no startup OAuth/credential configuration and owns neither
backend exposure metadata nor configuration argv construction.
This seam is intended to disappear with general plugin configuration/profiles,
not to become their schema.

Deployment and build details are maintained in
[`app/README.md`](../../app/README.md#normal-backend-startup) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).
Checkout paths are not portable/production packaging, an installer, or a cache.

Normal Chat, Filesystem Tools, Command Tools, and OpenAI activity frontend
activations independently consume catalog-discovered EVCs, not per-stock artifact
fields or deployment defines. Flutter build-time tooling prepares all four before
app launch/build, outside the normal runtime import graph. Tool Inspection retains
the same view/runtime across coalesced snapshot updates rather than reloading
bytecode for lifecycle changes. A missing, corrupt, or retired frontend does not
retire backend support or trigger source compilation or a native presentation
fallback. The SDK/eval pin remains bounded interoperability infrastructure;
broad third-party interpreted UI support still requires eval modernization.

## Proven and deferred

The `workspace_demo` fixture proves local AOT compilation, shared process-hosted
loading, typed async communication, interpreted rendering, interaction, and
rebuild/reload on Linux x64 Flutter profile mode. Windows, macOS, release mode,
packaging, activation contexts, and broad plugin APIs remain unproven.

The prepared startup catalog supports independently optional frontends and
metadata-driven presentation registration, alongside backend capability/extension
activation, operation-scoped unary host reads/mutations for AGENTS.md, Search,
and Filesystem Tools, and reverse server-streaming processes for Command Tools.
Two stock activations remain static and outside installed discovery; Chat and
selector migration is deferred. Host and backend artifacts require matching
protocol version 1 and rebuilding as a coherent set; installed manifests remain
version 1. See the
[pre-release transport policy](contracts-and-capabilities.md#transport-version-policy).
Enable/disable management, profiles, version solving, filesystem watching,
client/bidirectional streaming, ambient callbacks, general symmetric RPC, and hot
upgrade remain deferred.

Maintained plugin backends additionally prove generated server streaming,
multiple generation-bound configuration contexts, real HTTP/SSE model-provider
integration, Git Environment establishment/restoration, and bounded
Session-authorized Environment reads composed by stock Filesystem and Search
tool plugins.

These proofs do **not** implement the accepted general recursive extension
system, complete Project/Task/Session/Environment product lifecycle, broader
workbench UI composition, plugin-defined extension API packaging/versioning, or
sandboxing.

Plugin-specific typed vertical tests belong to the plugin backend package that
owns the implementation and contract. The shared backend host package tests
only generic framing/lifecycle behavior and does not take development
dependencies on fixture contracts or plugin APIs solely for a plugin test.
