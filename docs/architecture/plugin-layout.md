# Source Plugin Layout

## Canonical form

Plugin source is the canonical distribution format. The development build
pipeline derives persisted frontend eval bytecode and a native Dart AOT backend
from that source.

`workspace_demo` establishes the intended repository shape:

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

The plugin directory is a small Dart workspace. Its root manifest coordinates
the source packages; `adele_plugin.yaml` is the draft ADELE manifest.

For development builds, `packages.contract` selects the plugin's contract
package. The builder reads its Dart package name from `pubspec.yaml`, derives
`lib/<package-name>.dart`, resolves that source to an absolute path, and runs
`contract_codegen --check --source <path>` after validating Dart but before any
backend compilation. Repository-wide generator configuration is not used to
choose a requested plugin's contract.

## Package split

| Package | Responsibility | Rules |
| --- | --- | --- |
| Contract | Shared typed async declarations and immutable values | Pure Dart; no Flutter; no transport or generation implementation |
| Backend | Privileged or native Dart behavior | Depends on the contract; never on the frontend; compiled locally to AOT and hosted in an external isolate group |
| Frontend | Plugin UI source | Depends on the contract; never on the backend; may use Flutter; currently interpreted with pinned `flutter_eval`/`dart_eval` |

Frontend/backend communication uses shared public contracts and generated typed
transport. Source imports do not cross between their implementation
packages, and crossing the runtime boundary never shares object identity.

## Distinct identities

The following are independent concepts and must not be inferred from one
another:

| Identity or state | Example or meaning |
| --- | --- |
| Plugin ID | Stable, globally namespaced identity such as `dev.adele.workspace-demo` |
| Display name | Human-readable `Workspace Demo` |
| Plugin version | Source/plugin release string such as `0.1.0` |
| Repository name | Checkout or catalog naming |
| Dart package name | `workspace_demo_contract`, `workspace_demo_backend`, or `workspace_demo_frontend` |
| Runtime build identity | Exact source and build/toolchain context used for an artifact |
| Installation | Source and compiled artifacts available to one ADELE installation |
| Profile activation | Whether an installed plugin participates in an ADELE profile |
| Plugin runtime instance | Running plugin created for an activation context |
| Configured capability instance | Persistent named provider/account/connection managed by a runtime |
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
installations or backend copies. This default is not a permanent prohibition
on multiple runtimes; additional isolation or concurrency models are deferred.

Temporary runtime resources are created and disposed during operation. They
are not plugin instances and are not persistent provider configurations.

## Proven and deferred

The `workspace_demo` fixture proves local AOT compilation, shared process-hosted
loading, typed async communication, interpreted rendering, interaction, and
rebuild/reload on Linux x64 Flutter profile mode. Windows, macOS, release mode,
packaging, discovery, and broad plugin APIs remain unproven.

Maintained backend-only plugins additionally prove generated server streaming,
multiple generation-bound configuration contexts, real HTTP/SSE model-provider
integration, and bounded read-only source access. These development proofs do
not establish packaging, profile lifecycle, sandboxing, or final Workspace
semantics.

Plugin-specific typed vertical tests belong to the plugin backend package that
owns the implementation and contract. The shared backend host package tests
only generic framing and lifecycle behavior and does not take development
dependencies on fixture contracts or plugin APIs solely for a plugin test.
