# Workspace Demo Plugin

`workspace_demo` is ADELE's internal source-plugin reference fixture. Its stable
plugin ID is `dev.adele.workspace-demo`; that ID is distinct from this
repository directory and from all Dart package names below.

The nested Dart workspace has a pure-Dart contract package with sibling backend
and frontend consumers:

```text
workspace_demo_contract
          ^
          |-- workspace_demo_backend
          `-- workspace_demo_frontend
```

The frontend and backend never depend on one another. Plugin production code
does not depend on ADELE's internal `plugin_runtime`, `plugin_builder`,
`agent_kernel`, or `adele_desktop` packages. The backend integration test uses
`plugin_runtime` only as a development dependency to exercise the host boundary.

The separate development-runtime smoke path locally compiles this fixture from a
known location. It does not implement discovery, installation, profiles, or
configured providers and is not the normal application startup path.

The annotated declarations in
[`workspace_demo_contract.dart`](packages/contract/lib/workspace_demo_contract.dart)
are authoritative and retain `part 'workspace_demo_contract.g.dart';`.
[`contract_codegen.yaml`](../../contract_codegen.yaml) selects this source for
native generation. Its generated sibling supplies the typed native client,
dispatcher, codecs, and service ID. It is a Git-ignored local artifact, not
committed source. Maintained generation materializes it before native consumers
compile; `bootstrap` also prepares it for IDEs and direct tool use. See
[`contract_codegen`](../../packages/contract_codegen/README.md) and the
[toolchain workflow](../../docs/development/toolchain.md#generated-contract-artifacts).

The filesystem [backend](packages/backend/README.md) compiles against that
generated part. Its entrypoint uses `WorkspaceDemoServiceDispatcher` through the
configuration-context router and owns the ready/shutdown lifecycle. The fixture's
Linux x64 profile smoke path uses the shared backend host.

The [frontend](packages/frontend/README.md) remains an interpreted fixture with
its own small typed async eval bridge, backed by the native generated client.
It does not use the generic generated eval-client path; the native sibling is not
its interpreted client artifact.
