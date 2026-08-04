# ADELE Contract

`adele_contract` is an experimental public, pure-Dart package imported by
plugin contract source. It provides declaration annotations, the
transport-neutral `AdeleRequestChannel`, abstract `AdeleRemoteFailure` boundary
with an optional declared failure type identifier, and
`AdeleProtocolException` for malformed generated-protocol values.

Generated clients use `AdeleProtocolException` for local request preflight and
malformed responses. Generated dispatchers classify malformed request values as
`invalid_request`; constructor failures are opaque at both boundaries, including
when a contract constructor itself throws `AdeleProtocolException`.

Phase II contract source is an intentionally constrained IDL embedded in Dart,
not arbitrary Dart API source. Every schema-participating declaration and member
uses a public ASCII identifier matching `[A-Za-z][A-Za-z0-9_]*`; private,
dollar-prefixed, and non-ASCII schema names are rejected. These restrictions may
remain permanent and should only be relaxed for a concrete contract use case.

## Dependencies

Allowed dependencies are small, platform-neutral public packages required by
actual contract declarations. Flutter, analyzer internals, compiler packages,
`build_runner`, internal host packages, and plugin implementations are
prohibited.

## Deferred

The Phase II annotations cover async request/response services and immutable
values. Annotated values use one unnamed constructor with final fields and
matching required named field-formal parameters of exactly the same type.
Recursive annotated value schemas are rejected. JSON-compatible maps reject
active-path identity cycles and nesting deeper than 64 containers. Actions,
streams, cancellation, typed handles, compatibility
policy, and general schema evolution remain deferred. Serialization and
generation do not belong here; the separate internal `contract_codegen` package
owns them.
