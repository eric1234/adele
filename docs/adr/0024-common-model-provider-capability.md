# ADR 0024: Common model-provider capability

## Status

Accepted for Phase IV-B2

## Context

Phase IV-B1 connected the provider-neutral kernel to a fixture-specific stream.
The provider-boundary survey found that a common boundary must preserve typed
ordered input, semantic settlement, completed tool calls, live observations,
and compatibility-bound native state without copying one provider protocol.

## Decision

`adele_model_provider` is an experimental public package independent of
`agent_kernel`, host runtime packages, Flutter, and concrete providers.
Capability `dev.adele.model.provider` major 1 exposes service `modelProvider`
with one generated server-streaming invocation.

A configured provider binding and selected provider-scoped model are distinct.
Requests carry instructions, ordered typed message/tool semantics, function
tools, auto/none tool choice, optional maximum output, provider options, and
optional opaque invocation state. Authentication is not invocation data.

Events separate nonauthoritative text deltas, authoritative completed text or
tool proposals, and one explicit semantic terminal. Multiple proposals are
legal. Tool call, provider item, response, and request IDs remain distinct.

Settlement is completed, incomplete with a coarse reason, refused, or failed
with a small host-behavior classification. Provider details, usage, effective
model, identities, and native state remain optional metadata. Normal provider
API failures use semantic terminals; declared failure is contract/backend-only.

Item and invocation native state are opaque JSON-compatible envelopes bound to
the exact provider/model compatibility context. They are neither canonical
conversation meaning nor common reasoning.

EOF is not success. EOF or transport failure before terminal fails invocation;
teardown after terminal does not replace settlement. Post-terminal events are
violations. Consumer cancellation remains transport lifecycle.

The adapter retains one exact `ProviderBinding`; stale generations never
silently migrate. A second scripted AOT entrypoint implements the common
service, while fixture unary/stream/probe infrastructure remains intact.

## Consequences

- Plugins implement the public contract without importing the kernel.
- Text deltas reach the Run journal without entering Session history.
- Completed proposal metadata survives model/tool/model continuation.
- The provisional strategy's one-proposal restriction remains local.
- Real providers, authentication, media, reasoning, tool deltas, richer tool
  choice, retries, catalogs, and native-state persistence remain deferred.

Evidence is retained in
[`../research/model-provider-semantic-boundary-survey.md`](../research/model-provider-semantic-boundary-survey.md).
