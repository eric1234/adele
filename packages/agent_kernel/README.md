# Agent Kernel

`agent_kernel` is ADELE's internal, pure-Dart, provider-neutral execution
substrate. Phase IV establishes Session and Run separation, context assembly,
streaming-shaped model invocation, immutable tool materialization, proposal
resolution, invocation-specific effects, policy, interruptions, structured tool
execution outcomes, and typed execution observation.

## Dependencies

It may depend on public typed contracts and small pure-Dart implementation
packages required by proven execution mechanics. Flutter, `adele_desktop`,
plugin implementations, and provider-specific SDKs or formats are prohibited.
Plugins must not depend on this package.

## Ownership

Session ports expose canonical conversational snapshots. Runs own execution
identity, a small lifecycle, interruptions, terminal failure, and a deterministic
in-memory journal. Runs do not own canonical transcripts, models, tool catalogs,
context policy, or workflow sequencing.

Model ports return semantic event streams. The maintained common ModelProvider
application path consumes generated server streaming and cancellation; the
scripted fixture's unary method remains only regression/reference
infrastructure. Tools have semantic IDs independent from model aliases and
retain exact executable objects in immutable per-model-invocation
materializations.

Concrete model providers, concrete tools, editors, Git, terminals, workspace
implementations, coding-agent workflows, profile management, and provider
account management do not belong here.

## Journal

`RunJournal` is deterministic observation for tests and inspection. It is not
durable storage, replay, recovery, or an event-sourcing decision.

## Deferred

Persistent Session/Run storage, stabilization of the experimental public
ModelProvider capability, production workflow and agent contributions, parallel
execution, complete effect/content taxonomies, durable approval, runtime
resources, artifacts, recovery, and multi-agent abstractions remain deferred.
