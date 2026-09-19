# Chat Backend

`chat_strategy_backend` owns canonical in-memory Chat history, configuration, and
sequencing. Its AOT entrypoint exposes the generated Chat Session service and the
existing remote orchestration service over one backend router and one retained
`ChatSessionStore`. It advertises only its orchestration strategy contribution.

The strategy preserves ordered canonical user/final-assistant projection,
provider-native Run-local replay, sequential tool proposals, approval pauses,
refusals, and the positive model-invocation limit. Instructions and the limit are
captured at materialization; the default limit is eight and stock instructions
are backend-owned. Intermediate tool, native, reasoning, and narration items do
not enter canonical history.

Service mutations are rejected while the Session has a materialized execution,
including approval waits and terminal acknowledgement. Read-only snapshots and
other Sessions remain available. Chat-owned `ChatRemoteOrchestrationBackend`
runs sequencing against an execution-local history copy and commits its final
assistant entry only after `RemoteOrchestrationBackend` returns acknowledged
completion. Rejected completion discards that candidate, preserving accepted
user entries and prior history. The claim is released after execution close and
commit or discard; closing during advancement drains the same settlement.
Generic host orchestration retains
model/tool execution, policy, Environment authority, and approval authorization;
Chat composes the unchanged F3f backend, not direct provider/tool calls.

Backend startup is independent of frontend activation. A missing or corrupt EVC
does not prevent headless execution. State belongs to this backend generation;
retirement does not migrate it or cause an old frontend to attach to a replacement.

The sequencing and state tests live here rather than in a second root semantic
package. The in-process activation helper is for explicit backend/host fixtures,
not production application composition. See the [plugin overview](../../README.md)
for the contract and execution semantics.
