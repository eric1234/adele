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

The frontend and backend never depend on one another. The plugin does not
depend on ADELE's internal `plugin_runtime`, `plugin_builder`, `agent_kernel`, or
`adele_desktop` packages.

The development runtime locally compiles this source from a known location. It
does not implement discovery, installation, profiles, or configured providers.

The filesystem backend, manual typed transport, persisted interpreted frontend,
and typed async eval bridge are maintained integration fixtures. The complete
Linux x64 profile path uses the shared backend host described by ADR 0019.
