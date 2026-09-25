# Dependency Rules

Role: Canonical architecture

Check these rules before adding dependencies, importing another subsystem,
creating a public API package, or wiring plugin/application composition.
`pubspec.yaml` files and source imports define the actual present graph; this
document defines ownership and architectural prohibitions, not an exhaustive
allowlist. An existing edge does not waive a boundary violation.

## Dependency direction

```text
public/plugin-facing APIs
            ^
internal host/build implementations
            ^
desktop composition root
```

Arrows point **from a consumer toward its dependency**, not toward callers.
Dependencies point toward public semantic contracts and away from concrete
composition/implementation owners:

```text
plugin implementation         -> public/plugin-facing APIs
internal host implementation  -> public/plugin-facing APIs
desktop app                   -> public APIs + internal host implementations

public/plugin-facing API      -X-> internal host implementation
public/plugin-facing API      -X-> desktop app
public/plugin-facing API      -X-> concrete plugin implementation
```

These are layer constraints, not permission for arbitrary same-layer dependencies.
Every edge needs a concrete semantic use and must remain acyclic. Apply the rules
to production imports/exports and their dependency graph, not just manifest labels.
Workspace membership is not a production dependency. "Public/plugin-facing"
describes intended consumers, not publication or stability: the current packages
use `publish_to: none`, and public APIs remain experimental.

## Critical package boundaries

All public rows obey the layer prohibitions above. Package names link to their
manifests for exact current dependencies, including development-only dependencies.

| Package | Responsibility / layer | Critical boundary |
| --- | --- | --- |
| [`adele_plugin_api`](../../packages/plugin_api/pubspec.yaml) | Public: generic plugin identity, extension registration, and binding liveness | No Flutter, host implementations, app, or concrete plugins. |
| [`adele_core_extensions`](../../packages/core_extensions/pubspec.yaml) | Public: core-owned extension contracts without another domain owner | Not a catch-all for public APIs; no Flutter or implementation dependencies. |
| [`adele_contract`](../../packages/contract/pubspec.yaml) | Public: declarations, channels, and exposure values | No Flutter, analyzer/compiler, generation tooling, or host/runtime implementation dependencies. |
| [`adele_plugin_backend_support`](../../packages/plugin_backend_support/pubspec.yaml) | Public: generic plugin-side host-call channels | No Flutter, host internals, or domain-specific orchestration semantics. |
| [`adele_capabilities`](../../packages/capabilities/pubspec.yaml) | Public: capability/provider identities and routing | No Flutter, host implementations, app, or concrete providers. |
| [`adele_model_provider`](../../packages/model_provider/pubspec.yaml) | Public: provider-neutral model-provider contract | No Flutter, host implementations, app, or concrete providers. |
| [`adele_product`](../../packages/product/pubspec.yaml) | Public: product identities and immutable values | No executable orchestration, extension registration, UI, host, or plugin implementation concerns. |
| [`adele_project_storage`](../../packages/project_storage/pubspec.yaml) | Public: Session-scoped relational storage contract shared by host and plugins | Pure Dart; no SQLite, Flutter, app, host implementation, or concrete plugin dependencies. |
| [`adele_model_tool`](../../packages/model_tool/pubspec.yaml) | Public: model-tool semantics and transport | No Flutter, host implementations, app, or concrete tools. |
| [`adele_orchestration`](../../packages/orchestration/pubspec.yaml) | Public: strategy/execution semantics and transport | No `agent_kernel`, other host implementations, Flutter, app, or concrete strategies. |
| [`adele_environment`](../../packages/environment/pubspec.yaml) | Public: Environment provider and authorized-facet contracts | No Flutter, host implementations, app, or concrete providers. |
| [`adele_ui`](../../packages/ui/pubspec.yaml) | Public: Flutter presentation and bridge contracts | No internal host, app, or concrete plugin dependencies; app-native bridge implementations stay in the app. |
| [`agent_kernel`](../../packages/agent_kernel/pubspec.yaml) | Internal: generic execution mechanics | No Flutter, app, concrete strategies, providers, tools, or other plugin implementations. |
| [`plugin_runtime`](../../packages/plugin_runtime/pubspec.yaml) | Internal: backend/runtime hosting and routing | No Flutter, app, or plugin implementations. |
| [`plugin_backend_host`](../../packages/plugin_backend_host/pubspec.yaml) | Internal: shared AOT backend host | No Flutter, app, or plugin implementations. |
| [`plugin_builder`](../../packages/plugin_builder/pubspec.yaml) / [`contract_codegen`](../../packages/contract_codegen/pubspec.yaml) | Internal: source preparation / contract generation | Build-only, not plugin runtime APIs; no linked plugin implementations or Flutter UI dependencies. |
| [`adele_desktop`](../../app/pubspec.yaml) | Private: Flutter desktop composition root | No production dependency on any package under `plugins/**`, including contracts; not a public plugin-API owner. |

