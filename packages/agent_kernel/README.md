# Agent Kernel

`agent_kernel` is an internal, pure-Dart package reserved for a future
provider-neutral agent execution substrate. It contains no agent API or loop in
Phase 0.

## Dependencies

It may depend on public typed contracts and small pure-Dart implementation
packages required by proven execution mechanics. Flutter, `adele_desktop`,
plugin implementations, and provider-specific SDKs or formats are prohibited.
Plugins must not depend on this package.

## Ownership

Future responsibilities may include sessions, runs, model invocation
coordination, tool-call lifecycle, approval, cancellation, persistence and
replay, execution events, and errors.

Concrete model providers, concrete tools, editors, Git, terminals, workspace
implementations, coding-agent workflows, profile management, and provider
account management do not belong here.

## Deferred

Agent loops, complete message/tool/event/persistence models, and multi-agent
abstractions are intentionally deferred.
