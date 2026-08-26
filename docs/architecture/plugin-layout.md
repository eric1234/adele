# Source Plugin Layout

## Canonical form

Plugin source is the canonical distribution format. The development build
pipeline derives persisted frontend eval bytecode and a native Dart AOT backend
from that source.

`workspace_demo` establishes the maintained reference repository shape; its name
is historical fixture terminology and does not establish a first-class ADELE
Workspace domain concept:

```text
plugins/workspace_demo/
|-- adele_plugin.yaml
|-- pubspec.yaml
`-- packages/
    |-- contract/
    |   `-- pubspec.yaml  # workspace_demo_contract
    |-- backend/
    |   `-- pubspec.yaml  # workspace_demo_backend
    `-- frontend/
        `-- pubspec.yaml  # workspace_demo_frontend
```

The plugin directory is a small Dart workspace in the Dart package-management
sense. Its root manifest coordinates source packages; `adele_plugin.yaml` is the
draft ADELE manifest.

For development builds, `packages.contract` selects the plugin's transport
contract package. The builder reads its Dart package name from `pubspec.yaml`,
derives `lib/<package-name>.dart`, resolves that source to an absolute path, and
runs `contract_codegen --check --source <path>` after validating Dart but before
backend compilation. Repository-wide generator configuration is not used to
choose a requested plugin's contract.

## Package split

| Package | Responsibility | Rules |
| --- | --- | --- |
| Contract | Shared typed async transport declarations and immutable values | Pure Dart; no Flutter; no transport/generation implementation |
| Backend | Privileged/native Dart behavior | Depends on public contract/API packages as needed; never on frontend; compiled locally to AOT and hosted in an external isolate group |
| Frontend | Plugin UI source | Depends on public contract/API packages as needed; never on backend; may use Flutter; currently interpreted with pinned `flutter_eval`/`dart_eval` |

Frontend/backend communication uses shared public contracts and generated typed
transport. Source imports do not cross between their implementation packages,
and crossing a runtime boundary never shares object identity.

A plugin may also publish a deliberately public lightweight API package for an
extension point it owns when another plugin concretely needs to implement that
interface. That API package is interface surface, not permission to import the
owning plugin's frontend/backend implementation. General plugin-defined
extension packaging is accepted direction but not yet implemented as a manifest
or lifecycle system.

See [`dependency-rules.md`](dependency-rules.md) and
[`plugin-extension-model.md`](plugin-extension-model.md).

## Distinct identities

The following are independent concepts and must not be inferred from one
another:

| Identity or state | Example or meaning |
| --- | --- |
| Plugin ID | Stable globally namespaced identity such as `dev.adele.workspace-demo` |
| Display name | Human-readable `Workspace Demo` |
| Plugin version | Source/plugin release string such as `0.1.0` |
| Repository name | Checkout/catalog naming |
| Dart package name | `workspace_demo_contract`, `workspace_demo_backend`, or `workspace_demo_frontend` |
| Runtime build identity | Exact source + build/toolchain context used for an artifact |
| Installation | Source/compiled artifacts available to one ADELE installation |
| Profile activation | Whether an installed plugin participates in a context |
| Plugin runtime instance | Running plugin created for an activation context |
| Configured capability instance | Persistent named provider/account/connection managed by a runtime |
| Project/Task/Session/Environment | Core product identities associated with plugin behavior, not plugin/package identity |
| Runtime resource | Temporary document, terminal, browser session, process, or similar handle |

The draft manifest starts with independent plugin metadata:

```yaml
manifestVersion: 1
id: dev.adele.workspace-demo
version: 0.1.0
displayName: Workspace Demo
```

It must not embed current activation state, an active profile, or a claim that
the plugin is loaded. Installation does not imply activation.

## Runtime mapping

The intended default is one plugin runtime instance per activation context;
activation-context lifecycle is not implemented. The maintained runtime proves
that one plugin generation may expose several configured capability instances,
such as API-key and experimental ChatGPT providers, without additional
installations or backend copies.

This default is not a permanent prohibition on multiple runtimes; additional
isolation/concurrency models remain deferred.

Temporary runtime resources are created/disposed during operation. They are not
plugin instances and are not persistent provider configurations.

Future active plugins may register several independent semantic extensions from
one runtime—for example Git may provide Environment behavior, review/SCM
services, Commands, summary contributions, and model tools. Registration into
multiple extension points does not imply multiple plugin runtimes.

## Proven and deferred

The `workspace_demo` fixture proves local AOT compilation, shared process-hosted
loading, typed async communication, interpreted rendering, interaction, and
rebuild/reload on Linux x64 Flutter profile mode. Windows, macOS, release mode,
packaging, discovery, activation contexts, and broad plugin APIs remain
unproven.

Maintained backend-only plugins additionally prove generated server streaming,
multiple generation-bound configuration contexts, real HTTP/SSE model-provider
integration, and bounded read-only source access.

These proofs do **not** implement the accepted general recursive extension
system, Project/Task/Session/Environment product lifecycle, production UI
composition, plugin-defined extension API packaging/versioning, or sandboxing.
The DevelopmentSource root is not the final Environment abstraction.

Plugin-specific typed vertical tests belong to the plugin backend package that
owns the implementation and contract. The shared backend host package tests
only generic framing/lifecycle behavior and does not take development
dependencies on fixture contracts or plugin APIs solely for a plugin test.