Contract declarations and generation remain separate: compiler/analyzer tooling
belongs to `contract_codegen`, not `adele_contract` or its runtime consumers.
Build tooling may read and compile plugin source without linking plugin
implementations into the normal application runtime.

### Special ownership rules

- **`adele_core_extensions`** owns only core-owned extension contracts with no
  natural existing public domain owner. Project selection and provider backing
  preparation are narrow examples, not a template for moving all extension points
  here. These pure-Dart contracts use public capability/transport APIs, not SQLite
  or filesystem hosting. New APIs normally belong with their product,
  orchestration, tool, Environment, UI, or plugin-domain owner.
- **`adele_product`** remains independent of executable strategy/runtime/UI layers
  and extension registration. Its `adele_capabilities` dependency supplies generic
  `ProviderId` values; the transitive `adele_plugin_api` dependency does not mean
  product owns or consumes extension infrastructure. Do not couple product values
  to orchestration implementations or plugin-specific schemas.
- **`adele_project_storage`** owns the genuinely shared host/plugin service, not
  immutable product values, a Run operation, generic transport/channel plumbing,
  provider-selection extensions, or concrete Chat behavior. Those existing owners
  are therefore not appropriate homes. `adele_contract` supplies its declarations
  and generated transport; SQL/schema semantics stay with each plugin. The separate
  package is justified by this present cross-layer use, not hypothetical reuse.
- **`adele_ui`** owns public semantic presentation contracts that genuinely need
  Flutter. Do not add Flutter to product, orchestration, or tool packages for
  presentation convenience. App-native bridge implementations and hosting belong
  in the composition root, not public semantic packages.

## Application composition

**Production `app/lib/**` must not import or depend on packages under `plugins/**`,
including plugin contracts.** Production `dependencies` in `app/pubspec.yaml`
must preserve that boundary.

The app is the generic composition root. It may depend on public ADELE APIs,
internal host packages, and generic host/native third-party libraries required
for bridges and composition. It must not become the implementation owner of
concrete plugin behavior or define public plugin contracts in application code.

The private Project database and its `sqlite3` dependency belong in `app`, not
`adele_product`, `adele_project_storage`, `adele_core_extensions`, or a plugin
backend. The provider describes source-relative placement through public values;
the host owns filesystem confinement, schema coordination, one connection per
Project, and canonical publication. `ProjectStorageHost` implements the public
contract without making application code a public API owner.

