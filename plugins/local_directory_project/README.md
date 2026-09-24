# Local Directory Project

Stock Local Directory Project selection and backing provider. The plugin root is
not a Dart package. It contains independent components under one plugin identity:

| Component | Responsibility |
| --- | --- |
| `packages/frontend`, `local_directory_project_frontend` | Interpreted Flutter picker entrypoint and lexical path-to-URI conversion through public `adele_ui`. |
| [`packages/backend`](packages/backend/README.md), `local_directory_project_backend` | Pure-Dart AOT source validation and relative database placement through public `adele_core_extensions`. |

Neither component imports app code, host internals, or the other's implementation.
The frontend descriptor registers the public Project selector through the existing
extension registry; the ready backend separately advertises the Project provider
capability. There is no static selector or native selection-semantics fallback.
Loading and registration do not open a picker or database.

- Plugin ID: `dev.adele.plugin.local-directory-project`.
- Plugin display name: `Local Directory Project`.
- Extension ID:
  `dev.adele.plugin.local-directory-project.project-selector`.
- Selector label: `Open Local Directory...`.
- Project provider ID: `dev.adele.project.local-directory`.

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
The frontend does not resolve symlinks or validate filesystem existence, access,
Git, or repository suitability. Lexical Windows/UNC conversion is not a promise
that the provider or current host accepts that source for SQLite backing.

The evaluated entrypoint returns only the URI string. The descriptor also names
the Project provider. The host validates the exact frontend and owning backend
provider before picking, after picking, and after provider preparation, then opens
durable storage through core lifecycle. Cancellation is a no-op, and retirement
cannot switch an in-flight operation to a replacement. Selection/preparation
alone allocate no Project identity, Task, Environment, Session, or Run.

## Backing

`LocalDirectoryProjectProviderService` accepts supported absolute local `file:`
directory URIs and returns the selected source with `.adele/data.db`. This literal
placement is the backend's policy, not a universal path in core. Network
authorities/UNC backing and malformed paths fail explicitly. The backend does no
database I/O or Project ID allocation; the host independently checks source
existence, path confinement, and symlinks before opening SQLite.

Project identity/source survive restart and moving the source with its database.
The [product model](../../docs/architecture/product-model.md#project-storage)
owns schema, migration, publication, and non-durable-state boundaries. Git
suitability and Task/Environment establishment remain the Environment provider's
responsibility, not this plugin's backing validation.

## Preparation

`compileLocalDirectoryProjectFrontend` in
`app/tool/local_directory_project_frontend_compiler.dart` compiles the frontend
with the host's `DirectoryPickerDeclarations`;
`app/tool/compile_local_directory_project_frontend.dart` is the Flutter build-time
harness. It requires `ADELE_REPOSITORY_ROOT` and
`ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT`. Normal repository preparation adds
`local-directory-project/frontend.evc` and `backend.aot` to one prepared
installation in the shared catalog. `tools/backend_artifacts.dart` prepares the
backend; stock frontend executable metadata and its provider ID remain centralized
in `tools/stock_frontend_descriptors.dart`.

Normal startup consumes prepared bytecode, never source. Missing or failed selector
preparation/activation has no native fallback. Frontend and backend availability
are independent, but every prepared selector requires its exact same-installation
ready provider to open a Project. A headless caller can use that provider with a
known source without loading Flutter or the selector frontend.

## Deferred

Recents, defaults/Profiles, remote selectors, Git discovery, and selection UI
policy are not implemented here. General plugin persistence is not provided by
the Project database. A Project is not intrinsically a local directory just
because this stock implementation uses one. Narrow storage follow-ups are recorded
with the [storage limits](../../docs/architecture/product-model.md#storage-scope-and-limits),
not by silently editing users' root ignore files.

## Validation

After workspace dependency resolution, run
`dart tools/adele.dart test --target local_directory_project_frontend`
from the repository root. This uses `flutter test` without Linux desktop build
dependencies. Tests compile and execute the actual frontend source with a fake
picker bridge, covering POSIX/Windows paths, escaping, normalization, cancellation,
empty/relative rejection, delayed settlement, and picker failures. Native bridge
and exact-generation lifecycle tests belong to the app; launcher/discovery tests
belong to `test/tools`.
The [backend README](packages/backend/README.md#validation) maps its pure-Dart
target. These tests do not prove interactive native picking or macOS/Windows builds.
