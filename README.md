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
Phase V-A  Session-authorized plugin-composed Environment read/search
Phase V-B  conditional Environment replacement + deterministic apply_patch
```

Interpreted Flutter frontends and locally compiled AOT backends run through one
shared child Dart runtime with generated typed clients, codecs, backend
dispatch, and deterministic provider selection. `workspace_demo` remains the
Phase I/II regression fixture, `resource_inspector` remains the Phase III
multi-provider capability fixture, and `scripted_model` remains deterministic
model-provider/transport regression infrastructure. These are internal
reference fixtures, not product UI or product-domain definitions.

Plugin installation/discovery, production product plugin activation, packaging,
permissions, sandboxing, and general third-party extension APIs are not yet
implemented.

Phase IV establishes provider-neutral Run/context/model/tool/policy/approval,
outcome/effect-certainty, and execution-observation semantics. The maintained
proof uses a bounded Chat-shaped Session representation; ADR 0031 now defines
the long-term Session as a core container permanently bound to one orchestration
strategy, with strategy-specific state defining its semantic contents.

The common `ModelProvider` capability uses generated streaming/cancellation,
ordered semantic/provider-native items, explicit settlement, and exact
generation-bound routing. The real OpenAI plugin provides the public API-key
Responses route and two separately routed configured contexts: API key and an
explicitly experimental ChatGPT subscription-backed route. The latter is
positive interoperability evidence, not a documented/stable third-party OpenAI
integration contract.

Phase V-A establishes durable Project, Task, and Environment values and binds
provisional agent Sessions authoritatively to one Task-associated Environment.
Active plugin generations contribute contextual model tools through the generic
extension registry. The independent stock Filesystem Tools and Search Tools
plugins own `read_file`, `apply_patch`, and `search`, while a Session-scoped host
facade supplies coherent read and mutation facets over the one authorized
Environment filesystem. Search requests only the read facet and recursively
composes `readDirectory` and `readFile` in Dart; it is not an Environment
provider method.

The OpenAI API-key and experimental ChatGPT source-coding paths now use this
plugin-composed, Session-authorized Environment tool path. Deterministic AOT
integration proves recursive discovery and reading of copied maintained ADELE
source, real-model continuation, and generation-safe replacement of tool and
Environment-provider generations. Deterministic integration now also proves
model-visible Read File revision flow into plugin-owned exact-unique
`apply_patch`, conditional mutation of the Session-authorized Git worktree, and
model continuation. Real-model source mutation and command-backed validation are
not yet proven.

## Accepted long-term architecture beyond the current implementation

The maintained runtime is deliberately narrower than ADELE's accepted product
and extension direction.

ADR 0030 accepts a **recursive typed extension model**:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

Plugins should normally cooperate through public typed interfaces and live
runtime discovery rather than dependencies on specific implementation plugins.
Capabilities remain the callable Action/Service provider mechanism; Events are
read-only fact notifications; UI/composition extension points may use different
zero/one/many and merge/failure semantics. General extension-point runtime/UI
APIs are not yet implemented.

ADR 0031 accepts these shared product-domain identities:

```text
Project
└── Task
    ├── Environment(s)
    └── Session(s)
        ├── Run(s)
        └── child Session(s)
```

- Project is an abstract core identity, not intrinsically a local directory.
- Task is the durable core unit of user intent.
- Environment is initially the practical filesystem/source + process context;
  providers such as Git Worktree or Docker may implement it differently.
- A separate first-class Workspace concept is not required unless future
  concrete needs demonstrate an independent identity.
- Session is permanently bound to one orchestration strategy; Chat history is
  one strategy's state, not the universal Session model.
- Child Sessions represent delegated work and may share or use another
  Task-associated Environment.

The expected default development experience is itself a plugin/configuration
composition rather than hard-coded core behavior. See
`docs/architecture/stock-plugin-direction.md` and `docs/mockups/README.md`.
Most of that stock plugin set does not exist yet.

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

The repository development command above is unrelated to ADELE's future
application-level Command Palette/keybinding subsystem described by the
extension architecture.

## Repository

```text
app/                         single Flutter desktop application
packages/plugin_api/         adele_plugin_api (experimental public)
packages/contract/           adele_contract (experimental public)
packages/contract_codegen/   contract_codegen (internal, pure Dart)
packages/model_provider/     adele_model_provider (experimental public)
packages/model_tool/         adele_model_tool public contribution/execution API
packages/capabilities/       adele_capabilities (experimental public)
packages/product/            adele_product canonical product identities/values
packages/environment/        adele_environment provider/filesystem contract
packages/plugin_runtime/     plugin_runtime (internal, pure Dart)
packages/plugin_backend_host/ shared backend host (internal, pure Dart)
packages/plugin_builder/     plugin_builder (internal, pure Dart)
packages/agent_kernel/       agent_kernel (internal, pure Dart)
plugins/workspace_demo/      internal source-plugin reference fixture
plugins/resource_inspector/  Phase III two-provider capability fixture
plugins/scripted_model/      deterministic ModelProvider/transport fixture
plugins/openai/              real OpenAI ModelProvider; ChatGPT route experimental
plugins/filesystem_tools/    stock Session-authorized Read File/Apply Patch tools
plugins/search_tools/        stock Session-authorized literal Search tool
plugins/git_environment/     Git worktree Environment provider
docs/architecture/           architecture boundaries/directional models
docs/adr/                    architectural decision records
tools/                       root development command driver
```

Key current direction documents include:

```text
docs/architecture/plugin-extension-model.md
    accepted recursive extension architecture

