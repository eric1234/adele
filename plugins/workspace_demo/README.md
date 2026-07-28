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

Phase 0 does not discover, compile, load, activate, or configure this plugin. It
contains no profile settings or configured provider instances.

Phase 1 will attempt an interpreted file-tree and text UI, an AOT filesystem
backend, typed asynchronous communication, and source rebuild and reload. These
mechanisms remain unproven.
