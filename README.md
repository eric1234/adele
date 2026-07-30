# ADELE

ADELE is an extensible, cross-platform desktop environment for building,
running, inspecting, and extending agent systems. The long-term goal is for
ADELE to become capable of developing ADELE itself.

ADELE's maintained foundation includes the Phase I plugin runtime proof:
interpreted Flutter frontends and locally compiled AOT backends hosted in one
shared child Dart runtime. `workspace_demo` remains an internal reference
fixture, not product UI. Plugin discovery, packaging, permissions, sandboxing,
and general third-party APIs are not implemented.

## Toolchain

The integrated foundation is temporarily pinned to Flutter `3.38.10`
(framework `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`, engine
`cafcda5721a78a7884db92f13c5e89f7643d52dd`) and bundled Dart `3.10.9`.
`.tool-versions` selects this SDK for asdf users and `toolchain.json` records the
manager-independent identity. This is not ADELE's permanent toolchain.

`flutter_eval 0.8.2` fails against Flutter 3.44.8 due to missing
`Container.isAntiAlias` support. Modernizing or replacing the eval dependency
is required before exposing a broad third-party interpreted UI API.

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

The internal Linux profile smoke is explicit and does not alter normal app
startup:

```sh
ADELE_DEVELOPMENT_REPOSITORY_ROOT="$PWD" \
ADELE_DEVELOPMENT_PLUGIN_DIRECTORY="$PWD/plugins/workspace_demo" \
ADELE_DEVELOPMENT_DIRECTORY=/path/to/demo-root \
dart tools/adele.dart smoke linux --profile
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
packages/plugin_backend_host/ shared backend host (internal, pure Dart)
packages/plugin_builder/     plugin_builder (internal, pure Dart)
packages/agent_kernel/       agent_kernel (internal, pure Dart)
plugins/workspace_demo/      internal source-plugin reference fixture
docs/architecture/           architecture boundaries and terminology
docs/adr/                    architectural decision records
tools/                       root development command driver
```

Packages intended to become part of the public plugin-development surface use
the `adele_` prefix. Internal implementation packages use concise unprefixed
names. Every package is unpublished (`publish_to: none`). Public packages never
depend on internal host packages; pure-Dart packages never depend on Flutter.
The application is the composition root.

`workspace_demo` exercises separate pure-Dart contract, Dart backend, and
Flutter frontend packages. Frontend and backend depend on the contract, never
on one another. It is maintained reference infrastructure, not product UI.

## Profiles

ADELE profiles are planned named collections of plugin activation, optional
configuration overrides, and preferred providers. They are not implemented.
The development runtime uses one implicit default development profile. Plugin
installation, profile activation, shared plugin configuration,
profile overrides, runtime instances, configured capability instances, and
temporary runtime resources remain distinct concepts.

The shell text "No workspace is open" does not establish workspace semantics.
Workspace, Project, and Environment are intentionally not foundational ADELE
types in Phase 0.

## Next Work

Validate Windows, macOS, release packaging, and current Flutter compatibility;
modernize or replace the eval stack; and define packaging and discovery before
expanding the public plugin API. See `docs/architecture/overview.md` and ADR
0019.
