# Testing and Validation

Role: Current repository development procedure

Use this guide to choose validation for a change and to use ADELE's maintained
analysis, test, and check workflow. [`tools/adele.dart`](../../tools/adele.dart)
and current source/tests remain authoritative for exact commands and targets.
SDK setup, bootstrap, generation, and build preparation belong to
[toolchain policy](toolchain.md).

## Proportionate validation

Choose checks for the boundary and risk being changed, not simply the largest
available suite.

| Change type | Normal validation |
| --- | --- |
| Documentation-only | Source/doc consistency, links/fragments as relevant, `git diff --check`; behavioral suites normally unnecessary. |
| Small isolated Dart behavior | Focused package/test target plus analysis and formatting as appropriate. |
| Public contract/schema | Generation/check plus affected consumers and tests. |
| Package/plugin wiring | Owning target plus maintained discovery/integration checks. |
| Application composition | Relevant app/integration tests and the app dependency boundary. |
| Broad cross-system/runtime change | Multiple maintained targets or repository check as scope warrants. |
| Native packaging/runtime | Relevant build/smoke where the change actually affects it. |
| Live-provider behavior | Explicit gated live test only when intentionally needed. |

**Do not run behavioral suites for a prose-only change merely to prove unchanged
runtime behavior.** Source/test inspection is normally sufficient to validate
factual documentation claims. A behavioral test is appropriate for documentation
work only when a specific factual uncertainty cannot reasonably be resolved by
inspecting source and existing tests.

Catalog-wide integration tests should tolerate additive frontend contributions
while checking independently named required identities, uniqueness, and lifecycle
invariants. Intentionally closed fixtures should retain exact cardinality checks
when the declared fixture set is the contract. Sensitive capability opt-in
restrictions remain explicit contracts, not incidental catalog sizes.

## Maintained commands

Run repository commands from the repository root with the pinned toolchain:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart format --check
dart tools/adele.dart generate --check
dart tools/adele.dart analyze
dart tools/adele.dart test
dart tools/adele.dart check
```

These are available operations, not a checklist to run for every edit.

| Command | Current behavior |
| --- | --- |
| `bootstrap` | Prepares/verifies pinned CodeForge and AppFlowy source before `flutter pub get`, verifies that `dart pub workspace list` succeeds, then materializes configured ignored native contract parts. No Rust compilation. |
| `resolve-workspace` | Performs the same editor source preparation, pub resolution and workspace listing as bootstrap, but does not generate or check contract parts. Use bootstrap for IDEs and direct Dart/Flutter compilation. |
| `format --check` | Checks repository Dart formatting without rewriting files; formatting differences fail. |
| `generate --check` | Fresh semantic generation compares current local siblings without writing or consulting incremental receipts; missing or stale output fails. |
| `analyze` | Prepares/verifies both editor sources, regenerates current contracts, then analyzes repository tools, tool tests, and maintained Dart/Flutter analysis targets with fatal infos. |
| `test` | Prepares/verifies both editor sources and regenerates contracts before workers; selecting any target declaring `nativeCodeEditor` builds one shared pinned native editor test library and supplies the loader environment only to those targets. |
| `check` | Runs `generate --check`, then format check, then analysis, then tests, stopping between phases on failure. |

`check` does not bootstrap the workspace or run desktop builds/smokes. Its app test
phase does build the native editor test library. The initial generation check
deliberately exposes missing/stale local output before later analysis or testing
could regenerate it. See
[generated contract artifacts](toolchain.md#generated-contract-artifacts) for
generation inputs, ignored outputs, freshness, and cleanup semantics.

Incremental native generation belongs to `contract_codegen`; launcher routing,
preparation leases, and failure-before-launch belong to `adele_tools`. The generator
suite includes a clone of the actual configured source inventory, not only small
schema fixtures. After changing freshness behavior, run the owning tests and an
authoritative `generate --check` after a warm Linux preparation. Performance evidence
should compare consecutive unchanged builds with the same pinned toolchain and
separate cold receipt construction from warm validation; a reported cache hit alone
does not establish launch savings. Run controlled measurements without concurrent
pub resolution or source writers, which intentionally trip the mutation fences.

For desktop preparation changes, start with the relevant suite under `test/tools/`:
`desktop_build_inputs_test.dart` compares the real bootstrapped repository graph
across the worker/coordinator boundary. `desktop_tool_artifacts_test.dart` covers
cache keys for the generator and discovery tools. `desktop_final_input_fence_test.dart`
checks changes between discovery and use. Run `dart tools/adele.dart test --target adele_tools`
for full preparation and revalidation coverage. Compare several serial warm builds
with all tool/plugin components cached; separate worker execution, response
validation, and the final input-fence subphases from Flutter build time. A launcher
`run` total includes application lifetime; readiness/first-frame measurements need
an explicit runtime observation rather than that total.

Linux `run` and `build` share preparation before constructing their different
Flutter invocations. Use `run` to test compiler failure at every backend
entrypoint and compiler failure, missing output, and empty output at every
frontend target. Repeat these checks through `build` at the first and last
positions of each sequence. The routing and publication tests check the final
Flutter arguments for both commands.

## Maintained test targets

`dart tools/adele.dart test` runs all maintained targets with bounded package-level
concurrency. The default is at most two concurrent target processes, reduced to
one on a single-processor host. This is separate from concurrency inside an
individual Dart/Flutter test process. Queued targets still run after another
target fails; the final summary reports failures. Within one maintained invocation,
Flutter targets with the same normalized working directory run one at a time so
they cannot write the same build outputs concurrently. Targets in independent
directories can still run in parallel. This is not a cross-process lock: serialize
separately launched Flutter commands that share a package directory yourself.

For one maintained target, use `dart tools/adele.dart test --target <name>`
or `dart tools/adele.dart test --target=<name>`.
Representative choices are:

```sh
dart tools/adele.dart test --target adele_desktop
dart tools/adele.dart test --target adele_plugin_interactions
dart tools/adele.dart test --target adele_tools
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target adele_project_storage
dart tools/adele.dart test --target search_tools_backend
```

Do not treat those examples as an exhaustive list. Obtain the current
machine-readable target/matrix view with:

```sh
dart tools/adele.dart test-plan --json
```

This exports the CI expansion of the maintained registry, including logical target
names, distinct job display names, shard identity/count, Linux desktop and PTY
prerequisites, native Code Editor/TOML requirements, and CI concurrency metadata.
It can run before bootstrap without resolving dependencies or generating artifacts.
It is not automatic discovery of every package containing tests.

| Test option | Meaning and constraints |
| --- | --- |
| `--jobs N` | Positive integer controlling concurrent target processes; `--jobs=N` also works. Cannot be combined with `--target`. An explicit value may exceed the default of two. |
| `--target NAME` | Runs exactly one named maintained target. Unknown names fail; `--target=NAME` also works, including with `--ci`. |
| `--ci` | Valid only with `--target`. Applies that target's CI runner arguments/concurrency policy. It is not a generic credential/environment scrub. |
| `--shard N` | Selects one 1-based CI shard; `--shard=N` also works. Requires `--ci` and a sharded target: `adele_desktop` (1 through 4), `adele_plugin_interactions` (1 or 2), or `git_backend` (1 through 7). Missing, malformed, duplicate, out-of-range, and unsupported selections fail before preparation. |

The [CI workflow](../../.github/workflows/ci.yaml) consumes `test-plan --json` and
runs each matrix entry with `test --target NAME --ci` after `resolve-workspace`,
adding `--shard N` for the four desktop, two interaction, and seven Git backend
entries. On ordinary pushes and PRs, discovery then resolves and generates once,
publishing just the configured native siblings. Each first-attempt matrix worker
still resolves locally; its launcher takes an explicit `--ci-contracts=FILE`
and verifies the current checkout, resolution, SDK, run/attempt and complete
output inventory before restoring anything. Failed preparation, upload, download,
verification or installation fails the job; the worker does not run. Discovery
and matrix failures still fail the aggregate gate. Retried jobs (including
consumer-only retries) and manual dispatches use ordinary full generation and
never look for an older artifact. This is not a cache or a local generation flag.

Analysis still resolves and generates for itself. The separate `generated` job
runs full bootstrap then `generate --check` to verify the materialized parts
without repairing them. The Linux build path is unchanged. See the
[comparison and trust limits](../research/workflow-generated-artifacts-2026-11-28.md).

Each matrix entry gets an independent runner and its target's normal setup. The
registry declares `linuxDesktopDeps`, `linuxPtyDeps`, `nativeCodeEditor`, and
`nativeToml` according to what the selected suites need, not the use of Flutter
or the presence of a plugin in a fixture. All Git backend and desktop shards
declare the Linux PTY prerequisites. Update the receiving target's requirements
when moving a suite that introduces new dependencies. Shards are
emitted first to encourage early scheduling, not to guarantee runner launch order.
The local two-process default does not limit CI matrix parallelism. The aggregate
`test` gate requires every matrix entry to pass; `fail-fast: false` lets other
entries continue after a failure.

Desktop, interaction, and Git backend shards recursively discover `*_test.dart`
under `app/test/`, `app/plugin_interactions_test/`, and
`plugins/git/packages/backend/test/`, respectively. New nested suites are included
automatically; support files without that suffix are ignored. All three targets
use duration-weighted longest-processing-time-first (LPT) allocation with one CI
test worker per shard. Each target's `ciTestFileCosts` in `tools/adele.dart`
contains relative hints in approximate ten-second units, not measured shard
durations, an allowlist, or timeouts. Unlisted files cost **1**. See the
[desktop CI replay](../research/ci-performance-2026-11-26.md#desktop-fix-the-distribution-then-move-coverage-to-its-owner)
and [interaction timing comparison](https://github.com/eric1234/adele/pull/277)
for historical calibration. The desktop replay assigned hints to whole files.
Neither the portable Git hint nor the buffered-process hint measured the stock
and probe cases separately.

Whole files are considered by descending cost, then ascending package-relative
path (with `/` separators). Each goes to the least-loaded shard, with the lower
1-based shard id breaking load ties. Identical inventories and hints produce
identical assignments regardless of filesystem discovery order. Adding files or
updating hints can rebalance existing assignments.

For each target, every discovered file belongs to exactly one nonempty shard.
Empty partitions fail before preparation rather than falling back to full-suite
execution. Normal test annotations, skips, environment gates, timeouts, and
assertions remain in effect.

To reproduce a single CI selection locally:

```sh
dart tools/adele.dart test --target adele_desktop --ci --shard 1
dart tools/adele.dart test --target adele_plugin_interactions --ci --shard 1
dart tools/adele.dart test --target adele_plugin_interactions --ci --shard 2
dart tools/adele.dart test --target git_backend --ci --shard 1
```

Logs list the shard identity, selected file count and paths before preparation,
then the existing START/PASS/FAIL and elapsed-time summary. Omitting `--shard`
still runs the complete selected target, with or without `--ci`. For `git_backend`,
`--ci` selects one worker; without it, Dart uses its normal worker default. The ordinary
`test` and `check` commands run each logical target once, not extra shard runs.

For the complete plain-Dart Git backend suite, run:

```sh
dart tools/adele.dart test --target git_backend
```

### Application-level test ownership

Choose the owner by the behavior an assertion protects, not by the number of
plugins installed in its fixture:

| Behavior under test | Maintained owner |
| --- | --- |
| Generic hosting, authority, lifecycle, presentation infrastructure or native bridges | `adele_desktop`, recursively under [`app/test/`](../../app/test/). A real plugin may supply fixture data without owning the assertion. |
| Observable behavior of one plugin | That plugin's maintained suite, even when a development-only desktop host, compiler or other plugin supplies test infrastructure. |
| Cooperation between concrete plugin implementations | `adele_plugin_interactions`, recursively under [`app/plugin_interactions_test/`](../../app/plugin_interactions_test/), outside `app/test/`. |

If a backend-only plugin needs a real desktop host and has no suitable Flutter
test target, use a private `plugins/<plugin>/packages/desktop_tests/` workspace
member. Register it in the plugin's nested workspace and the maintained Flutter
analysis and test registries. Keep Flutter, the app, and the plugin under test in
`dev_dependencies`. The test package has no production entrypoint, installation
descriptor, or production consumers; the backend stays pure Dart.

[`git_desktop_tests`](../../plugins/git/packages/desktop_tests/) uses normal
recursive Flutter discovery under its own `test/`. The pre-bootstrap
`test-plan --json` lists one unsharded job with one Flutter worker; the target
does not accept `--shard`.
The target participates in normal `test`, `check`, and the aggregate CI gate,
separately from the seven plain-Dart `git_backend` shards. See the
[normal Git Task and startup checks](#focused-normal-git-task-and-startup-checks),
[buffered process checks](#focused-buffered-process-checks), and
[durable Git Task checks](#focused-durable-git-task-checks) for commands and prerequisites.

Without the explicit CI artifact, the maintained launcher runs full contract
generation before starting test workers. Git-hosted, desktop, and interaction suites compile their own AOT
fixtures with the pinned SDK; no host or backend snapshot is handed from one
suite to another. After bootstrap, run the full Git-hosted selection with
`dart tools/adele.dart test --target git_desktop_tests --ci`. Direct Flutter
runs also compile fresh but require current generated parts.

The two app targets use the same `app/` Flutter package and working directory.
Both participate in `test`, `check`, and application analysis. The interaction
target selects its whole directory when unsharded and explicit files for each shard.
Only `*_test.dart` files are suites; shared fixtures and compiler
helpers remain development-only. Migration is incremental: `adele_desktop` still
runs unmigrated integration files, not just generic host tests.

For the complete interaction target, run
`dart tools/adele.dart test --target adele_plugin_interactions` from the root;
add `--ci` without `--shard` to run the same directory with one Flutter worker.
Both CI shards prepare the native CodeForge library because prerequisites are
target-level. Open in Source needs it; portable Git review does not. For a
direct run of the whole directory, bootstrap and configure the
[native editor loader](#focused-editor-checks) first, then run
`flutter test --no-pub --concurrency 1 plugin_interactions_test` from `app/`.
Plain `flutter test` there selects only `test/`, not all application-level
integration coverage.

`chat_strategy_frontend`, `filesystem_tools_frontend`, `command_tools_frontend`,
`openai_frontend`, `source_editor_frontend`, and `diff_viewer_frontend` run
single-plugin interpreted frontend suites with development-only host dependencies
and shared app-side compiler support.

Single-plugin Apply Patch and Run Command rich/compact Inspection semantics live
in the [Filesystem frontend suite](../../plugins/filesystem_tools/packages/frontend/test/filesystem_tools_frontend_eval_test.dart)
and [Command Inspection suite](../../plugins/command_tools/packages/frontend/test/command_tools_inspection_frontend_eval_test.dart).
The Command target also discovers its existing output presentation suite.
Generic activation rollback remains in
[`prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart).

The [generic Session/Inspection test](../../app/test/tool_inspection_frontend_eval_test.dart)
stays in `adele_desktop`. Opening Inspection from the Session first mounts the real
Filesystem compact row for a one-edit patch waiting for approval. The real Command
presenter is also available as a negative control: with no corresponding tool
activity, the unexecuted `run_command` proposal stays `Proposal: run_command`.

The [Filesystem and Command interaction suite](../../app/plugin_interactions_test/inspection/tool_inspection_interaction_test.dart)
belongs to `adele_plugin_interactions`. It checks both presenters together:

- When the compact Filesystem renderer fails, the host refreshes its factual fallback without retrying the renderer or losing the Command row.
- Retiring the Filesystem frontend invalidates its simultaneous rich views while Command stays live.
- A mixed compact group follows model proposal order and keeps the Command row mounted after Filesystem retires.
- A missing or corrupt Filesystem EVC does not disable the independent Command presenter.

Focused commands after bootstrap/current generation:

```sh
# Repository root: single-plugin presentation semantics.
dart tools/adele.dart test --target filesystem_tools_frontend
dart tools/adele.dart test --target command_tools_frontend
# app/: generic Session/Inspection first mount.
flutter test --no-pub --concurrency 1 test/tool_inspection_frontend_eval_test.dart
# app/: mixed Filesystem and Command presenters.
flutter test --no-pub --concurrency 1 plugin_interactions_test/inspection/tool_inspection_interaction_test.dart
```

Each `adele_desktop` CI shard runs Flutter test files with one worker. Its real-AOT
and prepared-EVC fixtures are compiler-heavy; concurrent files can consume activity
deadlines through resource contention. Parallelism comes from the four independent
desktop jobs. Unsharded desktop `--ci` execution also uses one worker. The non-CI
desktop target retains Flutter's normal worker default.

