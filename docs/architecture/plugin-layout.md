# Source Plugin Layout

## Canonical form

Plugin source is the canonical distribution format. The development build
pipeline derives prepared frontend eval bytecode and native Dart AOT backend
artifacts from the source components a plugin supplies. A plugin need not supply
both a frontend and an AOT backend. Normal runtime activation consumes prepared
artifacts and never compiles source; future installation/update should own that
preparation. Current checkout tooling is a stand-in, not plugin installation or
artifact caching.

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
draft ADELE manifest.

For development builds, `packages.contract` selects the plugin's transport
contract package. The builder reads its Dart package name from `pubspec.yaml`,
derives `lib/<package-name>.dart`, resolves that source to an absolute path, and
runs `contract_codegen --check --source <path>` after validating Dart but before
backend compilation. Repository-wide generator configuration is not used to
choose a requested plugin's contract.

## Package split

| Package | Responsibility | Rules |
| --- | --- | --- |
| Contract | Shared typed async transport declarations and immutable values | Pure Dart; no Flutter; no transport/generation implementation |
| Backend | Privileged/native Dart behavior | Depends on public contract/API packages as needed; never on frontend; compiled locally to AOT and hosted in an external isolate group |
| Frontend | Plugin UI source | Depends on public contract/API packages as needed; never on backend; may use Flutter; currently interpreted with pinned `flutter_eval`/`dart_eval` |

Typed frontend/backend service communication uses shared public contracts and
generated transport. Source imports do not cross between implementation packages,
and crossing a runtime boundary never shares object identity. A narrow frontend
presentation bridge need not expose backend services or implementation objects.

A plugin may also publish a deliberately public lightweight API package for an
extension point it owns when another plugin concretely needs to implement that
interface. That API package is interface surface, not permission to import the
owning plugin's frontend/backend implementation. General plugin-defined
extension packaging is accepted direction but not yet implemented as a manifest
or lifecycle system.

See [`dependency-rules.md`](dependency-rules.md) and
[`plugin-extension-model.md`](plugin-extension-model.md).

### Stock Chat split

`plugins/chat_strategy` keeps the pure-Dart `chat_strategy_plugin` at its root for
in-process orchestration and retained canonical history. The separate Flutter
package `packages/frontend` (`chat_strategy_frontend`) owns the evaluated
history/composer. It depends on neither the headless implementation nor app/kernel
code; this split does not introduce a Chat AOT backend or a general manifest
installation model.

The generic app host consumes public Flutter `adele_ui` Session presentation
contributions. `app/lib/plugins/stock_chat_frontend.dart` supplies the provisional
stock activation proxy/controller adapter; `app/lib/frontend` owns only generic
prepared-generation/runtime hosting. Chat state, execution objects, and approval
authority stay outside the evaluated package. The narrow primitive bridge and
host-owned execution presentation are described in
[`overview.md`](overview.md#session-presentation).

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

The draft manifest starts with independent plugin metadata:

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

Session presentation retains exact extension bindings. Retirement removes old
widgets and their resources; only fresh resolution may select a replacement.
Missing or failed presentation does not invalidate the Session or headless/backend
execution. Eval runtime allocation is an implementation detail of the pinned
stack, not a permanent one-runtime-per-presentation contract.

Future active plugins may register several independent semantic extensions from
one runtime—for example Git may provide Environment behavior, review/SCM
services, Commands, summary contributions, and model tools. Registration into
multiple extension points does not imply multiple plugin runtimes.

## Normal stock artifact composition

Normal composition uses existing backend-only Git and OpenAI plugins without linking
their implementations into Flutter. Synchronous, provider-free `AdeleRuntime()` owns
in-process stock registrations and generic `ApplicationPluginBootstrap` on its
existing capability registry. `AdeleApplication` explicitly invokes async stock
composition, supplying activation callbacks to that application-lifetime owner
of one shared backend host. Git is required startup; OpenAI is an additional
independently failing activation exposing only experimental ChatGPT in normal use.

`app/lib/plugins/stock_git_environment.dart` centralizes stock Git plugin/provider
IDs, display name, capability/service exposure, and default configuration-context
registration for normal and self-hosting paths. It loads an artifact using host
APIs and public Environment contracts, not backend implementation imports.
Self-hosting retains its separate larger artifact/host topology.

`app/lib/plugins/stock_openai.dart` owns analogous ChatGPT identity/exposure and
plugin-local startup arguments. They contain a credential-store path and public
OAuth configuration, not tokens. API-key and ChatGPT contexts can coexist for other
consumers, but neither context requires a dummy configuration for the other.

The app consumes prepared artifacts; source discovery and compilation belong to
tooling. Missing required host/Git configuration or failed required startup leaves
Task support unavailable without blocking Project opening and cleans up acquired
resources. Optional OpenAI activation failure affects only model availability.
Deployment and build details are maintained in
[`app/README.md`](../../app/README.md#normal-backend-startup) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).
This is not plugin installation, production packaging, discovery, or profiles.

Normal Chat activation separately consumes prepared EVC. Flutter build-time
tooling prepares it before app launch/build, outside the normal runtime import
graph. A missing or failed frontend does not retire backend support or trigger
source compilation or a native Chat fallback. The SDK/eval pin remains bounded
interoperability infrastructure; broad third-party interpreted UI support still
requires eval modernization.

## Proven and deferred

The `workspace_demo` fixture proves local AOT compilation, shared process-hosted
loading, typed async communication, interpreted rendering, interaction, and
rebuild/reload on Linux x64 Flutter profile mode. Windows, macOS, release mode,
packaging, discovery, activation contexts, and broad plugin APIs remain
unproven.

Maintained backend-only plugins additionally prove generated server streaming,
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
