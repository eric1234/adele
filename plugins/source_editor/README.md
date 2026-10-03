# Source Editor

Source Editor is a frontend-only stock plugin. Its
`packages/frontend` package, `source_editor_frontend`, imports Flutter and the
public UI bridges, not application code, filesystem I/O, native controllers, or
CodeForge. It contributes ordinary Main Content panes and an Open Source File
path form. It has no backend, autosave, file watcher, or new-file operation.

## Ownership

`lib/source_documents.dart` owns document identity (captured Environment plus
provider-normalized relative path), local order, last saved text, opaque provider
revision, conservative dirty state, pending Save/Close, and conflict policy.
Primitive records are held through the public contribution data bridge. The host
retains native text/undo owners independently of mounted presentation and retains
the records for the current window; this is not durable workbench persistence.
Navigation, browser display, pane remount, and repeated initialization do not
replace document text or undo history. Returning to an Environment projects all
its retained records in plugin order. Other Environments' records remain hidden.
Pane titles escape control/directional characters and are limited to 160 code
units including the dirty marker; the complete normalized resource path remains
in the document record and is used unchanged for file operations.

An exact match to a retained normalized path focuses that buffer without a read,
even if its provider or file is no longer available. Opening another path reads a
complete existing file before creating a native editor. Only a successful read
and native initialization publish a record. Alias deduplication occurs after
provider normalization and again after asynchronous initialization; a losing
provisional editor is released without replacing the winner. Display results ask
the host to focus an ID only if the original captured Environment is still shown.
The form calls the same `display` operation as the public DisplaySourceFile path.

Save captures one native text snapshot and the last accepted provider revision,
then conditionally replaces the existing file. Only one Save can be pending per
document. Success advances the baseline to the saved snapshot, not text edited
during the write. Failure preserves baseline and provider revision, with the
provider's structured code/message/details available in the record and result.
There is no automatic retry or claim that a failed write rolled back. Conflicts
retain native text and expose Close, Discard, then Reopen as explicit recovery.
A later explicit Open or Save can obtain fresh access to the same captured
Environment under the [frontend grant](../../docs/architecture/contracts-and-capabilities.md#frontend-behavioral-operations).
Save still sends the document's last acknowledged provider revision; the host
neither replaces that revision nor automatically retries a write.
The provider normalizes paths and enforces file type, encoding, confinement,
symlink, revision, and size policy. The stock Git Environment provider's current
complete-text limit is one MiB; that is not a universal public API file-size bound.

Native revision counts notifications, including selection and layout, not content
edits. `Possibly modified` and the title's `*` are deliberately conservative.
Remount, Save, Close, and exit use actual text snapshots; undoing to the baseline
therefore does not cause a discard prompt merely because the counter changed.
Close refuses while saving, otherwise closes unchanged text or asks through
plugin-owned `SourceDocumentPort.confirmDiscard`. Its adapter supplies all text
to the public generic `confirmContribution` two-choice dialog; discard policy is
not host-owned. Exit examines every record, including hidden documents
while Task Browser is shown, refuses pending saves, and asks one aggregate discard
confirmation. Accepted exit does not erase records or dispose native editors;
the host performs final shutdown after all participants accept.
This does not protect against forced OS termination, crashes, hot plugin
replacement with unsaved documents, or cross-window/restart recovery.

**Complete input composition before Save or departure.** Native snapshots do not
promise uncommitted IME composition, and the existing native component has known
selected-composition departure limitations. This plugin adds no composition
repair or lossless-departure claim. See the
[native editor evidence](../../docs/experiments/codeforge-correctness.md).
Highlighting is limited to Dart, JSON, and Python; other suffixes use plain text.

## Entrypoints

`packages/frontend/lib/main.dart` supplies the prepared ABI:

| Entry | Purpose |
| --- | --- |
| `initializeSource()` | Reconcile the captured Environment's ordered panes without replacing existing pane identities. |
| `sourcePane()` | Native editor, path/status, Save/Close, and left/right ordering controls. |
| `openSourceInput()` | Existing relative-path input widget. |
| `displaySource()` | Finite `display` operation, with `arguments.path`. |
| `saveSource()` | Finite `save` operation, with `arguments.id`. |
| `closeSource()` | Finite `close` operation, with `arguments.id`. |
| `closeSources()` | Finite `exit` operation without an Environment; returns `accepted`. |

Finite operations receive immutable host-captured context. Environment keys and
document IDs are identity data, never authority to select another Environment.
`main_content_bridge.dart` supplies Session/Environment context, pane IDs, and
collection changes; `contribution_bridge.dart` supplies operation arguments,
retained records/resources, and generic confirmation. Only finite operations use
`environment_access_bridge.dart` for captured file access. Session-less exit reads
all retained records without inventing a current Environment.
`code_editor_bridge.dart` gives each view a fresh native presentation handle.
Bridge notifications refresh copied data rather than transmitting text. The
implementation uses the repository's conservative interpreted Flutter subset:
external TextField labels, non-null button callbacks, explicit Expanded flex,
and simple map/list policy with no plugin-owned text controller.

## Validation

`packages/frontend/test/source_documents_test.dart` exercises document policy
through an explicit in-memory implementation of the public port shape. It does
not substitute for prepared-EVC/native integration, authority, or catalog checks.
The compiler, descriptor, installation, and repository discovery are maintained
outside this plugin. Follow the [testing guide](../../docs/development/testing.md)
and [toolchain policy](../../docs/development/toolchain.md), and serialize Flutter
invocations sharing app output.
The [disposable-worktree manual workflow](../../docs/development/testing.md#manual-source-workflow)
covers Open, Edit, Save, Environment navigation, conflict, and Close/exit
cancellation through the normal application. Automated launch is not human
keyboard or IME validation.

Global boundaries belong to the [UI package](../../packages/ui/README.md),
[plugin architecture](../../docs/architecture/plugin-system.md), and
[dependency rules](../../docs/architecture/dependency-rules.md).
