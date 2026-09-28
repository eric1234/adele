# Terminal Frontend

Role: Local frontend package map

`terminal_frontend` is the interpreted frontend of the stock
[Terminal plugin](../../README.md). It supplies two top-level entrypoints in
[`lib/terminal_frontend.dart`](lib/terminal_frontend.dart):

| Entrypoint | Responsibility |
| --- | --- |
| `newTerminal` | Calls public `openEnvironmentTerminal` with Terminal's retained label, close, title, and exit-removal policy. Returns the bridge's safe asynchronous result. |
| `buildTerminal` | Obtains one presentation-scoped surface handle and builds that native surface. Creates no resource and owns no tab chrome. |

The entrypoint library is `package:terminal_frontend/terminal_frontend.dart`.
Prepared action metadata comes from
[`stock_frontend_descriptors.dart`](../../../../tools/stock_frontend_descriptors.dart),
not a second registry in this package. Its `console` descriptor has no strategy,
model, or owning-backend requirement.

The public [creation bridge](../../../../packages/ui/lib/environment_terminal_bridge.dart)
returns `[true, null]` or `[false, safeErrorString]`; it does not expose native
exceptions or provider handles. Creation runs once in an operation evaluator;
validated policy is retained natively rather than as callbacks into that evaluator.
The separate [surface bridge](../../../../packages/ui/lib/terminal_surface_bridge.dart)
is installed afresh for each view. Cached old view access cannot be revived by a
later mount. Calling these interpreted-only entrypoints natively provides no fallback.

Production dependencies are only Flutter and `adele_ui`. App/eval dependencies in
`dev_dependencies` support compilation and tests, not production imports. The
native emulator, resource owner, authority checks, and cleanup mechanism stay in
the [application](../../../../app/README.md#session-console); shell selection stays
with the Environment provider. Terminal-specific behavior belongs to the
[plugin policy](../../README.md#terminal-policy), not the generic console host.

[`compileTerminalFrontend`](../../../../app/tool/terminal_frontend_compiler.dart)
compiles the actual source plus the public stubs with compile-only declarations.
The harness [`compile_terminal_frontend.dart`](../../../../app/tool/compile_terminal_frontend.dart)
uses the unchanged repository [toolchain](../../../../docs/development/toolchain.md).
The package participates in workspace membership and maintained `terminal_frontend`
analysis/test discovery. [`terminal_frontend_test.dart`](test/terminal_frontend_test.dart)
targets actual EVC policy transfer, safe failure, and content-only mounting; full
normal app/Git integration belongs to the
[console validation map](../../../../docs/development/testing.md#focused-console-checks).
