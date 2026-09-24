# ADR 0033: Durable Project storage and provider-selected backing

## Status

Accepted.

Amends [ADR 0031](0031-project-task-session-environment-domain-direction.md) for
Project opening and storage: a selected source now passes through an explicit
Project provider before host-owned durable publication. Its product identities,
semantic ownership, and separation from live bindings remain unchanged. This also
extends the narrow core-extension example in
[ADR 0030](0030-recursive-typed-plugin-extension-model.md), without creating another
public package or moving unrelated extension contracts.

## Context

A Project needs an identity that survives application restart and movement of its
backing, rather than a new identity each time a selector returns a URI. That need
does not make all product state persistent, turn Project into a local-directory
type, or give a presentation plugin ownership of lifecycle or filesystem authority.

Project implementations need to describe their backing policy independently of
UI. At the same time, the host must control database access, confinement, schema
coordination, and publication of canonical identities. Ordinary inspectable SQL
keeps storage understandable to developers and external tools without introducing
an opaque universal state store or prematurely designing a plugin persistence API.

## Decision

### Storage and ownership

Use one ordinary SQLite database per Project, with explicit SQL tables and
migrations. The Project implementation establishes/describes its backing and
chooses its location. The initial descriptor uses a confined source-relative
database path; the host validates and opens it. The stock Local Directory provider's
`.adele/data.db` placement is implementation policy, not a universal core path.

The application-private `ProjectDatabase` hosts `sqlite3`. Core owns Project
identity, its SQL schema and migration steps, and commit-before-publication.
Migration coordination records versions by semantic owner and applies ordered
upgrades transactionally. Storage support does not transfer another owner's
semantics into core: future strategy/plugin tables remain their owners' concern.
There is no opaque key/value envelope, ORM, public database handle, or general
plugin migration registry in this decision. The canonical current schema and
failure rules live in the [product model](../architecture/product-model.md#project-storage).

Malformed or newer unsupported core storage must fail non-destructively,
without reset, replacement identity, downgrade, or silent volatile fallback.
Unknown owners and their tables remain intact.
Moving a Project with its database preserves its ID; opening at the new source
refreshes the stored source location. This is not a catalog, cloud synchronization,
or Environment restoration mechanism.

### Selection and backing contract

The existing pure-Dart `adele_core_extensions` owns both narrow contracts.
`ProjectSelectorContribution` retains its `selectProject` callback and requires
an explicit `projectProviderId`. Selection supplies a source URI or cancellation;
the host resolves that exact provider, not a default substitute.
`ProjectProviderService.prepareSource` returns an immutable `ProjectBacking`
describing the selected source and relative database location. It neither creates
a Project identity nor opens storage. `adele_product` remains an immutable-value
and identity package, not the owner of executable provider or SQLite APIs.

Local Directory uses an independently prepared pure-Dart AOT backend under the
same plugin identity as its interpreted Flutter selector. The frontend retains
lexical path conversion and the app-native picker bridge; the backend owns source
suitability and backing placement. The host independently enforces filesystem
authority and confinement. A headless caller can supply a known source and exact
provider binding without loading a frontend. Production app code imports no
concrete plugin and provides no missing-provider fallback.

### Exact operations and lifetime

Every prepared selector requires the Project capability registration owned by the
exact ready backend from the same `PreparedPluginInstallation`. Generic
registration ownership checks establish that relationship; matching `PluginId`
or provider identity is insufficient. This is mandatory, not an optional affinity
enum or a stock-plugin exception. Independent component activation does not mean
an operation requiring both may run with a missing counterpart.

Capture and validate the frontend selection and provider before the picker, after
the picker, and after provider preparation. Only then may the host accept backing,
perform synchronous SQLite transactions, and publish the canonical live Project
after its identity/source commit. Retired generations cannot be replaced inside
the operation. After successful publication, the Project is not permanently
pinned to either generation, and no executable binding is serialized.

Runtime shutdown stops admission of new lifecycle work and joins in-flight Project
opens and database closure with backend teardown. Teardown must start without
waiting for preparation so normal connection revocation can settle remote opens.
Existing window-owned Task establishment and Run draining retain their owner;
this does not introduce
general cancellation, rollback of external effects, or a shutdown deadline.

## Alternatives considered

- Keep Project entirely in memory: cannot preserve identity across restart or a
  move, and makes repeated selection manufacture another Project.
- Let the frontend create identities or open SQLite: ties durable semantics to
  optional presentation and bypasses host authority and headless composition.
- Fix one database path in core: unnecessarily makes stock local-directory policy
  universal for other Project implementations.
- Persist opaque blobs through a generic key/value store or adopt an ORM: obscures
  the small relational model and migrations without a concrete requirement.
- Build a public persistence/migration framework now: broadens a Project-only
  requirement into unresolved plugin, configuration, and distributed-state APIs.

## Consequences

Only Project identity and source are durable in the current implementation.
Tasks, Environments and provider state, Sessions and authority, Runs, Chat,
configuration, Profiles, and general plugin state gain no disk persistence.
`createProject` remains explicitly volatile for development and deterministic
fixtures, not a fallback for failed durable opening.

The host now needs writable native access to the selected backing. On macOS this
requires user-selected read-write access rather than the picker-only read-only
entitlement; native wiring is not evidence of macOS or Windows build success.

Small synchronous SQLite operations keep acceptance, commit, and publication
free of asynchronous generation changes, but can block the host during I/O or
locking. Filesystem preflight confinement is not protection against hostile
concurrent symlink replacement. Git-ignore ergonomics remain follow-up work,
without automatic edits to a user's root ignore rules. Moved retained Environment
state is not restored by Project source refresh. A future cloud-backed Project
may materialize or synchronize its SQLite backing differently; that protocol,
remote SQL, and a public migration registry remain deferred.
