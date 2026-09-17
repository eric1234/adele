# AGENTS.md Backend

`agents_md_backend` is the pure-Dart AOT entrypoint for the stock root-level
AGENTS.md source. `bin/agents_md_backend.dart` advertises one inference-context
extension with `failureMode: 'required'` and no capabilities or startup arguments.

It implements generated `RemoteInferenceContextSourceService`, calls generated
`AuthorizedEnvironmentReadService` through public `adele_plugin_backend_support`,
and reuses `agents_md_plugin` semantics. Session/Run strings are not read authority;
only the host-issued operation context permits the captured Session's file read.
It imports no app, kernel, internal runtime, or Flutter implementation.

Normal preparation installs `agents-md/backend.aot`. Explicit self-hosting uses
its own `agentsMdArtifact` on the same shared host without a normal installation
root. Both use generic remote extension activation. Root-only reread, `not_found`,
blank-file, exact-text/revision, and required-source semantics are maintained in
[the plugin README](../../README.md), including the confirmed Linux profile build.
Build success does not by itself establish runtime or live-service validation.
