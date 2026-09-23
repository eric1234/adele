# Search Tools

Search Tools owns the stock model-facing `search` operation over a
Session-authorized Environment. It contributes one semantic model tool:

| Identity | Value |
| --- | --- |
| Plugin, `searchToolsPluginId` | `dev.adele.plugin.search-tools` |
| Contribution, `searchToolsExtensionId` | `dev.adele.plugin.search-tools.model-tools` |
| Tool, `searchToolId` | `dev.adele.plugin.search-tools.search` |
| Model alias | `search` |

Search owns argument validation, literal matching, traversal, stock exclusions,
budgets, and result diagnostics. It does not own Environment identity/lifecycle,
general filesystem access, Capability provider resolution, application
policy/approval, UI presentation, or generic model-tool execution mechanics.
Those boundaries belong to [Environment](../../packages/environment/README.md),
the [model-tool API](../../packages/model_tool/lib/adele_model_tool.dart), and
[remote model-tool architecture](../../docs/architecture/contracts-and-capabilities.md#remote-model-tools).

## Current Composition

The pure-Dart root package, `search_tools_plugin`, supplies shared semantics.
The `search_tools_backend` package adapts them for an AOT backend. Current stock
[preparation](../../tools/backend_artifacts.dart) assembles a `search-tools`
installation with `backend.aot` only;
[frontend preparation](../../tools/frontend_artifacts.dart) supplies no dedicated
Search frontend.

The backend advertises its contribution at the existing
`dev.adele.extension.model-tools` extension point, not a Capability exposure.
Normal activation discovers the prepared installation and registers the advertised
contribution through generic remote adapters. Production `app/lib/**` has no
Search package import, static Search activation, or in-process fallback.
`SearchToolsPlugin.activate` remains available for explicit local composition,
not as a substitute when the prepared backend is missing.

## Authority

Search requires only Session-authorized Environment read access. Exposure
`hostServices` declares `authorizedEnvironmentRead` as a dependency to capture;
the tool descriptor's `executionHostServices` requires that same read service.
Neither declaration grants permission by itself.

Remote materialization and argument validation use `SearchExecutable.unbound()`;
description receives captured identity but no read client. None of these phases
receives arbitrary filesystem authority. Only execution through the normal host
policy path receives a fresh operation-scoped authorized read service, used for
`readDirectory` and `readFile`. Transported Session/Environment IDs cannot select
another Environment: the host supplies authority over the exact captured binding.
No mutation or process service is granted.

Search describes a certain `sourceRead` effect for its canonical scope; the host
owns authorization and any approval requirements. Execution authority ends with
the enclosing operation's settlement, cancellation, or retirement, without
retargeting stale bindings. This host-service boundary is not an OS sandbox.
See [Environment](../../packages/environment/README.md) and
[operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).

## Search Semantics

- `query` is a nonempty, case-sensitive literal substring, not a regular expression.
  `path` is the only optional argument; omitted or empty scope searches the
  Environment root. Directory scopes recurse; file scopes search only that file.
- Paths stay Environment-relative. Validation canonicalizes redundant `/` and `.`
  segments and rejects a leading `/`, `..` segments, NUL, and malformed Unicode. The
  Environment provider owns filesystem confinement and read eligibility. A failed
  requested scope never broadens to root.
- Stock defaults exclude `.git`, `.dart_tool`, `build`, and `node_modules`
  directories case-insensitively, including rejection of explicit excluded scopes.
  This is not `.gitignore` interpretation or a configurable exclusion system.
- Directory entries are sorted by relative path and traversed depth-first; matching
  lines retain ascending line order. Each matching line yields one result with
  Environment-relative path, one-based line number, and a bounded snippet.
- Current budgets are 100 matching lines, 10,000 visited entries, 16 MiB admitted
  for searching, and 32 failed file reads. Snippets are bounded to 500 UTF-16 code
  units without splitting surrogate pairs. The byte budget applies after a whole
  file read, not as a bound on all provider I/O.
- Structured results distinguish `truncated` (a resource limit stopped searching)
  from `incomplete` (nested Environment read failures caused skips), and include
  stop reasons and counters. Partial results can be successful; success or "No
  matches" does not imply exhaustive coverage. Requested-scope failures and
  binding/infrastructure failures remain failures rather than skipped-success
  results.

Source and semantic tests below define the exact limits, validation rules, and
failure behavior; the backend reuses that implementation rather than maintaining
a second search algorithm.

## Boundaries And Dependencies

The [root package](pubspec.yaml) depends only on public Environment, model-tool,
and plugin APIs. The [backend](packages/backend/pubspec.yaml) depends on the root
semantics and public contract, Environment, model-tool, product, and backend-support
APIs. Neither imports Flutter, application code, internal host implementations, or
another stock plugin's implementation. Search consumes authorized Environment
reads rather than opening host files or invoking a native search command.
See [dependency rules](../../docs/architecture/dependency-rules.md).

## Source And Validation Map

| Anchor | Responsibility |
| --- | --- |
| [`lib/search_tools_plugin.dart`](lib/search_tools_plugin.dart): `SearchToolsPlugin`, `SearchExecutable` | Identities, contribution, shared validation/effects, search, and results. |
| [`test/search_tools_plugin_test.dart`](test/search_tools_plugin_test.dart) | Semantic behavior, scope/confinement validation, ordering, bounds, partial results, and liveness. |
| [`packages/backend/lib/search_tools_backend.dart`](packages/backend/lib/search_tools_backend.dart): `SearchToolsBackend` | Remote service adaptation and operation-scoped generated reads. |
| [`packages/backend/bin/search_tools_backend.dart`](packages/backend/bin/search_tools_backend.dart): `main` | Ready advertisement, routing, host-response multiplexing, and shutdown. |
| [`packages/backend/test/search_tools_backend_test.dart`](packages/backend/test/search_tools_backend_test.dart) | Descriptor/semantic parity, authority-free preparation, token-bound reads, and failures. |
| [`packages/backend/test/search_tools_entrypoint_test.dart`](packages/backend/test/search_tools_entrypoint_test.dart) | Extension-only advertisement, generated transport, cancellation, and shutdown. |

Both packages are maintained analysis/test targets in
[`tools/adele.dart`](../../tools/adele.dart). Prepared installation shape is covered
by [preparation tests](../../test/tools/backend_artifacts_test.dart); generic
activation and captured authority are covered by the app's
[remote model-tool integration tests](../../app/test/core/remote_model_tool_integration_test.dart).
