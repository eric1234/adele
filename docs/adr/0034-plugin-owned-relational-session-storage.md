# ADR 0034: Plugin-owned relational Session storage

## Status

Accepted.

Amends [ADR 0033](0033-durable-project-storage-and-provider-backing.md) narrowly:
durability now includes core Sessions and their Environment associations, plus
plugin-owned relational Session state through a shared service. Provider-selected
backing, app-private SQLite, owner semantics, and commit-before-publication remain.

Amends [ADR 0032](0032-remote-backend-extensions-use-operation-scoped-host-services.md)
only where it confines all host access to operation invocations: an explicit,
generation-scoped infrastructure grant now serves storage outside execution.
Model/tool/orchestration and Environment-facet authority remain operation-scoped;
semantic IDs still cannot manufacture execution authority.

## Context

Restoring Project, Task, and Environment records is insufficient if Session
identity, its selected strategy, and canonical strategy state disappear on restart.
Chat makes the need concrete, but its conversation and configuration are not
universal Session fields. Other plugins can own state associated with the same
Session without owning that identity or importing Chat.

Snapshots, user append, configuration, and lazy strategy materialization need
storage even when no Run operation is active. Reusing execution tokens would
couple durable state to the wrong lifetime or broaden execution authority. Letting
plugins open SQLite directly would instead bypass host-owned backing and connection
lifetime. The requirement is shared infrastructure, not a generic settings system
or complete execution recovery.

## Decision

### Core graph and publication

Keep one host-owned SQLite connection per open Project in app-private
`ProjectDatabase`. Core owner `dev.adele.product` includes
`adele_product_sessions(id, task_id, strategy_id)` and
`adele_product_session_environment_authority(session_id, environment_id)` alongside
its Project/Task/Environment tables. Stored authority is a semantic same-Task
association, not a serialized token, binding, or live facet.

`ProjectDatabase.loadProductGraph` supplies the complete semantic graph to
`InMemoryProductStore.publishRestoredProject`. Validate all values, relationships,
duplicates, orphans, and live identity conflicts before any live-store mutation;
every Session requires exactly one same-Task Environment authority. Reopen does
not resolve stored strategies, initialize plugin state, or materialize Environments.
The selected Project provider remains necessary to open backing. The live store
remains the canonical runtime graph, not a SQL facade.

Session creation validates Task, exact strategy, and Environment before ID
allocation, then revalidates the strategy and identity conflicts. SQL commits
Session and authority together before live publication. Failure publishes neither,
with no fallback. Explicit `createProject` remains volatile for fixtures.
Current core and Chat schemas each have only a version-1 pre-release baseline;
there is no retained history or compatibility reader for development schemas.

### Shared contract, private hosting

Introduce pure-Dart `adele_project_storage`, with
`lib/adele_project_storage.dart` as the public contract. `ProjectStorageService`
provides explicit durability lookup, owner-schema initialization, named-parameter
`SELECT` queries, and host-owned atomic `RelationalStatement` batches of `INSERT`,
`UPDATE`, or `DELETE` with optional expected-row checks. Statement-class checks
protect connection/transaction mechanics, not table ownership or SQL sandboxing.
`RelationalRow.values` and parameters admit strings, integers, and null.
Query responses fail beyond 1000 rows or 1 MiB rather than truncate. Owner schema
version is the migration list length; coordination is transactional.
The host validates every plugin migration statement before execution. Current
scripts allow only `CREATE TABLE`, which meets Chat's baseline needs; unsupported
forms, including transaction and connection control, are rejected. The storage
contract README defines the deliberately restricted script syntax.

A new package is justified by actual host/plugin sharing. This service is neither
an immutable product value, an orchestration operation, generic transport/channel
plumbing, a provider extension, nor concrete Chat behavior. Putting it in any of
those existing owners would weaken their boundaries. SQLite remains app-private;
plugins own their schema SQL, constraints, and domain validation.

The host resolves Session -> Task -> currently open durable Project without live
strategy or Environment resolution. `isDurableSession` is false only for an
explicitly volatile published Session; missing, closed, or failed storage throws.
Callers cannot supply an owner, backing path, or SQLite handle. Owner identity is
captured as `PluginId(connection.pluginId)` by `ProjectStorageHost` through
`projectStorageServices(lifecycle, connection)`.

This is not a malicious-plugin SQL sandbox. Session scope selects backing, not
row-level access. There is no SQL parser sandbox, table-prefix enforcement, or
row isolation. Stock SQL respects its semantic owner's tables and relational
foreign keys to core identities; arbitrary hostile SQL isolation is deferred.
No filesystem, model, tool, facet, or execution authority is granted by this API.

