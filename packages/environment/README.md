# ADELE Environment

`adele_environment` defines one coherent Environment provider capability for
establishment, restoration, bounded text-file reads, conditional replacement of
existing text files, direct-child directory listings, and bounded foreground
process execution. It uses ADELE's generated contract transport and existing
capability registry.

The wire carries a narrow closed snapshot of the relevant Environment, Task,
and Project values. The backend adapter reconstructs fresh canonical product
values and a component-local `LocalEnvironment`, so provider code can navigate
`environment.task.project` without host callbacks or transparent remote
objects. `GeneratedEnvironmentProvider` performs the inverse host adaptation.

Each text-file read carries a provider-produced opaque revision. Replacement
requires the observed revision and returns the post-write revision; providers
must reject a detected mismatch without performing the requested write. The
contract does not define the revision representation or promise atomicity
against writers outside a provider's coordination mechanism.

The package also defines one Session/Environment authority identity with
coherent filesystem, read, mutation, and process views. Facets are operation
views over the same authorized provider materialization, not separately selected
Environment identities. The mutation facet exposes conditional existing-file
replacement; Filesystem Tools remains responsible for patch interpretation and
the model-facing `apply_patch` contract, while Search Tools consumes only the
read facet and Command Tools consumes only the process facet for `run_command`.

`runForegroundProcess` accepts a non-empty program, an immutable ordered
argument vector, an Environment-relative working directory, and a required
timeout from 1 through 600 seconds. It has no implicit shell semantics. Its
generated server stream carries non-empty UTF-8 text observations tagged as
stdout or stderr, followed by one completed event for normal exit or timeout.
Nonzero exit codes are ordinary process results. Providers bound retained and
emitted output independently for each stream and report truncation in the
completed event.

New-file creation, deletion, general write semantics, recursive search,
model-facing command policy/classification, background processes, process identity,
stdin/PTY support, arbitrary environment overrides, release/destruction,
complete Session lifecycle, and persistence remain outside this package in this
round.
