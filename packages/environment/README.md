# ADELE Environment

`adele_environment` defines one coherent Environment provider capability for
establishment, restoration, bounded text-file reads, create-new text files,
conditional replacement and deletion of existing text files, direct-child
directory listings, and bounded foreground process execution. It uses ADELE's
generated contract transport and existing capability registry.

The wire carries a narrow closed snapshot of the relevant Environment, Task,
and Project values. The backend adapter reconstructs fresh canonical product
values and a component-local `LocalEnvironment`, so provider code can navigate
`environment.task.project` without host callbacks or transparent remote
objects. `GeneratedEnvironmentProvider` performs the inverse host adaptation.

Each text-file read carries a provider-produced opaque revision. Creation
requires an absent target and returns the resulting revision. Replacement
requires the observed revision and returns the post-write revision. Deletion
requires the observed revision and returns no post-delete revision. Providers
must reject detected stale replacement/deletion without performing the requested
mutation, and the shared `file_already_exists` creation failure guarantees that
no file was created or replaced. The contract does not define the revision
representation or promise atomicity against writers outside a provider's
coordination mechanism.

The package also defines one Session/Environment authority identity with
coherent filesystem, read, mutation, and process views. Facets are operation
views over the same authorized provider materialization, not separately selected
Environment identities. The mutation facet exposes create-new, conditional
existing-file replacement, and revision-conditional deletion. Filesystem Tools
remains responsible for the model-facing `create_file`, `apply_patch`, and
`delete_file` contracts, while Search Tools consumes only the read facet and
Command Tools consumes only the process facet for `run_command`.

F3a also defines generated unary `AuthorizedEnvironmentReadService` alongside the
provider service in `lib/adele_environment.dart`. Its sole operation is
`readFile(String relativePath) -> Future<EnvironmentTextFile>`, reusing the same
file DTO and declared `EnvironmentFailure` rather than flattening `not_found` or
other domain failures into generic transport errors. It has no authority-ID
arguments, directory reads, mutation, or process methods and is not a separately
selected provider capability.

For remote inference sources, the app captures canonical
`InferenceContextSourceContext`, obtains its `AuthorizedEnvironmentFileReadFacet`,
and validates exact authority around each read. A secure opaque per-operation host
context allowlists this service on the exact connection generation; transported
Session/Run IDs never select authority. Calls use the existing ports/framed host
and are revoked at operation settlement, retirement, and termination. See
[operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).
This adds neither reverse streaming nor a sandbox.

`runForegroundProcess` accepts a non-empty program, an immutable ordered
argument vector, an Environment-relative working directory, and a required
timeout from 1 through 600 seconds. It has no implicit shell semantics. Its
generated server stream carries non-empty UTF-8 text observations tagged as
stdout or stderr, followed by one completed event for normal exit or timeout.
Nonzero exit codes are ordinary process results. Providers bound retained and
emitted output independently for each stream and report truncation in the
completed event.

General create-or-overwrite semantics, directory/move/copy/binary mutation,
recursive search, model-facing command policy/classification, background
processes, process identity, stdin/PTY support, arbitrary environment overrides,
release/destruction, complete Session lifecycle, and persistence remain outside
this package in this round.
