# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Phase 0 Fallback

The app owns its shell, theme, and private widgets. It displays only the ADELE
name and static empty-state messages. "No workspace is open" is UI copy, not a
definition of future workspace semantics.

## Phase 1 Experiment

When all `ADELE_PHASE1_*` values are passed through the root driver, the app
shows private build/start/stop/reload controls, toolchain/build/backend/frontend
diagnostics, and an interpreted widget host. The app owns frontend compilation,
the temporary workspace-demo proxy/codecs, and the custom eval bridge. Without
Phase 1 activation it retains the Phase 0 empty shell.

Linux profile build succeeds, but runtime backend loading fails because
Flutter's `Isolate.spawnUri` executes the Flutter app entrypoint instead of the
supplied backend AOT snapshot. This is evidence, not a production plugin system.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root. Phase 0 needs only Flutter.

The app must not be a dependency of plugins or reusable core packages. Plugin
implementations, agent logic, public plugin APIs, and core host logic do not
belong here.

## Deferred

Workspace selection, ADELE profile selection, plugin loading, agent execution,
and plugin-facing UI APIs are deferred.