`AdeleRuntime` constructs lifecycle before backend bootstrap and supplies the
generic `projectStorageServices(lifecycle, connection)` factory for every normal
connection. Transport/runtime packages know only explicit infrastructure
dispatchers and exact-generation access, not Chat or application database semantics.
Production composition imports no stock implementation or plugin contract and
does not special-case a plugin ID to grant storage. See
[infrastructure access](contracts-and-capabilities.md#generation-scoped-infrastructure-access).

Tests, development tooling, and self-hosting may know concrete stock plugins when
their role requires it. Keep those dependencies development-only and outside
the normal production import graph; a `dev_dependencies` entry does not permit
an import from `app/lib/**`.

The existing identity-only provider-selection exception is documented in the
[application README](../../app/README.md#chatgpt-source-checkout-configuration).
It does not relax the plugin package/import prohibition. Current startup,
frontend hosting, native bridges, and stock composition belong in the
[application map](../../app/README.md), [plugin system](plugin-system.md),
[plugin layout](plugin-layout.md), and
[contracts and capabilities](contracts-and-capabilities.md), not this rule set.

## Plugin dependencies

Production plugin code may use deliberately public ADELE APIs, its own
contract/public API packages, and deliberately public extension APIs defined by
another component/plugin where semantically appropriate. Appropriate third-party
libraries and same-plugin implementation reuse must still respect these boundaries.

It must not depend on `app` / `adele_desktop`, internal host/build packages
(`plugin_runtime`, `plugin_backend_host`, `plugin_builder`, `contract_codegen`,
`agent_kernel`), or another plugin's frontend, backend, or private implementation.
A strategy obtains execution semantics through `adele_orchestration`, not by
importing `agent_kernel`. A backend obtains Project storage through
`adele_project_storage` over `adele_plugin_backend_support`, not by importing the
app database, linking SQLite to reach its backing, or opening a second connection.

Depending on a public interface is not requiring one implementation to be active.
Discover compatible registrations at runtime; missing participation follows the
owning extension point's semantics, not hidden activation dependencies. A package
being accessible in the repository does not make it a public interface.

Plugin tests may use internal host packages under `dev_dependencies` for
integration testing. Production plugin libraries and entrypoints must not import
them. Build/generation tooling is likewise separate from plugin runtime APIs.

### Frontend and backend separation

Within a source plugin, shared contracts may supply this dependency shape;
arrows again point toward dependencies:

```text
       shared contract/public API
           ^              ^
           |              |
       backend         frontend
```

Backend and frontend implementations do not depend directly on one another.
They may use shared contracts as needed; neither a shared package nor both
components are mandatory. Shared transport contracts remain Flutter-free.
Frontends may depend on Flutter and public UI contracts. Source arrangement and
prepared-component details belong to [plugin layout](plugin-layout.md), while
concrete package layouts belong to local plugin READMEs.

## Pure-Dart boundary

Product, Project storage contracts, orchestration, contracts, capability routing,
Environment semantics, model-provider/tool semantics, backend runtime, and execution
mechanics must remain usable and testable without Flutter where Flutter is not
intrinsic to their purpose. Generic plugin APIs, backend support, and internal build/generation
packages also retain Flutter-free production dependency graphs.

`adele_ui` and `adele_desktop` are deliberate Flutter boundaries; plugin frontend
packages may also use Flutter. Pure Dart does not mean web portability, no native
I/O, or that the whole checkout and its build operations need no Flutter toolchain.

## New packages and APIs

Prefer an existing semantic owner and the smallest concrete interface. Do not
create a generic public extension package, provider-instance package, profile
package, another application UI package, or plugin-defined public API package
merely because future architecture could use it. A new package requires a concrete
ownership/dependency boundary; a plugin-defined API package needs at least one
concrete shared interface use.

When adding a package or plugin, verify workspace membership and maintained
analysis/test discovery. Passing a direct package test alone does not establish
repository integration.

## Verification and source map

Inspect both manifests and production source, separating `dependencies` from
`dev_dependencies` and runtime entrypoints from test/build tooling. Existing
checks cover important subsets; they are not a complete dependency-graph linter.

| Check | Source anchors |
| --- | --- |
| Workspace membership | Root [`pubspec.yaml`](../../pubspec.yaml) and nested plugin workspace manifests; `dart pub workspace list` |
| Actual package edges | The package manifests linked above and their `lib/` imports/exports |
| Application production boundary | [`app/pubspec.yaml`](../../app/pubspec.yaml), [`app/lib/`](../../app/lib/), and [`app_plugin_boundary_test.dart`](../../test/tools/app_plugin_boundary_test.dart) |
| Plugin production versus development edges | [`plugins/`](../../plugins/) package manifests, production `lib/` and `bin/` entrypoints, and local READMEs |
| Maintained analysis/test discovery and wiring checks | [`tools/adele.dart`](../../tools/adele.dart) and [`test/tools/adele_test.dart`](../../test/tools/adele_test.dart) |

The tooling tests belong to `dart tools/adele.dart test --target adele_tools`.
For a focused boundary check without generation or the broader tooling suite, run
`dart test test/tools/app_plugin_boundary_test.dart test/tools/adele_test.dart`.
The app checker covers manifest dependencies and imports/exports, including
conditional and relative directives; it does not validate every public/plugin
graph or Dart part. Review those boundaries directly when changing them.
