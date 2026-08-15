# Dependency Rules

## Layers

```text
public contracts and plugin-facing APIs
  adele_plugin_api
  adele_contract
  adele_capabilities
  adele_model_provider
            ^
internal host implementations
  plugin_runtime
  plugin_builder
  agent_kernel
            ^
desktop composition root
  adele_desktop
```

Arrows point toward dependencies. Dependencies flow toward public contracts
and APIs; public packages never depend on internal host packages or the
desktop application. All packages are initially private to the repository via
`publish_to: none`, even when described as public or plugin-facing.

## Package boundaries

| Package | Surface | Allowed dependencies | Prohibited dependencies |
| --- | --- | --- | --- |
| `adele_contract` | Experimental plugin-facing | Dart SDK; other lightweight public packages only if a concrete need emerges | Flutter, internal host packages, application code, analyzer/compiler internals, `build_runner` |
| `adele_capabilities` | Experimental plugin-facing | Dart SDK and lightweight public contract types when required | Flutter, internal host packages, application code |
| `adele_plugin_api` | Experimental plugin-facing | Dart SDK and lightweight public packages when required | Flutter unless a future UI API explicitly establishes a boundary; internal host packages; application code |
| `adele_model_provider` | Experimental plugin-facing | Dart SDK, `adele_contract`, and `adele_capabilities` | Flutter, internal host packages, application code, concrete providers |
| `plugin_runtime` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, plugin implementations |
| `plugin_builder` | Internal, pure Dart | Dart SDK, public packages, and build dependencies selected when implementation begins | Flutter UI, application code, plugin implementations as linked host dependencies |
| `agent_kernel` | Internal, pure Dart | Dart SDK, public packages, and concrete acyclic internal dependencies | Flutter, application code, concrete providers, tools, editors, workflows, or plugin implementations |
| `adele_desktop` | Private Flutter application | Flutter and any host package needed for composition | Definitions intended as public plugin APIs; plugin implementation logic |

An allowed dependency is not a requirement. New edges must have an immediate,
concrete use, remain acyclic, and preserve pure-Dart testability where Flutter
is unnecessary.

Contract declarations and contract generation are separate concerns.
`adele_contract` stays lightweight; generation belongs in a future internal
package such as `contract_codegen`, created only when implementation starts.

## Plugin dependencies

A plugin may depend on these public surfaces as needed:

```text
adele_plugin_api
adele_contract
adele_capabilities
adele_model_provider
future plugin-facing UI APIs
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
          plugin contract (pure Dart)
             ^              ^
             |              |
         backend         frontend
```

The backend and frontend depend on the shared contract as needed. They do not
depend on one another. The contract does not depend on Flutter. A frontend may
depend on Flutter and future plugin-facing UI APIs. A backend may use full Dart
capabilities in later phases, subject to the eventual runtime and security
model.

Plugin tests may use internal host packages as development-only dependencies to
exercise integration boundaries. Those dependencies must remain under
`dev_dependencies` and must not be imported by plugin production libraries or
entrypoints. The `workspace_demo_backend` host integration test uses
`plugin_runtime` on this basis; the backend's production dependency graph does
not include it.

Plugins communicate through public contracts and capability discovery, never
by importing another plugin's frontend, backend, or other implementation
package.

## Repository rules

- Keep the application as the composition root.
- Keep internal core packages pure Dart unless Flutter is intrinsically required.
- Avoid dependency cycles at every layer.
- Do not create packages solely for hypothetical reuse.
- Require a concrete responsibility and dependency boundary for every new package.
- Keep public surfaces small and experimental through the proof-of-concept stages.
- Do not introduce a profile package, provider-instance package, or separate application UI package in Phase 0.
