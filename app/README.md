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
materialization, and a Session-authorized Environment Read File tool. Lifecycle
UI and normal stock-plugin composition are not implemented yet.

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
Environment-backed Search and mutation/command tools, profiles, product plugin
discovery/activation, production Agent UI, application Commands/keybindings,
and plugin-facing UI extension APIs remain deferred. The stock Git worktree
Environment provider is currently exercised through focused backend and
shared-host AOT tests rather than normal UI.

The application composition root does contain the development-only Phase IV
model/source capability adapters, bounded Chat-shaped tool-loop strategy, and
AOT integration tests. These prove execution boundaries but do not establish
the final product workflow, strategy-bound Session persistence, or stock UI
composition. The Phase IV `DevelopmentSource` path remains maintained pending
V-A3 Environment-backed Search and OpenAI/ChatGPT source-coding migration.

See `docs/architecture/overview.md`, `docs/architecture/plugin-extension-model.md`,
and ADR 0031.