### Distinct infrastructure lifetime

`PluginBackendHost.startPlugin(createInfrastructureServices: ...)` calls the
factory with the actual connection. Bootstrap supplies one required opaque
`hostInfrastructureContext` string for that generation and its explicit service
allowlist. Backend support exposes `bindInfrastructure` separately from invocation
`bind`. Shared reverse envelopes require `hostContextKind` (`invocation` or
`infrastructure`) and `hostContext`; both protocols remain version 1, with coherent
artifact rebuilds and no legacy wire shape.

Backend activation retirement/rollback, stop, close, or termination revokes this
grant before asynchronous cleanup. Storage revalidates
`connection.validateInfrastructureContext` at actual service entry to reject calls
queued by generated dispatch before revocation. No backend storage service is
granted through operation tokens. `AdeleRuntime` constructs lifecycle first and
passes the generic factory through normal bootstrap for all connections, without
stock imports or plugin-ID special cases.

### Plugin state and failure boundaries

Chat owner `dev.adele.plugin.chat-strategy` owns `adele_chat_sessions` for
configuration/counter and `adele_chat_entries` for ordered canonical history.
The backend lazily initializes defaults only on first actual access to an
uninitialized Session, otherwise validates and restores state. Corruption is an
error, never a reset. A generation-local cache is not the durable source of truth.
Missing Chat leaves its tables and core Session association intact; explicit
strategy resolution fails, and a later fresh backend can load compatible state.

User append commits entry and counter before cache/return; configuration commits
both fields before cache mutation. Successful assistant history remains staged
until the existing host terminal `completed` acknowledgement, then commits to SQL
before canonical merge/return. Failed execution or a known failed transaction
does not publish staged history. There are no hidden retries or a new coordinator.

Host Run completion and plugin history persistence are separate boundaries. A
storage failure after host completion must surface while preserving honest
terminal evidence, not pretend the Run rolled back. Losing transport acknowledgement
after SQL commit leaves an uncertain outcome; a fresh backend reloads the source
of truth rather than silently retrying. Direct in-memory `ChatSessionStore` is
intentional; remote volatile operation requires explicit `isDurableSession` false,
not a storage-error fallback.

## Alternatives considered

- Keep Session and Chat volatile: preserves neither canonical identity nor strategy
  state across restart or backend replacement.
- Add Chat fields/opaque blobs to core Session or a universal key/value store:
  erases semantic ownership and the inspectable relational model.
- Let each plugin open its own database connection: bypasses host-selected backing,
  lifecycle, migration coordination, and core foreign-key relationships.
- Put the service in an existing product, orchestration, transport, extension, or
  Chat package: couples unrelated semantics rather than sharing the narrow API.
- Reuse operation tokens or expose unrestricted host RPC: either makes snapshots
  depend on a Run or broadens execution authority beyond its valid lifetime.
- Coordinate host Run completion and plugin SQL as one transaction: requires a
  new recovery protocol and misstates what can roll back after execution effects.
- Add hostile-SQL isolation now: requires a separate security design; owner labels
  and table naming are not an adequate substitute for one.

## Consequences

Core identity and plugin state can survive restart independently of installed or
active strategy implementations. Plugins retain domain ownership, while the host
retains backing, connection lifetime, and exact-generation access. This increases
transport/lifecycle obligations without turning storage into execution authority.
Synchronous SQLite can block the host; existing filesystem confinement and native
platform limits from ADR 0033 remain. Known transaction failures are atomic, but
transport uncertainty after commit is not an exactly-once guarantee.

Out of scope: durable Runs, live claims, execution evidence/activity, approval
restart, model-native replay, composer/Draft Request persistence, Task/Session
browsers, navigation or automatic selection/resume, Profiles, general settings,
configured-provider/credential management, workbench/window state, cloud sync, and
arbitrary malicious-plugin sandboxing.

Canonical details live in the [product model](../architecture/product-model.md#project-storage),
[plugin state boundary](../architecture/plugin-system.md#plugin-owned-state-and-persistence),
[contracts and authority](../architecture/contracts-and-capabilities.md#generation-scoped-infrastructure-access),
and [dependency rules](../architecture/dependency-rules.md).
[Testing guidance](../development/testing.md#application-validation-map) maps the
focused lifecycle, storage-host, Chat, and real-AOT integration checks; this record
does not claim test results or complete runtime restoration.
