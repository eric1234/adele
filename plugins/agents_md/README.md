# AGENTS.md stock plugin

`agents_md_plugin` remains the pure-Dart semantic package, including
`agentsMdInstructions` and the in-process `AgentsMdPlugin.activate` seam used by
focused tests. Normal application startup and development/self-hosting instead
load [`agents_md_backend`](packages/backend/README.md) from `packages/backend` as
AOT on their shared backend host. The app no longer imports/depends on the semantic
package or statically activates it; five other static plugins remain.

The backend advertises one `extensionExposures` entry for
`dev.adele.extension.inference-context-sources`, with extension ID
`dev.adele.plugin.agents-md.instructions`, service `inferenceContextSource`, its
connection-bound configuration context, and only `{'failureMode': 'required'}`
metadata. PluginId is connection-owned (`dev.adele.plugin.agents-md`), not an
exposure field. It advertises no capabilities and requires no configuration or
startup arguments. Generic `PluginBackendActivation` and the app's
`RemoteInferenceContextSourceAdapter` register/retire its exact generation in the
existing `ExtensionRegistry`; there is no AGENTS-specific activation table or fallback.
Activation alone does not read a file or require a Project or Session.

This is the initial **root-level AGENTS.md implementation**, not complete
AGENTS.md-standard compatibility or a generic repository-instructions framework.
Each new inference snapshot reads only canonical `AGENTS.md` at the root of the
Session-authorized Environment through generated
`AuthorizedEnvironmentReadService.readFile(relativePath)`. The host adapter captures
the canonical `InferenceContextSourceContext` and obtains its
`AuthorizedEnvironmentFileReadFacet`; transported Session/Run strings never grant
authority. The service preserves `EnvironmentTextFile` and declared `EnvironmentFailure`,
with no authority-ID parameters, mutation, or process operations. The source has
no direct host filesystem fallback, directory scan, watcher, cache, or configuration.

Generated `RemoteInferenceContextSourceService.snapshot(sessionId, runId,
hostInvocationContext)` returns `RemoteInferenceInstruction(key, text, revision)`
with nullable revision. The backend uses public pure-Dart
`adele_plugin_backend_support` for unary host requests on the existing ports and
framed host, not internal host imports. Secure opaque per-operation contexts are
allowlisted for that read service and revoked in `finally`, on retirement, and on
termination; exact connection generations are stamped by the host. This is not
general symmetric RPC, reverse streaming, or a sandbox.

The source is required while active. Environment `not_found` and blank/whitespace
files produce successful empty contributions. All other read/service/authority
failures follow required-source failure semantics and abort composition.

Nonblank Markdown is opaque: its exact contents and Environment revision are
retained as `InferenceInstructionMaterial(key: 'AGENTS.md')`. A separate stable
`semantics` instruction tells the model that explicit user instructions and direct
requests take precedence over AGENTS.md. The file text is not parsed or wrapped.
The existing composer owns immutable snapshots and same-inference reuse; each new
capture rereads current content.

Nested/path-scoped files, overrides, alternate names, home/global files, imports,
Skills, Agent Roles, maps, memory, and other context mechanisms are not supported.
Those other mechanisms remain independent plugin concerns.

Normal Linux preparation adds backend-only `agents-md/backend.aot` to the six
installations, alongside the existing four EVCs and two other backend snapshots.
The shared host snapshot is separate. The same four generic deployment defines
are used, with no AGENTS configuration. Self-hosting supplies its explicit
`agentsMdArtifact` on the same host through the same adapter activation, without
requiring a normal installation root. Both host/plugin protocol versions are 2.

The semantic package, backend, and support package are workspace members with
maintained analysis/test discovery. Focused semantic validation uses
`dart tools/adele.dart test --target agents_md_plugin` from the repository root.
The Linux profile build has passed with this backend, the other two backends,
the shared host, and four EVCs. This is build evidence, not a new test-suite or
live-service result; see [normal backend startup](../../app/README.md#normal-backend-startup).
