# local_directory_project_selector_plugin

Stock in-process ADELE local directory project selector. It implements the public
`adele_core_extensions` project selection contract over the existing
`adele_plugin_api` extension registry; it has no product or internal host dependency.

`LocalDirectoryProjectSelectorPlugin` has a const constructor with the narrow
optional `Future<String?> Function() pickDirectory` injection. `activate` returns
one `ExtensionRegistration`, with no picker calls or filesystem work at activation.
Closing that registration removes the contribution and makes retained bindings
stale using the existing registry lifecycle.

- Plugin ID: `dev.adele.plugin.local-directory-project-selector`.
- Extension ID:
  `dev.adele.plugin.local-directory-project-selector.project-selector`.
- Display name: `Open Local Directory...`.

## Selection

The default Flutter adapter uses the flutter.dev-maintained `file_selector`
`getDirectoryPath()` API. The plugin does not implement platform channels.
The host remains responsible for native plugin integration and platform
entitlements.

Null means user cancellation. Picker errors propagate unchanged, and an empty
string is a failure rather than cancellation or implicit selection of the current
directory. A nonempty platform path is converted using
`Directory(path).absolute.uri.normalizePath()` to an absolute `file:` directory
URI. This encodes spaces, resolves relative paths against the host process's
current directory, and normalizes dot segments and directory trailing separators.
It does not resolve symlinks or validate filesystem existence, access, Git status,
or repository structure.

The plugin returns only the URI. The host validates the exact selected extension
binding before invocation and before accepting a returned URI, and creates the
Project. Cancellation remains a no-op. Retirement never causes an
in-flight selection to switch to a replacement. Activation and selection create
no Project, Task, Environment, Session, or Run.

## Headless Composition

The library conditionally imports the Flutter picker only when `dart.library.ui`
is available. ADELE's shared runtime also participates in the pure-Dart
self-hosting CLI import graph, so importing and activating this stock plugin must
not load Flutter libraries or open a dialog in a headless host.

Without Flutter, invoking the default picker throws `UnsupportedError` with an
explicit Flutter host requirement. This is not fallback cancellation. Headless
activation remains valid until selection is requested; an injected picker can
exercise selection deterministically without Flutter. Dependency resolution still
uses the workspace's Flutter SDK because the default adapter is Flutter-backed.

## Deferred

Project persistence and recents, defaults and profiles, remote selectors,
validation/canonicalization beyond lexical path normalization, symlink identity,
Git discovery, Task/Environment establishment, and selection UI policy are not
implemented here. A Project is not intrinsically a local directory just because
this stock selector returns one.

## Validation

After workspace dependency resolution, run
`dart tools/adele.dart test --target local_directory_project_selector_plugin`
from the repository root. This uses `flutter test` without Linux desktop build
dependencies. Injected-picker tests cover path handling, cancellation, failures,
activation, and retirement. A `FileSelectorPlatform` fake tests the default Flutter
adapter without native dialogs or platform channels.

From this package, `dart test test/local_directory_project_selector_plugin_test.dart`
also runs the injected-picker tests and verifies the default headless
`UnsupportedError`. Only that headless-specific assertion is skipped by the Flutter
runner.
