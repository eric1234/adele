# Filesystem Tools

Filesystem Tools is an independently activatable stock plugin that contributes
four model tools over one Session-authorized Environment filesystem authority:

- `read_file` (`dev.adele.plugin.filesystem-tools.read-file`)
- `apply_patch` (`dev.adele.plugin.filesystem-tools.apply-patch`)
- `create_file` (`dev.adele.plugin.filesystem-tools.create-file`)
- `delete_file` (`dev.adele.plugin.filesystem-tools.delete-file`)

No tool accepts an Environment ID. Paths are well-formed Unicode,
Environment-relative logical file paths canonicalized before policy and
execution. Reads return bounded UTF-8 text and a provider-produced opaque
revision.

`read_file(relativePath, startLine?, lineCount?)` reads the whole file when both
range arguments are omitted. Each range argument is independently optional:
`startLine` defaults to 1 and is 1-based; omitted `lineCount` means through EOF.
Both must be positive integers, and `lineCount` is a maximum number of logical
lines, not an ending line. Unknown arguments and alternate range grammars are
rejected.

Ranged results contain compact metadata and one exact, unnumbered source
substring. LF, CRLF, and lone CR delimit logical lines without normalization,
trimming, Unicode changes, or per-line shortening. A final terminator creates no
phantom line. Empty files and starts beyond EOF return explicit successful empty
selections. Finite counts extending beyond EOF return available lines. If later
source remains, `nextStartLine` and a model-visible next call retain the requested
finite count. Host evidence includes the selected text only, effective
`startLine`, `requestedLineCount`, `returnedLineCount`, `totalLines`, and nullable
`nextStartLine`, alongside ordinary file identity, whole-file size and revision.

The revision always identifies the complete observed file and can be passed
directly to `apply_patch`; outside-view changes still conflict and matching is
still unique across the whole file. The effect remains `sourceRead` targeting
the file itself. Filesystem Tools selects the view after the existing authorized
whole-file Environment read, subject to its unchanged size, UTF-8, accessibility,
and confinement rules. There is no provider-level ranged I/O or oversized-file
partial access yet, and no default window or new model-output cap.

`apply_patch(relativePath, expectedRevision, edits)` takes exactly those three
arguments. `edits` is a non-empty ordered array of objects with exactly `search`
and `replace` string fields. Each non-empty search must occur exactly once in
the current working string, using exact, case-sensitive, literal matching that
counts overlapping candidate starts. Replacement text may be empty, and neither
field is trimmed or normalized. Later edits see earlier replacements.

The tool reads once to preflight the original opaque `expectedRevision` before
matching any edit. Zero or multiple matches fail without any writes and report
the zero-based `failedEditIndex` and total `editCount`. An edit whose search and
replacement are identical fails with `no_change` and the same index/count
diagnostics. If the final working text equals the original, including when edits
cancel one another, `no_change` is reported without writing. Otherwise, after
every edit passes, the tool requests one conditional whole-file replacement with
the unchanged original revision as the final stale-write guard. Filesystem Tools
owns this model-facing patch grammar; Environment owns the conditional
replacement primitive.

Success returns model text with exactly three lines: `Patched: <JSON path>`,
`Edits applied: <editCount>`, and `Revision: <JSON new revision>`. Host data
contains `environmentId`, `relativePath`, `editCount`, and `newRevision`.

`create_file(relativePath, content)` creates a new bounded UTF-8 regular file
only when the target is absent. Empty content is valid, content is preserved
without trimming or normalization, and the parent directory must already exist.
It never falls back to overwrite and returns the resulting opaque revision.

`delete_file(relativePath, expectedRevision)` first reads the current file,
rejects a stale model revision, and then passes the original opaque token
unchanged to the Environment provider's final conditional deletion. It does not
delete directories or accept force/recursive behavior.

All mutation tools describe an exact `sourceMutation` target with no effect
uncertainty. Successful mutations are known to have occurred. A create
`file_already_exists` failure and a delete/patch `revision_conflict` are known
not to have occurred; unexpected failures after provider dispatch remain
uncertain.

The Environment provider enforces byte bounds, direct-path confinement,
symbolic-link policy, and concrete publication/deletion behavior. General
create-or-overwrite, directory mutation, move/copy, binary files, permissions,
and host-filesystem fallback remain unsupported. Deterministic real-Git
integration proves create -> read -> delete continuation; no paid create/delete
model smoke is claimed.
