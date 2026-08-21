# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Normal Application

The app owns its shell, theme, and private widgets. It displays only the ADELE
name and static empty-state messages. "No workspace is open" is UI copy, not a
definition of future workspace semantics.

The normal application does not display the workspace reference plugin. The
maintained `lib/development_smoke.dart` entrypoint exercises the plugin runtime
only through the explicit root smoke command.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root.

The app must not be a dependency of plugins or reusable core packages. Plugin
implementations, agent logic, public plugin APIs, and core host logic do not
belong here.

## Deferred

Workspace selection, ADELE profile selection, normal product plugin
loading/discovery, product agent UI, and plugin-facing UI APIs are deferred. The
application composition root does contain the development-only Phase IV model
and source capability adapters, bounded tool-loop strategy, and AOT integration
tests; these do not establish product workflow or final Workspace behavior.
