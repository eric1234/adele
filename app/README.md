# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Phase 0

The app owns its shell, theme, and private widgets. It displays only the ADELE
name and static empty-state messages. "No workspace is open" is UI copy, not a
definition of future workspace semantics.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root. Phase 0 needs only Flutter.

The app must not be a dependency of plugins or reusable core packages. Plugin
implementations, agent logic, public plugin APIs, and core host logic do not
belong here.

## Deferred

Workspace selection, ADELE profile selection, plugin loading, agent execution,
and plugin-facing UI APIs are deferred.
