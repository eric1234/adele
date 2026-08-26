# Dependency Rules

## Layers

```text
public contracts and plugin-facing APIs
  adele_plugin_api
  adele_contract
  adele_capabilities
  adele_model_provider
  future core extension/UI APIs
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

The maintained code currently implements only part of this picture. Plugin-defined extension API packages and general plugin-facing UI/extension APIs remain architectural direction rather than a proven package structure.

## Package boundaries

| Package | Surface | Allowed dependencies | Prohibited dependencies |
| --- | --- | --- | --- |
| `adele_contract` | Experimental plugin-facing | Dart SDK; other lightweight public packages only if a concrete need emerges | Flutter, internal host packages, application code, analyzer/compiler internals, `build_runner` |
| `adele_capabilities` | Experimental plugin-facing | Dart SDK and lightweight public contract types when required | Flutter, internal host packages, application code |
| `adele_plugin_api` | Experimental plugin-facing | Dart SDK and lightweight public packages when required | Flutter unless a future UI API explicitly establishes a boundary; internal host packages; application code |
| `adele_model_provider` | Experimental plugin-facing | Dart SDK, `adele_contract`, and `adele_capabilities` | Flutter, internal host packages, application code, concrete providers |
| future core extension/UI APIs | Experimental plugin-facing | Only lightweight public dependencies required by concrete interfaces | Internal host packages, application code, concrete plugins |
| plugin-defined public extension API | Experimental plugin-facing | Public/core APIs and other deliberately public interface packages needed by the concept | Another plugin's implementation packages, internal host packages, application code |
| `plugin_runtime` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, plugin implementations |
| `plugin_builder` | Internal, pure Dart | Dart SDK, public packages, and build dependencies required by the implemented pipeline | Flutter UI, application code, plugin implementations as linked host dependencies |
| `agent_kernel` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, concrete providers, tools, editors, workflows, or plugin implementations |
| `adele_desktop` | Private Flutter application | Flutter and any host package needed for composition | Definitions intended as public plugin APIs; plugin implementation logic |

An allowed dependency is not a requirement. New edges must have an immediate, concrete use, remain acyclic, and preserve pure-Dart testability where Flutter is unnecessary.

Contract declarations and contract generation are separate concerns. `adele_contract` stays lightweight; generation belongs to the internal `contract_codegen` package and does not add analyzer/compiler dependencies to the public contract package.

## Plugin dependencies

A plugin may depend on public surfaces as needed:

```text
adele_plugin_api
adele_contract
adele_capabilities
adele_model_provider
future core plugin-facing extension/UI APIs
public extension API packages defined by other plugins/components
```

A plugin must not depend on host implementations or application code:

```text
plugin_runtime
plugin_builder
agent_kernel
adele_desktop
```

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
```

At runtime, compatible registrations are discovered dynamically. If no implementation is active, the relevant affordance or integration is unavailable; ADELE should not silently enable another plugin merely to satisfy it.

A plugin-defined extension API must be deliberately public. Plugins must not import another plugin's frontend, backend, private library, or other implementation package merely because the code is accessible in the repository.

This enables recursive plugin-defined extension ecosystems while avoiding a complex implementation-level dependency/activation graph.

## Repository rules

- Keep the application as the composition root.
- Keep internal core packages pure Dart unless Flutter is intrinsically required.
- Avoid dependency cycles at every layer.
- Prefer typed runtime discovery over dependencies on implementation identities.
- Do not create packages solely for hypothetical reuse.
- Require a concrete responsibility and dependency boundary for every new package.
- Keep public surfaces small and experimental through the proof-of-concept stages.
- Do not create a plugin-defined API package until at least one concrete interface needs to be shared.
- Do not introduce a profile package, provider-instance package, separate application UI package, or generic extension package without a concrete implemented need.
