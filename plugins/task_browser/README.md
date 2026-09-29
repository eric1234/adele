# Task Browser

Stock frontend-only Task Browser presentation. The plugin root is not a Dart
package; [`packages/frontend`](packages/frontend/README.md) contains the
interpreted Flutter implementation and focused evaluator tests.

- Plugin ID: `dev.adele.plugin.task-browser`.
- Extension ID: `dev.adele.plugin.task-browser.task-browser`.
- Dart package: `task_browser_frontend`.
- Library: `package:task_browser_frontend/task_browser_frontend.dart`.
- Entrypoint: `createTaskBrowser`.

The plugin presents the current Project's Tasks, a selected Task's primary
Environment identity, and its Sessions. It owns local title-substring search,
the new-Task form, and responsive list/detail presentation. It does not own
Project opening, Task/Environment establishment, strategy resolution, Session
identity, storage, or workbench navigation. Those remain host operations exposed
through the public interpreted `adele_ui/task_browser_bridge.dart` boundary.

This plugin has no backend or own-backend RPC dependency. Missing strategy or
Session presentation support remains visibly unavailable; there is no native
Task Browser substitute in this package. Loading the frontend does not create a
Task, Environment, Session, or Run.

The current stock flow provides Task list/search/create/select, primary
Environment identity, and Session list/create/open. Project/Task breadcrumbs are
host-owned navigation into this presentation. The UI deliberately shows only
available facts: titles, Session counts, generic preparing/running/waiting/terminal
counts with failed outcomes visible, Environment/provider identities, Session
identities and presentation names, and host-issued creation choices. Each Session
also shows its host-projected execution status independently of whether its
presentation can currently open. This is passive background observation, not a
durable Task status store, Command-specific progress, or an approval surface.

Categories/archive, summaries, progress, usage, SCM status, meaningful Session
titles, child Session browsing, rename/delete, Environment management, and
persisted browser/workbench selection remain deferred. See the [product model](../../docs/architecture/product-model.md)
and [UI architecture](../../docs/architecture/plugin-system.md#ui-and-presentation)
for semantic ownership, rather than treating this stock view as the product model.

## Preparation

The local frontend compiler delegates to `app/tool/task_browser_frontend_compiler.dart`,
which reads the plugin source and public bridge stub with the application's
compile-time Task Browser declarations. Its Flutter test
harness requires `ADELE_REPOSITORY_ROOT` and
`ADELE_TASK_BROWSER_FRONTEND_OUTPUT`. Prepared descriptors and repository
installation assembly are maintained outside this plugin under `tools/`.
Runtime activation consumes EVC bytecode, not source; compilation grants no
native product authority.

The [frontend README](packages/frontend/README.md) maps the local compiler and
validation commands. General frontend hosting and dependency constraints belong
to [plugin layout](../../docs/architecture/plugin-layout.md) and
[dependency rules](../../docs/architecture/dependency-rules.md).
