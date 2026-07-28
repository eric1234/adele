# Workspace Demo Backend

`workspace_demo_backend` is the future full-Dart/AOT backend package for the
workspace demo plugin. It is a plugin implementation package, neither an ADELE
public API nor an internal host package, and is a placeholder in Phase 0.

It may depend on `workspace_demo_contract`, public ADELE plugin-facing packages,
and full Dart libraries needed by proven backend behavior. Flutter, the sibling
frontend, ADELE internal packages, and `adele_desktop` are prohibited.

Filesystem access, AOT entry points, dispatch, transport, lifecycle, and reload
behavior are deferred to Phase 1.
