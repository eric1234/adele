# Plugin Source and Installation Layout

Role: Canonical architecture

Implementation status: Partial

This document defines the representations a plugin passes through from authored
source to a runtime-discoverable prepared installation, and the information that
belongs at each boundary. Source organization, build/preparation, installed
artifacts, and live activation are distinct concerns.

This is not an exact manifest or parser specification. The local
[`plugin_builder`](../../packages/plugin_builder/README.md) and
[`plugin_runtime`](../../packages/plugin_runtime/README.md#prepared-catalog)
documentation maps their current formats and behavior; owning source/tests are
authoritative for exact schemas, validation, and failure rules.

## Representation pipeline

```text
authored/source plugin
    | preparation/build
    v
derived component artifacts
    | installation assembly
    v
prepared installation
    | runtime discovery (startup catalog snapshot)
    v
component activation
    v
live capability/extension registrations
```

Producing an artifact is not yet assembling an installation. Discovering an
installation is not activating it, and an activation attempt is not proof of live
contributions. The startup catalog and live registry discovery have different
lifetimes.

## Authored/source plugin

Plugin source is the canonical distribution form. It is source-controlled material
used to develop and prepare a plugin, not a runtime installation directory.
Semantic `PluginId` is independent of repository/directory names, Dart package
names, display names, and artifact locations; see
[ADR 0010](../adr/0010-plugin-identity-differs-from-dart-package-identity.md).

A source plugin may contain backend, frontend, contract/public API, or other
deliberate source packages as needed. Backend and frontend are independent roles;
not every plugin supplies either role, and neither requires the other merely to
exist. A source package is not necessarily an independently activated component.

Frontend and backend implementations must not depend on one another. Shared typed
declarations belong in a deliberate contract/public API package rather than in
either implementation. Shared transport contracts are pure Dart and depend on
neither Flutter nor the implementations. A public API dependency is not a demand
that its owning plugin implementation be active. See
[dependency rules](dependency-rules.md) and the
[recursive plugin model](plugin-system.md#recursive-typed-extension-points).
The separation recorded in [ADR 0003](../adr/0003-separate-contract-frontend-and-backend-packages.md)
does not make its historical three-package wording a requirement to supply all
three roles today.

There is no mandatory physical directory tree. Current stock plugins use varying
source arrangements, including shared public contracts and retained same-plugin
implementation packages. [`workspace_demo`](../../plugins/workspace_demo/) is a
reference fixture for the generic source-builder path, not a universal plugin
template or a requirement to use that builder or its manifest. Its name is fixture
terminology, not a first-class ADELE Workspace domain concept.

## Preparation/build

Preparation derives runtime-consumable artifacts from source. Current examples are
native backend AOT snapshots and interpreted frontend EVC artifacts. Generated
contract transport is intermediate/local build output consumed by compilation,
not another required installed executable component. Authored declarations remain
its source of truth; see [`contract_codegen`](../../packages/contract_codegen/README.md).

Derived artifacts depend on source and build/toolchain context. A plugin release
version is not an exact build identity, and neither identifies a live activation
generation. Preparing or publishing build output does not establish readiness or
register contributions. Build tooling may understand source topology; normal
runtime discovery and activation must not need plugin source or compile it on
demand.

Source preparation is partly repository/stock-aware today: maintained checkout
tooling explicitly selects some source entrypoints and frontend compilation inputs.
It does not universally discover source plugins from a common build manifest.
Prepared runtime discovery, by contrast, reads installations generically to produce
the startup catalog.
Replacing stock-aware preparation should not require merging source topology into
that runtime model. Exact commands and toolchain procedures belong in
[development documentation](../development/README.md) and the
[builder's local documentation](../../packages/plugin_builder/README.md).

## Two manifest domains

| Manifest | Boundary and purpose |
| --- | --- |
| `adele_plugin.yaml` | Source/build input where that builder path is used. It identifies source packages and entrypoints needed for preparation, not runtime availability. |
| `adele_plugin.installation.json` | Prepared/runtime-discovery input. It records plugin identity, prepared components, and the metadata needed to host their artifacts, not how to find or build their source. |

These are not interchangeable schemas. The narrow reference source builder does
not define every plugin's source layout, and producing its development build
output does not automatically produce an installed manifest. Stock preparation
can assemble the runtime representation without using that source manifest.

The installed manifest is not a source location or dependency graph, an activation
decision, Profile state, general plugin/provider/account configuration, or a
backend capability/extension exposure list. Hosting metadata belongs here;
configuration and live advertisements belong at their own boundaries below.

## Prepared installation snapshot

A prepared installation is the on-disk runtime-discoverable representation of one
plugin implementation. It supplies stable plugin identity, release/display
metadata, and independently optional prepared components. It is runtime input,
not source/build metadata or live generation state.

`PreparedPluginCatalog.discover` reads on-disk installations into one deterministic
startup catalog snapshot. The application backend and frontend owners consume
that same snapshot; discovery does not activate either component. This captures
parsed metadata, validated component locations/descriptors, and discovery issues,
not an atomic filesystem snapshot or immutable artifact bytes. Component owners
acquire their generation-bound resources later.

Current discovery examines immediate child installations without recursing or
watching for changes. An empty installation root is a valid zero-plugin
composition. Duplicate semantic plugin identities exclude the conflicting
installations rather than silently selecting a winner by version or order.
Root I/O failure is not silently converted into an empty composition.

### Independently optional components

An executable installation may provide a backend only, a frontend only, or both.
Current validation also retains metadata-only installations with neither
component; they start nothing and provide no executable support.

Backend and frontend are separate preparation and lifecycle units. Tooling may
prepare them together, but their runtime availability and readiness need not
coincide. An invalid component is omitted without automatically discarding a
healthy sibling. Installation-level identity or envelope invalidity can instead
make the installation unusable. Component-local activation failure likewise need
not retire a healthy sibling; this is not a promise to isolate shared-host failure.
An operation requiring both components still needs its exact live counterparts.

### Prepared frontend descriptors

Prepared frontend metadata tells the host which supported interpreted entrypoints
and semantic roles can be attempted. Current categories include presentation
descriptors and behavioral extension descriptors. Library/entrypoint identifiers
are executable ABI/preparation metadata for prepared code, not instructions to
locate or compile source packages at runtime.

Installed descriptors are not active registrations. They become live contributions
only through successful frontend activation. They are neither Profile/activation
policy nor general configuration or authority grants. Semantic role metadata does
not make a frontend the owner of the presented or invoked domain. Exact descriptor
schemas belong to the [runtime catalog owner](../../packages/plugin_runtime/README.md#prepared-catalog);
own-backend collaboration belongs to
[contracts and capabilities](contracts-and-capabilities.md#own-backend-frontend-requests).

### Artifact references and confinement

Artifact references are installation-relative and must remain confined to their
containing installation after filesystem resolution. A manifest must not direct
discovery outside that boundary. Current catalog validation requires referenced
prepared artifacts to exist as regular files and validates descriptor structure.
It does not prove that an artifact will load, its code will execute successfully,
or a backend will become ready. Loading/executable checks belong to subsequent
hosting and activation; exact path and rejection rules belong to the local
[catalog source/tests](../../packages/plugin_runtime/README.md#prepared-catalog).

## Live activation and registrations

The prepared installation describes what can be attempted. Runtime owners
separately start/load valid prepared components and establish live registrations.
Backend exposures cross a later boundary than installed metadata:

| Boundary | Information established |
| --- | --- |
| Prepared backend component | An artifact is available for a backend activation attempt. |
| Backend ready handshake | This live backend generation advertises its current public capability/extension contributions, possibly none. |
| Host activation | Validated/adapted contributions enter the existing registries with exact-generation lifetime. |

A prepared backend does not predeclare all contributions it will expose. A ready
connection is also not itself a registry registration. The protocol and exposure
semantics belong to
[contracts and capabilities](contracts-and-capabilities.md#backend-ready-advertisements),
not the installation schema.

Frontend activation similarly creates registrations from prepared descriptors;
catalog presence alone creates none. Successful registration does not guarantee
every later view or behavioral operation will succeed. Retirement ends the owned
generation's registrations; a replacement does not revive captured old bindings.
See [plugin system](plugin-system.md#backend-and-frontend-composition) for component
hosting/lifecycle and [live discovery and exact bindings](plugin-system.md#live-discovery-and-exact-captured-bindings)
for runtime composition rather than installed-catalog discovery.

## Availability is not participation or configuration

Installation metadata describes prepared availability. It does not answer whether
a plugin is enabled for a Profile/context, which configured account/provider
instances exist, which provider is preferred, what ordinary settings apply, what
authority an invocation receives, or which registrations are currently live.

Normal startup currently attempts all discovered valid prepared components. That
is a fixed participation policy, not proof that installation and activation are
the same concept or that profile-aware activation exists. Configuration and
activation decisions remain separate from both prepared artifacts and their live
generations; see [profiles and configuration](profiles-and-configuration.md).
Invocation authority remains [host-owned](plugin-system.md#authority-remains-host-owned).

## Implementation scope

Current checkout preparation and startup hosting do not constitute a production
installer/updater. Generic source/build discovery, profile-aware activation,
installation watching/hot upgrade, and release packaging remain incomplete.

## Source map

| Concern | Primary anchors |
| --- | --- |
| Source manifest/build preparation | [`packages/plugin_builder/`](../../packages/plugin_builder/), [`development_plugin_builder.dart`](../../packages/plugin_builder/lib/src/development_plugin_builder.dart): `_readManifest`, `DevelopmentPluginBuilder.prepareBackend` |
| Reference source-builder fixture | [`plugins/workspace_demo/`](../../plugins/workspace_demo/) |
| Generated contract transport | [`packages/contract_codegen/`](../../packages/contract_codegen/) |
| Stock checkout preparation | [`tools/backend_artifacts.dart`](../../tools/backend_artifacts.dart): `prepareDesktopPluginDefines`; [`tools/frontend_artifacts.dart`](../../tools/frontend_artifacts.dart): `prepareDesktopFrontendArtifacts`; frontend compiler harnesses under [`app/tool/`](../../app/tool/) |
| Prepared catalog/schema implementation | [`packages/plugin_runtime/`](../../packages/plugin_runtime/), [`prepared_plugin_catalog.dart`](../../packages/plugin_runtime/lib/src/prepared_plugin_catalog.dart): `PreparedPluginCatalog`, `PreparedPluginInstallation`, component/descriptor types; [catalog tests](../../packages/plugin_runtime/test/prepared_plugin_catalog_test.dart) |
| Backend activation | [`app/lib/core/application_plugin_bootstrap.dart`](../../app/lib/core/application_plugin_bootstrap.dart): `ApplicationPluginBootstrap` |
| Frontend activation | [`app/lib/frontend/application_frontend_bootstrap.dart`](../../app/lib/frontend/application_frontend_bootstrap.dart): `ApplicationFrontendBootstrap` |
| Runtime composition architecture | [Plugin system](plugin-system.md) |
| Transport/exposure semantics | [Contracts and capabilities](contracts-and-capabilities.md) |
