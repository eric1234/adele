# Command Tools

Command Tools is an independently installed stock plugin that contributes the
`run_command` model tool (`dev.adele.plugin.command-tools.run-command`). It asks
the Session host only for `AuthorizedEnvironmentProcessFacet` and runs one
foreground executable directly with verbatim arguments; it does not implicitly
invoke a shell. The root `command_tools_plugin` package owns the semantics;
`packages/backend` (`command_tools_backend`) reuses them through public generated
model-tool and Environment transport plus `adele_plugin_backend_support`. Its
entrypoint is `packages/backend/bin/command_tools_backend.dart`. Validation, effect
description, capture, and terminal output bounds are not duplicated
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
Environment stdout and stderr are captured by this plugin, not forwarded into
generic tool progress, RunJournal, or activity snapshots. The terminal model result
independently retains at most 32 Ki UTF-16 code units per stream as a deterministic
16 Ki head plus 16 Ki tail. Model-result truncation is not transcript truncation.

## Full decoded-text capture

`lib/src/command_transcripts.dart` owns the relational schema, writer, validation,
read service, and notifications. The backend binds `ProjectStorageServiceClient`
once from its generation-scoped infrastructure context under the actual
`dev.adele.plugin.command-tools` owner, independently of each operation's process
token. Native callers explicitly inject `CommandTranscriptStore`; omission allows
materialization/description but rejects execution before process launch. There is
no default in-memory transcript or native application reader.

The current v1 baseline has `adele_command_captures` headers keyed by the host's
existing Run-local tool-invocation ID with composite key `(invocation_id, run_id)`
and `adele_command_chunks` with composite primary key
`(invocation_id, run_id, position)`. Headers store Session/Run association, Environment and
direct-command metadata, capture state, committed high-water/UTF-16 extent, version,
and known termination/exit facts. Session identity references the canonical Session
row; Run/invocation association does not reference terminal-only core history.
`ToolExecutionContext.toolInvocationId` is the opaque value of the existing public
orchestration identifier, not a new command identity or authority token.

Schema and unique header admission commit before listening to the lazy process
stream. Neither validation, denied approval, description nor passive reads create
a command row. Repeated admission cannot overwrite or append to an existing
invocation, even for identical command text. Every received decoded text event is
split without dividing supplementary characters and immediately committed in
bounded transactions; there is no timer waiting for a newline, future event, or
command completion. Each transaction compare-and-swaps the writer's acknowledged
version/position and atomically inserts chunks with the advanced extent. Watch
invalidation happens only after acknowledgement of readable state.

| Bound | Limit |
| --- | --- |
| Provider/transport event | 16,384 UTF-16 code units; the provider separately bounds already-admitted pipe reads, see the [Git provider](../git_environment/README.md). |
| Stored chunk | 4,096 UTF-16 code units; provenance is `stdout` or `stderr`. |
| Append batch | At most four chunks / 16,384 UTF-16 code units, one awaited transaction per writer, with one header update plus at most four inserts. |
| Flush delay | No intentional batching delay: even one received partial-line event is committed before requesting another. Actual latency includes storage/transport admission and commit. |
| Read page | At most 16 chunks / 65,536 UTF-16 code units; caller bounds may reduce both. The row limit is conservatively reduced by the maximum chunk size. |
| Metadata | At most 128 KiB encoded JSON at admission, ensuring individual headers remain readable within shared storage limits. |
| Model result | 32,768 UTF-16 code units per stream, independent head/tail calculation over all received output. |
| Watcher | One in-flight bounded state read, one admitted notification, and a dirty bit; paused changes coalesce rather than queue per append. |

No transcript text, per-chunk index, snapshots, or append Future chain is retained
in plugin memory. There is one writer per active command, one schema Future per
accessed Session, and bounded failure information per failed invocation when
failure acknowledgement is unavailable. Successful completed writers are removed.
For a fixed set of commands/readers, these objects and the buffers above do not
grow with output volume. SQLite remains host-owned; capture does not expose paths
or handles. Reads use indexed keyset seeks, never full-history loading.

