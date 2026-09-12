# AGENTS.md stock plugin

`agents_md_plugin` registers `AgentsMdPlugin` at the existing
`inferenceContextSources` extension point. The maintained development/self-hosting
composition activates it automatically and closes its registration on teardown.

This is the initial **root-level AGENTS.md implementation**, not complete
AGENTS.md-standard compatibility or a generic repository-instructions framework.
Each new inference snapshot reads only canonical `AGENTS.md` at the root of the
Session-authorized Environment through `AuthorizedEnvironmentFileReadFacet`
resolved from `InferenceContextSourceContext`. There is no host filesystem access,
directory scan, watcher, cache, or configuration.

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

Focused validation: `dart test plugins/agents_md/test` from the workspace root.
