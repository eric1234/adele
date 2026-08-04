# ADR 0020: Experimental contracts generate typed request/response transport

## Status

Accepted for the Phase II experimental foundation

## Context

Phase I proved the shared backend-host process and one external AOT isolate
group per active plugin. `workspace_demo` still duplicated method names,
serialization, response validation, and dispatch in handwritten app and backend
code. ADR 0013 requires declarations and generation to remain separate.

## Decision

`adele_contract` provides explicit service, method, value, field, and failure
annotations, a transport-neutral request channel, an abstract structured remote
failure boundary, and a protocol exception. Contract source is
authoritative. The internal analyzer-based `contract_codegen` package validates
the annotated source and deterministically emits committed client, codec, and
dispatcher files.

Generated clients depend only on `AdeleRequestChannel`. The internal
`PluginBackendConnection` implements that interface and remains responsible for
adapting generated requests to the Phase I runtime. Generated dispatchers own
ordinary contract requests only. Plugin entrypoints retain the reserved
`shutdown` lifecycle branch.

Each Phase II contract declaration library contains exactly one non-empty
annotated service, with a client and dispatcher generated for that service.
Dispatch is staged as
envelope validation, method classification, selected payload validation, service
invocation, and result encoding. This ordering ensures an unknown method is
reported as `unknown_method` without interpreting its payload. `Uri` is a string
scalar on the wire and is reconstructed with `Uri.parse`; `ResourceRef` is
encoded as its URI string and nullable media type.

Generation is explicit through `dart tools/adele.dart generate`. Root `check`
and CI verify generated files before analysis or smoke execution. The plugin
builder resolves and verifies the selected plugin's own contract source before
backend compilation. Generated files are derived artifacts and do not replace
contract declarations as the source of truth.

The annotation import is canonical, unprefixed, and has no combinators or
configurations. The plugin API import has the same shape exactly when
`ResourceRef` occurs in the extracted schema. Additional imports from either
canonical package and every other import are prefixed. Conditional imports
involving either canonical package are rejected. Import prefixes participate in
the generated top-level collision namespace.

## Consequences

- Typed request/response transport is implemented for `workspace_demo` without
  changing process framing, host request correlation, isolate containment,
  bounded shutdown, restart, or eval bridge behavior from ADR 0019.
- Stable wire namespaces and method names are explicit annotations rather than
  inferred solely from Dart symbol names.
- Plugin contract packages do not depend on analyzer, compiler, builder,
  runtime, backend-host, or Flutter packages.
- Only failures carrying the contract's explicit `declaredFailureType` become
  contract-specific failures at the generated client boundary. Transport and
  lifecycle failures remain runtime failures; malformed values raise
  `AdeleProtocolException`.
- Generated failure responses have `kind: response`, an integer `requestId` when
  the request supplied one, `ok: false`, and an `error` map containing optional
  `declaredFailureType`, `code`, `message`, and recursively JSON-compatible
  `details`. Invalid declared-failure details or an unencodable backend result
  become an opaque `backend_contract_violation` with no declared type and empty
  details; undeclared service exceptions become opaque `internal_error` values.
- The generator and annotation API remain experimental. General schema
  compatibility, streams, cancellation, events, capability resolution,
  discovery, packaging, and security sandboxing remain deferred.
- The supported schema is deliberately local and unary: imported annotated
  schema, multiple or empty services, non-reconstructible failures, malformed
  or relative URIs, non-finite doubles, positional value construction, and
  permissive wire identifiers are rejected rather than becoming compatibility
  commitments.
- Contract source is a constrained IDL embedded in Dart. Annotated service,
  value, and failure names, their transported members and validated constructor
  parameters, and reachable enum names and values must match
  `[A-Za-z][A-Za-z0-9_]*`. Private, dollar-prefixed, and non-ASCII schema names
  are rejected; unreachable private helpers and enums remain outside the schema.
  This restriction may be permanent.
- Annotated values require exact required named field-formal reconstruction and
  cannot form schema cycles through nullable values or lists. Decoders validate
  fields before entering an opaque constructor boundary that catches every
  constructor exception; declared-failure reconstruction is contained likewise.
- JSON-compatible maps detect cycles by identity on the active traversal path,
  so shared acyclic references remain valid, and conservatively reject nesting
  deeper than 64 containers.
- Service declarations reject constructors, fields, getters, setters, static or
  concrete methods, and operators. Generation rejects collisions among emitted
  public and private symbols and all source top-level declarations before
  writing source. Generic annotated values, failures, and services are rejected,
  and the generated part is the exact sibling `<source-basename>.g.dart`.
- Annotation collection rejects repeated role, method, and field annotations
  and mixed class roles without depending on metadata order. Generated members
  and locals use reserved indexed `_adele` names; schema methods such as
  `dispatch` coexist with generated client and dispatcher APIs without a scope
  allocator. All source-derived Dart strings pass through one single-quoted
  literal escaper.
- Generated unqualified ADELE runtime and SDK names are reserved, with
  `ResourceRef` reserved conditionally. Supported SDK types are accepted only
  from their exact `dart:core` or `dart:async` libraries, and `ResourceRef` only
  from its canonical plugin API declaration; same-named lookalikes are rejected.
- Analyzer aliases are rejected recursively through nullable, list, enum,
  annotated-value, `ResourceRef`, imported, and chained schema positions,
  including an alias for the outer `Future`. Unused aliases outside the schema
  remain ordinary implementation details. Diagnostics identify the precise
  method, parameter, field, or enum-value declaration involved.
