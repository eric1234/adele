# Workspace Demo Plugin

`workspace_demo` is source-only scaffolding for ADELE's Phase 1 walking
skeleton. Its stable plugin ID is `dev.adele.workspace-demo`; that ID is distinct
from this repository directory and from all Dart package names below. The draft
manifest is not parsed or validated in Phase 0.

The nested Dart workspace has a pure-Dart contract package with sibling backend
and frontend consumers:

```text
workspace_demo_contract
          ^
          |-- workspace_demo_backend
          `-- workspace_demo_frontend
```

The frontend and backend never depend on one another. The plugin does not
depend on ADELE's internal `plugin_runtime`, `plugin_builder`, `agent_kernel`, or
`adele_desktop` packages.

Phase 1 locally compiles this source in a known development location. It does
not implement discovery, installation, profiles, or configured providers.

The filesystem backend, manual typed transport, persisted interpreted frontend,
and typed async eval bridge were individually proven. The complete profile path
failed because Flutter's `Isolate.spawnUri` did not execute the supplied AOT
backend. See `docs/experiments/phase-1-dual-runtime.md`.