The desktop, interaction, and Source Editor frontend targets need Rust 1.93.0
for both CodeForge and the app's transitive native TOML hook. In the
[review interaction suite](../../app/plugin_interactions_test/review/prepared_diff_git_integration_test.dart),
Open in Source exercises native editing and undo. Neither it nor the
[command capture suite](../../app/plugin_interactions_test/execution/command_output_capture_integration_test.dart)
uses the Git PTY helper: review uses Git worktrees and buffered processes;
command capture uses foreground pipes and `setsid`. The interaction target runs
Flutter widget tests, not a Linux desktop bundle. Neither it nor Source Editor
requests the desktop or PTY prerequisites. Frontend targets with a development
dependency on the app also declare `nativeToml`; `diff_viewer_frontend` needs
that hook but no CodeForge library, even for its host-backed test. Source-only
bootstrap and tooling tests do not require Rust.
The standalone credential package and its `adele_credential_store_native` Rust
test/Clippy target also receive the pinned compiler in CI. The desktop and its
development-only frontend consumers share that compiler with native TOML and
require no live keyring. Credential-native prerequisites are described
[separately](toolchain.md#native-credential-storage); `nativeToml` still means TOML,
not a generic native dependency flag.
Follow [native preparation](toolchain.md#native-editor-preparation)
and use an explicit pinned `FLUTTER_ROOT`, not just a Dart executable selected by
a version-manager shim.

When adding a package/plugin, verify workspace membership and update maintained
analysis/test discovery and relevant wiring checks where appropriate. Passing
the package's direct `dart test` alone does not establish repository or CI
integration. See [dependency rules](../architecture/dependency-rules.md#new-packages-and-apis),
the driver's `analysisTargets` / `testTargets`, and
[`test/tools/adele_test.dart`](../../test/tools/adele_test.dart).

## Direct local iteration

Direct commands remain useful for narrow iteration after dependencies and
generated parts are current. In the owning Dart package, run `dart test`; from
`app/`, for example:

```sh
flutter test --no-pub <test-path>
flutter analyze --no-pub --fatal-infos
```

A direct local test proves that selected code/test passes. A maintained
`tools/adele.dart` target additionally uses repository-maintained selection and
runner policy shared with CI. Direct Flutter commands do not regenerate native
contract parts; use `dart tools/adele.dart generate` from the repository root
after declaration changes. Repository `analyze` has no focused `--target` option.
Direct CodeForge tests also need the separately built native library and loader
environment described in [focused editor checks](#focused-editor-checks); a direct
Flutter test invocation does not perform that preparation.

## Rich-document editor checks

After bootstrap, native AppFlowy and evaluated rich-document checks need no
separate CodeForge library:

```sh
# app/
flutter test --no-pub --concurrency 1 test/appflowy_editor_smoke_test.dart test/rich_document_markdown_test.dart test/native_rich_document_editor_test.dart test/rich_document_editor_bridge_test.dart
# Repository root
dart tools/adele.dart test --target adele_ui
```

The native owner and genuine compiled-EVC fixture use the actual patched package,
normal `PreparedFrontend` hosting, and Flutter text-input/keyboard routes. Conversion
tests separately exercise import/export and explicit unsupported cases. The suites
cover ordinary remount/undo ownership, snapshots and observation, read-only input,
independent documents, invalid and retired handles, mounted-widget revocation,
input-client closure, and resource disposal. Use bounded frame pumping rather than
waiting indefinitely for upstream cursor/selection animations to settle.

All tests under `app/test/` are discovered by `adele_desktop` and its CI shards;
public interpreted-stub tests belong to `adele_ui`. Select the existing CodeForge,
Terminal, prepared frontend failure, Main Content, and presentation lifecycle tests
when changing shared hosting, with the native prerequisites described below.
Keep app Flutter commands serialized. These native checks do not establish human
IME acceptance or other-platform packaging. Production Chat additionally requires
the compiled frontend and normal application checks below.

For rich Chat integration, run
`dart tools/adele.dart test --target chat_strategy_frontend` from the root,
plus the prepared Main Content/catalog and
normal Chat application suites. The frontend suite retains its draft queue,
acceptance, navigation, history, and retirement checks with actual AppFlowy input;
it also exercises formatting, code, serialization refusal, composition, and native
owner replacement. `app/test/core/normal_chatgpt_run_integration_test.dart` owns
normal prepared Chat activation, durable draft restoration, and fake-provider Run
settlement, including coexistence with Source, Console, and Settings. These tests
need no paid model credentials. That app suite requires the existing native
CodeForge test library and loader environment, unlike the focused rich-editor tests.
Descriptor validation belongs to `plugin_runtime`; preparation/compiler source
inventories and production import boundaries belong to `adele_tools`.

For dependency-preparation changes, `dart tools/adele.dart test --target adele_tools`
owns local archive/patch/hash
preparation fixtures, cache integrity and deliberate recovery, plus launcher tests
that require prepared source before pub and reject tampering before consumers.
Fixtures use no network; fresh production bootstrap downloads the pinned archive.
See [source preparation](toolchain.md#native-rich-editor-dependency) for exact
identity and licensing; preparation tests do not substitute for Markdown or
evaluated-frontend validation.

## Configuration foundation checks

After bootstrap, select the focused targets below. The TOML document,
configuration-store, and Settings host targets also require the
[native TOML prerequisites](toolchain.md#native-toml-documents); platform-storage
and semantic Settings tests do not require native TOML. These commands identify
validation owners, not recorded test outcomes.

```sh
dart tools/adele.dart test --target adele_platform_storage
dart tools/adele.dart test --target adele_toml_document
dart tools/adele.dart test --target adele_configuration_store
dart tools/adele.dart test --target adele_settings
dart tools/adele.dart test --target adele_settings_host
dart test test/tools/adele_test.dart
```

The storage suite injects OS/environment/home inputs and explicit roots, testing
Linux XDG defaults/overrides, macOS/Windows path conventions, domain separation,
invalid inputs, and absence of directory creation without using real user roots.
These are cross-platform path-policy tests, not executed macOS/Windows acceptance.

The TOML target runs ordinary standalone Dart tests against real Rust `toml_edit`.
The package build hook prepares and bundles its native library automatically;
there is no native CodeForge build or loader environment variable. Tests cover
parsing, scalar reads/updates/insertion/removal, comments/layout, Unicode, exact
no-ops, and invalid-operation isolation. CRLF normalization on edits is an asserted
upstream limitation, not silently treated as lossless preservation. The tooling
suite owns workspace/analysis/target discovery and CI compiler metadata, including
the persistence and Settings host targets' transitive native TOML requirement.
It also checks the packages' narrow direct production dependencies: public
Settings depends only on `adele_plugin_api`, the internal Settings host depends on
Settings/configuration-store/TOML plus credential-store's pure reference identity,
and configuration-store retains its existing storage/TOML/path boundary. The
app/plugin boundary test also restricts Settings host credential imports to
`credential_reference.dart`, including conditional/relative directives, and keeps
that identity entrypoint SDK-only. These are focused checks, not a repository-wide
dependency-graph linter.

The configuration-store target uses temporary configuration/state/data/cache roots
and real native TOML to check loading, no-op preservation, conditional replacement,
stale and external writes, permissions, symlinks, artifact cleanup, and storage-domain
separation. Its process test uses pipe-gated writers and a nonblocking lock probe,
not timing delays, to verify that the stable local-state lock spans publication.
Staging faults are injected through Dart I/O overrides without a production fault
API. Run as an unprivileged Linux user for the actual permission-denied assertions;
the target uses coreutils `chmod` and `stat`. Linux x64 is the validated persistence
path, not macOS/Windows or unconditional power-loss durability evidence.

The `adele_settings` target owns pure-Dart definition, catalog, and resolution
checks, including record identity/presence, credential-slot declarations and shared
scalar validation, without filesystem persistence or native TOML. The `adele_settings_host`
target owns the thin adapter boundary using actual configuration-store and native
TOML operations with temporary roots, not a fake persistence layer. Semantic
resolution checks do not substitute for native host integration checks; neither
target establishes application Settings UI or Profile activation behavior.

Prepared declaration parsing remains pure Dart in the `plugin_runtime` target,
covering independent schemas, scalar constraints, ownership, bounded metadata,
asset confinement, whole-schema rejection, component isolation, and deterministic
duplicate diagnostics. Record tests cover optional display fields and credential
slots, strict kind/key validation, bounds and multi-type isolation, including the
authoritative stock OpenAI schema. The tooling
target exercises actual stock schema publication through the maintained installation
helper, not just a hand-authored manifest.

`packages/settings_host/test/configuration_records_test.dart` uses the real OpenAI,
Agent and Model Preset record schemas published by that helper and discovered through the
prepared catalog, without backend startup or credentials. It checks independently
named records, rename without identity changes, optional absence, sibling byte preservation,
delete/reconstruction, stale baselines including no-ops, unknown/comment retention,
malformed-file diagnostics, aliases and symlink rejection. A test-only job type
exercises Boolean, bounded integer and enum fields without a dummy production
plugin. The existing host target already declares `nativeToml`; no additional
target or worker is needed. The configuration-store suite separately exercises
multi-file transactions, conditional create/delete and cross-process coordination.
Credential-reference cases in that host suite use only the pure identity API and
real TOML, not a keyring: absent/empty tables, known reference edits, unknown nested
content preservation, malformed entries, shared value/reference conflicts and
whole-record deletion guards. TOML tests own `ensureTable` and `tableKeys` behavior.

Agent cases additionally check Markdown string round-trips, nonblank names versus
required but possibly empty Instructions, both optional fields' absence versus empty strings, and
an empty collection after deleting all records and reconstructing the store.

`app/test/prepared_settings_test.dart` loads the real Source declaration with
temporary configuration roots and checks native persistence/provenance, explicit
invalid overrides, unknown/comment preservation, stale-save conflicts, exact-owner
access and installation projection, and frontend failure isolation. The Source
frontend target exercises the compiled Source operation and rendered CodeForge
folding option with retained controller/text/undo and document identity. These
tests never write user roots.
Configuration is a startup snapshot, not a live update test: edit the file and
restart for new values; existing native owners are not reconstructed.

For backend settings delivery, use the maintained `adele_plugin_backend_support`,
`plugin_runtime`, and `plugin_backend_host` targets for immutable scalar reads,
pre-start copying/validation, and actual shared-host AOT delivery. Application
ownership and failure isolation belong to `app/test/prepared_settings_test.dart`
and `app/test/core/application_plugin_bootstrap_test.dart`. Check that foreign
installations cannot acquire another owner's values, invalid known overrides do
not silently default, settings-free components survive unrelated failures, and
missing required consumed values fail explicitly. Schema discovery failure remains
distinct from executable failure.

Backend record opt-in uses the same maintained runtime target: discovery tests
cover owned/multiple types, nested namespaces, same-collection foreign types,
invalid requests and independently missing/malformed schemas without activating
metadata-only or frontend-only installations. Stock publication assertions in
`test/tools/stock_installation_publication_test.dart` check the maintained OpenAI
and Agent Configuration backend opt-ins against their authored record declarations.

`app/test/core/startup_record_projection_test.dart` exercises real native TOML
through the retained Settings worker: declared scalar presence, deterministic
ordering, unknown content/reference stripping, diagnostics, collection failures,
absence without writes, exact declaration ownership, immutable copies and UI
baseline preservation through pending edits and failed projections. Transport
bounds are enforced before the worker result crosses isolates. These checks use
synthetic references and a credential adapter that rejects all operations, never
a live keyring.

`app/test/core/backend_record_startup_integration_test.dart` compiles the actual
shared host and a generic AOT public-decoder fixture. It covers owner/peer isolation,
explicit empty configuration, scalar Settings coexistence, shutdown during a read,
directory-failure isolation, immutable running generations and a fresh subsequent
generation. `app/test/core/openai_record_startup_integration_test.dart` additionally
publishes actual stock metadata, creates Work/Personal through the host, attaches
protected associations through the real coordinator with a deterministic adapter,
and starts the actual OpenAI AOT backend. It checks independently advertised
configured providers, stable record IDs and zero credential operations during
projection/startup. The generic observer verifies exact decoded values without
adding inspection APIs to production OpenAI. The stock suite also exercises actual
provider HTTP against loopback synthetic Responses SSE, as described
[below](#configured-openai-provider-checks); no external provider is contacted.

Public decoder limits, strict shape, duplicates, immutable copies and bounded
value-free errors belong to `adele_plugin_backend_support`. Raw malformed-frame
rejection before plugin spawn and real-AOT generation delivery belong to
`plugin_backend_host`; runtime pre-dispatch copying belongs to `plugin_runtime`.
The desktop target and its shards discover the record-projection and startup
suites under `app/test/core/`. Focused iteration after bootstrap uses:

```sh
# app/
flutter test --no-pub --concurrency 1 test/core/startup_record_projection_test.dart test/core/backend_record_startup_integration_test.dart test/core/openai_record_startup_integration_test.dart test/core/application_plugin_bootstrap_test.dart
```

Live nonsecret reads reuse these projection and AOT suites. The projection suite
also checks current reads against separate Settings owners, concurrent writes,
unchanged UI edit baselines, all-invalid partial results and close-time publication
fencing. The AOT observer retains earlier immutable observations while ordinary host
CRUD creates, updates and deletes records on the same connection. It also exercises
missing grants, strict selector-free requests, partial versus empty/unavailable
configuration, and pending-read retirement. No fixture substitutes an in-memory
persistence map. `app/test/core/backend_configuration_host_test.dart` checks exact
installation binding, fixed diagnostic redaction and dispatcher lifetime; public
`backend_configuration_test.dart` belongs to the existing backend-support target.
The startup credential-authority suite checks that live observations neither obtain
credential authority nor refresh old captures. Focused host iteration adds:

```sh
# app/
flutter test --no-pub --concurrency 1 test/core/backend_configuration_host_test.dart test/core/startup_credential_authority_test.dart test/core/backend_credential_integration_test.dart
```

Retain existing Settings/credential service and application lifecycle suites,
Source/Review retention tests and normal configured-provider tests.
Production backend startup packaging changes also require the maintained
`dart tools/adele.dart build linux --profile`; an isolated AOT fixture alone does
not validate desktop packaging.

Credential-slot consumption has distinct coverage from nonsecret record delivery.
The `plugin_runtime` target validates default-deny, exact owned types/slots, P3a
type opt-in prerequisites, duplicates, bounds, malformed/missing schemas and
component-local failure. Stock publication tests assert OpenAI's exact `api-key`
permission without changing its production schema. The backend-support target's
`packages/plugin_backend_support/test/backend_credentials_test.dart` checks startup
and live-capture wire shapes, bounded immutable records, independent scopes, local
release/late-publication fencing, fixed failures, malformed responses and strict
secret limits. Runtime framing and shared-host suites use distinctive
synthetic secrets to check rejected-payload and exception/diagnostic redaction.

`app/test/core/startup_credential_authority_test.dart` owns real worker/coordinator
checks with native TOML and deterministic protected storage: genuine versus copied
capture, independent records, complete protected binding, uncertain fences,
same-reference replacement, ordinary edits, strict identical-byte file replacement,
aliased-root invalidation and pre/post-wait stale checks. Paused read continuations
test mutations in the postcheck-to-publication window; identity-observer tests
distinguish transient unavailability from actual deletion. Gated reads verify that unrelated Settings work can
complete while OS access is pending, and that close fences delivery but drains the
read. Live-capture cases in the same authority suite check fresh genuine batches
against nonauthorizing observations/copied views, unchanged siblings, and
coordinator/Settings close during a pending capture. `adele_settings_host` separately
tests strict startup identity without changing editable byte-baseline semantics.
The maintained Linux identity observation uses GNU `stat` device/inode and
nanosecond change metadata; it needs no live keyring.

`app/test/core/backend_credential_host_test.dart` isolates the exact connection
dispatcher, request allowlist, malformed-envelope redaction and retirement against
a scripted transport peer. Live-scope cases cover pending/draining capacity,
issued-handle release, cross-host/generation rejection, failed cleanup and late
publication. `app/test/core/backend_credential_integration_test.dart`
compiles the actual shared host and a public-client AOT fixture, discovers prepared
installations through normal bootstrap, and resolves independent Work/Personal
credentials using the real coordinator. It covers absent grants, unknown/new/foreign
records and slots, stolen grants, no startup reads, fixed failures, concurrent edits,
late-response fencing and fresh subsequent generations. Live-capture cases exercise
create/Replace/Forget within one connection, partial versus clean-empty and failed
scans, release during a blocked OS read, unchanged startup values/registrations, and
generation retirement without vault access during capture. The stock OpenAI startup
suite retains that controlled observer over its actual declarations, independently
of the configured-provider HTTP cases below. All secrets are synthetic. The generic
credential-host/authority fixtures perform no model-provider network requests;
the stock-provider cases use loopback HTTP only.
Both direct connection revocation and normal bootstrap close settle pending reverse
requests before the OS gate is released. An actual accepted `AdeleApplication` exit
also proves admission fencing and dependency draining with a live AOT read.

After bootstrap, focused credential-delivery iteration from `app/` is:

```sh
flutter test --no-pub --concurrency 1 test/core/backend_credential_host_test.dart test/core/startup_credential_authority_test.dart test/core/backend_credential_integration_test.dart test/core/openai_record_startup_integration_test.dart
```

Retain the P1/P2, Settings, application lifecycle, Source/Review and bootstrap
regressions below. The credential-delivery suites above run in `adele_desktop`
and its CI shards. Production reverse-transport changes require the
maintained Linux profile build as well as these AOT fixtures. Real Secret Service
smokes remain separately isolated and opt-in.

Chat's declaration and bounded execution belong to `chat_strategy_contract` and
`chat_strategy_backend`; real prepared application composition and durable reopen
belong to `app/test/core/durable_chat_session_integration_test.dart`. Validate
declared defaults and nondefault budgets across startup and new Runs, retained
Run limits through continuations/approval waits, and the absence of budgets from
Session snapshots and SQL. Native `ChatStrategyPlugin` and
`ChatRemoteOrchestrationBackend` fixtures require an explicit positive
`maxModelInvocations`; direct AOT fixtures inject it through
`PluginBackendHost.startPlugin(settings: ...)`, never `configureSession`.
Prepared-catalog fixtures should publish the authoritative Chat schema through
the maintained stock helper and inject `PreparedSettingsSnapshot.resolve` or
temporary configuration roots. Do not let tests inherit real user overrides or
reproduce the schema default as an implicit fixture fallback.

`app/test/core/global_settings_service_test.dart` exercises the retained I/O worker
with actual native persistence, temporary roots, separate owner baselines, serialized
rapid operations, shutdown fencing/draining, load/save failures, and unchanged CFG2
conflicts. Record operations share that worker: tests cover off-UI I/O, cross-owner
scalar/record ordering, immutable presentation results, malformed siblings, duplicate
occupants, scan failures, and lock-gated shutdown draining. Record edit/delete coverage
checks owner-bound revisions, Reload and mutation retirement, fresh saved handles,
independent-record baselines, stale no-ops, out-of-band writes, and correctable
pre-write validation. Update/delete operations use the same native store and lock
fixtures as scalar requests, not a replacement persistence engine.
`app/test/global_settings_dialog_test.dart` covers scalar controls,
category/section organization, validation, search, provenance, empty/invalid catalogs,
per-setting save/reset, explicit reload, and real Source schema persistence. A
pipe-gated separate Dart lock holder tests dismissal during an admitted transaction;
this uses the same Dart file-lock domain, not `flock`.
Keyboard traversal excludes filtered editors while retaining their drafts. A
test-only service subclass injects a lost acknowledgement after actual native
publication to verify conservative error reporting and mandatory Reload.

The `model_configuration_contract` and `model_configuration_backend` targets
exercise Model Preset wire validation, live record projection and conditional
Session selection. Run `dart tools/adele.dart test --target model_configuration_frontend`
for the compiled selector: stable choices, incomplete observations, failed
reads, unacknowledged changes, revision checks, and retired presentations.
For the structured field editor, run `test/prepared_settings_field_editor_test.dart`
from `app/` to exercise the compiled proposal and form behavior boundaries,
draft lifetime and exact owner. The Model Configuration frontend target exercises the stock presentation;
the `adele_settings_host` target checks native subtable persistence and conflicts.
Opening Settings or saving a preset must not authenticate or query a provider.
For Model Browser integration, the `prepared Model Browser` case in
`app/test/core/openai_record_startup_integration_test.dart` installs the compiled
stock editor and real configured OpenAI backend against Work/Personal loopback
endpoints. Use this fixture to check exact account headers, stale row rejection,
row-specific effort choices and unsaved clears, draft versus disk, and the difference between an approval continuation and a
fresh Run. The [local browser suite](../../plugins/model_configuration/packages/frontend/test/model_browser_eval_test.dart)
checks the interpreted table against controlled successes, failures and delays.
From `app/`, run
`flutter test --no-pub test/core/model_preset_integration_test.dart` to cross
the prepared frontend/backend boundary with real Settings and Project storage.
Its instrumented ModelProvider checks the route, model and effort after a
Session selection, through an approval wait, and after changing or clearing the
choice for a later Run. For the generic mount and service allowlist, select
`test/session_accessory_host_test.dart` and `test/prepared_session_accessory_test.dart`. Select
`test/core/remote_run_model_preference_integration_test.dart` and
`test/core/application_plugin_bootstrap_test.dart` for generic expected-source
ownership and retirement. A preset should be selectable with no matching
provider installed; do not use a live account or substitute a provider catalog
for the Settings worker in these fixtures.

The `agent_configuration_contract` and `agent_configuration_backend` targets cover
the generated catalog, record projection, and bounded Session-selection contract
and failure semantics. From `app/`, run
`flutter test --no-pub test/core/agent_catalog_integration_test.dart` for real
shared-host AOT startup and live Settings CRUD on one backend generation.
`test/core/agent_selection_integration_test.dart` adds ordinary compiled Agent
selection over real host-mediated Project transactions, durable reopen and
temporary backing, revision conflicts, corruption, and lost-acknowledgement
reconciliation. Its compiled inference-source cases distinguish the active Run's
captured Markdown from what a fresh Run reads after edits, deletion, recreation,
or backend replacement, without Environment services.
Its compiled selector cases also mount a non-Chat pane with and
without the accessory location, and retire or navigate away from a selector
while a committed write is awaiting acknowledgement. These tests use isolated
Settings roots and no Chat Run.
Run `dart tools/adele.dart test --target agent_configuration_frontend` from the
repository root for the compiled selector's loading, live refresh, revision and
unacknowledged-write behavior. The `normal Chat restores rich Markdown` case in
`test/core/normal_chatgpt_run_integration_test.dart` installs the stock selector
beside a second accessory: a choice created through Global Settings survives
departure/return without changing the submitted Draft Request. Check this suite
for outbound Agent instructions: a continuation after approval must still carry
the original Markdown, while a new Run observes current selection and definition.
An unresolved selected ID fails before strategy materialization, not as a
terminal Run or model invocation.
`test/core/durable_chat_session_integration_test.dart` covers Chat and Project
reopen when Agent activation fails. Declaration-only installations still need no
executable host, as tested by `test/core/application_plugin_bootstrap_test.dart`.

For the generic lifetime boundary, use the `adele_orchestration` target's
`inference_context_test.dart` (native material capture and composition) and
`remote_inference_context_test.dart` (wire contract). From `app/`, run
`flutter test --no-pub test/core/remote_inference_context_integration_test.dart`
for compiled AOT capture, retirement during a pending request, and fresh
per-inference `AGENTS.md` reads. `test/core/orchestration_host_test.dart` checks
Run preparation and release independently of stock Agent behavior.

`app/test/record_settings_dialog_test.dart` covers generic collection navigation,
details, display-title fallback, shared create/edit multi-type forms, direct required
inputs, direct optional editing and removal, scalar validation, retained drafts/focus (including
collapsed editors), narrow layout, reentrant admission, exact-record delete confirmation,
conflict/uncertain-outcome recovery, and confirmed persistence without a plugin
executable, including the actual published Agent schema with a missing backend artifact.
`app/test/application_test.dart` publishes the actual OpenAI and Source
schemas through maintained tooling and manages two records before any Project:
create, display-name edit with stable filename, optional endpoint insertion/removal,
unknown/comment preservation, independent sibling bytes, canceled/confirmed deletion,
reopening, and explicit Reload after disk changes. Its credential flow uses the
application's real retained
association coordinator with a deterministic storage adapter to check independent
OpenAI associations, explicit storage checks, replacement, Forget before deletion,
and reopening without automatic vault reads. These installations have declarations
but no backend artifact: writes must work without activating a provider. This is not
a test of runtime apply on an active backend.
Pipe-gated locks verify accepted application exit drains admitted record updates and
deletes before releasing the settings worker.

Application entry, modal/Command Palette isolation, unavailable frontend recovery,
and captured storage roots are covered in `app/test/application_test.dart`. The
normal Source case in `app/test/core/normal_chatgpt_run_integration_test.dart` opens
Settings in no-Project, Task Browser, and active Session states, saves through the
real prepared schema and host store, and checks retained native/document/workbench
identities and startup-only folding for later editors. Creation and existing-record
edit drafts and the original Settings route also survive navigation and rejected
application-exit preflights. This Source case requires native editor preparation
and runs in `adele_desktop`; no production dummy settings are installed.

From `app/`, after bootstrap and native prerequisites:

```sh
flutter test --no-pub --concurrency 1 test/core/global_settings_service_test.dart test/global_settings_dialog_test.dart test/record_settings_dialog_test.dart test/application_test.dart test/prepared_settings_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --name 'normal Source Editor (retains Environment|and generic Review exit Cancel)'
```

For package-specific analysis, run `dart analyze --fatal-infos` in each package.
The small native ABI suite can be run from `packages/toml_document/native/` with
`cargo test --locked`, and its formatting with `cargo fmt --check`, using that
directory's pinned toolchain. Native ABI checks do not cover Settings semantics
or host persistence integration.

### Configured OpenAI provider checks

The maintained `openai_model_provider_backend` target owns plugin configuration,
endpoint policy, credential-failure mapping and Responses behavior.
`test/openai_configured_provider_test.dart` uses the real credential client with
controlled reverse responses and HTTP objects for identity/endpoint validation,
safe diagnostics, all credential-failure mappings, fresh per-invocation reads,
cancellation/pause propagation and temporary-client cleanup.
`test/openai_configured_refresh_test.dart` exercises the eight-capture bound with
catalog calls held on retired routes. It checks explicit retry after drain, refusal
to retry unknown publication, and release of the exact scope after admitted work
settles. `app/test/core/backend_credential_host_test.dart` checks host capacity
during pending capture, release and unconfirmed cleanup.
`test/openai_record_startup_test.dart` covers startup decoding and advertisements;
`test/openai_configuration_context_integration_test.dart` compiles the real shared
host and OpenAI backend and invokes the ordinary generated model-provider service.
Its deterministic credential dispatcher exercises the real backend client and
reverse transport, not the app's protected-storage authorization. It checks exact
Work/Personal routes and headers, ChatGPT coexistence, wrong-context/service rejection,
safe pre-HTTP failure terminals, independent streams, pause/resume, pending-read and
active-SSE cancellation, and generation retirement/replacement. The existing combined
environment API-key/ChatGPT scenario remains a distinct compatibility check.

`app/test/core/openai_record_startup_integration_test.dart` owns the full
configuration-to-HTTP path: maintained stock installation metadata, actual TOML
records, real association coordinator/protected envelopes and generation-scoped host
authorization, actual compiled host/OpenAI artifacts, and local Responses SSE.
The injected protected-storage adapter is deterministic, not a real keyring. Cases
check independent Work/Personal keys and endpoints in one generation, no startup or
uninvoked-sibling reads, payload/model IDs unable to select an account, safe missing,
invalid, unavailable and reconciliation-required outcomes without fallback, and
stale-after-edit/Replace/Forget/delete-recreate behavior followed by either explicit
refresh or a fresh generation. Live-refresh cases verify add/edit/delete, unchanged
nonsecret bytes after credential replacement, Forget, partial-observation refusal,
held HTTP on old routes, exact inference/catalog associations and repeated refresh
without capture accumulation. Pending credential gates check cancellation/retirement before HTTP and
continued Settings I/O; they do not establish a bound on OS unlock prompts.

For Global Settings apply, `record_settings_dialog_test.dart` and
`record_credential_settings_dialog_test.dart` isolate which acknowledgements
trigger apply and which actions must not. `core/record_apply_coordinator_test.dart`
checks exact-owner dispatch, coalescing, safe outcomes and retirement with a
controlled transport. In `core/openai_record_startup_integration_test.dart`, run
the Global Settings cases for the UI-to-AOT path, not just the explicit refresh
helper. These app paths are relative to `app/test/`.

After bootstrap/current generation, use the pinned toolchain:

```sh
# Repository root
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target openai_model_provider_backend
dart tools/adele.dart test --target adele_capabilities
dart test test/tools/app_plugin_boundary_test.dart test/tools/stock_installation_publication_test.dart test/tools/adele_test.dart
# app/
flutter test --no-pub --concurrency 1 test/record_settings_dialog_test.dart test/record_credential_settings_dialog_test.dart test/core/record_apply_coordinator_test.dart
flutter test --no-pub --concurrency 1 test/core/openai_record_startup_integration_test.dart test/core/backend_credential_integration_test.dart test/core/startup_credential_authority_test.dart test/session_execution_test.dart
```

Keep the existing experimental ChatGPT authorization regressions and generic runtime
generation/registry checks. `app/test/session_execution_test.dart` owns explicit
selected-provider failure without fallback and retained bindings across retirement;
the app's temporary selection still explicitly names ChatGPT, regardless of new
configured providers in the registry. Use deterministic storage and loopback HTTP
for record apply; applying or refreshing configured registrations should not
authenticate with OpenAI. Keep explicit model catalog HTTP requests on loopback.
These are validation procedures, not recorded passing results. Production backend
AOT changes also require the maintained Linux profile build, not only isolated AOT fixtures.

## Credential storage checks

After bootstrap and the [native credential prerequisites](toolchain.md#native-credential-storage),
run the maintained package/native targets and focused host/tooling checks:

```sh
# Repository root
dart tools/adele.dart test --target adele_credential_store
dart tools/adele.dart test --target adele_credential_store_native
dart test test/tools/adele_test.dart test/tools/app_plugin_boundary_test.dart
# app/
flutter test --no-pub --concurrency 1 test/core/credential_service_test.dart test/core/record_credential_service_test.dart
flutter test --no-pub --concurrency 1 test/credential_application_lifecycle_test.dart test/record_credential_application_lifecycle_test.dart
flutter test --no-pub --concurrency 1 test/record_credential_settings_dialog_test.dart test/application_test.dart
```

The package target owns the synchronous native/Dart boundary. The native target
runs `cargo test --locked` then
`cargo clippy --locked --all-targets --features fixture-probe -- -D warnings`
with Rust 1.93.0, stopping on failure. Clippy includes the opt-in probe without
executing it or accessing a keyring. The SDK-only underlying command,
`dart tools/adele.dart test-credential-store-native`, runs those checks directly
without editor preparation or pub resolution. Neither target needs an unlocked
keyring. App service tests use deterministic adapters for strict values, redaction,
queueing, uncertain-mutation fences, explicit reconciliation, and shutdown draining.
`app/test/core/record_credential_service_test.dart` exercises the host association
coordinator with real conditional configuration persistence and deterministic
credential adapters. It owns protected binding checks, whole-envelope size bounds,
attach/replace/forget ordering, missing-local establishment, status-only inspection,
partial failures, explicit reconciliation and owner/revision/slot isolation. Select
it with the existing worker regressions when changing admission: an OS wait must
not allow ordinary CRUD or another owner's configuration requests to interleave.
`app/test/record_credential_application_lifecycle_test.dart` adds lazy pairing,
mount-time factory capture, rebuild retention, rejected-exit usability and blocked
association drain to the existing standalone credential lifecycle tests.

`app/test/record_credential_settings_dialog_test.dart` exercises declaration-generated
slot controls through the real coordinator and Settings worker with temporary roots,
native TOML persistence and deterministic credential adapters, not mocked coordinator
results. Select it for unchecked/no-automatic-read behavior, explicit check/set/replace,
missing-local establishment, Forget and reconciliation, transient masked-input
clearing, and pending-operation presentation lifetime. Recovery checks cover fresh
owner-bound handles after success or partial failure without losing scalar drafts or
sibling baselines, stale/configuration failure requiring Reload, and unknown-entry
deletion guards. The actual OpenAI application case is described in
[configuration checks](#configuration-foundation-checks). Both are discovered by the
existing desktop target and shards; neither requires a live keyring or provider.

Deterministic adapter tests do not establish real Secret Service behavior and do not
replace the native fixtures below. Tooling tests check workspace,
analysis and CI discovery, pre-bootstrap `test-plan`, native command failure
propagation, and the prohibition on production plugin credential-store dependencies
and imports, plus the host's identity-only credential dependency.

The real-keyring fixture is **separate and opt-in**, not an ordinary CI dependency.
With the pinned `FLUTTER_ROOT` exported, from the repository root:

```sh
ADELE_CREDENTIAL_STORAGE_SMOKE=1 dart tools/credential_storage_smoke.dart
```

The fixture requires Linux x64, `dbus-daemon`, `dbus-run-session`, `gdbus`, and
`gnome-keyring-daemon`, plus `setsid` from util-linux for process-tree cleanup,
in addition to the native/compiler prerequisites. It must
use a private bus with service activation disabled and disposable daemon
HOME/XDG/control directories, never the developer's login keyring. Simply unsetting
`DBUS_SESSION_BUS_ADDRESS` does not isolate the test: D-Bus can fall back to the
user's runtime bus. Do not manually enable the gated app test against the normal
desktop session. The fixture owns daemon/process cleanup and invokes the app probe
and `app/test/credential_storage_responsiveness_test.dart` inside its isolated
environment. The same runner invokes `app/test/credential_association_smoke_test.dart`
in separate attach and reopen processes across a disposable daemon restart, using
the real OpenAI declaration and temporary configuration roots. That fixture checks
nonsecret TOML references, bound-envelope reconstruction, same-reference replacement
and Forget before record deletion. This is where real persistence, storage failures
and off-UI native blocking are checked, rather than inferred from fake adapter tests.
These commands describe validation procedures, not recorded successful outcomes.

Native packaging changes also require the retained actual application build:

```sh
dart tools/adele.dart build linux --profile
```

That build must retain CodeForge, native TOML, and AppFlowy alongside credential
code assets. Building a standalone probe or running the unrelated development
runtime smoke does not establish this coexistence. Commands here specify validation
owners, not completed results; Linux fixture/build evidence does not establish
macOS/Windows support, cross-process credential CAS, cancellation, bounded keyring
prompt duration, or portable release packaging.

## Application validation map

Select tests for the application boundary being changed. Paths in the table are
relative to `app/`; this is a testing map, not an application architecture map.

| Changed boundary | Representative app test paths |
| --- | --- |
| Zero-plugin runtime/shell | [`test/core/adele_runtime_test.dart`](../../app/test/core/adele_runtime_test.dart), [`test/application_test.dart`](../../app/test/application_test.dart) |
| Window Session Context | [`test/core/window_session_context_test.dart`](../../app/test/core/window_session_context_test.dart) (pure-Dart snapshot/revision, observer isolation/cleanup, independent windows, and native Command invocation capture); [`test/application_test.dart`](../../app/test/application_test.dart) (canonical Main Content/Console selection, palette admission, and cleanup without external context attachment); existing prepared navigation, concurrent Session, and shutdown cases in [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (pending/rejected preflight, committed departure, Inspection clearing, background Run isolation, and shutdown). These app files are discovered by the maintained desktop target. |
| Global Commands/Command Palette | [`test/command_palette_test.dart`](../../app/test/command_palette_test.dart), [`test/application_test.dart`](../../app/test/application_test.dart) (AppBar and fixed platform-shortcut dispatch across shell states, text-field focus restoration, modal isolation, repeat suppression, focus/search/keyboard/empty states, live conflicts and exact stale selection, safe failures, Session-only console toggling/navigation fencing, and application retirement); pure-Dart identity/resolution/admission belongs to the maintained `adele_core_extensions` target and [`commands_test.dart`](../../packages/core_extensions/test/commands_test.dart) |
| Context-free remote Commands | [`test/core/remote_command_integration_test.dart`](../../app/test/core/remote_command_integration_test.dart) (real shared-host/probe AOT, strict backend-ready metadata, local availability, exact route/generation, retirement and admitted completion, and backend-only prepared installation through the actual application palette before Project opening); generated client/dispatcher payload and completion tests belong to [`remote_command_test.dart`](../../packages/core_extensions/test/remote_command_test.dart) in `adele_core_extensions` |
| Context-free prepared frontend Commands | [`test/prepared_command_palette_test.dart`](../../app/test/prepared_command_palette_test.dart) (actual compiled EVC, normal frontend-only/no-presentation startup before Project opening, safe invocation failure, and live palette retirement/replacement); [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart) covers operation validation, no-authority invocation/return shape, rollback, exact retirement and evaluator lifetime; the remote integration suite above proves native/backend/frontend coexistence. Strict descriptor parsing belongs to the maintained `plugin_runtime` catalog tests. |
| Prepared Session Commands and native operations | [`test/prepared_session_command_test.dart`](../../app/test/prepared_session_command_test.dart) (actual EVC/AOT, canonical invocation capture, exact installation/backend routing, hidden/disabled/pending availability, registration versus generation retirement, navigation and shutdown); [`test/command_bridge_test.dart`](../../app/test/command_bridge_test.dart) (native and interpreted independent opt-ins, UTF-16 bounds, write-only clipboard acknowledgement/failure, retirement fencing, and safe feedback). Public native-stub denial belongs to `adele_ui`; strict descriptor parsing/roundtrip belongs to `plugin_runtime`. |
| Contextual Console-action Commands | [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart) (same-component target validation before publication); [`test/prepared_console_host_test.dart`](../../app/test/prepared_console_host_test.dart) (canonical authority, availability without EVC, shared creation/policy, safe warning, rollback, and asymmetric exact retirement); [`test/console_controller_test.dart`](../../app/test/console_controller_test.dart) (fresh post-reveal admission and owner/action pending state across context changes); stock palette/PTY evidence is in the Terminal case of [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart). |
| Contextual Main Content input-action Commands | [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart) (exact sibling targets and synchronous rollback); [`test/prepared_main_content_host_test.dart`](../../app/test/prepared_main_content_host_test.dart) (availability and asymmetric registration/replacement lifetime); [`test/main_content_controller_test.dart`](../../app/test/main_content_controller_test.dart) and [`test/main_content_host_test.dart`](../../app/test/main_content_host_test.dart) (exact action/current attachment, single input route, shared button/Command presentation, safe factory failure, and navigation). Stock Source EVC/no-read-before-submit belongs to the Source frontend target; normal global palette behavior belongs to the Source cases in the normal application suite. |
| Prepared backend/frontend bootstrap | [`test/core/application_plugin_bootstrap_test.dart`](../../app/test/core/application_plugin_bootstrap_test.dart), [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart), [`test/prepared_frontend_failure_test.dart`](../../app/test/prepared_frontend_failure_test.dart) |
| Prepared backend callable Capability consumption | [`test/core/backend_capability_integration_test.dart`](../../app/test/core/backend_capability_integration_test.dart) owns independent prepared consumer/provider AOT through normal catalog/bootstrap and the public generated semantic client; [`test/core/backend_capability_host_test.dart`](../../app/test/core/backend_capability_host_test.dart) owns exact binding, handle bounds, release/retirement, and admitted unary settlement. Public facade/mediation contract tests belong to `adele_plugin_backend_support`; strict backend declarations and generation infrastructure belong to `plugin_runtime`. See [focused checks](#focused-backend-capability-checks). |
| Prepared cross-plugin callable Capabilities | [`test/prepared_capability_integration_test.dart`](../../app/test/prepared_capability_integration_test.dart) (frontend-only EVC, separately installed ready-advertised AOT providers, authoritative generated native/eval contract, normal catalog/bootstrap/Main Content path); [`test/capability_access_bridge_test.dart`](../../app/test/capability_access_bridge_test.dart) (default-deny grants, exact handles, retirement/admitted unary settlement, bounded retention, lazy streams and presentation fencing). Shared transport regressions remain in [`test/owning_backend_stream_bridge_test.dart`](../../app/test/owning_backend_stream_bridge_test.dart); descriptor validation belongs to `plugin_runtime`. |
| Prepared contextual Environment-read Capabilities | [`test/prepared_environment_capability_integration_test.dart`](../../app/test/prepared_environment_capability_integration_test.dart) (independent frontend-only EVC and backend-only AOT through normal catalog/Main Content hosting, generated value DTOs and actual reverse reads from canonical nonprimary Environments, separate declarations, navigation and concurrent presentation isolation); [`test/core/environment_capability_invocation_integration_test.dart`](../../app/test/core/environment_capability_invocation_integration_test.dart) adds native bridge handle bounds, release/retirement and the external synchronous grant-revocation hook. Run alongside the unchanged C1 unary/streaming, C2a selection, Main Content and frontend activation suites, not instead of them. Public request-only API belongs to `adele_ui`; strict descriptor/roundtrip tests belong to `plugin_runtime`. |
| Prepared contextual buffered-process Capabilities | The [desktop host suite](../../app/test/prepared_environment_buffered_process_integration_test.dart) uses independent Environment, callable and frontend fixtures to check grants, routing and retirement. Use the [focused buffered process checks](#focused-buffered-process-checks) for direct backend and hosted stock Git coverage. |
| Portable Git inspection, approval and retained anchors | `adele_desktop` owns generic authority; `adele_plugin_interactions` owns stock Git/Diff review. `git_desktop_tests` owns hosted Git service behavior and the [Task anchor store suite](../../plugins/git/packages/desktop_tests/test/git_task_anchor_store_test.dart) against real Project storage. |
| Stock Diff/Git change review | The [prepared review interaction suite](../../app/plugin_interactions_test/review/prepared_diff_git_integration_test.dart) in `adele_plugin_interactions` exercises real Git-backed snapshots and index mutations in the selected Environment, Open in Source with retained native text/undo and focus, and Diff submission to Chat through scheduling and feedback Inspection. Enumeration/parser/process bounds belong to `git_backend`; generated values and single-plugin presentation belong to the Diff targets. See [focused Diff checks](#focused-diff-checks). |
| Project/native picker bridge | [`test/project_opening_test.dart`](../../app/test/project_opening_test.dart), [`test/directory_picker_bridge_test.dart`](../../app/test/directory_picker_bridge_test.dart) |
| Native editor ownership | [`test/native_code_editor_test.dart`](../../app/test/native_code_editor_test.dart) (ordinary editing/undo, external controller lifetime, fixed read-only configuration, same-editor clipboard completion, and targeted small fixes) |
| Prepared editor bridge | [`test/code_editor_bridge_test.dart`](../../app/test/code_editor_bridge_test.dart) (actual prepared EVC, explicit text snapshots, generic revisions, scoped handle retirement, and independently owned text/undo) |
| Grouped Main Content ownership/layout | [`test/main_content_controller_test.dart`](../../app/test/main_content_controller_test.dart), [`test/main_content_host_test.dart`](../../app/test/main_content_host_test.dart), [`test/adele_shell_test.dart`](../../app/test/adele_shell_test.dart) (registered groups only, ordinary ordering including Chat, zero-pane geometry, contiguous groups, stable panes, equal individual widths/minima, local reveal/focus, departure/retirement, and canonical Session context independent of view availability) |
| Prepared Main Content/catalog composition | [`test/prepared_main_content_host_test.dart`](../../app/test/prepared_main_content_host_test.dart), [`test/main_content_editor_test.dart`](../../app/test/main_content_editor_test.dart), [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (provider-free canonical Session/Environment context without grants, explicit per-pane services/native bindings, scoped operations, independent editor text/undo, and direct contributed Chat coexistence); see [focused commands](#focused-main-content-checks) |
| Main Content source-display consumers | [`test/main_content_source_display_test.dart`](../../app/test/main_content_source_display_test.dart) owns focused native and compiled authority checks: default denial, pane-only access, canonical Session validation before resolution, status-only settlement, exact provider retirement/replacement, and late attachment refresh/focus fencing without cancellation of admitted finite work. Public resolver behavior belongs to [`display_source_file_test.dart`](../../packages/ui/test/display_source_file_test.dart); strict consumer/provider declaration separation belongs to `plugin_runtime`. |
| Session-content Inspection | [`test/session_content_inspection_frontend_eval_test.dart`](../../app/test/session_content_inspection_frontend_eval_test.dart) mounts independently prepared compiled producer/renderer frontends in canonical no-Run Session Main Content and the normal Inspection stack. [`test/session_content_inspection_backend_test.dart`](../../app/test/session_content_inspection_backend_test.dart) adds real shared-host/AOT retrieval and exact owning-installation/generation isolation. `session_content_inspection_test.dart`, `session_content_inspection_bridge_test.dart`, and `main_content_inspection_test.dart` cover stack, delayed factories/reads, pane-only admission, canonical identity, and synchronous retirement. `application_session_content_inspection_test.dart` covers production application navigation and exit admission/retirement. All are discovered by `adele_desktop`; public contracts and strict descriptors belong to `adele_ui` and `plugin_runtime`. Retain existing stack, activity, prepared lifecycle, and Filesystem/Command/OpenAI frontend targets when changing this shared hosting. |
| Source retained data/native owners and captured file authority | [`source_editor_frontend/test/source_editor_host_test.dart`](../../plugins/source_editor/packages/frontend/test/source_editor_host_test.dart), [`test/environment_text_files_test.dart`](../../app/test/environment_text_files_test.dart), [`test/environment_access_bridge_test.dart`](../../app/test/environment_access_bridge_test.dart) (actual Source EVC, explicit-operation recovery without same-capture retry/migration, unchanged expected revisions, finite Save/Close, hidden exit, denied grants, and structured failures); see [focused Source checks](#focused-source-checks) |
| Normal Source workflow and exit cancellation | Source cases in [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (stock catalog/EVC and real Git worktrees, Session/Environment retention without Chat or Run, conditional Save/conflict/Close, and hidden unsaved exit cancellation without closing an active Run) |
| Native terminal emulator/view | [`test/native_terminal_surface_test.dart`](../../app/test/native_terminal_surface_test.dart) (real control parsing/styles/Unicode, hidden output, finite retention/geometry, local read-only copy/scroll, attachment, denied ambient clipboard, and explicit disposal) |
| Prepared terminal bridge | [`test/terminal_surface_bridge_test.dart`](../../app/test/terminal_surface_bridge_test.dart) (actual EVC compilation/mount, native input/focus/paste/mouse, resize/rebuild, scoped handles, retained-widget and pending-paste revocation, prepared failure/retirement, independent lifetimes, and bundled MIT notice) |
| Shared console contracts/state/chrome | [`test/console_controller_test.dart`](../../app/test/console_controller_test.dart), [`test/workbench_console_test.dart`](../../app/test/workbench_console_test.dart), plus [`adele_ui` console tests](../../packages/ui/test/console_test.dart) (independent contributions, selected-only default, lazy bounded LRU residency including the selected slot, exact interaction epochs, working-set departure, advisory confirmation, retirement, and bounded cleanup) |
| Prepared console/Session Environment authority | [`test/prepared_console_host_test.dart`](../../app/test/prepared_console_host_test.dart) (actual EVC action/content paths, canonical Session association rather than Task primary, captured creation scope, fresh view access, title/exit policy, and failure cleanup) |
| Native terminal lifecycle/title observation | [`test/native_terminal_surface_test.dart`](../../app/test/native_terminal_surface_test.dart), [`test/environment_terminal_owner_test.dart`](../../app/test/environment_terminal_owner_test.dart) (normalized title changes, hidden observation, lifecycle/cleanup evidence separate from output, and conservative pre-resource failure) |
| Task/Environment lifecycle | [`test/task_creation_test.dart`](../../app/test/task_creation_test.dart), [`test/core/product_lifecycle_test.dart`](../../app/test/core/product_lifecycle_test.dart) |
| Environment-eligible Capability selection | [`test/core/environment_capability_selection_test.dart`](../../app/test/core/environment_capability_selection_test.dart) (canonical nonprimary capture, sticky materialization/selection, exact binding retirement and replacement); [`test/core/environment_capability_integration_test.dart`](../../app/test/core/environment_capability_integration_test.dart) (real shared-host/backend AOT advertisements, shared-context instances, bootstrap rollback, gated canonical restore, generated calls without host authority). Association parsing and exact registration ownership belong to the maintained `adele_contract` and `plugin_runtime` targets; retain the C1 bridge/integration regressions above. |
| Contextual unary Capability admission | [`test/core/environment_capability_invocation_integration_test.dart`](../../app/test/core/environment_capability_invocation_integration_test.dart) (real shared-host/backend AOT, generated plugin-owned service and authorized reverse reads, canonical nonprimary authority, overlapping calls, payload/allowlist/generation isolation, grant expiry, failures and replacement). Router opt-in belongs to `adele_contract`; explicit operation-context lifetime to `adele_plugin_backend_support`; exact channel and individual registration revocation to `plugin_runtime`; wire forwarding and unchanged stream controls to `plugin_backend_host`. Run alongside the C2a, C1, and remote extension regressions, not instead of them. |
| Task Browser canonical projection/actions | [`test/window_task_browser_source_test.dart`](../../app/test/window_task_browser_source_test.dart) (immutable Session queries, Project/Task scope, canonical opening independent of frontend/backend availability, separate execution status/readiness, exact orchestration creation choices and label fallback, retirement, and opening without Environment materialization or Run start) |
| Task Browser bridge/view hosting | [`test/task_browser_bridge_test.dart`](../../app/test/task_browser_bridge_test.dart), [`test/task_browser_presentation_host_test.dart`](../../app/test/task_browser_presentation_host_test.dart) (safe action settlement, subscriptions/revocation, zero/one/many resolution, and retained factory state) |
| Prepared Task Browser activation | [`test/prepared_task_browser_host_test.dart`](../../app/test/prepared_task_browser_host_test.dart) (frontend-only activation, lazy source creation/disposal, exact retirement, and per-view bytecode/entrypoint failure) |
| Durable Project/Task/Environment records | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_project_lifecycle_test.dart`](../../app/test/core/durable_project_lifecycle_test.dart), [`test/core/durable_task_environment_lifecycle_test.dart`](../../app/test/core/durable_task_environment_lifecycle_test.dart). For publication after real Git establishment, stock Task comparison failures, or Local Directory + Git restart/move, see [focused durable Git Task checks](#focused-durable-git-task-checks). |
| Durable Session identity/Environment association | [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart), [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart) (complete-graph validation, atomic creation, missing strategy/provider, and no volatile fallback) |
| Terminal Run schema/publication | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart) (separate product/execution v1 owners, atomic record/activity retention, whole-graph publication, immutable lookup, and explicit volatile retention) |
| Terminal execution evidence | [`test/core/execution_evidence_test.dart`](../../app/test/core/execution_evidence_test.dart) (normalized schema, field-by-field public snapshot roundtrip, Run-local ordering/provenance validation, corruption rejection, and record/evidence rollback) |
| Terminal Run execution/restart | [`test/core/durable_run_lifecycle_test.dart`](../../app/test/core/durable_run_lifecycle_test.dart) (completed/failed fresh-runtime snapshot restore, unstarted/waiting close without invented outcomes, approval completion, SQLite and execution-plus-storage failures without retry, deferred mechanics draining, and no ID allocation or live execution/approval recreation) |
| Session- or Environment-addressed plugin storage host | [`test/core/project_storage_host_test.dart`](../../app/test/core/project_storage_host_test.dart) (owner schema, canonical Project routing before Sessions, scalar/query bounds, atomic batches, explicit volatile distinction, later Session mirroring, and queued-entry revocation); [`test/core/backend_capability_integration_test.dart`](../../app/test/core/backend_capability_integration_test.dart) exercises the generated client over compiled infrastructure transport, owner/backing isolation and generation retirement/replacement without Environment execution grants. |
| Durable Chat across real backend generations | [`test/core/durable_chat_session_integration_test.dart`](../../app/test/core/durable_chat_session_integration_test.dart) (conversation/configuration/plain-text draft, user-entry Run association, atomic draft submission, fresh-runtime reopen, and completed Run/activity retention despite Chat storage failure; real Local Directory/Git/Chat AOT backends and SQLite with a deterministic native model fixture, no paid provider) |
| Session Evaluator retained evidence and ordinary prepared handoff | [`test/core/session_evaluator_integration_test.dart`](../../app/test/core/session_evaluator_integration_test.dart) (prepared Chat/Command Tools/evaluator AOT and production evaluator EVC, generated services, normal application/Task Browser/palette composition, evaluator absence, automatic copy and selectable copy-failure feedback, plugin-owned three-file publication, captured Session across navigation, cancellation, duplicate admission, partial coverage, safe failures, shutdown, retirement/replacement, read-only SQL snapshots and nonprimary Git provenance; temporary host path lookup and backend-side write gates, no paid provider); [command capture interaction](../../app/plugin_interactions_test/execution/command_output_capture_integration_test.dart) (real Git/Command Tools/evaluator AOT, full decoded command export beyond the model-result bound, unsealed prefix, evaluator-only reopen, and whole-export limit failure). Plugin-local summary, source/README, writer and operation lifecycle suites live under [`session_evaluator/packages/backend/test`](../../plugins/session_evaluator/packages/backend/test/); compiled completion/copy tests belong to its frontend package. See [focused checks](#focused-session-evaluator-checks); normal catalog/compiler-input/launcher selection belongs to tooling tests. |
| Prepared Chat applicability/composer/history | [`chat_strategy_frontend/test/chat_frontend_eval_test.dart`](../../plugins/chat_strategy/packages/frontend/test/chat_frontend_eval_test.dart) (initializer strategy match without service acquisition, local service failure, plugin-owned layout, draft saves/submission/retry, latest-save deactivation settlement, recoverable failure/pending-Send refusal, stale snapshot protection, historical activity placement, and preserving live handles during refresh) |
| Contributed-pane services and departure settlement | [`test/session_presentation_lifecycle_bridge_test.dart`](../../app/test/session_presentation_lifecycle_bridge_test.dart), [`test/prepared_session_services_test.dart`](../../app/test/prepared_session_services_test.dart), [`test/prepared_main_content_host_test.dart`](../../app/test/prepared_main_content_host_test.dart) (exact service/affinity capture, per-pane hooks, async acceptance/failure/retry, no-hook behavior, retirement during settlement, and action revocation on unbind/reopen without closing execution) |
| Session execution/approval | [`test/session_execution_test.dart`](../../app/test/session_execution_test.dart), [`test/session_execution_bridge_test.dart`](../../app/test/session_execution_bridge_test.dart) (passive retained-owner lookup, independent Session advancement, shared IDs, exact approval isolation, semantic readiness, and all-owner shutdown) |
| Tool authorization contributions | [`tool_authorization_policy_composer_test.dart`](../../app/test/core/tool_authorization_policy_composer_test.dart) and `test/session_execution_test.dart` cover host composition and normal execution. [`remote_tool_authorization_integration_test.dart`](../../app/test/core/remote_tool_authorization_integration_test.dart) exercises the generated transport and exact registrations with a test AOT backend. [`conservative_tool_policy_integration_test.dart`](../../app/test/core/conservative_tool_policy_integration_test.dart) exercises the prepared stock backend and restart-bound participation. Generated transport tests belong to `adele_orchestration`; effect projection tests belong to `adele_model_tool`. No paid model is needed. |
| Orchestration/authority adapters | [`test/core/orchestration_host_test.dart`](../../app/test/core/orchestration_host_test.dart), [`test/core/orchestration_authority_test.dart`](../../app/test/core/orchestration_authority_test.dart), [`test/core/model_tool_host_test.dart`](../../app/test/core/model_tool_host_test.dart), [`test/core/remote_inference_context_integration_test.dart`](../../app/test/core/remote_inference_context_integration_test.dart) |
| Activity/Inspection | [`test/core/run_activity_projection_test.dart`](../../app/test/core/run_activity_projection_test.dart), [`test/inspection_host_test.dart`](../../app/test/inspection_host_test.dart), [`test/inspection_stack_test.dart`](../../app/test/inspection_stack_test.dart), [`openai_frontend/test/openai_activity_frontend_eval_test.dart`](../../plugins/openai/packages/frontend/test/openai_activity_frontend_eval_test.dart) |
| Scoped activity reacquisition | [`test/session_execution_activity_test.dart`](../../app/test/session_execution_activity_test.dart), [`test/session_execution_bridge_test.dart`](../../app/test/session_execution_bridge_test.dart) (live/waiting/preparing and historical Session validation, fresh read-only opaque handles, permanent old-view revocation, unchanged activity/Inspection paths, and no execution authority) |
| Prepared Git Task creation, Git/OpenAI startup, or shared host lifecycle | See [normal Git Task and startup checks](#focused-normal-git-task-and-startup-checks) for the three suites and their owners. |
| Prepared normal Chat composition, no live model | [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (local fake Responses/credentials and picker; canonical Session opening with missing components or zero Main Content, ordinary Chat/editor coexistence, frontend retirement without Run closure, concurrent Session commands in separate Task worktrees through shared AOT hosting, warm Command Output switching and cold Session history return, browser running/attention status, live/terminal Chat/activity reentry, stale approval callbacks, delayed/failed draft settlement, Inspection clearing, and hidden-owner shutdown; not interactive native-picker proof) |
| Environment-authorized agent integration | [`test/development/agent/environment_read_agent_integration_test.dart`](../../app/test/development/agent/environment_read_agent_integration_test.dart) (remote context/tools, source reads/mutations, and commands in distinct Task worktrees with deterministic model fixtures) |

Application dependency-boundary checks belong to
[`test/tools/app_plugin_boundary_test.dart`](../../test/tools/app_plugin_boundary_test.dart)
in `adele_tools`. They check production app manifest dependencies and import/export
directives and run the generic application runtime under the Dart SDK without a
Flutter engine; they do not check every repository dependency edge. The same target
covers [stock installation publication](../../test/tools/stock_installation_publication_test.dart),
[launcher routing](../../test/tools/desktop_launcher_routing_test.dart), and the
[repository test driver](../../test/tools/adele_test.dart).

### Focused Session Evaluator checks

The [Session Evaluator README](../../plugins/session_evaluator/README.md#retained-evidence)
owns the versioned document format, coverage meaning, consistency guarantees, and
bounds. Choose validation for the changed boundary; these commands identify owners,
not recorded passing outcomes. After bootstrap/current generation, select affected
targets from the repository root:

```sh
dart tools/adele.dart test --target session_evaluator_contract
dart tools/adele.dart test --target session_evaluator_backend
dart tools/adele.dart test --target session_evaluator_frontend
dart tools/adele.dart generate --check
```

The [contract suite](../../plugins/session_evaluator/packages/contract/test/session_evaluator_contract_test.dart)
owns exact v2 schema acceptance, explicit v1 rejection, bounded assembly only after
successful EOF, and unchanged generated routing/cancellation. The
[backend suite](../../plugins/session_evaluator/packages/backend/test/session_evidence_collector_test.dart)
owns read-only schema discovery, exact retained rows/text, command coverage and
provenance, composite identity/Session isolation, bounded chunk pagination,
initial/final committed-extent validation, safe growth versus corruption, and
whole-document query/size failures without publishing a successful prefix.
These do not replace the real prepared-backend/native-directory boundary tests.
The separate handoff contract suite validates the one-path completion shape,
failed/empty/duplicate completion, and generated effectful-service routing.

The [frontend suite](../../plugins/session_evaluator/packages/frontend/test/session_evaluator_frontend_eval_test.dart)
uses the production EVC compiler, generated handoff client, and real generic bridges
with a scripted service channel and mocked platform clipboard. It owns exact
path/cardinality/EOF validation, malformed generated items, automatic copy only
after successful EOF, OS acknowledgement, distinct preparation/copy failure,
safe feedback, and retirement. Its native-helper compilation case records the
pinned `StreamIterator` constraint; the workaround stays plugin-local. Generic
Session capture and per-registration admission belong to
`app/test/prepared_session_command_test.dart`; default-denied independent bridge
opt-ins, bounds, and lifetime fencing belong to `app/test/command_bridge_test.dart`.
These isolated checks do not replace normal application composition or real AOT
publication below.

The plugin-owned [summary suite](../../plugins/session_evaluator/packages/backend/test/session_evaluation_summary_test.dart) owns
deterministic factual projections, null/zero/partial usage coverage, Run-local
ordering and identities, bounded references, and exact raw evidence preservation.
The [metadata suite](../../plugins/session_evaluator/packages/backend/test/session_evaluation_handoff_test.dart) owns the
backend helper's canonical Session association, strict Worktree v2 source
state, and passive exact Git SQL anchor lookup over existing durable
backing. Missing or corrupt anchors never become HEAD
comparisons, and diagnostic reads must not initialize backing or schema. The
[directory writer suite](../../plugins/session_evaluator/packages/backend/test/session_evidence_file_test.dart) owns unique
allocation, exact three-file output (`README.md`, `summary.json`, `evidence.json`),
incomplete-write cleanup, revocation, and size bounds. Backend operation tests add
lazy bounded admission, cancellation and shutdown around collection/publication.
Prepared Command integration uses the generic host path lookup with an injected
temporary local-state resolver, not real user storage or a handoff request parameter; a
rejecting Save-picker spy verifies that no picker is invoked. It checks complete
handoff publication, automatic clipboard copying, and selectable safe copy-failure feedback
without changing the evidence schema or collector limits. Its real stock Git AOT
fixture uses a reopened nonprimary Session Environment with a nested Project source
and compares Git state before and after preparation without materialization.
These are deterministic source/integration checks, not a human desktop or
macOS/Windows acceptance claim.

For collector/handoff integration changes, run from `app/`, serializing Flutter
invocations sharing its build directory:

```sh
flutter test --no-pub --concurrency 1 test/core/session_evaluator_integration_test.dart plugin_interactions_test/execution/command_output_capture_integration_test.dart test/core/backend_local_state_host_test.dart
```

`adele_plugin_interactions` owns command capture; `adele_desktop` and its shards
discover the other two files. The `session_evaluator_backend` and
`session_evaluator_frontend` targets discover their plugin-local suites.
For generic Command hosting changes, additionally run
`test/prepared_session_command_test.dart` and `test/command_bridge_test.dart` from
`app/`, plus the affected `adele_core_extensions`, `adele_ui`, and `plugin_runtime`
targets. Public bridge stubs belong to `packages/ui/test/command_bridge_test.dart`;
catalog acceptance, rejection, and roundtrip tests belong to
`packages/plugin_runtime/test/prepared_plugin_catalog_test.dart`.
The path-only infrastructure contract belongs to `adele_plugin_backend_support`,
its host/liveness checks to the app, and OS path policy to `adele_platform_storage`.
Command
writer/schema changes require their own [Command Output checks](#focused-command-output-checks);
the evaluator is a passive reader and must not initialize or migrate that schema.
Catalog/launcher, compiler-input discovery, or dependency-boundary changes
additionally use `adele_tools`, in particular `stock_installation_publication_test.dart`,
`desktop_launcher_routing_test.dart`, `desktop_build_inputs_test.dart`, `adele_test.dart`,
and `app_plugin_boundary_test.dart`.
For documentation-only edits, inspect those sources and run `git diff --check`
rather than compiling the integration suite without a behavioral reason.

### Focused Diff checks

These commands map validation ownership, not passing outcomes. After
bootstrap/current generation, select affected targets from the repository root:

```sh
dart tools/adele.dart test --target diff_viewer_contract
dart tools/adele.dart test --target diff_viewer_backend
dart tools/adele.dart test --target diff_viewer_frontend
dart tools/adele.dart test --target adele_plugin_interactions --ci
dart tools/adele.dart test --target source_editor_frontend
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target git_backend --ci
dart tools/adele.dart test --target adele_tools
dart tools/adele.dart generate --check
```

The draft contract suite exercises generated native/eval anchored comments,
typed enums, bounds, exact text, and failure reconstruction. The maintained
`diff_viewer_backend` target uses test-owned real SQLite for transactional draft
CRUD, concurrency, rollback, bounded snapshots, corruption and uncertain outcomes.
Its review-submission suite additionally covers complete-collection preparation,
monotonic submission allocation, backend freeze, exact receipt finalization,
scheduling-attempt CAS, bounded active retention, and all-state on-disk recovery.
`app/test/core/durable_review_draft_integration_test.dart` owns actual Diff AOT and
generated-client access through canonical Project storage: durable close/reopen,
volatile Project lifetime, backend replacement, lost acknowledgements, retirement,
and Project-close fencing. It needs no source materialization or Run. Run it from
`app/` with `flutter test --no-pub --concurrency 1 test/core/durable_review_draft_integration_test.dart`.
The [Diff README](../../plugins/diff_viewer/README.md#pending-comments) owns the
schema, limits, and semantics; timing output is diagnostic, not a CI threshold.

The `diff_viewer_frontend` target discovers the
[frontend-only installation test](../../plugins/diff_viewer/packages/frontend/test/desktop/change_source_absent_test.dart).
It compiles only Diff's frontend and mounts it through normal host activation.
The product lifecycle establishes the Session and Environment, so the test
needs neither a Git worktree nor an active backend. Refresh and scope selection
must retain the Diff pane and report the change source as unavailable, never
clean. To run this case alone after bootstrap, with the
[native TOML prerequisites](toolchain.md#native-toml-documents) but no CodeForge
library, run from `plugins/diff_viewer/packages/frontend/`:

```sh
flutter test --no-pub test/desktop/change_source_absent_test.dart
```

The separate [Diff frontend suite](../../plugins/diff_viewer/packages/frontend/test/diff_viewer_frontend_test.dart)
compiles real EVC and covers default/switching scopes, separate committed/staged/unstaged/conflict
rows, same-path cancellation, clean states, selected-scope Refresh/Retry, pending
scope/departure fencing, eligible/ineligible headers, unchanged unusual paths,
availability, duplicate suppression, safe errors, and stale callbacks alongside
snapshot rendering.
Submission cases exercise the actual compiled controls and generated draft client:
all saved scopes, unsaved-editor exclusion, authoritative revisions, immutable
identity retention, explicit reconciliation/retry, narrow layout, and independent
approval/Source access after feedback failure. These injected bridge fixtures do
not replace real host/strategy authority or SQLite tests.
The separate review test dispatcher exercises actual generated-client hunk and file
actions, independent complete-file eligibility, layer-specific typed revisions/indices,
unavailable or denied approval, shared pending admission, success-only refresh,
unconfirmed feedback and stale-selection fencing.
Contract tests cover native and interpreted generated decoding,
nested immutability, strict malformed responses, declared failures, and zero authority
arguments for all methods. Real Git backend tests own baseline/HEAD/index/worktree comparison,
intent-to-add, unmerged entries, mode/nontext placeholders, immutable object reads,
deterministic HEAD/index/worktree races, baseline/branch integrity and
whole-observation resource bounds. Provider lifecycle tests verify the exact
establishment SQL plan and baseline-free operational state. For that plan's
publication in real Project storage and the stock comparison after reopen, see
[focused durable Git Task checks](#focused-durable-git-task-checks).
The generator's nested nonnullable-list storage regression belongs to
[`contract_codegen`](../../packages/contract_codegen/README.md#generated-eval-clients).
The injected frontend provider is not cross-plugin authority evidence
and does not instantiate a native editor. The existing
[Source host suite](../../plugins/source_editor/packages/frontend/test/source_editor_host_test.dart)
owns Source document policy and native text/undo across admitted operations.

From `app/`, focused native/compiled consumer authority checks need no native editor
library. Serialize Flutter invocations sharing its build directory:

```sh
flutter test --no-pub --concurrency 1 test/main_content_source_display_test.dart test/prepared_main_content_host_test.dart test/session_feedback_presentation_test.dart
```

For a direct run of the prepared Diff/Git review suite, first run
`dart tools/adele.dart build-code-editor-tests` from the repository root and set
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` to the absolute directory it prints.
Then run from `app/`:

```sh
flutter test --no-pub --concurrency 1 plugin_interactions_test/review/prepared_diff_git_integration_test.dart
# Related desktop-owned Environment and Main Content checks:
flutter test --no-pub --concurrency 1 test/prepared_environment_capability_integration_test.dart test/core/environment_capability_selection_test.dart test/core/environment_capability_integration_test.dart test/core/environment_capability_invocation_integration_test.dart test/prepared_main_content_host_test.dart
```

For Git worktree establishment and materialization, see the separate
[Git-hosted normal Task check](#focused-normal-git-task-and-startup-checks).
For Diff/Git review, use the pinned explicit `FLUTTER_ROOT` and the
[native editor prerequisites](toolchain.md#native-editor-preparation). The review suite
uses independent Diff and Source EVC installations with real Git AOT and native
Source editing, unlike the standalone text-only Diff tests. It checks committed-only
visibility in Task while Uncommitted is clean, independent nonprimary baselines,
Refresh after real commits, staged-only visibility, partial staging and A/B/A
cancellation as separate layers, real staging/worktree edits, and actual Diff
actions against the canonical nonprimary Environment, normalized document
deduplication without rereading, dirty text/undo preservation, focus, and captured
read completion across navigation. Snapshot lifecycle gates hold a real generated
buffered-process response after execution on the selected Environment, then verify
departure and retirement prevent further requests and stale publication.
The Source read gate likewise holds a real provider response, not substituted file contents;
neither gate adds a production testing hook. These tests do not need a PTY.
Review-submission cases in the same prepared integration file add actual Diff and
Chat AOT with compiled Diff, Chat, and Chat feedback Inspection EVC, canonical
Project storage, and deterministic normal model/tool execution. They check complete
model-facing feedback, compact authoritative Chat occurrences, explicit structured
Inspection through the dedicated read-only service, and correct occurrence
association. They also retain mounted-Chat notifications, independent Git/Source
state, waiting occupancy, retired acknowledgements, remount, and durable Project
reopen. The
durable draft integration suite separately gates real storage commits around
preparation, acceptance and local finalization. Run the public orchestration and
Chat contract/backend/frontend targets alongside these app selections when
changing feedback delivery or expected-occurrence materialization.
Review controls additionally prove exact selected-hunk and complete-file index object
changes and unchanged working-file hashes, HEAD/branch and Task baseline, nonprimary isolation,
manual-staging staleness, index-lock rejection and retirement after a real index
effect. Its native generated-client case rejects cross-Session revision reuse on
the same selected Environment. Missing provider/permission keeps the actual compiled
Diff read-only with Source navigation. Complete-file cases assert one index-mutating
request for multiple shifting hunks, preserved partial staging and unrelated entries
outside the selected source scope, and accurate Uncommitted/Task refresh.
For stock Diff controls over an independent Environment rather than the Git
Worktree provider, run the [stock portable review check](#focused-buffered-process-checks).
Both stock review suites belong to `adele_plugin_interactions`; the durable draft
suite remains in `adele_desktop`. These checks exercise
prepared artifacts, not a human desktop session. Review submission uses local
fixtures, not a live model or credentials.

For changes to test ownership or prerequisites, check discovery, launcher routing
(including the native library environment), and production dependency boundaries
from the repository root:

```sh
dart test test/tools/adele_test.dart test/tools/desktop_launcher_routing_test.dart test/tools/app_plugin_boundary_test.dart
```

### Focused buffered process checks

Bootstrap with the pinned toolchain and set `FLUTTER_ROOT` to that SDK. Real
buffered processes need Linux x64 and util-linux `setsid`; portable Git inspection
also needs the [Environment-side Linux commands](../../plugins/git/README.md#portable-unstaged-inspection).
The Git-hosted target declares `nativeToml` for the app's transitive build hook
([Rust 1.93.0 and prerequisites](toolchain.md#native-toml-documents)). It needs no
CodeForge library or loader variable, Linux desktop bundle dependencies, or Git
PTY helper. The portable suites under `app/` also run directly without CodeForge;
the full app targets prepare it for other suites.

Choose the buffered-process test by the boundary you changed:

- **Direct backend (`git_backend`, plain Dart):** The [supervisor test](../../plugins/git/packages/backend/test/buffered_process_test.dart)
  uses a Dart child process to check binary pipes, bounds, deadlines and cleanup.
  The [backend host integration](../../plugins/git/packages/backend/test/backend_host_integration_test.dart)
  calls the stock Git AOT provider through the generated Environment client to
  check maximum payloads, worktree selection and Git plumbing without a frontend.
- **Generic host (`adele_desktop`):** The [prepared host test](../../app/test/prepared_environment_buffered_process_integration_test.dart)
  uses independent Environment, callable and EVC consumer fixtures. It checks
  grant and handle boundaries, concurrent presentations and rejection of stale
  results. Its source guard checks that the callable and consumer neither start
  processes nor import Git's implementation.
- **Hosted stock Git (`git_desktop_tests`):** The [prepared Worktree test](../../plugins/git/packages/desktop_tests/test/prepared_git_buffered_process_integration_test.dart)
  uses the real stock Git AOT Environment provider with an independent callable
  AOT and EVC consumer. It hashes binary stdin, checks NUL-delimited filenames in
  the selected nonprimary worktree against the primary, and distinguishes nonzero
  exits from timeout and overflow failures. Neither Command nor Diff is the consumer.

```sh
# Repository root: complete Git-owned hosted target; --ci selects one worker.
dart tools/adele.dart test --target git_desktop_tests
dart tools/adele.dart test --target git_desktop_tests --ci
# plugins/git/packages/backend/: direct process supervision.
dart test test/buffered_process_test.dart
# plugins/git/packages/desktop_tests/: stock buffered execution, anchor storage, or portable service.
flutter test --no-pub --concurrency 1 test/prepared_git_buffered_process_integration_test.dart
flutter test --no-pub --concurrency 1 test/git_task_anchor_store_test.dart
flutter test --no-pub --concurrency 1 test/prepared_portable_git_service_integration_test.dart
# app/: generic host suites, then stock Git/Diff interaction; run serially.
flutter test --no-pub --concurrency 1 test/prepared_environment_buffered_process_integration_test.dart
flutter test --no-pub --concurrency 1 test/prepared_portable_git_integration_test.dart
flutter test --no-pub --concurrency 1 plugin_interactions_test/review/prepared_portable_git_stock_integration_test.dart
```

The [Git service suite](../../plugins/git/packages/desktop_tests/test/prepared_portable_git_service_integration_test.dart)
and the [desktop authority suite](../../app/test/prepared_portable_git_integration_test.dart)
each prepare a real shared backend host AOT, an independent Environment AOT that
runs real processes, a separate callable AOT using Git's production services, and
a synthetic EVC consumer of Diff's generated contracts. Neither prepares stock
Git or stock Diff artifacts. They share [fixture code](../../app/test/support/prepared_portable_git.dart),
not compiled artifacts, repositories, live installations or Project storage.

Choose the Git suite for selected-index effects, stale revisions, typed nonprimary
snapshots, inventory batching and exact persisted anchors across replacement and
reopen. Keep cases that check a real index write **and** retirement or departure
together: a lost response must not replay or roll back that write. Choose the
desktop suite for grant/selector denial, admission without fallback, and fencing
outstanding results or stale invocation tokens on retirement, replacement or
departure. The [independent fixture source guard](../../plugins/git/packages/desktop_tests/test/portable_git_source_boundary_test.dart)
belongs with Git; the [stock consumer source guard](../../plugins/diff_viewer/packages/frontend/test/portable_git_source_boundary_test.dart)
belongs to `diff_viewer_frontend`. Neither guard compiles the fixture.

The [stock portable review suite](../../app/plugin_interactions_test/review/prepared_portable_git_stock_integration_test.dart)
uses actual stock Git AOT and Diff EVC. It exercises hunk, added/deleted file
and whole-layer approval and unapproval, checking the selected Git index without
needing a Task anchor. It
also checks layered snapshots, conflicts and unsupported files, retained
nonprimary anchors across reopen, and a missing selected anchor without fallback
to the primary Environment. Clean 100/500/900-file and mixed layered snapshots
assert process counts; elapsed times are diagnostic. The independent Environment
runs real commands without importing Git's Worktree provider. This demonstrates
provider independence, not OS sandboxing or non-Linux portability.

The plain-Dart `git_backend` target owns the portable snapshot and parser tests;
`git_persisted_change_set_source_test.dart` covers adapter failures and deadlines.

After bootstrap with the pinned SDK, the existing targets discover the binary
Environment contract and stock provider tests without a new CI job or target:

```sh
dart tools/adele.dart test --target adele_environment
dart tools/adele.dart test --target git_backend --ci
dart tools/adele.dart generate --check
dart test test/tools/app_plugin_boundary_test.dart test/tools/adele_test.dart
```

The Environment suite owns strict Base64 validation, request/result limits,
generated sending/receiving boundaries, optional-facet absence, and unchanged
authorized-service surfaces. `git_worktree_environment_provider_test.dart` retains
streamed foreground regressions. Strict framing regressions remain in
`packages/plugin_runtime/test/backend_host_protocol_test.dart`. For host admission
changes also check `plugin_runtime` exposure/catalog/invocation and
`plugin_backend_host` token allowlist tests.

For native buffered execution without process grants, select the Git-owned Task
suite. For independent read-authority regressions, select the desktop suites:

```sh
# plugins/git/packages/desktop_tests/
flutter test --no-pub --concurrency 1 test/normal_task_git_integration_test.dart
# app/
flutter test --no-pub --concurrency 1 test/core/environment_capability_invocation_integration_test.dart test/prepared_environment_capability_integration_test.dart
```

The normal Git integration uses canonical Environments from `EnvironmentRuntime`,
not a native process test helper. These tests do not grant buffered execution to
independent Capability backends or interpreted frontends. Linux x64 with util-linux
`setsid` is the real-process target; no equivalent process-group guarantee is
claimed for other platforms.

### Focused backend Capability checks

For dynamic publication, also select `adele_capabilities`, `adele_contract`, and
`plugin_backend_host` maintained targets. Registry/runtime tests own exact group
adoption, preflight, association closure, rollback and retirement observers; contract
tests own immutable routes and admitted stream/control cleanup. The public publisher
suite owns strict bounded requests, fixed failures, and explicit cleanup retries.
From `app/`, add:

```sh
flutter test --no-pub --concurrency 1 test/core/backend_capability_publication_host_test.dart test/core/backend_capability_publication_integration_test.dart test/session_execution_test.dart
```

The publication integration independently compiles provider, peer consumer and shared
host AOT artifacts, then uses normal bootstrap for add/replace/retire, exact catalog
associations, held old unary/stream work, and unchanged sibling/Command registrations.
It performs no external provider or credential I/O. These files participate in the
existing desktop test discovery and shards.

These commands identify validation owners, not passing outcomes. After bootstrap
and current generation, run affected public API, catalog/runtime, generation, and
dependency-boundary targets from the repository root:

```sh
dart tools/adele.dart test --target adele_plugin_backend_support
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart generate --check
dart test test/tools/app_plugin_boundary_test.dart test/tools/adele_test.dart
```

The backend-support suite owns the request-only facade, structured values/failures,
and local release fencing. Catalog tests own the backend-only default-empty
`consumesCapabilities` allowlist, strict validation, bounds, immutable roundtrip,
and healthy-sibling preservation. Runtime tests own exact configured-channel
provenance and generation-infrastructure revocation, not semantic plugin services.

From `app/`, serialize this compiler-heavy integration run with other Flutter invocations:

```sh
flutter test --no-pub --concurrency 1 test/core/backend_capability_integration_test.dart test/core/backend_capability_host_test.dart test/core/application_plugin_bootstrap_test.dart
```

The integration boundary requires actual separately prepared consumer and provider
artifacts, normal catalog/bootstrap, and plugin-owned generated transport, not a
native consumer stand-in or application semantic-contract adapter. The host suite
uses a command-gated scripted transport peer with actual connections and advertised
activations to isolate ownership, retirement/replacement, and release/admitted-publication
semantics. Missing providers remain a runtime discovery outcome, not a startup
dependency. The existing unrestricted `adele_desktop` target discovers these files;
no new test target or CI concurrency policy is needed. Retain nearby frontend
Capability, contextual Environment, Project storage, and remote-extension
regressions when their shared infrastructure is changed. This unary context-free
coverage does not establish backend streaming, contextual authority propagation,
general recursive composition, or OS sandboxing.

### Focused Command checks

After bootstrap/current generation, run from `app/` with the pinned SDK:

```sh
flutter test --no-pub --concurrency 1 test/command_search_test.dart test/command_palette_test.dart test/prepared_command_palette_test.dart test/application_test.dart test/adele_shell_test.dart
```

The pure-Dart search tests cover matching tiers, ordered label subsequences,
word/ID boundaries, deterministic ties and empty-query order, and long valid inputs.
Palette fixtures also exercise ranked keyboard navigation, disabled relevance,
registry reranking, and exact Tab-focus/selection/replacement identity. These files
are discovered by the existing unrestricted `adele_desktop` target.
The application fixtures cover the keyboard-to-Command boundary without adding a
backend or new integration harness. Platform variants verify modifier policy,
not physical macOS/Windows execution. The native editor and terminal suites also
exercise the production shell shortcut around focused real native views; terminal
cases include Kitty and modifyOtherKeys encoding, repeats/releases, and absence of
the shell scope. Run those files with the existing
[editor library prerequisites](#focused-editor-checks) and
[terminal checks](#focused-terminal-checks). Palette IME composition and Tab-focused
exact row identity remain in the palette suite; native IME behavior is unchanged.

### Focused Main Content checks

These commands map affected boundaries, not recorded test outcomes. After bootstrap
and current generation, select public API, catalog, and tooling targets from the
repository root:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target adele_orchestration
dart tools/adele.dart test --target adele_tools
```

The public cases live in
[`packages/ui/test/main_content_test.dart`](../../packages/ui/test/main_content_test.dart)
and [`session_bridge_test.dart`](../../packages/ui/test/session_bridge_test.dart);
descriptor validation remains in
[`prepared_plugin_catalog_test.dart`](../../packages/plugin_runtime/test/prepared_plugin_catalog_test.dart).
For focused host iteration from `app/`, serialize Flutter invocations sharing its
build directory:

```sh
flutter test --no-pub --concurrency 1 test/main_content_controller_test.dart test/main_content_host_test.dart test/adele_shell_test.dart test/inspection_stack_test.dart
flutter test --no-pub --concurrency 1 test/prepared_main_content_host_test.dart test/main_content_source_display_test.dart test/prepared_session_services_test.dart test/session_presentation_lifecycle_bridge_test.dart
flutter test --no-pub --concurrency 1 test/window_task_browser_source_test.dart test/session_execution_bridge_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
```

The controller/widget tests target registered groups without an injected strategy
pane, zero-pane layout, ordinary Chat ordering, exact retirement, and pane
identity across title/order/width changes, local scroll/focus, bounded geometry,
and failure isolation. Prepared-host tests use actual EVC through the generic
catalog/bootstrap path, including readiness and stale callback boundaries. Service
tests keep exact backend/installation/controller validation separate from renderer
selection. The source-display consumer suite keeps native and compiled authority
checks separate from the [real Diff/Source/Git integration](#focused-diff-checks)
and from the existing Source host's document behavior. Chat's initializer uses only
captured identities; applicability mismatch must not acquire execution or backend
services. Navigation checks distinguish canonical `canOpen` from
`executionAvailable` and retained status, and creation
choices from UI availability.

For native editor ownership and stock Chat integration, first run
`dart tools/adele.dart build-code-editor-tests` from the repository root and set
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` to the absolute directory it prints.
Then, from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/main_content_editor_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --plain-name 'normal catalog editor panes preserve the stock Chat draft and active Run'
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --name 'actual Task Browser opens retained|hidden installed Session|prepared Chat navigation'
```

The focused editor case checks independent EVC runtimes, native text/undo, and
stable view/controller identities across interpreted collection changes. The
normal application case installs the frontend-only synthetic fixture alongside the
stock catalog and launches actual `AdeleApplication`. The interpreted
[`main_content_frontend.dart`](../../app/test/fixtures/main_content_frontend.dart)
owns open/title/order/focus/remove requests; the shared
[`main_content_fixture.dart`](../../app/tool/main_content_fixture.dart) supplies
independent native editor bindings. Assertions compare retained Chat presentation,
composer, Session/Run, and editor identities before and during a gated local fake
Responses invocation. Neighbor operations must retain the actual Chat EVC, not a
native stand-in. The same suite maps retained opening with absent frontend,
absent backend, or no Main Content; per-pane draft settlement/retry; and frontend
retirement while core execution survives. The synthetic editors may release their
owners on Session departure; this is fixture policy, not the stock
[Source Document lifetime](../../plugins/source_editor/README.md#ownership).
These are test paths and intended assertions, not recorded passing
outcomes, live-model checks, or human desktop evidence.

For changes across Main Content hosting, run the desktop target with
`dart tools/adele.dart test --target adele_desktop --ci`. It discovers these files and
prepares the native library/environment. Use the [editor checks](#focused-editor-checks)
for lower-level native/bridge changes and the
[manual grouped workspace](#manual-grouped-workspace) for interactive inspection.

### Focused Source checks

These are validation commands and ownership maps, not passing outcomes. After
bootstrap/current generation, select the affected public, policy, catalog, and
tooling targets from the repository root:

```sh
dart tools/adele.dart test --target source_editor_frontend
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target adele_tools
```

The Source target runs both isolated pure-Dart policy cases in
[`source_documents_test.dart`](../../plugins/source_editor/packages/frontend/test/source_documents_test.dart)
and real prepared-EVC/native integration in
[`source_editor_host_test.dart`](../../plugins/source_editor/packages/frontend/test/source_editor_host_test.dart)
through Flutter, with native editor preparation handled by the maintained runner. Public resolver cases are in
[`display_source_file_test.dart`](../../packages/ui/test/display_source_file_test.dart).

The Source host suite also verifies the real plugin-owned folding schema through
stock installation publication and owner-scoped startup resolution. For direct
iteration, run the application tests `test/prepared_settings_test.dart` and
`test/contribution_settings_bridge_test.dart` alongside the Source target. These
use the native TOML prerequisites; the latter checks compiled scalar bridge access
and retirement without needing a CodeForge editor instance. Live folding changes
on already-open editors are deliberately not implemented or claimed by this suite.

Catalog checks own explicit permissions/actions/operations and hook validation;
tooling checks own workspace/analysis/test discovery, stock descriptor entrypoints,
frontend-only preparation, and the production app/plugin dependency boundary.
The Source host fixture mounts the window-local input coordinator and invokes the
stock semantic Command, proving no provider read before form submission and the
same normalized, deduplicated native editor flow in the captured Environment.
Normal-product Source coverage uses the actual global palette as well as the
existing button, including hidden availability outside a Session.

From `app/`, serialize Flutter invocations sharing build output. Authority and
generic action-chrome checks need no native editor library:

```sh
flutter test --no-pub --concurrency 1 test/environment_text_files_test.dart test/environment_access_bridge_test.dart test/main_content_controller_test.dart test/main_content_host_test.dart
```

For the app-owned whole-product Source workflow, first run `dart tools/adele.dart build-code-editor-tests`
from the repository root and set `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR`
to the absolute directory it prints. Then, from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --name 'normal Source Editor'
```

The focused host fixture compiles actual Source EVC and uses a deterministic
Environment provider with held/failing operations: Save snapshots and baseline
advancement, edits during a held write, navigation, stale callbacks, explicit Open
recovery after restore failure or retirement, later explicit Save with the last
acknowledged revision, conflicts, native owner release, and hidden exit snapshots
are separate boundaries. The capture and Environment bridge tests distinguish
sticky per-capture failure/exact binding from fresh-operation access, and cover
denied grants, complete DTOs, structured failures, and admitted acknowledgements
without automatic retry.
The normal application cases use prepared stock components and real Git AOT/file
replacement; their active-Run case uses local fake model responses, not paid/live
credentials. Provider encoding, confinement, one-MiB bound, and revision checks
belong to `git_backend` and its
[`git_worktree_environment_provider_test.dart`](../../plugins/git/packages/backend/test/git_worktree_environment_provider_test.dart).
The Source workflow app cases above run in `adele_desktop`. These checks do not
establish human keyboard/IME, profile packaging, or macOS/Windows acceptance. Follow the
[manual Source workflow](#manual-source-workflow) and preserve the
[native limitations](../../app/README.md#known-limitations).

### Focused editor checks

The current tests cover conventional CodeForge ownership and the thin EVC boundary,
not a custom input/cancellation policy. These are commands to run, not recorded
pass results. Bootstrap with the explicit pinned SDK and native prerequisites from
[toolchain policy](toolchain.md#native-editor-preparation). For the maintained
tooling and desktop targets, run from the repository root:

```sh
dart tools/adele.dart test --target adele_tools --ci
dart tools/adele.dart test --target adele_desktop --ci
```

The desktop target discovers the editor tests and prepares their native
library/environment automatically. Tooling coverage includes
[`code_editor_dependency_test.dart`](../../test/tools/code_editor_dependency_test.dart)
for source verification, explicit reprepare, and source leases, plus
[`code_editor_smoke_test.dart`](../../test/tools/code_editor_smoke_test.dart),
shared settlement and launcher/discovery checks using local fixtures rather than
real Rust compilation or a live provider.

For narrow app iteration, first run `dart tools/adele.dart build-code-editor-tests`
from the repository root. Set `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` to the
absolute library directory it prints, then run from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/native_code_editor_test.dart test/code_editor_bridge_test.dart
```

The bridge fixture compiles only public UI and Flutter against compile-only editor
declarations, writes EVC bytes, and mounts through
`PreparedFrontend.load/createPresentation`. It exercises native input rather than
exporting a controller or mutation API to EVC. Its explicit synchronous snapshot is
`{text, revision}`; notifications carry no text. Revision includes component
selection/layout invalidations and is not a content version. Retired handles fail
against their captured owner; ordinary native operations already admitted to that
editor are not cancelled by a new focus policy. Text/undo ownership is separate
from widget lifetime, without a cursor/scroll restoration promise. See the
[current limitations](../../app/README.md#known-limitations), especially composition
at departure; a text snapshot is not lossless file-saving evidence.

When shared presentation or dependency wiring changes, include the nearby terminal,
prepared-host, public UI, analysis, and generation checks as appropriate. From
`app/`, serialize Flutter invocations sharing its build directory:

```sh
flutter test --no-pub --concurrency 1 test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart test/terminal_projection_bridge_test.dart
flutter test --no-pub --concurrency 1 test/prepared_frontend_activation_test.dart test/prepared_frontend_failure_test.dart
flutter analyze --no-pub --fatal-infos
```

From the repository root:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart analyze
dart tools/adele.dart generate --check
git diff --check
```

Select proportional checks rather than running both focused files and the full
desktop target for every edit. Widget/evaluator coverage is not a packaged library-loading
check or human keyboard/IME proof; use the separate
[integrated smoke](#integrated-editor-smoke) for Linux profile packaging. No
macOS/Windows acceptance is implied.

#### Deferred selected composition reproduction

[`selected_composition_repro.dart`](../../app/tool/code_editor_smoke/selected_composition_repro.dart)
is an explicit investigation, outside normal `*_test.dart` discovery and editor
acceptance. After bootstrap with the pinned SDK, prepare the native library from
the repository root:

```sh
dart tools/adele.dart build-code-editor-tests
```

From `app/`, use the absolute library directory printed by that command:

```sh
env FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=/absolute/path/printed/by/build-code-editor-tests \
  flutter test --no-pub --concurrency 1 tool/code_editor_smoke/selected_composition_repro.dart
```

Replacing selected `a` in `ab` with composing `x` must finish as `xb`. The normal
completion control preserves that result; the two departure cases, blur/refocus
and unmount/remount, are known to fail with `b`, while undo restores `ab`. Keep the
correct `xb` assertions: these failures are deferred evidence, not accepted
behavior or a normal acceptance gate. No composition repair or cancel-on-blur
policy is implied. See the [retained findings](../experiments/codeforge-correctness.md).

### Focused command output checks

After bootstrap/current generation, use the pinned SDK and serialize Flutter
invocations sharing the app build directory. The plugin-owned capture/read/watch
and generated contract checks run from the repository root:

```sh
dart tools/adele.dart test --target command_tools_plugin
dart tools/adele.dart test --target command_tools_backend
dart tools/adele.dart test --target command_tools_contract
dart tools/adele.dart test --target adele_model_tool
dart tools/adele.dart test --target adele_project_storage
dart tools/adele.dart test --target contract_codegen
dart test test/tools/adele_test.dart test/tools/app_plugin_boundary_test.dart
dart tools/adele.dart generate --check
```

For focused provider iteration, run `dart test
test/git_worktree_environment_provider_test.dart test/backend_host_integration_test.dart`
from `plugins/git/packages/backend/`. Select the foreground process
cases when unrelated provider coverage is unnecessary; this work does not require
the PTY target. From `app/`:

```sh
flutter test --no-pub --concurrency 1 test/owning_backend_stream_bridge_test.dart
(cd .. && dart tools/adele.dart test --target command_tools_frontend)
flutter test --no-pub --concurrency 1 test/tool_inspection_frontend_eval_test.dart test/tool_activity_inspection_bridge_test.dart test/inspection_host_test.dart
flutter test --no-pub --concurrency 1 plugin_interactions_test/inspection/tool_inspection_interaction_test.dart
flutter test --no-pub --concurrency 1 test/terminal_projection_bridge_test.dart test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart
flutter test --no-pub --concurrency 1 test/console_bridge_test.dart test/console_controller_test.dart test/prepared_console_host_test.dart test/workbench_console_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
flutter test --no-pub --concurrency 1 plugin_interactions_test/execution/command_output_capture_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/remote_model_tool_host_test.dart test/core/remote_model_tool_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/project_storage_host_test.dart test/core/project_database_test.dart test/core/product_lifecycle_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
flutter test --no-pub --concurrency 1 test/prepared_session_services_test.dart test/session_execution_bridge_test.dart
```

The early stream fixture compiles a generated `Stream<DTO>` client and mounts its
EVC through `PreparedFrontend.load/createPresentation`, proving the evaluator
projection and generic host bridge separately from Command behavior. The decisive
command fixture crosses real shared-host/Git/Command AOT, generated authorized
process transport in both hops, and the Project storage grant into SQLite. Its
socket-gated process emits more than 12 Mi UTF-16 code units per pipe, including
known beginning/middle/late markers and terminal controls, then waits for release.
Bounded pages establish live marker availability and exact full reconstruction
before exit. Two identical invocations share one Run but not one capture. A fresh
Project/backend read requires neither Git nor an Environment materialization.

The test-only interpreted capture consumer uses the plugin-generated client over
actual backend transport, reads pages and live state, unmounts without stopping
capture, and remounts with fresh access. It remains independent of production
presentation, so rendering changes do not weaken the full-volume capture proof.
Fixture source and compilation live in
`app/test/fixtures/command_output_frontend.dart` and
`app/tool/command_output_frontend_compiler.dart`, not runtime preparation of a
stock view.

The stock output EVC is built through the existing tool-Inspection compiler with
generated own-backend reads/watch and generic console/projection declarations.
`command_output_frontend_eval_test.dart` tests that actual client and stock UI with
small native retention, including prefix reconstruction, long unbroken lines,
state-only updates, frozen history, bounded read admission, safe failures, and
scalar-only cold-remount state. Prepared console coverage additionally checks
resident readers and generated-service accounting across warm tab switches;
native/bridge cases enforce the separate selected interaction epoch.
`terminal_projection_bridge_test.dart` separately
exercises scoped handles and revocation; existing interactive surface regressions
remain selected alongside it.
Readiness assertions observe native paint gating and settled viewport position at
frame boundaries, not only widget presence or the final rendered buffer. The stock
EVC cases cover finite high-water restoration under continued output, no ordinary
live-page flicker, and repeated hide/remount while a historical prefix is rebuilding.

The normal-application Command case in `normal_chatgpt_run_integration_test.dart`
uses the ordinary Chat activity click, stock Inspection/console EVCs, real Command
and Git AOT backends, SQLite, and deterministic local model responses. Its opt-in
mode in the existing socket-gated process fixture supplies ANSI, CR repainting,
partial lines, and known beginning/middle/late output. It checks both views before
completion, deduplication, identical-command independence, native scroll/follow,
and history beyond configured retention. Two warm output tabs retain tab,
resident, mounted view, and emulator identity across selection and repeated Show
more. A socket-gated later partial line is committed and consumed by the hidden
reader with Inspection closed; output also advances while interactive Terminal
is selected. Session departure revokes both residents and disposes their views,
while lightweight tabs survive for lazy cold historical reconstruction. It retains
the closing-readers-without-stopping-capture, nonzero completion, and fresh
compatible-backend history checks after Project reopen without installing Git.
The separate concurrent Session case continues to verify independent execution,
capture, approval, and history across navigation. These are debug
widget/evaluator/Linux-AOT checks, not paid-model or desktop/profile evidence.

Memory checks are accounting assertions, not absolute RSS claims: provider pending
decoded units/admitted reads and pause/resume, plugin pending batch row/text limits,
page limits, active writer/observer counts, coalesced paused notifications, and
absence of raw transcript events in generic progress/journal/activity. Test-owned
buffers used to compare expected whole transcripts do not represent production
retention. Resident count bounds are checked independently from Flutter subtree
disposal timing and do not claim absolute instantaneous object counts or RSS; see
the [host accounting policy](../../app/README.md#session-console). The normal
integration uses identity/lifetime evidence rather than adding production Command
read counters; deterministic stock EVC fixtures cover precise read/watch accounting.
The native process fixture is local and deterministic; these checks use
no paid/live model or desktop/profile run. Command capture
uses foreground pipes, not a PTY; the normal application's separate interactive
Terminal coexistence check does run the stock PTY path.
Run `dart tools/adele.dart test --target adele_plugin_interactions` from the root
for the maintained cross-plugin capture suite. The normal application suite is
still in `adele_desktop`.

### Focused terminal checks

After bootstrap, run from `app/` using the repository pin:

```sh
flutter test --no-pub --concurrency 1 test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart
flutter test --no-pub --concurrency 1 test/environment_terminal_owner_test.dart test/environment_terminal_integration_test.dart
flutter analyze --no-pub --fatal-infos
```

The fixture under `app/test/fixtures/terminal_frontend.dart` compiles against the
real public UI stub and compile-only declarations, writes EVC bytes, and loads and
mounts through `PreparedFrontend`. It uses synthetic ordered output and native
recording sinks, no shell, credentials, network, or product objects. Native event
paths exercise text/control input, explicit paste, focus, mouse reporting, and
layout changes. Fixed frame advancement accounts for the terminal's gesture and
cursor behavior; do not use unbounded `pumpAndSettle` with blinking cursors.

The Environment owner tests cover lifetime and captured authority separately from
the presentation-only regressions. The real integration prepares the same frontend
fixture and crosses the native owner, generated Environment transport, shared AOT
host, and actual Git backend. Its local process fixture uses bounded handshakes,
not credentials, network, or model calls. A widget-only or standalone native PTY
test is not a substitute for that combined path.

From the repository root, the owning public/backend and preparation checks are:

```sh
dart tools/adele.dart test --target adele_environment
dart tools/adele.dart test --target git_backend
dart tools/adele.dart test --target adele_tools
dart tools/adele.dart generate --check
```

The low-level terminal app files are automatically included by the unrestricted
`adele_desktop` target and its CI selection; their probe EVC needs no stock frontend
preparation. Stock console composition is a separate check below. The Git backend
target includes native PTY/shared-host and provider resource tests. CI explicitly
installs `gcc` and `libc6-dev` for the native Git/app checks. Keep Flutter compiler/test
invocations sharing the app build directory serialized. These checks target debug
widget/evaluator behavior on the pin, not native desktop/profile or cross-platform
runtime support.
The [application map](../../app/README.md#native-terminal-surface) owns the
adapter's lifetime, callback, and attachment policies.

### Focused console checks

This is a validation command map, not recorded pass results. After bootstrap and
current contract generation, run the focused host checks from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/console_controller_test.dart test/workbench_console_test.dart test/prepared_console_host_test.dart
flutter test --no-pub --concurrency 1 test/prepared_frontend_activation_test.dart test/command_palette_test.dart test/prepared_command_palette_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
```

From the repository root, select the public contract, descriptor, stock EVC, and
tooling targets as appropriate:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target terminal_frontend
dart tools/adele.dart test --target adele_tools
```

The stock Terminal case reuses the normal application integration fixture: prepared
Local Directory/Task Browser/Chat/Terminal EVC, real shared-host and Git AOT,
SQLite, and the prepared Git PTY helper. It targets Session-only chrome (no Task
Browser panel/toggle/actions), hidden New Terminal outside a Session, palette
creation from a collapsed console followed by `+` creation through the same stock
operation/numbering/Environment owners without a Run, independent shells,
input/resize, hidden output/title changes, Session/Environment navigation, actual
exit/removal, conservative close, and shutdown. It needs Linux x64/devpts and the
native prerequisites above, not credentials or a paid model.

The real-shell fixture launches the unchanged shared host through a controlled
environment wrapper with temporary `HOME`, `SHELL=/bin/sh`, and fixed `PATH`;
personal startup files do not determine test behavior. Provider-only default-shell
cases and their narrower environment seam belong to the
[Git provider](../../plugins/git/README.md#interactive-terminals).
Production shell resolution/startup is not replaced by that fixture configuration.

Keep Flutter compiler/test invocations sharing app build output serialized. Use
bounded predicate/frame advancement for mounted terminals, not unbounded
`pumpAndSettle` with a blinking cursor. These checks target debug widget/evaluator
and actual Linux AOT/process boundaries, not native desktop/profile or cross-platform
support. They complement rather than replace the low-level terminal checks above.

### Focused browser checks

The Task Browser public resolver belongs to
[`packages/ui/test/task_browser_test.dart`](../../packages/ui/test/task_browser_test.dart);
descriptor validation belongs to
[`packages/plugin_runtime/test/prepared_plugin_catalog_test.dart`](../../packages/plugin_runtime/test/prepared_plugin_catalog_test.dart).
The stock frontend's actual-EVC presentation cases belong to the
[`task_browser_frontend` tests](../../plugins/task_browser/packages/frontend/test/task_browser_frontend_test.dart),
separate from app source/authority and real-backend composition checks. Use the
maintained targets from the repository root after bootstrap:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target task_browser_frontend
dart tools/adele.dart test --target adele_tools
```

For focused host and navigation iteration from `app/`, with generated parts current:

```sh
flutter test --no-pub test/window_task_browser_source_test.dart test/task_browser_bridge_test.dart test/task_browser_presentation_host_test.dart
flutter test --no-pub test/prepared_task_browser_host_test.dart
flutter test --no-pub test/session_presentation_lifecycle_bridge_test.dart test/prepared_session_services_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
```

The normal integration uses prepared AOT/EVC components and real SQLite/Git with
local fake Responses and credentials, not a live paid model. Browser reads/opening
are checked separately from Task establishment and Run execution. Workspace,
analysis/test discovery, frontend compilation, frontend-only installation assembly,
and production app dependency boundaries are tooling concerns, not established by
a plugin widget test alone. These paths and commands are a validation map, not
recorded pass results or cross-platform desktop proof.

The concurrent Session case routes deterministic model continuation by each
Session's own prompt/tool context, not a global call count. Socket handshakes hold
A's command while B emits real output in a separate worktree; returning to A
checks retained Run/capture identity, hidden approval, exact resolution, and final
canonical history. Failed-test cleanup releases the processes before application
shutdown drains them. For application-wide ownership/navigation changes, follow
focused checks with the maintained `dart tools/adele.dart test --target
adele_desktop --ci`; preserve its single Flutter-worker policy.

### Focused normal Git Task and startup checks

Each suite compiles the actual shared host and stock Git and OpenAI backends to
AOT. Each case gets fresh installations and a runtime; teardown checks that the
loopback server received no OAuth or model requests and no credential file was
created. Choose by the behavior that must hold:

| Maintained target | What the suite checks |
| --- | --- |
| `git_desktop_tests` | [Git Task establishment and buffered processes](../../plugins/git/packages/desktop_tests/test/normal_task_git_integration_test.dart): clean and dirty nested sources produce isolated, anchored Task worktrees; a non-Git source publishes no Task or Environment. Native buffered operations select the exact worktree for each of two Tasks without granting process access to another backend. Both backends activate, but Git supplies the Environment. |
| `adele_plugin_interactions` | [Git/OpenAI startup](../../app/plugin_interactions_test/startup/git_openai_startup_interaction_test.dart): absent configuration (including root-only startup) leaves OpenAI active without a model; invalid configuration fails only OpenAI. Stopping configured OpenAI leaves the shared host, exact Git binding, materialization and Session authority intact for continued use and further Task creation. |
| `adele_desktop` | [Application startup and shutdown](../../app/test/core/normal_task_git_integration_test.dart): missing host or malformed startup arguments fail globally; installation failures and registration collisions stay local. Shared-host loss invalidates all bindings; close retires bindings before connections and host, drains acquired backends during startup, and skips later installations. |

After bootstrap, use the pinned `FLUTTER_ROOT`, its matching Dart AOT runtime,
Git, and the [native TOML prerequisites](toolchain.md#native-toml-documents).
The buffered-process case needs Linux x64 and util-linux `setsid`. These files
need no CodeForge loader, desktop bundle, Git PTY helper, or live credentials.
Run the selected commands from the repository root, serializing the two `app/` runs:

```sh
(cd plugins/git/packages/desktop_tests && flutter test --no-pub --concurrency 1 test/normal_task_git_integration_test.dart)
(cd app && flutter test --no-pub --concurrency 1 plugin_interactions_test/startup/git_openai_startup_interaction_test.dart)
(cd app && flutter test --no-pub --concurrency 1 test/core/normal_task_git_integration_test.dart)
```

### Focused durable Git Task checks

Each suite compiles the shared host and the stock Git and Local Directory
Project backends to AOT and uses real Project SQLite storage. Choose by the
behavior under test:

| Maintained target | What the suite checks |
| --- | --- |
| `adele_desktop` | [Host publication](../../app/test/core/durable_task_git_integration_test.dart): an anchor `INSERT` or deferred `COMMIT` failure publishes no new Task or Environment even though the Git worktree exists. A held establishment result cannot enter SQL after its provider retires, even with a same-ID replacement. |
| `git_desktop_tests` | [Stock Task comparison](../../plugins/git/packages/desktop_tests/test/durable_task_git_comparison_test.dart): after reopen, a missing anchor, unexpected branch, or unavailable baseline commit fails Task comparison without rewriting the anchor or disabling Unstaged and Uncommitted. The test uses Diff's generated client, not its frontend. |
| `adele_plugin_interactions` | [Local Directory + Git](../../app/plugin_interactions_test/project/durable_project_git_interaction_test.dart): the Project's `.adele/data.db`, Git anchor and dirty worktree survive both same-directory restart and a whole-Project move. Opening restores records without touching Git; explicit materialization restores the checkout and repairs moved metadata. |

For focused runs, bootstrap from the repository root with the pinned
`FLUTTER_ROOT`, its bundled Dart and matching `dartaotruntime`, and install
[Rust 1.93.0 for native hooks](toolchain.md#native-toml-documents). Use Git on Linux
x64; the comparison and restart/move cases also run real buffered processes
with util-linux `setsid` and the [Git inspection commands](../../plugins/git/README.md#portable-unstaged-inspection).
None of these files needs a CodeForge library or loader variable, a desktop
bundle, a Git PTY helper, or live credentials. The complete desktop and
interaction targets still prepare CodeForge for other files.

```sh
# app/: host publication, then the two-plugin interaction. Run serially.
flutter test --no-pub --concurrency 1 test/core/durable_task_git_integration_test.dart
flutter test --no-pub --concurrency 1 plugin_interactions_test/project/durable_project_git_interaction_test.dart
# plugins/git/packages/desktop_tests/: Git-owned comparison behavior.
flutter test --no-pub --concurrency 1 test/durable_task_git_comparison_test.dart
```

For a complete owner, run `dart tools/adele.dart test --target NAME --ci` from
the repository root with the target name from the table and no `--shard`.

### Focused persistence checks

After bootstrap, regenerate contracts from the repository root when declarations
or transport consumers change:

```sh
dart tools/adele.dart generate
```

For Session/storage work, use selected tests from `app/`, rather than routinely
running the full desktop target:

```sh
flutter test --no-pub test/core/project_database_test.dart test/core/durable_session_lifecycle_test.dart test/core/project_storage_host_test.dart
flutter test --no-pub --concurrency 1 test/core/durable_chat_session_integration_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
```

The real-AOT integration needs the pinned Dart AOT toolchain and Git but no live
provider credentials. It checks durable state across runtime/backend lifetimes,
including exact partial-draft restoration without Run start and submission
retention after another reopen, not interactive desktop navigation or approval
restart. The normal Chat test uses a local fake provider and exercises prepared
browser/breadcrumb navigation, composer-to-Run flow, and reopened terminal activity
through the same presentation paths. Consult the test source
for its exact cases; these commands are guidance, not recorded pass results.

The public contract's value/transport checks belong to
`dart tools/adele.dart test --target adele_project_storage`. Chat-owned store and
remote settlement cases live in
[`chat_durable_state_test.dart`](../../plugins/chat_strategy/packages/backend/test/chat_durable_state_test.dart)
and [`chat_remote_backend_test.dart`](../../plugins/chat_strategy/packages/backend/test/chat_remote_backend_test.dart).
From `plugins/chat_strategy/packages/backend/`, use:

```sh
dart test test/chat_durable_state_test.dart test/chat_remote_backend_test.dart
```

The maintained `chat_strategy_backend` target is the broader package check from
the root. These tests complement app integration for corruption, failed writes,
canonical-cache ordering, explicit volatile behavior, and post-materialization
Run association/cleanup without overwriting an accepted association.
Draft cases include SQLite-trigger rollback of set/submission, unchanged entry
occurrence IDs after failure, mutation/execution fencing, and rejection before
persisting a draft that would exceed the existing full-row read bound. Contract
changes, including the required nullable `ChatEntry.runId` key, additionally require
`dart tools/adele.dart test --target chat_strategy_contract`
and `dart tools/adele.dart generate --check`; eval preparation derives the current
wire shape from those same declarations, with no old-wire compatibility.

For execution evidence and terminal Run/history changes, select public-value
checks from the repository root for the affected boundary:

```sh
dart tools/adele.dart test --target adele_product
dart tools/adele.dart test --target adele_orchestration
dart analyze --fatal-infos packages/product
```

Then run the affected database, Session, authority, execution, and restart tests
from `app/`, plus deterministic Chat integration for its separate storage boundary:

```sh
flutter test --no-pub \
  test/core/project_database_test.dart \
  test/core/execution_evidence_test.dart \
  test/core/durable_session_lifecycle_test.dart \
  test/core/orchestration_host_test.dart \
  test/core/orchestration_authority_test.dart \
  test/session_execution_test.dart \
  test/session_execution_activity_test.dart \
  test/session_execution_bridge_test.dart \
  test/core/durable_run_lifecycle_test.dart
flutter test --no-pub --concurrency 1 test/core/durable_chat_session_integration_test.dart
flutter analyze --no-pub --fatal-infos \
  lib/core lib/ui/execution test/core test/session_execution_test.dart
```

These are focused implementation checks, not a reason to run the broad
`adele_desktop` target or launch/build the desktop for a terminal-history change.
The Run restart fixture uses real SQLite and deterministic strategy/model/tool
mechanics; the Chat fixture crosses real backend generations without a live model.
Evidence checks cover unfinished model/tool and approval prefixes, original
Run-local sequences/provenance, suffix-only SQL writes, immutable-prefix checks,
INSERT/COMMIT rollback, and complete validation before restored publication. A
failed terminal seal must preserve its earlier checkpoint without publishing a
product outcome. Recovery distinguishes sealed terminal evidence, unsealed
interrupted history, and unknown evidence; terminal-only lookup stays unchanged.
The durable Run suite also kills a small writer subprocess after independently
confirming its committed tool-start prefix, then reopens without orderly Run close.
The SIGKILL case is Linux-only; the remaining deterministic gates are
platform-neutral.
The assertions distinguish immutable historical evidence from live execution and
check pre-effect commit ordering, checkpoint-failure fencing, primary-error
preservation, sole storage-error surfacing, cleanup, and no automatic retry.
Historical activity checks also cover Session scope and the read-only bridge;
the prepared frontend cases cover placement and
safe display without feeding historical native data into future continuation.
See [terminal retention semantics](../architecture/execution-model.md#terminal-run-retention)
and [execution history](../architecture/execution-model.md#terminal-execution-history).
For documentation-only updates, use the [proportionate checks](#proportionate-validation)
instead of running these behavioral suites.

Infrastructure grants also require focused transport/lifecycle validation in
[`plugin_runtime/test/extension_runtime_test.dart`](../../packages/plugin_runtime/test/extension_runtime_test.dart),
[`plugin_backend_host/test/plugin_termination_test.dart`](../../packages/plugin_backend_host/test/plugin_termination_test.dart),
and [`plugin_backend_support/test/host_request_multiplexer_test.dart`](../../packages/plugin_backend_support/test/host_request_multiplexer_test.dart).
Use the owning package's direct tests or maintained target. Check workspace,
generation configuration, analysis/test discovery, and app production dependency
boundaries when changing `adele_project_storage` wiring; passing only direct
contract tests does not establish repository integration.

## Native build and runtime smoke

When native packaging or runtime changes warrant it, use the relevant path:

```sh
dart tools/adele.dart build linux --profile
dart tools/adele.dart smoke linux --profile
```

The normal build validates normal application preparation/packaging; it does not
run the app. The separate development smoke builds and executes
[`app/tool/development_runtime_smoke/main.dart`](../../app/tool/development_runtime_smoke/main.dart).
That exercises reference-fixture build/start/stop and runtime cleanup, not normal
product interaction. Neither path automatically proves interactive native-picker
behavior.

The smoke needs existing directories configured through
`ADELE_DEVELOPMENT_REPOSITORY_ROOT`, `ADELE_DEVELOPMENT_PLUGIN_DIRECTORY`, and
`ADELE_DEVELOPMENT_DIRECTORY`; the
[smoke workflow](../../.github/workflows/runtime-smoke.yaml) shows its reference
fixture and display setup. Follow [toolchain policy](toolchain.md) for SDK,
generation, and artifact-preparation details.

### Integrated editor smoke

[`tools/code_editor_smoke.dart`](../../tools/code_editor_smoke.dart) builds the
**actual application package** in profile mode with
[`app/tool/code_editor_smoke/main.dart`](../../app/tool/code_editor_smoke/main.dart)
as its development entrypoint. It first compiles the public-UI fixture into EVC,
then packages `data/editor_frontend.evc` beside the app's native library. Runtime
loads those prepared bytes; it never compiles source or substitutes another editor.
The default mode is an isolated development surface, separate from normal product
startup. The same target's [workspace mode](#manual-grouped-workspace) instead
hosts prepared contributions alongside stock Chat in the actual application.

Use Linux x64, the pinned Flutter/Dart and Rust toolchains, ordinary Linux Flutter
desktop dependencies, `timeout`, `sha256sum`, and Xvfb (`xvfb-run`). After bootstrap,
run from the repository root with explicit SDK selection:

```sh
ADELE_FLUTTER=/absolute/path/to/flutter-3.38.10
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart editor-smoke linux
```

The focused checks cover bundled `lib/libcode_forge.so` loading from
`/proc/self/maps`, native editing in a prepared EVC pane, generic notifications and
explicit snapshots, undo/redo, fixed read-only behavior, rendering, and text/undo
retention across fresh presentation mounts. They do not test strict content
versions, native callback cancellation, selection restoration, or distribution
clearance. Injected text-input messages and engine key records are not human OS
keyboard or IME tests.

The runner launches from a fresh working directory without loader overrides, then
temporarily removes the bundled library for a separate negative subprocess and
restores it afterward. Missing-library acceptance requires an actual initialization
failure, not a mapping failure after successful initialization, a timeout, signal,
or arbitrary nonzero exit. Shared settlement latches the first framework/platform
failure and rejects failure markers even if a completion marker was already
written. Logs, the native artifact hash, and `result.json` remain under
`app/build/code_editor_smoke/logs/`. The
[editor smoke workflow](../../.github/workflows/code-editor-smoke.yaml) invokes this
path and retains diagnostics.
These are expected checks, not a claim that the current profile run has passed.

#### Manual entrypoint

To prepare without running the automated positive/negative subprocesses, then
launch on the user's desktop, use the repository root:

```sh
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart editor-smoke linux --prepare-only
env -C /tmp -u LD_LIBRARY_PATH -u LD_PRELOAD -u FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR "$PWD/app/build/linux/x64/profile/bundle/adele_desktop" --interactive
```

`--prepare-only` builds the app and precompiles/packages EVC. This is a
source-checkout development target, not portable release packaging. The same
fixed-dark UI shows independent editable/read-only EVC panes, Snapshot/state
revision, synthetic clipboard, focus, unbind/rebind, and close controls; there is
no theme selector. Undo/redo use ordinary editor keyboard shortcuts.
Only synthetic in-memory content is used: no file opening/saving, diff, LSP, AI,
or network.
Do not run this preparation concurrently with other Flutter work sharing app build
output or with explicit dependency replacement.

1. Use **Focus editable**, type and delete a short ASCII sequence at a natural
   pace, then use Ctrl+Z/Ctrl+Y to check grouped undo/redo. Use **Snapshot** and
   inspect state revision; selection/layout changes may also advance revision.
2. Use **Copy synthetic emoji** or **Copy synthetic CRLF**, then **Focus editable**
   and paste. These replace the clipboard with U+1F600 or `a\r\nb` (actual CRLF).
   Use **Snapshot** after edits and undo to inspect the escaped text; distinguish
   `\r\n`, `\n`, and a stray `\r` rather than relying on rendering alone.
3. Use **Focus read-only**, select/copy text, and attempt typing, paste, and undo.
   Its text must remain unchanged. Switch panes and away from/back to the window;
   new typing should follow focus. Already admitted clipboard work may finish on
   its original editor.
4. Finish composition, use **Unbind editable**, then **Rebind editable** for a
   fresh presentation. Check retained text and undo, without expecting cursor or
   scroll restoration, then use **Dispose and close**. Consult the
   [known composition limitation](../../app/README.md#known-limitations) rather
   than treating departure during composition as a passed check.

Human validation of this integrated path is not established here. An automated
smoke result or `--prepare-only` build must not be reported as those human checks.

#### Manual grouped workspace

Reuse the same editor-smoke target rather than a separate development application.
With the pinned SDK and native prerequisites above, run from the repository root:

```sh
dart tools/adele.dart editor-smoke linux --workspace --prepare-only
env -C /tmp -u LD_LIBRARY_PATH -u LD_PRELOAD -u FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR "$PWD/app/build/linux/x64/profile/bundle/adele_desktop" --workspace
```

Preparation uses the stock catalog/build path and adds the freshly compiled
frontend-only Main Content fixture to that development installation root. Launch
uses `AdeleApplication`, ordinary catalog discovery/registration, stock Task Browser
and directly contributed Chat, and the shared fixture's native bindings. No runtime
compilation or manual collection injection substitutes for the interpreted contribution. Model
execution is intentionally disabled in this workspace route; no credentials or
Run are needed. The synthetic editor text is in memory, but ordinary Project/Task
creation still uses the stock product lifecycle, so choose a disposable Git Project.

1. Open that Git Project, create a Task, and create a Chat Session. Confirm Chat
   and **Editor A** are visible, then enter an unsent Chat draft.
2. Use **Open B**, **Rename B**, and **Reverse editors** in A. Check equal
   individual pane widths and that Chat's draft and both editors' text remain
   intact through title/order changes. Type separately in A and B and use ordinary
   undo/redo to check their independent state.
3. Narrow the window until Main Content overflows. Use **Focus A** and **Focus B**
   to reveal/focus the chosen editor without scrolling the surrounding surfaces.
4. Finish composition, use **Remove B** or its close chrome, then **Open B** again.
   B is a fresh editor; A and Chat should remain unchanged. Use the Task breadcrumb
   to leave, then reopen the Session to inspect fresh attachment. Consult the
   [known native limitations](../../app/README.md#known-limitations) for composition
   at departure.

The fixture deliberately releases its in-memory editor owners on departure.
It does not establish a rule for Source Documents keyed by Environment and
resource path; see [stock Source ownership](../../plugins/source_editor/README.md#ownership)
and the separate normal Source workflow below.

For automated profile coverage, `dart tools/adele.dart editor-smoke linux
--workspace` runs the existing editor positive/negative checks and an additional
`--workspace-smoke` subprocess over a temporary Git Project, normal application
navigation, and pane operations. It also exercises stock Source Open, explicit
Save into the captured Environment, retention/undo across Task Browser departure,
and Close, emitting `ADELE_SOURCE_WORKSPACE_COMPLETE`. This is not human
keyboard/IME evidence. Neither
these commands nor `--prepare-only` assert that manual validation has been run.
Do not prepare or run concurrent Flutter jobs against the same app build output.

### Manual Source workflow

Use the normal application, not the synthetic editor-smoke fixture. With the
pinned SDK/native prerequisites and bootstrap complete, run from the repository root:

```sh
dart tools/adele.dart run linux
```

Use a disposable Git Project with an existing committed small UTF-8 text file.
ADELE creates a separate Task Environment worktree; identify that checkout with
`git -C /absolute/path/to/disposable-project worktree list` before inspecting or
externally editing files. All checks below target that disposable Task worktree,
not the original Project source or the ADELE development checkout. No model
credentials or Run are needed. **Complete IME composition before Save, blur,
navigation, Close, or exit**; snapshots do not promise pending composition text.

1. Open the disposable Project, create a Task and Session, then choose
   **Open Source...**. Enter the existing Environment-relative path and choose
   **Open**; dismiss the input with **Close input**. Open the same path again and
   check that it focuses the same document without replacing text/undo. Open a
   second file and use **Move left** / **Move right** to check local order.
2. Edit each document independently and use ordinary undo/redo. Choose **Save**
   explicitly and inspect the Task worktree's file/diff. Check that the original
   Project source is unchanged. Unsaved edits are not autosaved; if edits occur
   while a Save is pending, only its captured snapshot is saved and later edits
   must remain unsaved.
3. Leave unsaved text, return to Task Browser, then reopen the Session or another
   Session in the same Task Environment. Check retained text, undo, and order.
   Create another Task/Environment and open the same relative path there: it is a
   separate document. Returning to the first Environment must not replace it.
4. With local edits still open, change that exact Task-worktree file externally.
   Choose **Save** and inspect the conflict indication and retained local text;
   the external version must not be forcibly overwritten. Use **Close**, then
   **Cancel** to retain the document. Deliberately choose **Close** / **Discard**
   and reopen to read the external version. There is no automatic retry, reload,
   merge, or force-save recovery.
5. Close unchanged/saved documents without a discard prompt. Close all Source
   panes and check that **Open Source...** still works. Make an unsaved edit,
   navigate to another Environment or Task Browser, then request window exit.
   Choose **Cancel** in the aggregate discard prompt and return to the document:
   text/undo and further editing/Save must remain usable. Finally save or explicitly
   accept discard and exit. There is no Project-switch action to test.

This procedure records no human result. Retain the existing
[selected-composition and Unicode limitations](../../app/README.md#known-limitations);
Source does not repair them or promise cursor/viewport restoration. The stock
provider rejects oversized, invalid UTF-8, or unsupported files rather than opening
a truncated editable preview. No autosave, file watcher, new-file operation, or
durable document restoration is implied; broader UX direction remains unchanged.

## Live tests

Live tests are explicitly opt-in and may incur API charges or consume subscription
usage. Run them deliberately, not as routine validation. Each gate below must be
exactly `1`. Credentials alone do not enable a test; an enabled test with missing
required credentials fails rather than silently skipping.

Normal CI discovers but skips these network cases because it supplies neither
gates nor credentials. Keep gates unset for normal local validation too:
`--ci` does not scrub inherited environment variables or disable live calls.

| App case | Enable variable | Provider / purpose |
| --- | --- | --- |
| [`openai_source_coding_live_test.dart`](../../app/test/development/agent/openai_source_coding_live_test.dart) | `ADELE_OPENAI_SOURCE_CODING_LIVE_TEST` | API key; search/read and continuation. |
| [`openai_source_mutation_live_test.dart`](../../app/test/development/agent/openai_source_mutation_live_test.dart) | `ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST` | API key; read/patch and continuation. |
| API-key case in [`openai_source_validation_live_test.dart`](../../app/test/development/agent/openai_source_validation_live_test.dart) | `ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST` | API key; read/patch/direct-argv validation. |
| [`chatgpt_source_coding_live_test.dart`](../../app/test/development/agent/chatgpt_source_coding_live_test.dart) | `ADELE_OPENAI_CHATGPT_LIVE_TEST` | ChatGPT; search/read and continuation. |
| ChatGPT case in [`openai_source_validation_live_test.dart`](../../app/test/development/agent/openai_source_validation_live_test.dart) | `ADELE_OPENAI_CHATGPT_SOURCE_VALIDATION_LIVE_TEST` | ChatGPT; read/patch/direct-argv validation. |

The app API-key cases require nonblank `OPENAI_API_KEY` and
`ADELE_OPENAI_TEST_MODEL`. They explicitly use the public Responses endpoint,
overriding inherited `ADELE_OPENAI_ENDPOINT`. App ChatGPT cases require
`ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE` and use `ADELE_OPENAI_CHATGPT_TEST_MODEL`
(missing/blank defaults to `gpt-6-astra`), not the normal desktop's
`ADELE_OPENAI_CHATGPT_MODEL`. Credential/OAuth/endpoint semantics belong to the
[OpenAI backend](../../plugins/openai/packages/backend/README.md) and its
[startup configuration](../../plugins/openai/packages/backend/bin/openai_model_provider_backend.dart).

The command-validation cases require Linux x64 process support and executable
`/usr/bin/setsid` or `/bin/setsid`; their gates do not automatically skip unsupported
platforms.

Provider-only live smokes belong to the
[OpenAI backend](../../plugins/openai/packages/backend/README.md#validation-scope):
`ADELE_OPENAI_LIVE_TEST=1` enables its API-key smoke, while
`ADELE_OPENAI_CHATGPT_LIVE_TEST=1` enables its ChatGPT continuation case. The latter
gate is shared with app source coding: running both suites with it set enables
both network cases. Consult the backend's
[API-key test](../../plugins/openai/packages/backend/test/openai_live_test.dart)
and [ChatGPT test](../../plugins/openai/packages/backend/test/openai_chatgpt_live_test.dart)
for their exact configuration; these are separate from the app full-stack cases
and from [desktop evaluation handoff preparation](../../plugins/session_evaluator/README.md#desktop-handoff).
