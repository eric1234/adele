# ADELE Contract

`adele_contract` is an experimental public, pure-Dart package imported by
plugin contract source. It provides declaration annotations, the
transport-neutral `AdeleRequestChannel` and `AdeleStreamChannel`, abstract `AdeleRemoteFailure` boundary
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

## Contract source rules

Every contract library imports
`package:adele_contract/adele_contract.dart` exactly once in canonical form:
unprefixed, unconditional, and without `show` or `hide`. It imports
`package:adele_plugin_api/adele_plugin_api.dart` in that same canonical form
exactly when the extracted transported schema uses `ResourceRef`. A prefixed
plugin API import does not require the canonical import when `ResourceRef` is
absent.

Every additional import from either ADELE package must have a prefix. This
includes a second import of either canonical URI with `show` or `hide`, as well
as imports of another library within those packages. Every unrelated import must
also have a prefix. Any conditional import whose default or configured URI is
within `adele_contract` or `adele_plugin_api` is rejected, whether prefixed or
not.

Generated unqualified ADELE names and SDK names are reserved against all
top-level declarations and import prefixes. This includes the annotation and
transport surface, generated clients and dispatchers, codec helpers, `String`,
`bool`, `int`, `double`, `List`, `Map`, `Uri`, `Object`, `Future`, `Stream`, and
`Exception`. `ResourceRef` and its codec helper names are reserved only when the
extracted schema uses `ResourceRef`. All derived generated identifiers and every
unconditional or conditional top-level declaration share the same collision
namespace.

Transported SDK types are recognized by semantic declaration identity, not by
name: core types must resolve to `dart:core`, and the outer service return
`Future` or `Stream` must resolve to `dart:async`. `ResourceRef` must resolve to the
canonical plugin API declaration. Same-named local, imported, or prefixed
lookalikes are unsupported. Typedefs and other analyzer aliases are rejected at
every transported type position, including aliases nested in nullable values or
lists and an alias for the outer `Future` or `Stream`; aliases unused by the schema remain
allowed.

Each service method is abstract, non-static, non-operator, and returns
`Future<T>` or `Stream<T>`. Parameters must be explicitly typed, required positional
parameters; optional, named, covariant, initializing-formal, super-formal,
function-typed, stream-typed, and implicitly dynamic parameters are rejected.
Streaming is server-only; `Stream<void>`, nested streams, client streaming, and
bidirectional streaming are unsupported. Wildcard or otherwise unnamed parameters are unsupported
because every transported parameter requires a stable schema name.

Generator failures are reported as `ContractDiagnostic` values with the source
path and one-based line and column. Diagnostics are attached to the most precise
relevant declaration or type node: imports, annotations, services, methods,
parameters, fields, constructors, enums, and enum values retain their own source
locations; whole-library constraints point at the compilation unit.

## Dependencies

Allowed dependencies are small, platform-neutral public packages required by
actual contract declarations. Flutter, analyzer internals, compiler packages,
`build_runner`, internal host packages, and plugin implementations are
prohibited.

## Deferred

The Phase II annotations cover unary and server-streaming services and immutable
values. Annotated values use one unnamed constructor with final fields and
matching required named field-formal parameters of exactly the same type.
Recursive annotated value schemas are rejected. JSON-compatible maps reject
active-path identity cycles and nesting deeper than 64 containers. Actions,
client/bidirectional streaming, replay, typed handles, compatibility policy,
and general schema evolution remain deferred. Serialization and
generation do not belong here; the separate internal `contract_codegen` package
owns them.
