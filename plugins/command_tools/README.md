# Command Tools

Command Tools is an independently activatable stock plugin that contributes the
`run_command` model tool (`dev.adele.plugin.command-tools.run-command`). It asks
the Session host only for `AuthorizedEnvironmentProcessFacet` and runs one
foreground executable directly with verbatim arguments; it does not implicitly
invoke a shell.

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

The headless package exports `runCommandToolId` for stock composition to register
`adele_ui`'s `ToolActivityInspectionContribution`. The frontend depends only on
Flutter and `adele_ui`, not the headless implementation, app, or kernel. The
generic host matches exact Tool ID and transports immutable maps/latest common
lifecycle without interpreting command fields.

The same EVC exposes a distinct compact entrypoint through
`ToolActivityCompactPresentationContribution`. It shows bounded program/argv
tokens with boundaries preserved, never reconstructed shell quoting. Common
hosting owns inspect interaction in Chat, group rows, and card headers. Missing
compact UI retains a factual alias fallback, not native command-field parsing.

Stock activation independently loads prepared EVC through `PreparedFrontend`;
coalesced read-only snapshot updates retain the same view/runtime. Missing/corrupt
or retired presentation stays unavailable without backend failure or a native
tool-card fallback. Only common host approval UI supplies exact-invocation
Allow/Deny; this card cannot execute, resume, approve, or navigate. Console
navigation and arbitrary plugin drill-down remain deferred. Build-time preparation is documented in
[`app/README.md`](../../app/README.md#prepared-chat-frontend).
