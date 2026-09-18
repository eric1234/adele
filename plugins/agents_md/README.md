# AGENTS.md stock plugin

`agents_md_plugin` is the pure-Dart semantic package for the stock root-level
AGENTS.md instruction source. It provides `agentsMdInstructions` and the in-process
`AgentsMdPlugin.activate` seam used by focused tests. Normal application startup
and development/self-hosting load [`agents_md_backend`](packages/backend/README.md)
from `packages/backend` as AOT on their shared backend host. The app does not import
or depend on either plugin package; activation uses the generic remote-source adapter.

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

This is a **root-level AGENTS.md implementation**, not complete
AGENTS.md-standard compatibility or a generic repository-instructions framework.
Each new inference snapshot reads only canonical `AGENTS.md` at the root of the
Session-authorized Environment through generated
`AuthorizedEnvironmentReadService.readFile('AGENTS.md')`. The host adapter captures
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
termination; exact connection generations are stamped by the host. Source capture
remains unary/read-only even though the shared transport supports separately
authorized process streams. This is not general symmetric RPC or a sandbox.

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

Normal Linux preparation installs backend-only `agents-md/backend.aot` under the
prepared installation root. Shared-host artifacts and generic deployment inputs
are described in [desktop tooling](../../packages/plugin_builder/README.md#desktop-tooling).
Self-hosting supplies its explicit `agentsMdArtifact` on the same host through the
same adapter activation, without requiring a normal installation root. Both
host/plugin protocol versions are 3; prepared artifacts must be rebuilt together.

The semantic package, backend, and support package are workspace members with
maintained analysis/test discovery. Focused semantic validation uses
`dart tools/adele.dart test --target agents_md_plugin` from the repository root.
