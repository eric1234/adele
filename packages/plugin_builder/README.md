# Plugin Builder

`plugin_builder` is an internal, pure-Dart package. It implements narrow
development manifest parsing, exact toolchain checks, dependency resolution,
fresh build directories, generated-contract verification, backend AOT
compilation, captured process diagnostics, and complete-build activation.

`prepareBackend` validates the Dart toolchain before running build tooling. It
resolves `packages.contract` from the requested plugin manifest, reads that
package's name from `pubspec.yaml`, and checks the absolute
`lib/<package-name>.dart` source with `contract_codegen --check --source`.
Missing or stale plugin contract sources fail before Flutter validation,
dependency resolution, or backend compilation.

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
caching, installation, signing, and invalidation remain deferred. Generation is
owned by `contract_codegen`; this package rejects stale generated files before
compilation and never activates an incomplete build. Its tests create isolated
temporary plugin layouts so verification cannot accidentally depend on the
repository's generator configuration or maintained fixture.
