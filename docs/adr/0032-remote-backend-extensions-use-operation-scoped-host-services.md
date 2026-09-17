# ADR 0032: Remote backend extensions use operation-scoped host services

## Status

Accepted; unary host calls and remote inference-context sources implemented,
broader extension adaptation and reverse streaming deferred

## Context

ADELE supports independently installed AOT plugin backends and prepared EVC
frontends. The recursive typed extension model also permits plugins to contribute
behavior through public extension points. Some implementations of those contracts
need host-owned services tied to canonical Session, Run, and Environment authority,
rather than only data passed to a standalone backend service.

AGENTS.md makes this requirement concrete: an inference-context source must read
the current Session's authorized Environment. Filesystem, Search, Command, and
Chat extensions create related pressure for authorized effects and orchestration
services. The host owns the relevant authority and lifecycle; a plugin cannot
establish that authority by supplying a Session or Run identifier.

Keeping these plugin implementations statically linked into ADELE would weaken
the meaning of independently installed plugins. Conversely, a generic unrestricted
backend-to-host RPC surface would expose more host authority than an individual
extension operation requires and make its lifetime difficult to enforce.

The accepted [recursive extension model](0030-recursive-typed-plugin-extension-model.md)
and [Session/Environment ownership](0031-project-task-session-environment-domain-direction.md)
must apply across the backend boundary without introducing a parallel contribution
registry or moving host authority into plugins.

## Decision

1. A ready backend generation may advertise typed extension participation
   separately from capability providers. The extension point owns its metadata
   interpretation and semantic rules; the generic advertisement does not define
   universal extension semantics.
2. Host adapters for known public extension contracts register exact-generation
   proxy contributions in the existing `ExtensionRegistry`. There is no second
   contribution registry. Captured bindings do not silently retarget replacement
   generations, and activation owns coherent capability/extension rollback and
   retirement for each backend attempt.
3. Plugin identity remains connection-owned, not advertisement-owned. The host
   associates advertisements and requests with their exact backend generation.
4. Backend-to-host access exists only inside an invocation context created by the
   host for an extension operation. Readiness grants no ambient host-service
   access. The backend receives an opaque, unguessable invocation identity, not
   host implementation objects or a persistent general capability handle.
5. Each invocation context is bound to the exact backend generation and operation
   lifetime and exposes only an explicit host-service allowlist. Existing backend
   configuration routing remains distinct from this host authorization boundary.
6. Semantic identifiers such as `SessionId` and `RunId` do not grant or select
   host authority. The host captures the authoritative operation context and
   supplies services from that context rather than reconstructing authority from
   plugin-supplied identifiers.
7. Invocation authority is revoked when the operation settles, whether it succeeds
   or fails, and on registration or connection retirement. Revocation is
   idempotent; expired, foreign-generation, and unapproved-service calls fail.
   Revocation does not promise rollback or cancellation of effects already in
   flight.
8. The initial backend-to-host transport is unary and reuses the existing backend
   connection. It does not replace the generated host-to-plugin service path.
   Reverse streaming is added only when a concrete extension requires it, not as
   speculative symmetric RPC infrastructure.
9. Process and isolate separation provide isolation, not a security sandbox.
   Invocation checks govern the host-service API; they do not sandbox native
   backend code or arbitrary operating-system effects.
10. Installation, profile participation, ready exposure, and invocation authority
    remain separate concerns. Installation metadata describes prepared components,
    not capability/extension exposures or activation/profile state.
    Neither ready advertisements nor invocation contexts are persisted profile or
    configuration state.

## Alternatives considered

A new statically linked `host` or `host-linked` plugin component type is not
adopted as the normal solution. It would tie those plugin implementations to the
ADELE binary and its rebuild/deployment lifecycle instead of preserving independent
backend installation. Typed host adapters and narrow host services remain host
implementation facilities, not another plugin component type.

Unrestricted symmetric backend-to-host RPC is also rejected. A running generation
does not receive permanent access to host services, a general service locator, or
the ability to select authority by passing product identifiers. Services are
granted only for the host operation that requires them.

## Implementation status

AGENTS.md is the first implemented remote extension consumer. Its backend-only
installation advertises an inference-context source at readiness. A host proxy
uses the normal inference composer and supplies only an authorized Environment
text-file read service during each snapshot. The canonical Session Environment
authority remains host-owned; there is no static AGENTS.md activation in
`AdeleRuntime`.

This implements one remote extension point, not the complete recursive extension
system. Other statically composed stock plugins remain eligible for incremental
migration. Reverse streaming and Profiles remain unimplemented. Normal prepared
startup currently attempts valid discovered components; that startup policy does
not define profile participation or grant invocation authority.

## Consequences

- The normal installed AOT backend model can serve extensions that previously
  required in-process composition, without a new host-linked plugin component.
- Host authority remains explicit, operation-scoped, and bound to exact
  generations rather than semantic identifiers supplied by a plugin.
- Backend/runtime protocol and lifecycle handling become more complex, including
  nested request correlation, local failure containment, and revocation while
  requests are pending.
- Each remotely supported extension point needs a host adapter that understands
  its typed semantic contract and the host services appropriate to its operations.
- Future reverse-streaming requirements remain deliberately unsolved until a
  concrete extension establishes the required lifetime and control semantics.
- Remaining statically composed plugins can migrate incrementally without
  changing the existing contribution registry or completing all recursive
  extension mechanisms at once.

Current transport and authority rules are maintained in
[`contracts-and-capabilities.md`](../architecture/contracts-and-capabilities.md).
The implemented subset and broader typed composition model are maintained in
[`plugin-extension-model.md`](../architecture/plugin-extension-model.md).
