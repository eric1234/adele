# ADELE Environment

`adele_environment` defines one coherent Environment provider capability for
establishment, restoration, bounded text-file reads, and direct-child directory
listings. It uses ADELE's generated contract transport and existing capability
registry.

The wire carries a narrow closed snapshot of the relevant Environment, Task,
and Project values. The backend adapter reconstructs fresh canonical product
values and a component-local `LocalEnvironment`, so provider code can navigate
`environment.task.project` without host callbacks or transparent remote
objects. `GeneratedEnvironmentProvider` performs the inverse host adaptation.

Mutation, recursive search, command execution, release/destruction, Session
authority, and persistence remain outside this package in this round.
