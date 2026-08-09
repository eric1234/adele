# Agent Kernel

`agent_kernel` is ADELE's internal, pure-Dart, provider-neutral execution
substrate. Phase IV implements one deterministic `AgentRun` initialized from a
user request.

## Dependencies

It may depend on public typed contracts and small pure-Dart implementation
packages required by proven execution mechanics. Flutter, `adele_desktop`,
plugin implementations, and provider-specific SDKs or formats are prohibited.
Plugins must not depend on this package.

## Ownership

The kernel defines small `AgentModel` and `AgentTool` ports, immutable request
snapshots, an explicit run state machine, mandatory tool approval or rejection,
terminal results and failures, and an append-only in-memory event journal with
run-local sequence numbers. It supports at most one proposed tool call per model
response.

Concrete model providers, concrete tools, editors, Git, terminals, workspace
implementations, coding-agent workflows, profile management, and provider
account management do not belong here.

## Deferred

Persistent sessions, durable storage, replay/recovery, cancellation, streaming,
parallel tool calls, policy-driven approval, complete conversation models, and
multi-agent abstractions are intentionally deferred. The event journal is
inspectable execution history, not an event-sourced persistence mechanism.
