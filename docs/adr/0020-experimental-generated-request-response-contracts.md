# ADR 0020: Experimental contracts generate typed request/response transport

## Status

Accepted for the Phase II experimental foundation

## Context

Phase I proved the shared backend-host process and one external AOT isolate
group per active plugin. `workspace_demo` still duplicated method names,
serialization, response validation, and dispatch in handwritten app and backend
code. ADR 0013 requires declarations and generation to remain separate.

## Decision

`adele_contract` provides lightweight annotations, a transport-neutral request
channel, structured remote failure, and protocol exception. Contract source is
authoritative. The internal analyzer-based `contract_codegen` package validates
the annotated source and deterministically emits committed client, codec, and
dispatcher files.

Generated clients depend only on `AdeleRequestChannel`. The internal
`PluginBackendConnection` implements that interface and remains responsible for
adapting generated requests to the Phase I runtime. Generated dispatchers own
ordinary contract requests only. Plugin entrypoints retain the reserved
`shutdown` lifecycle branch.

Generation is explicit through `dart tools/adele.dart generate`. Root `check`
and `plugin_builder` verify generated files before analysis, tests, or backend
compilation. Generated files are derived artifacts and do not replace contract
declarations as the source of truth.

## Consequences

- Typed request/response transport is implemented for `workspace_demo` without
  changing process framing, host request correlation, isolate containment,
  bounded shutdown, restart, or eval bridge behavior from ADR 0019.
- Stable wire namespaces and method names are explicit annotations rather than
  inferred solely from Dart symbol names.
- Plugin contract packages do not depend on analyzer, compiler, builder,
  runtime, backend-host, or Flutter packages.
- Structured transport failures become contract-specific failures at the
  generated client boundary; malformed values raise `AdeleProtocolException`.
- The generator and annotation API remain experimental. General schema
  compatibility, streams, cancellation, events, capability resolution,
  discovery, packaging, and security sandboxing remain deferred.
