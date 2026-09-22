# Agent Kernel

`agent_kernel` is ADELE's internal, pure-Dart, provider-neutral execution
substrate. It implements generic mechanics underneath the public orchestration
boundary; it is not the owner of the whole execution architecture. See the
[canonical execution model](../../docs/architecture/execution-model.md) for
cross-system semantics and binding lifetimes.

## Ownership

The package implements Run lifecycle and interruptions, model-stream collection,
tool contribution composition and immutable snapshots, proposal resolution,
effect/policy gates, authorized execution starts, outcome handling, and typed
execution evidence. `AgentRun` owns lifecycle, interruptions, terminal failure,
and its journal, not the model/tool loop.

It deliberately does not own product lifecycle, strategy-specific Session state
or sequencing, model/provider selection, inference-source discovery, Environment
selection/authority, concrete tools/providers, transport, persistence, or UI.
Application [`KernelOrchestrationHost`](../../app/lib/core/orchestration_host.dart)
adapts public strategy operations to these mechanics. Strategies receive semantic
turns and opaque handles through public orchestration, not kernel objects.

Minimal prepared Chat and activity presentation already exist outside this
package; richer/final product UX remains incomplete. Their current ownership and
behavior belong to the [application](../../app/README.md) and
[Chat plugin](../../plugins/chat_strategy/README.md), not a kernel UI roadmap.

## Dependencies

Plugins and public APIs must not depend on this package. The kernel may depend
on public contracts and small acyclic pure-Dart implementation dependencies needed
for concrete mechanics; it must not depend on Flutter, application code, concrete
plugins, or provider-specific SDKs/protocols. See
[dependency rules](../../docs/architecture/dependency-rules.md).

Product owns `SessionId`/`RunId`. Public
[`adele_orchestration`](../orchestration/README.md) owns shared Run state,
invocation/interruption identities, model/proposal values, approval resolutions,
and context snapshots. Public [`adele_model_tool`](../model_tool/) owns tool
contracts, effects, progress, outcomes, and `collectToolExecution`. The kernel
reuses/reexports these values rather than defining competing models.

## Internal entrypoints

| Anchor | Responsibility |
| --- | --- |
| [`lib/agent_kernel.dart`](lib/agent_kernel.dart) | Internal package barrel, including reused public model-tool values. |
| [`lib/src/identifiers.dart`](lib/src/identifiers.dart) | Reexports shared product and orchestration identities. |
| [`lib/src/model.dart`](lib/src/model.dart) | `SemanticModelRequest`, streaming `ModelPort`/events, and `collectModelInvocation`; validates invocation identity and explicit terminal settlement. |
| [`lib/src/tool.dart`](lib/src/tool.dart) | `ModelToolComposer`, `ToolCatalog`, `MaterializedToolSet`, `ToolInvocationResolver`, and `ToolPolicy`; retains exact executables and validates canonical arguments. |
| [`lib/src/run.dart`](lib/src/run.dart) | `AgentRun`, `RunInterruption`, `ToolPolicyGate`, single-start execution guards, typed `ExecutionEvent` values, and `RunJournal`. |
| [`test/`](test/) | Deterministic lifecycle, model collection, materialization, resolution, policy/approval, and stale-binding tests. |

Policy and journal mechanics are in `run.dart`, not separate subsystems or
strategy implementations. Tool execution context identifies Run/Session only;
application adapters capture authorized Environment facets outside the kernel.

## Journal

`RunJournal` records deterministic Run-local sequence numbers and supports
in-memory snapshots/suffix reads with asynchronous coalesced change notifications.
It is mechanics/test/projection infrastructure, not durable Run storage, canonical
strategy history, event sourcing, replay, or recovery.

The application's
[`RunActivityProjection`](../../app/lib/core/run_activity_projection.dart) supplies
the separate immutable public observation facade. Public consumers do not receive
internal events, executable objects, journal objects, or raw exception causes.

## Validation

From the repository root, run the maintained focused target:

```sh
dart tools/adele.dart test --target agent_kernel
```

Cross-system composition and authority tests live under
[`app/test/core/`](../../app/test/core/); the public API packages test their own
contracts. See [development guidance](../../docs/development/README.md) for broader
validation.