The store explicitly selects `ProjectStorageAccessMode.durableOrTemporary`.
Durable Projects retain plugin tables in their shared database, including after
Run failure, plugin disablement, or Project reopen. Explicitly volatile Projects
use a host-private temporary on-disk relational backing for the live Project
lifetime, surviving command, frontend, and backend replacement. They remain
non-durable, and orderly lifecycle disposal removes the backing. A failed durable
database never falls back to temporary storage. Core knows neither command SQL nor
capture metadata; a compatible future backend alone interprets retained tables.

## Passive read and watch

`packages/contract/lib/command_tools_contract.dart` is the annotated pure-Dart
source for generated native and evaluator clients. Its generated sibling is
registered in `contract_codegen.yaml` and ignored. The plugin-internal
`CommandOutputService` is routed alongside `modelTool` on the exact backend's
configuration context, not exposed as a core Capability. Native application code
has no contract import or handwritten Command codec.

`getState`, `readAfter`, `readBefore`, and `watch` take Session, Run, and exact tool
invocation IDs. Existing records validate all three associations. Absent capture
returns `state: absent`, distinct from an admitted empty command. One bounded SQL
snapshot selects the exact Run/invocation or a foreign candidate, so concurrent
admission cannot turn an earlier empty lookup into a false association mismatch.
Chunk positions
are stable one-based ordinals in observed combined pipe-arrival order, not byte
offsets or a stronger cross-pipe ordering guarantee. Cursors are exclusive:
`readAfter(..., 0, ...)` starts at the beginning; `readBefore(..., null, ...)`
reads the current tail, then the first returned cursor continues backward. Pages
always return ascending positions. An empty forward page means end of the current
committed extent, not command completion. A tail is text, not emulator state.

Subscribe before paging: watch immediately provides current state/high-water,
then coalesced committed extent and state changes. Page forward from the last
consumed cursor until the notified extent; another notification covers concurrent
appends. Version counts committed header transitions; an unacknowledged failure
can change live failure/state without advancing that version. Consumers must
observe state as well as extent/version, not deduplicate on output size alone.
Independent readers can page old data while another follows. A paused
reader catches up from storage. Cancelling/unmounting a watcher detaches only that
observer, never execution, capture, another reader, or stored data. History needs
only fresh permitted plugin storage access, not the former execution token or an
Environment materialization. The generic interpreted own-backend bridge carries
generated unary and server-streamed calls with exact generation/view lifetimes.

## Failure and lifetime

Process outcome, committed extent, capture completeness, backend availability, and
Run outcome are separate. `capturing` is live only with this generation's writer;
a fresh backend exposes an abandoned capturing row as `interrupted`, never as a
resumed process. `complete` requires all admitted output committed and an
acknowledged final seal. Nonzero exit may have complete output. Provider incomplete
drainage, append failure, transport loss, and seal failure never imply complete
capture, even with a known zero exit code.

Known setup failure prevents launch. Append failure stops consumption and cancels
the producer through its existing bounded path. The tool returns infrastructure
failure with uncertain effects once execution was admitted, preserving known
termination/exit facts. A failed seal does not invent another exit code. Failure
diagnostics prefer typed completion as a whole, including its null timed-out exit
code. Untyped optional facts are accepted only as `exited` plus an integer code or
`timedOut` plus null. Invalid pairs are omitted, not cast, reinterpreted, or copied
into structured diagnostics; the original error remains the failure cause. The
same plugin-local validator protects failure writes and stored-header reads.
Failure
marking is best-effort and conditional on the last acknowledged extent: a lost
append acknowledgement is not blindly retried or overwritten. If the marker
cannot commit, live state reports failure; without a committed seal the stored row
stays non-complete. Lost acknowledgement can still leave the atomic append or seal
committed, which a fresh reader can inspect without guessing rollback. No process is rerun to
resolve uncertainty and no core Run row is manufactured.

Backend close fences admission, closes watchers without waiting for paused UI,
and cancels active producers. It does not extend revoked storage grants to finish
writes. Normal execution seals before returning its terminal result; shutdown
that prevents sealing leaves honest partial history. Presentation disposal is
not backend shutdown. The [focused proof commands](../../docs/development/testing.md#focused-command-output-checks)
cover real shared-host AOT capture and a compiled test-only consumer mounted through
`PreparedFrontend`, separately from production presentation work.

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
