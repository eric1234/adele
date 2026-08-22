# ADELE

ADELE is an extensible, cross-platform desktop environment for building,
running, inspecting, and extending agent systems. The long-term goal is for
ADELE to become capable of developing ADELE itself.

ADELE's maintained foundation now includes:

```text
Phase I    dynamic plugin runtime proof
Phase II   generated unary + server-streaming/cancellation transport
Phase III  active capability registry and exact-generation routing
Phase IV   provider-neutral agent execution + real model/source coding vertical
```

Interpreted Flutter frontends and locally compiled AOT backends run through one
shared child Dart runtime with generated typed clients, codecs, backend
dispatch, and deterministic provider selection. `workspace_demo` remains the
Phase I/II regression fixture, `resource_inspector` remains the Phase III
multi-provider capability fixture, and `scripted_model` remains deterministic
model-provider and transport regression infrastructure. These are internal
reference fixtures, not product UI. Plugin installation, packaging,
permissions, sandboxing, and general third-party APIs are not implemented.

Phase IV establishes provider-neutral Session/Run, context, model, tool,
policy/approval, outcome, effect-certainty, and execution-observation semantics.
The experimental common ModelProvider capability uses generated streaming and
cancellation, ordered semantic and provider-native items, explicit settlement,
and exact generation-bound routing. The real OpenAI plugin provides the public
API-key Responses route and two separately routed configured contexts: API key
and an explicitly experimental ChatGPT subscription-backed route. The latter
is positive interoperability evidence, not a documented or stable OpenAI
third-party integration contract.

The provisional backend-only DevelopmentSource capability binds one read-only
source root to a plugin generation. Application composition projects it into
source-search and source-read model tools used by a bounded development
strategy. Deterministic AOT integration proves a real OpenAI provider can search
and read the checked-out ADELE source through ADELE's capability path and
continue to a final answer; only the remote HTTP responses are scripted. The
explicitly opt-in live ChatGPT source-coding smoke has also run successfully.
ADELE can therefore use a real model-provider integration to inspect ADELE's
own source through ADELE-owned, generation-bound tools and continue reasoning
from the results. It cannot yet modify or validate its own source through this
workflow.

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
plugins/scripted_model/      deterministic ModelProvider/transport fixture
plugins/openai/              real OpenAI ModelProvider; ChatGPT route experimental
plugins/development_source/  bounded read-only configured source capability
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

ADELE profiles are planned sparse named composition layers for plugin
activation, configuration overrides, provider availability, and provider
preferences. A future window/context may use an ordered stack such as
`Developer + Work` or `Developer + Personal`; the normal case may use only one
or two profiles, but the architecture does not impose an arbitrary small stack
limit. Profiles are not implemented, and the development runtime still uses one
implicit default development profile.

Activation, configuration, provider selection, configured capability instances,
runtime instances/resources, and workbench state remain distinct concepts. An
effectively disabled plugin is intended to disappear from that context's normal
product and settings surface without deleting dormant persisted configuration.
Open windows may keep independent live workbench state while remembered local
state seeds future windows. See
`docs/architecture/profiles-and-configuration.md` for the detailed directional
model and deferred decisions.

The shell text "No workspace is open" does not establish workspace semantics.
Workspace, Project, and Environment are intentionally not foundational ADELE
types. A configured DevelopmentSource root does not establish final Workspace
identity or lifecycle.

## Next Work

**Phase IV is complete.**

Phase V begins the minimum self-hosting capability set and workflow needed for
ADELE to make, inspect, validate, and review controlled changes to its own
source. Source mutation/editing, command/validation execution, and SCM/review
integration are upcoming implementation areas, not settled APIs or final
architecture.

Windows, macOS, release packaging, plugin packaging/discovery, sandboxing,
current Flutter compatibility, and eval-stack modernization also remain open.
See `docs/architecture/overview.md` and ADRs 0019 through 0028.
