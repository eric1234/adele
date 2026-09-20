# Chat Contract

`chat_strategy_contract` is Chat's pure-Dart component contract, shared by its
backend and frontend. The production ADELE application does not import it.

It owns the plugin/strategy identities, `ChatEntryId` occurrence identity,
immutable canonical `ChatEntry` and `ChatSessionSnapshot` values, and
`ChatSessionService`. The service supports snapshot, user-message append, and
atomic instruction/invocation-budget configuration. Accepted appends return the
canonical entry, including its stable Session-local ID. Assistant append and
arbitrary history replacement are not public operations.

`chat_strategy_contract.dart` is the annotated source of truth. The maintained
generation command emits its native client, dispatcher, codecs, and service ID:

```sh
dart tools/adele.dart generate --check
```

EVC preparation derives a bounded eval-compatible client from the same annotations
using generic `contract_codegen` tooling. No application-owned Chat codec exists.
The frontend supplies an `OwningBackendRequestChannel` for the explicitly
allowlisted service; native headless tooling can use the captured backend's
configuration-scoped channel. The service is plugin-internal, not a core extension
point or capability advertisement.

Entry IDs are opaque occurrence data, not core Product IDs or authority. Generic
Session/Run lifecycle, execution, approvals, frontend hosting, and Inspection stay
in ADELE public/core APIs. See the [plugin overview](../../README.md).
