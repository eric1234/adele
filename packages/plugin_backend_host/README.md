# Plugin Backend Host

`plugin_backend_host` is an internal pure-Dart executable package. One AOT host
process accepts framed stdin,
reserves stdout for protocol output, writes diagnostics to stderr, and loads one
external AOT isolate group per active plugin.

It is not plugin-facing API, a sandbox, a production daemon, or one process per
plugin. The host reuses `plugin_runtime`'s internal framing declarations while
owning isolate ports and plugin routing.

The host waits for actual isolate exit after shutdown acknowledgement and kills
an isolate that misses the exit deadline. Stdin EOF triggers full host cleanup.
Oversized plugin responses become bounded `response_too_large` failures without
terminating the host or plugin.
