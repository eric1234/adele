# Workspace Demo Contract

`workspace_demo_contract` is the plugin's shared pure-Dart contract package.
It is plugin-owned public contract source, not an ADELE public package or
internal host implementation package.

It may depend on `adele_contract`, `adele_plugin_api`, and
`adele_capabilities` as concrete declarations require. Flutter, the sibling
frontend and backend, ADELE internal packages, and `adele_desktop` are
prohibited dependencies.

Phase 1 defines immutable directory entries/listings, strict text contents, a
typed asynchronous filesystem service, structured semantic failure, and two
small eval-facing immutable snapshots. Transport maps, request IDs, ports, and
codecs remain outside this package. Bindings are manual; generation remains
proposed.
