# Workspace Demo Frontend

`workspace_demo_frontend` is the interpreted Flutter source package for the
Phase 1 proof. It is a plugin implementation package, neither an ADELE public
API nor an internal host package.

It may depend on Flutter, `workspace_demo_contract`, and future public
plugin-facing UI APIs after those APIs are proven. The sibling backend, ADELE
internal packages, and `adele_desktop` are prohibited dependencies.

The direct compiler API persists this source to EVC. Interpreted code awaits a
typed directory listing and text read through a small bridge and renders the
result. Due to a documented `dart_eval` async/stateful unboxing limitation, the
current proof selects the first regular file rather than providing interactive
selection.
