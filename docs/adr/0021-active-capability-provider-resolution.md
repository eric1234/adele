# ADR 0021

## Title

Active capability provider resolution

## Status

Accepted

## Context

Phase II proves typed unary request/response contracts over one shared backend
host process. A contract defines how a typed operation crosses that boundary,
but it does not answer which active plugin should receive a semantic request.
Several independently implemented plugins may provide the same capability.

Static support declared by an installed plugin is not evidence that its current
backend generation is ready. Resolution must therefore operate on active
registrations, remain deterministic across asynchronous startup order, and
must not merge capability selection into the generated wire protocol.

## Decision

Phase III introduces immutable capability keys and provider descriptors, an
in-memory host-owned registry, registration leases, immutable discovery
snapshots, and generation-specific provider bindings.

A capability key consists of a stable reverse-domain ASCII identifier and a
positive integer major version. Public capability, provider, and plugin IDs use
one grammar: at least two lowercase dot-separated segments, each beginning with
an ASCII letter and containing ASCII letters, digits, or internal hyphens.
Underscores, empty segments, whitespace, controls, and non-ASCII text are
invalid. Phase III compatibility is an exact key match.
Semantic-version ranges, negotiation, adapters, and schema compatibility are
deferred. This exact-match rule is provisional.

A provider descriptor has a stable provider identifier, capability key, owning
plugin identifier, display name, and integer rank. Identity never comes from a
Dart type, package name, display name, process, port, or isolate. Discovery is
ordered by higher rank first and then provider ID in ascending lexical order.
Default resolution selects the first provider in that order. Rank is a
provisional deterministic host fallback, not a persistent user preference or a
claim that a provider is globally primary. Explicit resolution never falls back
to another provider.

Registration associates a descriptor with one ready endpoint and one active
plugin generation. The endpoint is opaque to the capability model. The
`plugin_runtime` adapter binds that endpoint to the existing
`AdeleRequestChannel`; generated clients continue to own encoding, decoding,
and invocation. No second RPC mechanism is introduced.

The registry rejects invalid identities, duplicate active provider IDs for the
same capability, inactive generations, invalid endpoints, and detectable
contract-service mismatches. A registration lease removes exactly the
registration it owns and closure is idempotent. A registration group closes
all leases in reverse order and supports rollback after partial activation.

A request for an unknown capability ID produces `CapabilityUnavailable`. When
that capability ID has active providers at other majors, resolution instead
produces `CapabilityVersionUnavailable` with the requested and active majors.
No negotiation or fallback across majors occurs.

A binding captures the registration generation. Unregistration invalidates it.
Restarting a provider creates a new generation even when its stable provider ID
is unchanged. A stale binding fails as provider unavailable and cannot invoke
the replacement or resolve another provider implicitly.

The application runtime owns and injects the registry. It registers providers
only after their backend channel and generated client adapter are ready. It
retires registrations before normal endpoint disposal and when the runtime
reports backend termination. Partial startup is rolled back. Frontend failure
uses the existing inactive-state cleanup and therefore cannot leave active
registrations.

Plugin-facing discovery is exposed through a narrow injected resolver. Because
the eval runtime cannot retain arbitrary host objects, the bridge exposes
capability-semantic operations: provider discovery, default or explicit
resolution to an opaque generation binding token, and contract-specific typed
invocation. The interpreted consumer itself sequences those operations and
handles unavailable states. The host bridge does not precompute presentation
output, and invocation still constructs the generated contract client without
exposing frames, request IDs, maps, process IDs, ports, or isolate identities.
Expected capability lifecycle races cross that bridge as narrow structured
statuses. Tokens belong to one eval bridge generation, are cleared by
invalidation, and retain their original provider binding; they are neither
provider identities nor reusable handles across reload. Backend contract and
transport failures remain in the generated transport error model.

## Consequences

Capabilities and contracts remain separate: the former selects an active
endpoint and the latter invokes it. The shared backend-host process and one
isolate group per plugin remain unchanged. Registry failures are structured and
distinct from generated transport failures.

The same provider foundation can later support brokered actions and sustained
services, but Phase III implements only stateless unary use. Events, streams,
cancellation, reverse RPC, retained handles, preferences, profiles, configured
instances, accounts, credentials, and compatibility negotiation remain
deferred. The registry API, rank policy, and exact-major model are intentionally
experimental.
