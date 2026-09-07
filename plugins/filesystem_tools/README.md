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
revision. `apply_patch` replaces one exact unique literal occurrence and uses
the observed revision for conditional existing-file replacement.

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
