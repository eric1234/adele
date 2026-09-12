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
`adele_orchestration` implements strategy registration/execution and instruction
context composition, sharing semantic values with the internal kernel without
depending on it. B1 adds tiny pure-Dart `adele_core_extensions` for the concrete
Project selector contract, depending only on `adele_plugin_api`. Plugin-defined
extension API packages and broader plugin-facing UI APIs remain architectural
direction.

## Package boundaries

| Package | Surface | Allowed dependencies | Prohibited dependencies |
| --- | --- | --- | --- |
| `adele_contract` | Experimental plugin-facing | Dart SDK; other lightweight public packages only if a concrete need emerges | Flutter, internal host packages, application code, analyzer/compiler internals, `build_runner` |
| `adele_capabilities` | Experimental plugin-facing | Dart SDK and lightweight public contract types when required | Flutter, internal host packages, application code |
| `adele_plugin_api` | Experimental plugin-facing | Dart SDK and lightweight public packages when required | Flutter unless a future UI API explicitly establishes a boundary; internal host packages; application code |
| `adele_core_extensions` | Experimental plugin-facing, pure Dart; narrow core-owned extension contracts | Dart SDK and `adele_plugin_api` | Flutter, internal host packages, application code, concrete plugins |
| `adele_model_provider` | Experimental plugin-facing | Dart SDK, `adele_contract`, and `adele_capabilities` | Flutter, internal host packages, application code, concrete providers |
| `adele_product` | Experimental plugin-facing, pure Dart | Dart SDK and `adele_capabilities` | Flutter, internal host packages, application code, `adele_orchestration`, `adele_plugin_api`, `adele_core_extensions` |
| `adele_model_tool` | Experimental plugin-facing, pure Dart | Dart SDK, `adele_plugin_api`, and `adele_product` | Flutter, internal host packages, application code, concrete tools |
| `adele_orchestration` | Experimental plugin-facing, pure Dart | Dart SDK, `adele_product`, `adele_plugin_api`, and `adele_model_tool` | Flutter, `agent_kernel`, other internal host packages, application code, concrete strategies or sources |
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
- Strategy contracts, execution, and inference-context composition belong to `adele_orchestration`.
- Model-tool contracts belong to `adele_model_tool`.
- Environment provider contracts belong to `adele_environment`.
- Plugin-defined ecosystems keep their contracts with their deliberately public plugin/component API owners.

### Application backend composition

`AdeleRuntime()` synchronously registers six in-process stock contributions and
remains provider-free. It owns pure-Dart `ApplicationPluginBootstrap` on the same
`CapabilityRegistry` used by lifecycle, not a second provider registry. Normal
`AdeleApplication` explicitly invokes async stock bootstrap. The generic owner
uses `plugin_runtime` to own one backend host and callback-created activations;
stock selection belongs to `app/lib/plugins/stock_backend_plugins.dart`, not
generic runtime infrastructure.

`app/lib/plugins/stock_git_environment.dart` owns the normal/self-hosting stock
Git identities, display/service exposure, and configuration-context registration.
It depends on public Environment contracts and host activation APIs, never Git
backend implementation code. Generic Task presentation submits `projectId` and
`title` without a provider ID and never parses opaque `providerState`; lifecycle
keeps existing rank/identity default resolution and providers own source validation.

Normal bootstrap consumes prepared runtime/host/Git artifact locations through
three compile-time defines documented in [`app/README.md`](../../app/README.md#b2-backend-startup).
Source-checkout paths, compiler selection, and fresh AOT preparation belong to
repository tooling and `plugin_builder.compileAotSnapshot`, not the normal app
startup import graph. Self-hosting shares stock exposure metadata but retains its
independent artifact/host topology and does not consume normal configuration.
These boundaries add no public API package, profile system, plugin discovery, or
production packaging mechanism.

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

The backend and frontend depend on shared contract/API packages as needed. They do not depend on one another. Transport contracts do not depend on Flutter. A frontend may depend on Flutter and future plugin-facing UI APIs. A backend may use full Dart capabilities in later phases, subject to the eventual runtime and security model.

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
