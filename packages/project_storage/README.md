# ADELE Project Storage

`adele_project_storage` is the pure-Dart public contract for host-mediated,
Session-scoped relational storage. It depends only on `adele_contract`; it exposes
neither SQLite objects nor database paths, filesystem operations, or execution
authority. The application and the stock Chat backend are its concrete consumers.

This service has a separate package because persistence is neither an immutable
product value, an orchestration operation, a provider-selection extension point,
nor generic transport machinery. Its schema semantics belong to the calling
plugin; the application-private `ProjectDatabase` owns the shared connection.
See [dependency rules](../../docs/architecture/dependency-rules.md) and
[ADR 0034](../../docs/adr/0034-plugin-owned-relational-session-storage.md).

## Service

`ProjectStorageService` is supplied through an exact backend generation's
infrastructure context, not through a Run's `hostInvocationContext` and not through
Capability discovery. The host derives the schema owner from that connection's
`PluginId`. Requests contain no owner, Project override, path, or generation ID.

Every method takes a core Session ID. The host validates Session -> Task -> open
Project without resolving a strategy or materializing an Environment.

| Method | Semantics |
| --- | --- |
| `isDurableSession` | False only for a published Session in an explicitly volatile Project. Unknown Sessions, closed lifecycle, and storage errors fail. |
| `ensureSchemaForSession` | Validate all migration statements before execution, then apply supported `CREATE TABLE` statements and owner-version metadata atomically. The list length is the current version; each entry advances it once, starting at 1. Current pre-release owners supply only their current v1 baseline. |
| `queryForSession` | Execute one read-only `SELECT` statement and return immutable `RelationalRow.values` maps. |
| `transactionForSession` | Commit a host-owned transaction of `INSERT`, `UPDATE`, or `DELETE` statements; an unsupported statement, SQL error, or `expectedRows` mismatch rolls back the batch. |

The latter three methods require a durable Project. Explicit volatility is not a
fallback after failure. State initialization is separate from core Session
creation; a plugin may lazily create its own rows on first actual state access.

Named SQL parameters include the SQLite parameter prefix, for example SQL
`WHERE session_id = :session` with parameters `{':session': sessionId}`. Parameters
and row values support only strings, integers, and null. Transport maps are not an
opaque JSON storage format. SQL tables remain ordinary inspectable relational data.

A query response is bounded to 1,000 rows and 1 MiB of encoded row data. Excess or
unsupported values fail rather than truncate; consumers must page larger histories.
A single oversized row fails explicitly. Queries require unique column names.
Queries and batch operations must begin with their supported keyword after any
leading whitespace; keyword case does not matter. Leading comments, `WITH`, and
other statement classes are rejected before SQLite prepares them. Each operation
must contain exactly one statement, optionally ending with a semicolon. Embedded
semicolons, including those in literals/comments, are rejected without parsing;
values containing semicolons must use parameters. This also prevents the SQLite
library's trailing-statement check from preparing rejected SQL with side effects.
These restrictions protect host-owned connection and transaction mechanics:
SQLite's `isReadOnly` alone does not do so.

Schema migrations have a separate, deliberately narrow grammar: one or more
`CREATE TABLE` statements separated by semicolons, with optional trailing
semicolons and whitespace. Keyword case does not matter. This is sufficient for
the current Chat v1 baseline; other CREATE forms, DDL, and DML are not supported
in plugin migrations yet. The host validates every statement of every supplied
script before entering the migration coordinator, then executes the validated
statements individually inside the existing host-owned transaction.

Migration SQL rejects comment markers (`--`, `/*`, `*/`), NUL, double quotes,
backticks, and square brackets, even inside literals. Single-quoted literals
must be balanced within each semicolon-delimited statement; doubled single-quote
escapes work, but semicolons inside literals do not. Unsupported syntax/classes
are rejected before any SQL is prepared or executed. In particular, plugins
cannot issue `BEGIN`, `COMMIT`, `END`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, `PRAGMA`,
`ATTACH`, `DETACH`, or `VACUUM` through migration scripts. SQLite syntax errors in
otherwise allowed statements still roll back the whole migration and its version
metadata. This enforces host transaction/connection integrity, not table/row SQL
isolation.

## Ownership And Failure

One Project database serves core and plugin owners. Plugins operate on their own
tables and may reference published core identities by foreign key, but must not
mutate or redefine core rows. Session scope selects the Project database; it is not
row-level SQL isolation. The current native plugin model is not a malicious-SQL
sandbox, SQL parser, or table-prefix enforcement framework. Arbitrary plugin-to-
plugin relational contracts remain deferred.

The host revalidates generation access when a queued service method actually runs.
Generation retirement revokes access; a replacement needs a fresh context and
loads durable state anew. Grant tokens are transient transport authority, never
persisted state. Normal writes commit before successful responses, but loss of a
transport acknowledgment after commit can leave an uncertain caller outcome. There
is no automatic retry, operation deduplication, or distributed transaction with
Runs/model/tool effects.

## Validation

`lib/adele_project_storage.dart` is the declaration source. Its generated sibling
is ignored and materialized through `dart tools/adele.dart generate`. Contract
round-trip, immutable-data, and scalar-subset tests run with:

```sh
dart tools/adele.dart test --target adele_project_storage
```

Application integration lives in `app/test/core/project_storage_host_test.dart`
and `app/test/core/durable_chat_session_integration_test.dart`. See the canonical
[testing map](../../docs/development/testing.md) and
[generation-scoped host services](../../docs/architecture/contracts-and-capabilities.md).
