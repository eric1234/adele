# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Normal Application

The app currently owns its minimal shell, theme, and private widgets. It
displays only the ADELE name and static empty-state messages. The current
`No workspace is open` text is legacy/provisional UI copy; it does not define a
first-class Workspace product concept.

ADR 0031 now accepts Project, Task, Session, Run, and Environment as the shared
product-domain identities. Project/Task/Environment lifecycle UI and the stock
plugin composition are not implemented in the normal application yet.

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

Normal Project selection, Task/Session lifecycle UI, Environment providers,
profiles, product plugin discovery/activation, production Agent UI, application
Commands/keybindings, and plugin-facing UI extension APIs remain deferred.

The application composition root does contain the development-only Phase IV
model/source capability adapters, bounded Chat-shaped tool-loop strategy, and
AOT integration tests. These prove execution boundaries but do not establish
the final product workflow, strategy-bound Session persistence, Environment
lifecycle, or stock UI composition.

See `docs/architecture/overview.md`, `docs/architecture/plugin-extension-model.md`,
and ADR 0031.
