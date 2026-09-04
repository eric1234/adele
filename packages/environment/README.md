# ADELE Environment

`adele_environment` defines one coherent Environment provider capability for
establishment, restoration, bounded text-file reads, conditional replacement of
existing text files, and direct-child directory listings. It uses ADELE's
generated contract transport and existing capability registry.

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

New-file creation, deletion, patch semantics, model-facing mutation tools,
recursive search, command execution, release/destruction, Session mutation
authority, and persistence remain outside this package in this round.
