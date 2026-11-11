# Session Evaluator Frontend

`session_evaluator_frontend` owns the interpreted **Prepare Evaluation Handoff...**
Session Command. It has no widget or presentation contribution. Backend evidence,
summary, source/Git provenance, directory publication, and sensitive-data limits
belong to the [plugin README](../../README.md); this package neither reads SQL nor
writes handoff files.

## Operation And Preparation

`lib/session_evaluator_frontend.dart` exposes
`Future<void> prepareEvaluationHandoff(String sessionId)`. Normal Session Command
hosting captures the selected canonical Session ID and exact sibling backend. The
operation uses the generated `SessionEvaluationHandoffServiceClient` over public
`OwningBackendRequestChannel`, not handwritten RPC or an application-private API.

The singular build-side descriptor in
[`tools/stock_frontend_descriptors.dart`](../../../../tools/stock_frontend_descriptors.dart)
declares `kind: 'sessionCommand'` under `frontend.extensions`, with Command ID
`dev.adele.session-evaluator.export-session-evidence`, the handoff service allowlist
`dev.adele.session-evaluation-handoff`, and independent `clipboardWrite: true` and
`feedback: true` opt-ins. There are no presentations or execution grants.

`app/tool/session_evaluator_frontend_compiler.dart` compiles this package, the
generated eval client from the annotated contract, and public bridge stubs with
compile-only `CommandDeclarations` and `OwningBackendDeclarations`. The compiler
harness publishes `session-evaluator/frontend.evc` beside the backend in the normal
catalog; no evaluator-specific application runtime wiring is needed. Production
dependencies are public UI and the sibling contract; application/compiler imports
are test/build dependencies only.

## Completion And Feedback

`lib/src/read_prepared_handoff.dart` accepts exactly one nonempty absolute native
`README.md` path and successful stream EOF. Empty, duplicate, malformed, or failed
completion never authorizes copying. It preserves the exact path string, including
supported Windows drive/UNC forms. The helper uses validation followed by
`Stream.reduce` with rejection of any extra item. The native contract helper's
`StreamIterator` is unavailable in the pinned EVC compiler, and the pin's
`Stream.single` getter is not executable. This compatibility helper stays
plugin-local; generated service routing and decoding remain authoritative.

After validated completion, `writeCommandClipboard(path)` automatically copies only
the path and awaits OS acknowledgement. Success reports that copying completed.
Platform copy failure instead reports that preparation succeeded and includes the
exact path in selectable feedback; preparation failure reports only a fixed safe
message. There is no confirmation, manual Copy action, destination chooser, or
automatic evaluator launch. Neither evidence contents nor backend/platform
diagnostics are logged or displayed.

The [public Command bridge](../../../../packages/ui/README.md#interpreted-bridges)
is write-only and bounds clipboard text and feedback independently to 16,384 UTF-16
code units. Invalid or retired access throws rather than becoming an ordinary copy
failure. Host lifetime checks surround OS acknowledgement; an already submitted
write cannot be recalled. Navigation does not retarget admitted work, while window
shutdown or frontend/captured-backend retirement fences late bridge access. The
generic host disables duplicate admission for this registration while the operation
is pending; global preparation admission remains backend-owned.

## Validation

`test/session_evaluator_frontend_eval_test.dart` uses the production compiler and
actual EVC execution with generated service decoding and mocked platform clipboard.
It owns path/cardinality/EOF validation, copy acknowledgement and failure, safe
feedback, retirement fencing, and the pinned native-helper compilation constraint.
It does not replace real backend/file publication or normal application-hosting
integration in `app/test/core/session_evaluator_integration_test.dart`.

After repository bootstrap, from the repository root:

```sh
dart tools/adele.dart test --target session_evaluator_frontend
```

The package participates in workspace membership and maintained analysis/test
discovery. See [focused validation](../../../../docs/development/testing.md#focused-session-evaluator-checks)
for the separate contract, backend, generic host, catalog, and application owners;
these commands describe responsibilities, not passing outcomes.
