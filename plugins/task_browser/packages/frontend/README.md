# Task Browser Frontend

`task_browser_frontend` is the stock interpreted Task Browser. Production `lib/`
imports only Flutter and the public `adele_ui/task_browser_bridge.dart` stub.
The application dependency is development-only for native declarations and
evaluator tests, not a plugin runtime API.

## Presentation

`lib/task_browser_frontend.dart` exposes `createTaskBrowser`. A bounded host
surface is required: at widths of at least 760 logical pixels it renders a
320-pixel Task list next to the selected Task detail; narrower surfaces use a
Task list and a detail view with Back to Tasks. Both panes scroll independently
and the view uses the host's Material theme. On reopening with a selected Task,
the first successful snapshot initializes the narrow view to that Task's details.
Later notifications preserve a user's Back to Tasks navigation.

Search is a local, case-insensitive title substring match. The inline Card form
rejects blank titles and submits trimmed nonblank titles. Search text, unsubmitted
title text, and form visibility survive snapshot refreshes and host notifications.
Successful creation clears only the new-Task form, not search, and displays the
newly selected Task's details even when its title does not match the search.
Cancel discards the unsubmitted title without clearing search. These are local
presentation values, not durable Project data.

Task rows show host-supplied preparing/running/waiting/terminal Session counts,
including the failed subset of terminal outcomes. The detail shows primary
Environment ID and provider ID without interpreting provider state. Session rows
show the contributed strategy `displayName` with strategy-ID fallback, secondary
Session and strategy identities, and the generic execution status. `canOpen`
controls navigation separately from `executionAvailable`: a canonical Session can
open without a strategy backend, frontend, or Main Content contribution. Missing
execution support does not hide retained status or disable an otherwise openable
row. Waiting is an attention label only: approval requires opening the exact
Session's host-owned controls. No Command-specific status
or execution authority is exposed here. Exactly one creation
option gets a direct `New <displayName> Session` action; multiple options get a
small choice list headed `New Session: choose a strategy`. Only the host-issued
opaque handle is sent back, never a strategy ID
constructed by the frontend. Choices come from exact orchestration registrations,
not frontend availability or dummy UI registrations. Zero choices show a
non-actionable `New Session` label and the no-strategy message without hiding
existing Sessions. Zero Sessions also has an explicit empty state.

The public bridge owns product snapshots, subscriptions, and asynchronous actions.
Actions settle as `[true, null]` or `[false, safeErrorString]`; the view shows the
safe error, preserves failed form input, and does not automatically retry. While
an action is pending, duplicate mutations and selection are disabled and the
operation is labelled. Retained callbacks recheck their guards when invoked, not
only when the controls are built. Form callbacks capture a generation that changes
on opening, cancelling, and successful creation, so a discarded form cannot
submit or cancel a later form. `isTaskBrowserActive()` also prevents local
mutation or settlement updates in exit-retained views whose native authority has
already retired. Notifications refresh canonical data without rebuilding local
controllers. Disposal unsubscribes and ignores late action settlements.
The frontend never invents a local Task or Session before host publication.

The current evaluator pin does not support `FilledButton`, `AlertDialog`,
`TextField.decoration`, or nullable `TextButton.onPressed` in this path. New Task
uses the supported prominent Material `ElevatedButton`, and the form uses a Card
and external field labels. Unavailable button actions use non-actionable labels,
while row actions use `ListTile.enabled`. Row callback helpers deliberately create separate
eval call frames so repeated list rendering cannot alias row IDs or opaque handles.
Responsive layout uses the host's minimal `LayoutBuilderBridge` in
`app/lib/frontend/layout_builder_bridge.dart`, explicitly registered by both the
compiler and `PreparedTaskBrowserHost`. It wraps Flutter's actual `LayoutBuilder`
and the pin's existing BuildContext/BoxConstraints wrappers. `Expanded` supplies
its flex explicitly because the pin does not supply Flutter's default.
Nested snapshot maps stay dynamic across helper boundaries. Selection comparisons
are evaluated before passing the map to a row helper: indexing an already-pushed
map in a later argument can make the pin unbox it twice. Narrow list/detail
navigation uses distinct subtrees so the detail does not inherit the Task list's
scroll position.

## Compilation

- `tool/task_browser_frontend_compiler.dart` exposes
  `compileTaskBrowserFrontend(repositoryRoot: ...)`, returning bytecode.
- `tool/compile_task_browser_frontend.dart` writes that bytecode to
  `ADELE_TASK_BROWSER_FRONTEND_OUTPUT`; `ADELE_REPOSITORY_ROOT` identifies the
  checkout. It runs under the pinned Flutter test harness, not ordinary `dart run`.
- Native Task Browser declarations come from
  `app/lib/frontend/task_browser_bridge.dart`; production plugin code never
  imports that implementation.

The local compiler and harness delegate to the matching files in `app/tool/`,
which are also used by normal stock preparation. There is one set of compilation
inputs and native declarations, not separate test and installed frontend builds.

From this package after workspace bootstrap, a focused compilation is:

```sh
ADELE_REPOSITORY_ROOT=/path/to/adele \
ADELE_TASK_BROWSER_FRONTEND_OUTPUT=/existing/output/task-browser.evc \
flutter test --no-pub tool/compile_task_browser_frontend.dart
```

Use the repository's [toolchain policy](../../../../docs/development/toolchain.md)
and [testing guide](../../../../docs/development/testing.md) for maintained
preparation and discovery. Compiler imports are build-only; no static plugin
imports belong in production `app/lib`.

## Validation

From this package:

```sh
flutter test --no-pub test/task_browser_frontend_test.dart
flutter analyze --no-pub --fatal-infos
```

The maintained repository target is
`dart tools/adele.dart test --target task_browser_frontend` from the checkout root.

The tests compile another Flutter frontend first, then compile the actual Task
Browser source with the production declarations. They load its artifact through
`PreparedFrontend` and `PreparedTaskBrowserHost`, exercising production bridge
composition with a deterministic Task Browser source rather than a custom eval
runtime. They exercise empty states, search, exact row and choice dispatch,
notification-safe form state, failed and delayed actions, Session availability,
read-only background status and coalesced status refresh,
responsive navigation and selected-Task reopening, discarded titles, and
unsubscribe/late-settlement handling. They do not
prove real Environment establishment, persistence, strategy activation, native
desktop navigation, or installation discovery; those are host/tooling checks.

Broader workbench state persistence, advanced Task metadata, Session history
summaries, and Environment controls are outside this presentation subset. See the
[plugin overview](../../README.md) for ownership and global architecture links.
