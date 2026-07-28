# ADELE Contract

`adele_contract` is an experimental public, pure-Dart package imported by
plugin contract source. Phase 0 intentionally exposes no declarations beyond
the library boundary.

## Dependencies

Allowed dependencies are small, platform-neutral public packages required by
actual contract declarations. Flutter, analyzer internals, compiler packages,
`build_runner`, internal host packages, and plugin implementations are
prohibited.

## Deferred

Typed async service declarations, immutable values, actions, streams,
structured errors, typed handles, serialization metadata, and stable type and
method identifiers are deferred until needed. Serialization and generation do
not belong here. Future generation will use an internal package such as
`contract_codegen`, created only when implementation starts.
