# Local Directory Project Selector

Stock frontend-only ADELE Project selector. The Flutter workspace package
`local_directory_project_selector_frontend` lives in `packages/frontend`; the
plugin root is no longer a Dart package. It depends only on Flutter and the public
`adele_ui` API, not product lifecycle, app code, or internal host implementations.

Its prepared frontend extension descriptor registers the existing
`adele_core_extensions` Project selector contract through the host's existing
extension registry. There is no backend, static in-process selector, or native
selection-semantics fallback. Loading and registration do not open a picker.

- Plugin ID: `dev.adele.plugin.local-directory-project-selector`.
- Extension ID:
  `dev.adele.plugin.local-directory-project-selector.project-selector`.
- Display name: `Open Local Directory...`.

## Selection

The evaluated `selectProject()` entrypoint calls the public
`package:adele_ui/directory_picker_bridge.dart` `Future<String?> pickDirectory()`
bridge. The Flutter host owns `file_selector.getDirectoryPath()`, native plugin
integration, and platform entitlements. The bridge supplies only the picked path
or cancellation; URI conversion remains in this plugin's interpreted code.

Null means user cancellation. Picker errors propagate unchanged, and an empty
string is a failure rather than cancellation or implicit selection of the current
directory. Relative paths also fail explicitly: the frontend has no ambient
current-directory authority. Absolute POSIX paths, Windows drive paths, and Windows
UNC paths are converted with `Uri.directory(...).normalizePath()` and returned as
absolute `file:` directory URI strings. This preserves escaping, lexical dot
normalization, and trailing separators. Windows syntax is selected explicitly
because the pinned eval URI bridge otherwise defaults to POSIX on every host.
There is no symlink resolution or filesystem existence, access, Git, or repository
validation.

The plugin returns only the URI string. The host validates the exact selected extension
binding before invocation and before accepting a returned URI, and creates the
Project. Cancellation remains a no-op. Retirement never causes an
in-flight selection to switch to a replacement. Activation and selection create
no Project, Task, Environment, Session, or Run.

## Preparation

`app/tool/local_directory_frontend_compiler.dart` compiles this package with the
host's `DirectoryPickerDeclarations`; `app/tool/compile_local_directory_frontend.dart`
is the Flutter build-time harness. It requires `ADELE_REPOSITORY_ROOT` and
`ADELE_LOCAL_DIRECTORY_FRONTEND_OUTPUT`. Normal repository preparation adds
`local-directory-project-selector/frontend.evc` and its extension-only manifest to
the shared installation root. Stock executable metadata remains centralized in
`tools/stock_frontend_descriptors.dart`.

Normal startup consumes prepared bytecode, never source. Missing or failed selector
preparation/activation has no native fallback. Pure-Dart self-hosting is
selector-free and does not load Flutter or this frontend.

## Deferred

Project persistence and recents, defaults and profiles, remote selectors,
validation/canonicalization beyond lexical path normalization, symlink identity,
Git discovery, Task/Environment establishment, and selection UI policy are not
implemented here. A Project is not intrinsically a local directory just because
this stock selector returns one.

## Validation

After workspace dependency resolution, run
`dart tools/adele.dart test --target local_directory_project_selector_frontend`
from the repository root. This uses `flutter test` without Linux desktop build
dependencies. Tests compile and execute the actual frontend source with a fake
picker bridge, covering POSIX/Windows paths, escaping, normalization, cancellation,
empty/relative rejection, delayed settlement, and picker failures. Native bridge
and exact-generation lifecycle tests belong to the app; launcher/discovery tests
belong to `test/tools`.
