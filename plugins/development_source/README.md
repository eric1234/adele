# Development Source

This provisional backend-only plugin exposes one configured, read-only source
root through a generated typed capability. The root is supplied when the plugin
generation starts and is not part of semantic read or search requests.

`DevelopmentSourceService` reads one strict UTF-8 file by root-relative path and
performs deterministic recursive literal-text search. Reads and searchable
files are limited to 1 MiB, queries to 256 code units, results to 100 matches,
snippets to 500 code units, traversal to 10,000 entries, individual directories
to 2,048 entries, and scanned file contents to 16 MiB. Search reports
truncation when a result or traversal bound is reached. It skips links,
unreadable, non-UTF-8, and oversized files, plus `.git`, `.dart_tool`, `build`,
and `node_modules` directories.

This is **not** ADELE's final Environment filesystem/source service. It does not
define Project/Task/Environment identity or lifecycle, mutation, process
execution, Environment-provider behavior, indexing/watching, SCM behavior, or
security sandboxing.

ADR 0031 now defines Environment as the practical filesystem/source + process
context used for Task work and intentionally does not require a separate
first-class Workspace concept. DevelopmentSource remains a bounded Phase IV
self-inspection capability used to prove generation-bound source tools; future
Environment-backed source tools may replace or absorb its responsibility.

Root confinement rejects traversal and validates ordinary symbolic-link
resolution before and after reads. It is not descriptor-level protection
against another local process deliberately replacing a filesystem path during
the resolution/open race. Closing that security boundary portably would require
a future platform-native, opened-handle or descriptor-relative filesystem
facility; this provisional pure-Dart capability does not provide one.
