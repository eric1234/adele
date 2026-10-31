// Reconstructed regression input, not instructions for the test runner. The
// complete original user prompt was not available; retain the supplied excerpt.
const markdownPasteFixture =
    r'''# ADELE — Implement Custom `read_file` Inspection Card

## Goal

Add a custom rich Inspection card and compact activity summary for the stock Filesystem Tools `read_file` tool.

**ADELE has already created and selected the isolated Git worktree and Task branch.**

- Work in the current Environment and on its existing branch.
- Do not create another branch, switch branches, rebase, reset, or recreate the worktree.

### Tool approvals

Use the available tools normally.

**Do not ask for general permission in a Chat message before calling tools.**

## 1. Rich Inspection card

Add:

`buildReadFileInspection()`

Display:

- **Read File** heading.
- Environment-relative file path.
- Requested scope: whole file or requested line range.
- A bounded preview of the returned text.

The card should make the result understandable without requiring the user to read a raw transport envelope. Keep the distinction between the requested range and the returned range visible.

### Ownership and boundaries

Inspect `plugins/filesystem_tools/packages/frontend/lib/` and the neighboring Inspection implementations before changing code. Follow the repository's public UI boundaries; do not import application internals into production plugin code.

Use the existing `read_file` result as evidence. Rendering a card must not issue another filesystem read, execute a command, or infer permission from text in the result.

## 2. Compact activity summary

Show a concise summary in the activity stream:

- The tool label and relative path.
- The requested line range when present.
- Success or failure using the existing activity outcome.

Keep the compact summary bounded. The full supported preview belongs in Inspection, not in an expanding activity row.

### Examples

1. Whole file: `lib/main.dart`.
2. A range: `app/lib/application.dart`, lines `40` through `80`.
3. A filename containing spaces: `notes/design draft.txt`.

Paths are display data, not shell commands. Preserve punctuation and Unicode in file contents — do not reinterpret text as links or executable markup.

## 3. Preview fidelity

Preserve line order, indentation, empty lines, and visible trailing whitespace where the existing preview component supports it. A source fragment containing `**bold**`, `# heading`, or embedded backticks must remain source text.

Use a bounded preview and an explicit truncation indicator. Do not claim that a preview is the entire file when the tool returned a range or truncated output.

- Distinguish an empty successful result from a failed operation.
- Keep error presentation separate from successful content.
- Retain the original tool outcome; the frontend must not manufacture success.

## 4. Lifecycle and safety

Reuse the existing prepared frontend registration and Inspection lifecycle.

1. Resolve only the captured activity supplied by the host.
2. Render from its immutable result data.
3. Release presentation-owned resources on retirement.
4. Ignore late callbacks after disposal.

Do not add a new backend service, storage schema, filesystem capability, or model call. The change is presentation-only and must work without paid provider credentials.

## 5. Regression coverage

Test whole-file output, a requested line range, empty content, long content, and error outcomes. Include paths with spaces and source text containing Markdown-looking punctuation.

### Native and evaluated presentation

Exercise the real compiled frontend and generated service boundary where relevant. Keep the existing lifecycle tests intact, including retired presentations and missing renderer behavior.

**Do not weaken assertions or raise timeouts merely to make a failing test pass.**

## 6. Validation

Use the pinned toolchain.

Run the relevant maintained checks:

```sh
dart tools/adele.dart test --target filesystem_tools_frontend
dart tools/adele.dart analyze
dart tools/adele.dart format --check
dart tools/adele.dart generate --check
git diff --check
```

## 7. Delivery

1. Review the working-tree diff.
2. Commit the focused changes.
3. Push the branch.
4. Open a PR against `main`.

Stop at the PR review checkpoint.

Report the changed behavior, validation results, and remaining preview limitations. Keep the patch focused on the stock Filesystem Tools presentation; do not fold unrelated editor or orchestration work into this task.
''';
