# Plugin Builder

`plugin_builder` is an internal, pure-Dart package. It implements narrow
development manifest parsing, exact toolchain checks, dependency resolution,
fresh generation directories, backend AOT compilation, captured process
diagnostics, and complete-build activation.

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

## Current Scope

Frontend EVC compilation remains in the Flutter application because this
package stays pure Dart and must not depend on eval or Flutter. Production
caching, installation, signing, generation, and invalidation remain deferred.
