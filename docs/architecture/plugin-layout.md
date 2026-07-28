# Source Plugin Layout

## Canonical form

Plugin source is the canonical distribution format. The proposed build pipeline
will derive frontend eval bytecode and a native Dart AOT backend from that
source, but Phase 0 neither builds nor loads either artifact.

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

## Package split

| Package | Responsibility | Rules |
| --- | --- | --- |
| Contract | Shared typed async declarations and immutable values | Pure Dart; no Flutter; no transport or generation implementation |
| Backend | Privileged or native Dart behavior | Depends on the contract; never on the frontend; proposed for local AOT compilation |
| Frontend | Plugin UI source | Depends on the contract; never on the backend; may use Flutter; proposed for interpreted `flutter_eval`/`dart_eval` execution |

Frontend/backend communication must use shared public contracts and the future
generated transport. Source imports do not cross between their implementation
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

The expected default is one plugin runtime instance per activation context.
One runtime may expose several configured capability instances, such as Work
and Personal accounts, without additional installations or backend copies.
This default is not a permanent prohibition on multiple runtimes; additional
isolation or concurrency models are deferred.

Temporary runtime resources are created and disposed during operation. They
are not plugin instances and are not persistent provider configurations.

## Deferred proof

Phase 1 is intended to test an interpreted file-tree/text frontend, an AOT
filesystem backend, typed async communication, and source rebuild/reload. Local
AOT compilation and loading, eval compilation and rendering, communication,
reload, and behavior across Windows, macOS, and Linux all remain unproven.
