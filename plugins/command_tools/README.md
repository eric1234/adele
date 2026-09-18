# Command Tools

Command Tools is an independently installed stock plugin that contributes the
`run_command` model tool (`dev.adele.plugin.command-tools.run-command`). It asks
the Session host only for `AuthorizedEnvironmentProcessFacet` and runs one
foreground executable directly with verbatim arguments; it does not implicitly
invoke a shell. The root `command_tools_plugin` package owns the semantics;
`packages/backend` (`command_tools_backend`) reuses them through public generated
model-tool and Environment transport plus `adele_plugin_backend_support`. Its
entrypoint is `packages/backend/bin/command_tools_backend.dart`. Validation, effect
description, progress projection, and terminal output bounds are not duplicated
in the backend adapter.

Normal startup loads `command-tools/backend.aot`; `AdeleRuntime` has no Command
activation or production implementation dependency/import and no in-process
fallback. The combined installation retains the existing PluginId
`dev.adele.plugin.command-tools` and an independently available `frontend.evc`.
There are no Command-specific startup arguments, configuration, or deployment
defines. Self-hosting supplies explicit `commandToolsArtifact`; its
`includeCommandTools` switch controls backend start/registration, not runtime
construction.

Readiness advertises one extension at `dev.adele.extension.model-tools`, with
registration ID `dev.adele.plugin.command-tools.model-tools`, generated service
`modelTool`, configuration context `default`, and exactly
`hostServices: ['authorizedEnvironmentProcess']`. There are no capability
exposures. The `run_command` descriptor has the same process-only
`executionHostServices`. Materialization and validation receive no host token;
description uses pure identity and argument data. Only execution after host
policy/approval receives operation-scoped process authority.

Generated `AuthorizedEnvironmentProcessService.runForegroundProcess` reuses the
existing request/event DTOs with no authority-selection IDs. Reverse server
streaming uses one-item credit and cancellation. Settlement, cancellation, or
exact-generation retirement revokes authority immediately and cancels owned streams
with bounded cleanup; this neither rolls back process effects nor provides an OS
sandbox. See [remote model tools](../../docs/architecture/contracts-and-capabilities.md#remote-model-tools).

The tool exposes no Environment selector. Its effect targets the authorized
Environment as a whole and is marked as uncertain because arbitrary processes
can have secondary effects that this first command slice does not classify.
Environment stdout and stderr are projected as ordered structured tool progress.
The terminal model result independently retains at most 32 Ki UTF-16 code units
per stream as a deterministic 16 Ki head plus 16 Ki tail.

A paid opt-in OpenAI API-key application smoke proves that a real model can use
the direct `program` plus `arguments` interface for `git diff --check`, consume
the terminal model result, and continue after an existing-file source mutation.

Shell classification, background processes, stdin, signals, environment
overrides, and network policy remain outside this plugin.

## Run Command Inspection

The separate Flutter package `packages/frontend` (`command_tools_frontend`) owns
the interpreted `run_command` card. It interprets immutable structured arguments
and terminal data: program, individual direct-argv arguments, working directory,
timeout, common lifecycle, tool-result disposition, process termination/exit code,
and bounded stdout/stderr previews with truncation indicators. Successful tool
delivery does not imply exit code zero. Previews come from terminal outcome data,
not flattened progress history or a live Console stream.

Prepared `toolActivity` metadata supplies the exact tool and compact/Inspection
registration identities to generic frontend activation. The frontend depends only on
Flutter and `adele_ui`, not the headless implementation, app, or kernel. The
generic host matches exact Tool ID and transports immutable maps/latest common
lifecycle without interpreting command fields.

The same EVC exposes a distinct compact entrypoint through
`ToolActivityCompactPresentationContribution`. It shows bounded program/argv
tokens with boundaries preserved, never reconstructed shell quoting. Common
hosting owns inspect interaction in Chat, group rows, and card headers. Missing
compact UI retains a factual alias fallback, not native command-field parsing.

Generic catalog-driven activation independently loads prepared EVC through `PreparedFrontend`;
coalesced read-only snapshot updates retain the same view/runtime. Missing/corrupt
or retired presentation stays unavailable without backend failure or a native
tool-card fallback. Only common host approval UI supplies exact-invocation
Allow/Deny; this card cannot execute, resume, approve, or navigate. Console
navigation and arbitrary plugin drill-down remain deferred. Build-time preparation is documented in
[`app/README.md`](../../app/README.md#prepared-chat-frontend).
