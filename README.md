# ADELE

ADELE is an extensible, cross-platform desktop environment for building,
running, inspecting, and extending agent systems. The long-term goal is for
ADELE to become capable of developing ADELE itself.

The repository is at **Phase 0**. It establishes package boundaries,
architecture decisions, development tooling, and a runnable Flutter desktop
shell. Plugins are not discovered, compiled, loaded, or executed. The proposed
interpreted-frontend/AOT-backend design remains unproven.

## Toolchain

Phase 0 is pinned to Flutter `3.44.8` (framework revision `058e0af2c2`) and its
derived Dart `3.12.2`. Install that Flutter release and ensure `flutter` and
`dart` are on `PATH`. The exact identity is recorded in `toolchain.json`; the
SDK is not vendored.

Future ADELE distributions are expected to include a pinned toolchain capable
of compiling plugin source locally. A toolchain upgrade may invalidate compiled
plugin artifacts and require rebuilding them. ADELE's own version will not be
tied directly to Dart semantic versions.

## Commands

Run all commands from the repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart run linux     # use macos or windows on those hosts
dart tools/adele.dart format
dart tools/adele.dart analyze
dart tools/adele.dart test
dart tools/adele.dart check
dart tools/adele.dart build linux
```

`bootstrap` uses the standard Dart pub workspace through Flutter's pub command.
The command driver has no package dependencies, fails on the first failed
package, and names that package. `check` verifies formatting, analysis, and all
implemented tests.

## Repository

```text
app/                         single Flutter desktop application
packages/plugin_api/         adele_plugin_api (experimental public)
packages/contract/           adele_contract (experimental public)
packages/capabilities/       adele_capabilities (experimental public)
packages/plugin_runtime/     plugin_runtime (internal, pure Dart)
packages/plugin_builder/     plugin_builder (internal, pure Dart)
packages/agent_kernel/       agent_kernel (internal, pure Dart)
plugins/workspace_demo/      source-plugin workspace for the Phase 1 proof
docs/architecture/           architecture boundaries and terminology
docs/adr/                    architectural decision records
tools/                       root development command driver
```

Packages intended to become part of the public plugin-development surface use
the `adele_` prefix. Internal implementation packages use concise unprefixed
names. Every package is unpublished (`publish_to: none`). Public packages never
depend on internal host packages; pure-Dart packages never depend on Flutter.
The application is the composition root.

`workspace_demo` demonstrates the source layout only: separate pure-Dart
contract, Dart backend, and Flutter frontend packages. Frontend and backend
depend on the contract, never on one another. No fake runtime integration is
present.

## Profiles

ADELE profiles are planned named collections of plugin activation, optional
configuration overrides, and preferred providers. They are not implemented.
Phase 0 and the initial Phase 1 proof use one implicit default development
profile. Plugin installation, profile activation, shared plugin configuration,
profile overrides, runtime instances, configured capability instances, and
temporary runtime resources remain distinct concepts.

The shell text "No workspace is open" does not establish workspace semantics.
Workspace, Project, and Environment are intentionally not foundational ADELE
types in Phase 0.

## Next Milestone

Phase 1 should build one end-to-end `workspace_demo` walking skeleton: discover
source from a known development location; compile and launch its backend as AOT;
compile and render its frontend as eval bytecode; make one typed asynchronous
file-list/read call through a manually written proxy, dispatcher, and codec; and
support stop, rebuild, and reload in Flutter profile or release mode. It should
use the implicit development profile and temporary activation scaffolding, not
introduce profile management, provider-instance management, a workspace picker,
generated contracts, file watching, a production editor, or a production
capability registry.

See `docs/architecture/overview.md` for the complete architectural context and
the explicit Phase 1 risks.
