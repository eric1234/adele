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

Shell classification, background processes, stdin, signals, environment
overrides, network policy, and real-model command use remain outside this plugin.
