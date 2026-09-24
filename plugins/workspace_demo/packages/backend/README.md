# Workspace Demo Backend

`workspace_demo_backend` is the pure-Dart/AOT backend reference implementation.
It is a plugin implementation package, neither an ADELE public API nor an
internal host package.

It may depend on `workspace_demo_contract`, public ADELE plugin-facing packages,
and full Dart libraries needed by proven backend behavior. Flutter, the sibling
frontend, ADELE internal packages, and `adele_desktop` are prohibited.
The host integration test uses `plugin_runtime` only as a development dependency;
backend production code and its AOT entrypoint do not import it.

It lists immediate children deterministically, reads strict UTF-8 regular
files, confines canonical paths to the configured development root, rejects
outside-root symlink targets, and owns the filesystem/service behavior.

The [entrypoint](bin/workspace_demo_backend.dart) wraps `WorkspaceDemoFileService`
in `WorkspaceDemoServiceDispatcher` from the [contract package](../contract/README.md).
Serialization, codecs, and typed dispatch come from that package's ignored local
generated part, not backend-owned manual wire bindings. The entrypoint registers
the dispatcher with `AdeleConfigurationContextRouter.single` using the bootstrap
configuration context and generated service ID, sends ready, and closes the router
before acknowledging shutdown. The backend runs in an external isolate group
inside the shared backend host.
