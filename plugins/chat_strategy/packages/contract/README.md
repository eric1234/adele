# Chat Contract

`chat_strategy_contract` is Chat's pure-Dart component contract, shared by its
backend and frontend. The production ADELE application does not import it.

It owns the plugin/strategy identities, `ChatEntryId` occurrence identity,
immutable canonical `ChatEntry` and `ChatSessionSnapshot` values, and
`ChatSessionService`. The service supports snapshot, user-message append, and
atomic instruction/invocation-budget configuration. Accepted appends return the
canonical entry, including its stable Session-local ID. Assistant append and
arbitrary history replacement are not public operations.

These operations retain the same frontend contract for durable and explicitly
volatile Sessions. For durable state, successful mutations acknowledge SQL commit
before returning canonical values. Snapshots remain on the previous canonical
state while a write or terminal assistant commit is pending. Storage/corruption
failures are not invalid-content/session failures and do not select volatile
fallback. Schema, hydration, and terminal-acknowledgement details belong to the
[backend](../backend/README.md), not this transport contract.

`chat_strategy_contract.dart` is the annotated source of truth and retains
`part 'chat_strategy_contract.g.dart';`. Its native sibling is configured in
[`contract_codegen.yaml`](../../../../contract_codegen.yaml), is Git-ignored local
output rather than committed source, and supplies the native client, dispatcher,
codecs, and service ID. From the repository root:

```sh
# Materialize or update native contract siblings.
dart tools/adele.dart generate

# Verify existing local siblings without writing.
dart tools/adele.dart generate --check
```

The check fails when local output is missing or stale. Manual generation is
normally unnecessary: maintained bootstrap, analyze, test, and build/run flows
materialize output at their prerequisite boundary. See
[`contract_codegen`](../../../../packages/contract_codegen/README.md) and the
[toolchain workflow](../../../../docs/development/toolchain.md#generated-contract-artifacts).

EVC preparation uses `ContractGenerator.generateEvalClient` to derive a bounded
eval-compatible client directly from the same annotated declarations. That
projection is compiled into the EVC; it is not the native sibling or a second
hand-maintained semantic contract. No application-owned Chat codec exists.
The frontend supplies an `OwningBackendRequestChannel` for the explicitly
allowlisted service; native headless tooling can use the captured backend's
configuration-scoped channel. The service is plugin-internal, not a core extension
point or capability advertisement.

Entry IDs are opaque occurrence data, not core Product IDs or authority. Generic
Session/Run lifecycle, execution, approvals, frontend hosting, and Inspection stay
in ADELE public/core APIs. See the [plugin overview](../../README.md).