docs/architecture/stock-plugin-direction.md
    speculative expected default plugin topology

docs/architecture/agent-kernel-semantic-model.md
    provider-neutral execution semantics

docs/architecture/agent-tooling-direction.md
    stock tool/execution/presentation direction

docs/mockups/README.md
    stock development UX produced by the expected plugin/configuration set
```

Packages intended to become part of the public plugin-development surface use
the `adele_` prefix. Internal implementation packages use concise unprefixed
names. Every package is unpublished (`publish_to: none`). Public packages never
depend on internal host packages; pure-Dart packages never depend on Flutter.
The application is the composition root.

Plugins may eventually depend on deliberately public extension API packages
defined by core or another plugin/component. They must not import another
plugin's frontend/backend/private implementation merely because it is present in
the repository.

`workspace_demo` exercises separate pure-Dart contract, Dart backend, and
Flutter frontend packages. Frontend/backend depend on the shared contract,
never on one another. It is maintained reference infrastructure; the word
`workspace` in this historical fixture name is not a product-domain decision.

`resource_inspector` contains a lightweight shared capability/contract package,
independent basic/alternate backend packages, and an evaluated consumer. The
consumer lists providers, invokes deterministic default/explicit providers, and
renders structured unavailable state through the capability bridge. The Linux
smoke verifies provider lifecycle around startup/shutdown.

## Profiles and configuration

ADELE profiles are accepted as sparse named composition layers for plugin
activation, configuration overrides, provider availability, and provider
preferences. A future window/context may use an ordered stack such as
`Developer + Work` or `Developer + Personal`; the architecture imposes no
arbitrary small stack limit.

Profiles are not implemented, and the development runtime still uses one
implicit default development profile.

Activation, ordinary configuration, provider selection, configured capability
instances, product/runtime state, security/policy, and workbench state remain
distinct concepts. An effectively disabled plugin is intended to disappear from
that context's normal product/settings surface without deleting dormant
persisted configuration.

Open windows may keep independent live workbench state while remembered local
state seeds future windows. Plugin-facing workbench extension points should be
semantic rather than tied to current center/right/bottom placement.

Core is also expected to own application Command registration, Command Palette,
keybinding resolution, plugin-suggested defaults, and user rebinding. Those
systems are accepted direction but not yet implemented.

See `docs/architecture/profiles-and-configuration.md`.

## Next Work

**Phases IV, V-A, and the initial V-B1/B2 mutation slices are complete.**

Phase V-A1 established the Project-to-Task-to-primary-Environment spine and
stock Git worktree provider. V-A2 connected provisional Session authority to
Environment-backed reads. V-A3 added generic extension registration/liveness,
a public model-tool contribution path, and stock plugin-owned `read_file` with
independent tool-plugin and Environment-provider generation safety. The former
application-owned Read File executable was transitional and is removed.

V-A4 added Session-authorized directory access and independent stock
plugin-owned `search`. Its bounded deterministic literal search is native Dart
traversal over the provider-neutral Environment filesystem, and deterministic
integration proves Search-to-Read discovery against copied maintained source.
The implementation may later use `rg` or `grep` through future Environment
process execution without moving Search semantics into `EnvironmentProvider`.

V-A5 migrated the OpenAI API-key and experimental ChatGPT source-coding paths to
the Session-authorized Environment tool composition, retired the provisional
Phase IV DevelopmentSource capability, and completed the real-model
plugin-composed read-only self-inspection proof. `DevelopmentToolLoopStrategy`
remains application-owned provisional orchestration.

V-B1 added opaque observed-file revisions and conditional complete-file
replacement. V-B2 projects one Session/Environment filesystem authority through
read and mutation facets and adds Filesystem Tools' initial exact-unique
`apply_patch`, with deterministic real-Git Read-to-Patch continuation coverage.
Production orchestration-strategy registration/binding, a plugin-owned Chat
strategy, real-model mutation, file creation/deletion/general writes,
Environment-backed command/validation execution, complete strategy-bound Session
lifecycle, and SCM/review integration remain later work rather than settled
interfaces.

Implementation should introduce the smallest concrete extension boundaries
needed by those verticals rather than build a speculative universal framework
up front.

`EnvironmentRuntime` remains provisional and domain-specific. V-A3 did not
create a second durable Environment restoration/cache use case, so no common
materialization runtime was justified.

Windows, macOS, release packaging, plugin packaging/discovery, sandboxing,
current Flutter compatibility, and eval-stack modernization also remain open.
See `docs/architecture/overview.md`, ADRs 0030/0031, and the earlier ADRs they
refine rather than replace wholesale.
