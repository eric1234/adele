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

Generation is explicit through `dart tools/adele.dart generate`. Root `check`
and CI verify generated files before analysis or smoke execution. The plugin
builder resolves and verifies the selected plugin's own contract source before
backend compilation. Generated files are derived artifacts and do not replace
contract declarations as the source of truth.

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
- The generator and annotation API remain experimental. General schema
  compatibility, streams, cancellation, events, capability resolution,
  discovery, packaging, and security sandboxing remain deferred.
- The supported schema is deliberately local and unary: imported annotated
  schema, multiple or empty services, non-reconstructible failures, malformed
  or relative URIs, non-finite doubles, positional value construction, and
  permissive wire identifiers are rejected rather than becoming compatibility
  commitments.
