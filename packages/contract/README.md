# ADELE Contract

`adele_contract` is an experimental public, pure-Dart package imported by
plugin contract source. It provides declaration annotations, the
transport-neutral `AdeleRequestChannel`, structured `AdeleRemoteFailure`, and
`AdeleProtocolException` for malformed generated-protocol values.

## Dependencies

Allowed dependencies are small, platform-neutral public packages required by
actual contract declarations. Flutter, analyzer internals, compiler packages,
`build_runner`, internal host packages, and plugin implementations are
prohibited.

## Deferred

The Phase II annotations cover async request/response services and immutable
values. Actions, streams, cancellation, typed handles, compatibility policy,
and general schema evolution remain deferred. Serialization and generation do
not belong here; the separate internal `contract_codegen` package owns them.
