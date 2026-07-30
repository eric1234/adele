# Workspace Demo Backend

`workspace_demo_backend` is the pure-Dart/AOT backend reference implementation.
It is a plugin implementation package, neither an ADELE public API nor an
internal host package.

It may depend on `workspace_demo_contract`, public ADELE plugin-facing packages,
and full Dart libraries needed by proven backend behavior. Flutter, the sibling
frontend, ADELE internal packages, and `adele_desktop` are prohibited.

It lists immediate children deterministically, reads strict UTF-8 regular
files, confines canonical paths to the configured development root, rejects
outside-root symlink targets, and owns the manual dispatcher/backend codec. It
runs in an external isolate group inside the shared backend host.
