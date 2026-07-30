# Workspace Demo Frontend

`workspace_demo_frontend` is the interpreted Flutter reference frontend. It is
a plugin implementation package, neither an ADELE public API nor an internal
host package.

It may depend on Flutter, `workspace_demo_contract`, and future public
plugin-facing UI APIs after those APIs are proven. The sibling backend, ADELE
internal packages, and `adele_desktop` are prohibited dependencies.

The direct compiler API persists this source to EVC. Interpreted code awaits a
typed directory listing and text read through a small bridge and renders the
result and supports interactive selection.

Compatibility details remain isolated in the app adapter: explicit
`Compiler.entrypoints`, `$Value`-preserving wrappers, an interpreted disposal
flag because `State.mounted` is unavailable, and explicit first/second buttons
because `dart_eval 0.8.5` miscompiles a captured loop index. These are not public
plugin contract conventions.
