# ADR 0032: Remote backend extensions use operation-scoped host services

## Status

Accepted; unary read/mutation and bounded server-streaming process host calls,
remote inference-context sources, remote model tools, and generation-bound remote
orchestration strategies implemented; broader
extension adaptation, client/bidirectional streaming, and ambient callbacks deferred

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
   or fails, on stream cancellation, and on registration or connection retirement.
   Revocation is idempotent; expired, foreign-generation, and unapproved-service calls fail.
   Revocation does not promise rollback or cancellation of effects already in
   flight.
8. Backend-to-host transport reuses the existing backend connection and generated
   contracts for unary calls and bounded server streams. Command execution supplies
   the concrete reverse-streaming requirement: lazy opening, one-item credit,
   pause/resume, producer cancellation, and exact-generation ownership. Revocation
   is immediate and precedes bounded cleanup; pending producer cleanup cannot
   prolong authority. This does not replace the host-to-plugin path or introduce
   general symmetric RPC, client/bidirectional streaming, or ambient callbacks.
9. Process and isolate separation provide isolation, not a security sandbox.
   Invocation checks govern the host-service API; they do not sandbox native
   backend code or arbitrary operating-system effects.
10. Installation, profile participation, ready exposure, and invocation authority
    remain separate concerns. Installation metadata describes prepared components,
    not capability/extension exposures or activation/profile state.
     Neither ready advertisements nor invocation contexts are persisted profile or
     configuration state.
11. Model-tool dependency capture is distinct from effect authority. Materialization,
    argument validation, and effect description receive no effectful host-service
    authority. Description uses only host-supplied semantic identity data. Only an
    execute stream reached after host policy or approval permits execution receives
    the services in that tool descriptor's validated subset of captured dependencies.
12. Before the first release, unstable transport wire changes may be made in place
    under protocol version 1. Artifacts must match the relevant protocol version
    exactly and be rebuilt as a coherent runtime/host/backend set; prior development
    artifacts receive no compatibility layer, negotiation, or shim, even when their
    version numbers match. Increment only when released artifacts establish a
    compatibility boundary. Installed-manifest versioning remains separate.
13. Remote orchestration execution state may span several operations, but its
    host-service authority may not. Every start/resume receives a fresh invocation.
    Exact host-owned tool snapshots and proposal occurrences use private,
    execution/generation-scoped opaque data handles that can survive an approval
    pause. Those handles grant no host-service authority and are not a general
    remote-object registry. Consumed, released, or foreign handles cannot select
    another object or replacement generation.
14. Approval authorization is captured by the host for exactly one resume. A
    backend proxy accepts only the exact reconstructed resolution supplied to that
    call; reverse approval application has no plugin-selected fields and applies
    the host-captured real resolution once. Authorization disappears at settlement,
    even when execution-scoped semantic handles remain.
15. Strategy materialization is async-capable and grants no host authority.
    Exact binding validation brackets settlement. Idempotent async execution
    cleanup releases retained state after terminal settlement, explicit close,
    retirement, or connection termination, without changing Run evidence or
    resolving an abandoned waiting approval. Cleanup cannot replace a primary
    failure or revive retired authority.

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

AGENTS.md is an implemented remote extension consumer. Its backend-only
installation advertises an inference-context source at readiness. A host proxy
uses the normal inference composer and supplies an authorized Environment
read service during each snapshot. The source uses its text-file read. The canonical
Session Environment authority remains host-owned; there is no static AGENTS.md
activation in `AdeleRuntime`.

Search's backend-only installation and Filesystem Tools' and Command Tools'
combined backend/frontend installations advertise model-tool contributions,
reusing their pure-Dart root semantics. Their backends live under the owning
plugins' `packages/backend`; none is statically activated by `AdeleRuntime`.
Prepared frontends remain independent of backend readiness. Public `adele_model_tool` owns generated
materialize, validation, effect-description, and server-streaming execution
transport; the generic app adapter registers proxies in the existing registry.

Exposure `hostServices` declares the maximum dependencies to capture from the
allowed read/mutation/process services, not an authority grant or profile definition.
Each descriptor requires `executionHostServices`, a duplicate-free allowed subset
of that exposure and the exact execution allowlist. Filesystem's `read_file` needs
read only, `apply_patch` and `delete_file` need read plus mutation, and `create_file`
needs mutation only. Search needs read only; Command needs process only.

Materialization captures coherent Session-bound read/mutation/process facets and exact
remote/Environment generations. All captured facets must share the Session and
Environment. Synchronous binding validation checks every captured facet and never
reselects a generation. Opaque executable route IDs are generation-bound, not
persistent handles. `materialize(sessionId)` receives no token; argument validation
receives no authority; `describe` receives route, canonical arguments, Session/Run
IDs, and nullable Environment identity as pure data. Only `execute`, after policy
or approval allows it, receives a fresh token with exactly its descriptor's services.
The identity carried by describe/execute cannot select authority.

Execution authority begins on stream listen and is revoked on done, error,
cancellation, or retirement. The unchanged read service exposes no-argument
`authority()` for the bound Session/Environment identity, `readFile(path)`, and
`readDirectory(path)`. Separate `AuthorizedEnvironmentMutationService` exposes only
create-new, conditional replacement, and conditional deletion, without authority
queries, authority-selection IDs, reads, or process methods. Separate generated
`AuthorizedEnvironmentProcessService` exposes exactly
`runForegroundProcess(EnvironmentForegroundProcessRequest request) ->
Stream<EnvironmentProcessEvent>`, reusing existing DTOs and declared failures,
without authority queries or authority-selection IDs. Read/mutation calls remain
unary; process calls use reverse server streaming with one-item credit and
cancellation. Outer-operation settlement or retirement revokes authority
immediately and cancels owned streams with bounded cleanup. Both transport
protocol versions are 1; installed manifests remain version 1. Immutable execution
snapshots carry no exception causes. These checks authorize host-service access,
not native OS effects; they provide no sandbox or rollback of in-flight effects.

Remote orchestration adds unary materialize/start/resume/release transport and a
unary execution-host service over the same mechanism. The backend support proxy
preserves native strategy sequencing with an operation-local lifecycle mirror;
start is flushed before model/tool work and complete/fail before returning. The
app retains original tool snapshots/proposals, captured approval, actual mechanics,
and Run evidence. Strategy-requested failure uses bounded data, not serialized
exception objects. Runtime retirement revokes invocation authority before adapter
resource cleanup; already-started host work may settle without regaining authority.
A deterministic real-AOT test strategy proves multi-proposal approval pause/resume.

These remote extension points do not implement the complete recursive extension
system. Chat remains the only statically composed plugin; its migration is
deferred. Local Directory Project Selector is already a prepared frontend-only
behavioral extension. Client/bidirectional streaming,
ambient callbacks, general symmetric RPC, and Profiles remain unimplemented.
Normal prepared startup currently attempts valid discovered components; that startup policy does
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
- Reverse streaming has a concrete bounded lifetime and flow-control mechanism;
  broader streaming modes and ambient host callbacks remain deferred rather than
  becoming speculative general RPC infrastructure.
- Remaining statically composed plugins can migrate incrementally without
  changing the existing contribution registry or completing all recursive
  extension mechanisms at once.

Current transport and authority rules are maintained in
[`contracts-and-capabilities.md`](../architecture/contracts-and-capabilities.md).
The implemented subset and broader typed composition model are maintained in
[`plugin-extension-model.md`](../architecture/plugin-extension-model.md).
