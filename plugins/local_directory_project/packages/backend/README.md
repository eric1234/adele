# Local Directory Project Backend

`local_directory_project_backend` is the pure-Dart AOT backing provider
for `dev.adele.plugin.local-directory-project`. Its sibling interpreted
Flutter selector is optional for headless use and is not an implementation
dependency. See the [plugin map](../../README.md) for composition and preparation.

## Ownership

[`LocalDirectoryProjectProviderService`](lib/local_directory_project_backend.dart)
implements public `ProjectProviderService.prepareSource`. It validates local source
URI semantics and returns `ProjectBacking` with the unchanged source and relative
path `.adele/data.db`. That path is this implementation's policy, not a core
constant. It rejects non-file sources, network authorities/UNC backing,
query/fragment components, malformed segments, and unsupported Windows drive paths.

Preparation is descriptive: it creates no directories, opens no SQLite connection,
and allocates no Project identity. The host independently validates existence,
access/confinement, and symlinks and owns schema/migrations, identity publication,
and database lifetime. Git suitability and Task/Environment behavior are not this
provider's responsibility. See [Project storage](../../../../docs/architecture/product-model.md#project-storage)
for the canonical storage and failure boundaries.

## Service And Hosting

- Provider ID: `dev.adele.project.local-directory`.
- Capability: `dev.adele.project.provider`, major version 1.
- Generated service constant: `projectProviderServiceId`, value
  `dev.adele.project.provider`.
- Entrypoint: [`bin/local_directory_project_backend.dart`](bin/local_directory_project_backend.dart).

The entrypoint advertises its capability on readiness and dispatches the generated
service in the supplied configuration context. It accepts no plugin startup
arguments and needs no credentials or host invocation authority. Contract values,
client/dispatcher, and generation inputs belong to
[`adele_core_extensions`](../../../../packages/core_extensions/README.md), not a
new plugin contract package.

The shared backend host loads the prepared AOT artifact; normal app code imports
no plugin implementation. Headless durable opening uses a known source and an
explicit exact provider binding. The prepared frontend additionally requires that
registration to belong to its exact ready backend installation, not merely share
semantic IDs. Missing or retired providers fail without fallback.

## Validation

From the repository root, use
`dart tools/adele.dart test --target local_directory_project_backend`.
The package participates in root workspace membership and maintained analysis/test
discovery. App lifecycle tests own database publication, reopen/move, and
confinement checks; prepared composition and launcher checks belong to the app and
`test/tools`. Package validation is not macOS/Windows native build proof.
