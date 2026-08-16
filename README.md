# ADELE

ADELE is an extensible, cross-platform desktop environment for building,
running, inspecting, and extending agent systems. The long-term goal is for
ADELE to become capable of developing ADELE itself.

ADELE's maintained foundation includes the Phase I plugin runtime proof, the
Phase II-A generated unary contract path, Phase II-B generated server-streaming
and cancellation, the Phase III active
capability provider registry, and the Phase IV-A semantic agent-execution
foundation:
interpreted Flutter frontends and locally compiled AOT backends hosted in one
shared child Dart runtime, with generated typed clients, codecs, backend
dispatch, and deterministic provider selection. `workspace_demo` remains the
Phase I/II regression fixture. `resource_inspector` runs two independent
providers in separate isolate groups in the shared child process and invokes
both through generated transport. These are internal reference fixtures, not
product UI. Plugin installation, packaging, permissions, sandboxing, and
general third-party APIs are not implemented.

Phase IV separates canonical Session history, Run lifecycle, context
assembly, streaming-shaped semantic model events, immutable tool
materialization, ToolInvocation, effect description, policy, approval, tool
execution, structured outcomes, and typed execution observation. Its
development-only AOT provider implements the common generated ModelProvider stream
and a generation-bound ResourceInspector capability into those kernel ports.
The common adapter separates live text observations from authoritative output,
requires explicit semantic terminal settlement, retains item-native replay
metadata as complete kind/compatibility/data envelopes, and preserves exact
provider-generation binding. The scripted
fixture unary/stream/probe service remains regression infrastructure.

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
dart tools/adele.dart generate
dart tools/adele.dart analyze
dart tools/adele.dart test --jobs 2
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
`generate` deterministically updates committed experimental contract transport;
`generate --check` rejects stale outputs and is included in `check`.
The command driver runs package test suites through a bounded worker pool and
reports every failed package after all targets settle. `check` verifies
formatting, analysis, and all implemented tests, including committed
generated-output freshness.

## Repository

```text
app/                         single Flutter desktop application
packages/plugin_api/         adele_plugin_api (experimental public)
packages/contract/           adele_contract (experimental public)
packages/contract_codegen/   contract_codegen (internal, pure Dart)
packages/model_provider/     adele_model_provider (experimental public)
packages/capabilities/       adele_capabilities (experimental public)
packages/plugin_runtime/     plugin_runtime (internal, pure Dart)
packages/plugin_backend_host/ shared backend host (internal, pure Dart)
packages/plugin_builder/     plugin_builder (internal, pure Dart)
packages/agent_kernel/       agent_kernel (internal, pure Dart)
plugins/workspace_demo/      internal source-plugin reference fixture
plugins/resource_inspector/  Phase III two-provider capability fixture
plugins/scripted_model/      Phase IV-A unary plus Phase II-B stream fixture
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

`resource_inspector` contains a lightweight shared capability/contract package,
independent basic and alternate backend packages, and an evaluated consumer.
The consumer lists provider IDs and names, invokes the deterministic default,
explicitly invokes each provider, and renders a structured unavailable state.
Those discovery and resolution steps run in interpreted consumer code through a
narrow capability bridge; host code only adapts semantic operations and invokes
the selected binding with the generated typed client.
The Linux development smoke command above verifies that both providers are
active while running and absent after each shutdown.

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

Continue remaining Phase IV with targeted OpenAI/Codex subscription-auth
research, the first real provider, and minimal Agent/workflow refinement.
Windows, macOS, release packaging,
current Flutter compatibility, packaging/discovery, and eval-stack
modernization also remain open. See `docs/architecture/overview.md` and ADRs
0019 through 0023.
