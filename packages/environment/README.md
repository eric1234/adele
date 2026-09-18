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

Generated unary `AuthorizedEnvironmentReadService` is declared alongside the
provider service in `lib/adele_environment.dart`. It exposes `authority() ->
Future<AuthorizedEnvironmentIdentity>`, `readFile(String relativePath) ->
Future<EnvironmentTextFile>`, and `readDirectory(String relativePath) ->
Future<EnvironmentDirectoryListing>`. It reuses the existing file/directory DTOs
and declared `EnvironmentFailure` rather than flattening `not_found` or other
domain failures into generic transport errors. `authority()` takes no arguments
and returns the already-bound `sessionId` and `environmentId`. No method accepts
authority-selection IDs or exposes mutation/process operations; this service is
not a separately selected provider capability.

Separate generated unary `AuthorizedEnvironmentMutationService` exposes only
`createTextFile(relativePath, text)`, `replaceExistingTextFile(relativePath,
replacementText, expectedRevision)`, and `deleteExistingTextFile(relativePath,
expectedRevision)`. It reuses the provider's mutation results and declared
`EnvironmentFailure`, preserving create-new and revision-conditional semantics.
It has no authority query, authority-selection IDs, reads, or process methods.
The read service is unchanged; neither service implicitly grants the other.

Separate generated `AuthorizedEnvironmentProcessService` exposes exactly
`runForegroundProcess(EnvironmentForegroundProcessRequest request) ->
Stream<EnvironmentProcessEvent>`. It reuses existing process request/event DTOs and
declared `EnvironmentFailure`, with no authority query, authority-selection IDs,
reads, or mutations. It is an operation-scoped view of the captured
`AuthorizedEnvironmentProcessFacet`, not a separate provider capability or a
plugin-selected Environment. Neither filesystem host service grants process access.

For remote inference sources, the app captures canonical
`InferenceContextSourceContext`, obtains its `AuthorizedEnvironmentFileReadFacet`,
and validates exact authority around each read. A secure opaque per-operation host
context allowlists this service on the exact connection generation; transported
Session/Run IDs never select authority. Calls use the existing ports/framed host
and are revoked at operation settlement, retirement, and termination. Remote model
tools capture the read/mutation/process facets requested by exposure `hostServices` during
materialization, validating the same Session and Environment across facets. Every
captured exact binding is checked synchronously without re-resolution. Each tool's
required `executionHostServices` selects an exact allowed subset of those
dependencies. Materialize and argument validation receive no token; description
receives only pure identity data, including nullable Environment identity.
Only execution after policy/approval receives an operation token. Stream authority
starts on listen and ends on done, error, cancellation, or retirement.

Stock Search's AOT backend composes directory and file reads using its existing
pure-Dart semantics. Filesystem's AOT backend reuses its root tools: `read_file`
gets read only, `apply_patch`/`delete_file` get read and mutation, and `create_file`
gets mutation only. Command's AOT backend reuses its root `run_command` semantics
with process-only execution authority. Transported identities cannot choose an Environment. See
[operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).
Read/mutation host calls remain unary; process host calls use reverse server
streaming with one-item credit, pause/resume, and producer cancellation. Both
transport protocols are version 1 under the
[pre-release transport policy](../../docs/architecture/contracts-and-capabilities.md#transport-version-policy);
the installed manifest remains version 1.
Outer-operation settlement, cancellation, or retirement revokes authority
immediately and cancels owned reverse streams with bounded cleanup. This is not
general symmetric RPC, client/bidirectional streaming, ambient callbacks, or an OS
sandbox. Revocation does not roll back or cancel an already-started mutation.

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
