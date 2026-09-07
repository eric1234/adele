# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Normal Application

The app currently owns its minimal shell, theme, and private widgets. It
displays only the ADELE name and static empty-state messages. The current
`No workspace is open` text is legacy/provisional UI copy; it does not define a
first-class Workspace product concept.

ADR 0031 accepts Project, Task, Session, Run, and Environment as the shared
product-domain identities. The application now contains the in-memory
Project/Task establishment coordinator, a provisional authoritative
Session-to-Task/Environment relation, exact-generation Environment runtime
materialization, and a generic Session-scoped model-tool host context that
projects coherent read, mutation, and process facets over one Environment
authority. Independent stock Filesystem Tools, Search Tools, and Command Tools
plugins use that context to provide Environment-authorized `read_file`,
`apply_patch`, `search`, and `run_command`. Search requests only the read facet;
Command Tools requests only the process facet. Lifecycle UI and normal
stock-plugin composition are not implemented yet.

The normal application does not display the `workspace_demo` reference plugin.
The maintained `lib/development_smoke.dart` entrypoint exercises the plugin
runtime only through the explicit root smoke command.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root.

The app must not be a dependency of plugins or reusable core packages. Plugin
implementations, Agent/orchestration logic, public plugin APIs, and reusable
core host logic do not belong here.

The long-term extension direction expects the host to own broad workbench
geometry, Command/Command Palette/keybinding infrastructure, and composition of
semantic plugin surfaces. Concrete plugin-facing UI/Command APIs remain
unimplemented.

## Deferred

Normal Project selection, complete strategy-bound Task/Session lifecycle,
additional Environment-backed mutation tools, profiles, product
plugin discovery/activation, production Agent UI, application
Commands/keybindings, and plugin-facing UI extension APIs remain deferred. The
stock Git worktree Environment provider is currently exercised through focused
backend and shared-host AOT tests rather than normal UI.

The application composition root contains the development-only Phase IV model
adapters, bounded Chat-shaped tool-loop strategy, generic Session-scoped
model-tool host context, and AOT integration tests. The independent stock
Filesystem Tools, Search Tools, and Command Tools plugins, not application code,
define `read_file`, `apply_patch`, `search`, and `run_command`; the host context
exposes facets of only the Session-selected Environment. The OpenAI API-key and
experimental ChatGPT source-coding paths use the read/search composition.
Deterministic real-Git integration additionally proves model-visible revision
flow through `apply_patch`, direct `git diff --check` through `run_command`, and
model continuation after the successful command result. An opt-in paid OpenAI
API-key smoke now also proves real-model `read_file`
opaque-revision flow through `apply_patch`, mutation confined to the Task Git
worktree, post-write observation, and continuation. A distinct paid API-key
smoke proves real-model direct-argv `git diff --check` through `run_command`,
model-visible command-result interpretation, and final continuation after that
edit. These proofs do not establish experimental ChatGPT mutation or command
parity, the final product workflow, strategy-bound Session persistence, stock UI
composition, file creation/deletion, general filesystem mutation, fine-grained
command classification, or background command execution.
`DevelopmentToolLoopStrategy` and `EnvironmentRuntime` remain provisional
application/domain-specific implementation rather than production orchestration
or a general extension-runtime pattern.

## Live Tests

The OpenAI backend's provider-only API-key and ChatGPT live smokes validate
network, authentication, and Responses behavior in isolation. Separate app-level
source-coding live smokes validate the current read/search stack through
Project/Task/Environment establishment, Session authority, plugin-contributed
Search and Read File tools, provisional orchestration, and real model
continuation. A separate paid API-key smoke validates real-model `read_file`
opaque-revision flow through `apply_patch`, Task-worktree-only mutation, and
continuation; experimental ChatGPT live evidence remains read/search-only.
A separate paid API-key source-validation smoke has completed the combined
real-model `read_file` -> `apply_patch` -> direct-argv `run_command` ->
continuation path successfully, including exact Task-worktree and source-copy
isolation evidence.

`ADELE_OPENAI_SOURCE_CODING_LIVE_TEST=1` enables the paid API-key full-stack
smoke when `OPENAI_API_KEY` and `ADELE_OPENAI_TEST_MODEL` are also configured.
`ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST=1` independently enables the paid
API-key full-stack source-mutation smoke with the same credentials and model.
`ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST=1` independently enables the paid
API-key source-edit and command-validation smoke with the same credentials and
model.
`ADELE_OPENAI_CHATGPT_LIVE_TEST=1` enables the experimental ChatGPT
subscription-route full-stack smoke with
`ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE`. All four remain opt-in and are excluded
from normal CI.

See `docs/architecture/overview.md`, `docs/architecture/plugin-extension-model.md`,
and ADR 0031.
