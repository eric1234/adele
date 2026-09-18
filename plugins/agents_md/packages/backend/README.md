# AGENTS.md Backend

`agents_md_backend` is the pure-Dart AOT entrypoint for the stock root-level
AGENTS.md source, with PluginId `dev.adele.plugin.agents-md`.
[`bin/agents_md_backend.dart`](bin/agents_md_backend.dart) advertises one
inference-context extension with `failureMode: 'required'` and no capabilities or
startup arguments. PluginId belongs to the installation/connection, not the exposure.

[`AgentsMdBackend`](lib/agents_md_backend.dart) implements generated
`RemoteInferenceContextSourceService`. Each `snapshot` binds its opaque
`hostInvocationContext` and `authorizedEnvironmentReadServiceId` through public
`adele_plugin_backend_support.AdeleHostRequestMultiplexer`, constructs an
`AuthorizedEnvironmentReadServiceClient`, and calls `readFile('AGENTS.md')`.
It reuses `agentsMdInstructions` from `agents_md_plugin` to produce instruction
values. Session/Run strings are not read authority; the host-issued operation
context allowlists the read service on the exact connection generation and is
revoked at operation settlement, retirement, and termination. The host supplies
the captured Session's Environment read facet. The backend imports no app, kernel,
internal runtime, or Flutter implementation. This source uses only unary reads;
the shared transport's reverse process streaming grants it no process authority.
This is neither general symmetric RPC nor a sandbox.

Normal preparation installs `agents-md/backend.aot`. Explicit self-hosting uses
its own `agentsMdArtifact` on the same shared host without a normal installation
root. Both use generic remote extension activation. Root-only reread, `not_found`,
blank-file, exact-text/revision, and required-source semantics are maintained in
[the plugin README](../../README.md).
