# Plugin Builder

`plugin_builder` is an internal, pure-Dart package reserved for the future
source-plugin build pipeline. It contains no compiler integration in Phase 0.

## Dependencies

It may depend on lightweight pure-Dart build libraries and public contract
declarations when implementation begins. It must not depend on Flutter runtime
UI, `adele_desktop`, plugin implementations, or `plugin_runtime`. Plugins must
never depend on this package.

## Artifact Scope

Compiled artifacts normally belong to an installation and pinned-toolchain
context. Identical source and build context should allow reuse across ADELE
profiles and across configured capability instances. Toolchain changes may
invalidate those artifacts.

## Deferred

Manifest parsing, source resolution, dependency restoration, contract
generation, AOT compilation, eval compilation, diagnostics, provenance,
caching, invalidation, installation, and profile-specific builds are deferred.
Phase 0 does not invoke Dart, Flutter, `dart_eval`, or `flutter_eval` compilers.
