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
unreadable, non-UTF-8, and oversized files, plus `.git`, `.dart_tool`, and
`build` directories.

This is not ADELE's final Workspace service. It does not define workspace
identity, persistence, project association, mutation, process execution,
indexing, watching, SCM behavior, or security sandboxing.
