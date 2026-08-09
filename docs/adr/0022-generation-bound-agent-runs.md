# ADR 0022

## Title

Generation-bound deterministic agent runs

## Status

Accepted

## Context

Phase III resolves active semantic capabilities to generation-specific
bindings. Phase IV must prove a complete model request, tool proposal, explicit
decision, capability invocation, model continuation, and completion cycle
without merging provider selection into contracts or adding another RPC layer.

Approval has semantic meaning only if it refers to the exact tool provider that
was proposed. Model continuation likewise must not silently move to a restarted
provider generation.

## Decision

`agent_kernel` owns a pure-Dart, provider-neutral `AgentRun`. A run begins with
one user request and injected `AgentModel` and `AgentTool` instances. It has an
explicit state machine: created, invoking model, awaiting approval, executing
tool, completed, or failed. Phase IV supports at most one requested tool call
per model response and requires an explicit approval or rejection for every
proposal.

Model providers are normal ADELE capabilities. Application composition resolves
the model and tool capabilities before run execution and adapts each retained
`ProviderBinding` to a kernel port. Every adapter invocation acquires the
binding's request channel immediately before constructing its generated client.
It never re-resolves by provider ID. Restarted model and tool providers therefore
cannot receive continuation or an operation approved against an older
generation.

Agent tools are model-facing projections of selected ADELE capabilities, not a
parallel plugin integration mechanism. The Phase IV resource-inspector adapter
validates generic tool arguments and invokes the existing generated typed
client. A generic plugin-facing Tool Provider is deferred.

Tool continuation messages carry an explicit success, error, or rejected
outcome. Rejection and model-visible tool errors resume the same bound model
without relying on display text. Provider, transport, contract, validation, and
state-machine errors retain their original causal objects; provider execution
failures terminalize only the run.

Each run appends immutable events with monotonically increasing run-local
sequence numbers. The journal is in memory and provides deterministic inspection
and testing. It is not durable persistence, replay, recovery, or event sourcing.

## Consequences

The shared `dartaotruntime`, separate isolate groups, generated unary transport,
capability registry, and failure-containment boundaries remain unchanged.
Plugins do not depend on `agent_kernel`; the desktop application remains the
composition root.

Persistent sessions, durable runs, cancellation, streaming, parallel tool
calls, automatic approval, approval policies, real network model providers,
generic tool enumeration, and coding-agent workflows remain deferred.
