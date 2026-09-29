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
snapshot selects only the exact Run/invocation; a reused invocation string in
another Run does not establish an association. Watch registration precedes the
initial read, so a watcher remains subscribed after absence and observes later
admission, including admission racing that initial snapshot.
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

## Live Inspection and console output

The separate Flutter package `packages/frontend` (`command_tools_frontend`) owns
both interpreted output presentations. It depends on Flutter, `adele_ui`, and its
deliberate `command_tools_contract`, not the headless implementation, app, or
kernel. `command_tools_frontend.dart` retains argument boundaries and factual
tool lifecycle/disposition metadata. `command_output_view.dart` owns generated
`CommandOutputServiceClient` reads/watch, ordered replay, capture/process status,
history navigation, and follow behavior. Normal stdout/stderr appears only in
the terminal projection, not duplicate plaintext model-result previews or
truncation chrome. The bounded backend model result remains unchanged; factual
failure metadata and bounded failure detail remain available without a capture.

An ordinary Chat activity click opens the Command Tools Inspection card. Its
Session/Run/invocation strings come from the canonical activity occurrence,
including historical activity, through the generic read-only Inspection snapshot.
The card subscribes before reading, so opening before header admission shows
absence and then observes admission without a retry timer. Prepared, waiting,
denied, absent capture, admitted empty output, process outcome, capture failure,
reader failure, and replay state remain distinct. Nonzero exit can have complete
capture; partial failed captures still offer **Show more**.

The compact entrypoint remains a separate bounded program/argv summary. It does
not create an output reader, replay history, or request a terminal projection.
Common hosting owns inspect interaction and exact-invocation approval controls.
The card cannot execute, approve, rerun, send input, or materialize an Environment.
Opening it does not open the console.

Show more calls the generic declared-console bridge for
`dev.adele.plugin.command-tools.output`. Its opaque content key length-delimits
Run/invocation IDs; the host additionally scopes it to the exact contribution
generation and canonical Session. Repeated opens focus the existing tab without
resetting the reader; identical argv never determines identity. The host retains
only validated descriptors and bounded opaque data, not callbacks into the card.
The console EVC independently reads its content identity and acquires revocable
own-backend and projection access. Its prepared descriptor explicitly sets
`keepAlive`; Inspection and interactive Terminal do not acquire resident console
behavior merely by displaying output.

### Replay and history

Each presentation has an independent native read-only projection: fixed 80 columns,
6 rows for the preview or 20 rows for expanded output, and 200 retained lines
including the viewport. Narrow views can scroll horizontally without changing
the replay geometry. Follow targets the painted cursor/output rather than blank
emulator padding, including when the available height is less than 20 rows.
Pipe-display LF starts the next line at column zero; stored
text is unchanged, explicit CR/ANSI retain their behavior, and interactive PTY
handling is separate. No terminal-library types cross the public bridge.
REP controls through 1,024 repetitions render exactly; larger single-operation
amplification is an explicit unavailable projection, not silently clamped output.
The native owner discards that failed projection and acknowledges no text from
the failed feed. This bounds synchronous parser work independently of page size.

The plugin feeds stored chunks in their combined recorded order, preserving each
chunk's stream field in its read model without inserting stream labels. A fresh
emulator always replays from cursor zero, never from an arbitrary tail. One drain
owns at most four chunks / 16,384 UTF-16 code units, and feeds at most 1,024 units
or one screen's row advances before yielding through the scoped native projection
bridge. That yield checks exact presentation liveness before resumption and
avoids a pinned evaluator multi-compiler constructor limitation. Accepted feed counts
advance an intra-chunk offset; a chunk cursor advances only after its entire text
has been applied. Partial lines and split control sequences need no newline or
final model result to become visible.

Initial and remounted projections remain laid out but do not paint, accept local
interaction, or expose output semantics during reconstruction. A following reader
captures one finite committed high-water at initialization, reveals after that
prefix and its viewport settle, then drains newer live output without hiding again.
While newer committed output remains pending, following status reports that the
reader is catching up rather than implying it has consumed the current high-water.
Historical seeks likewise reveal only after their saved endpoint and local scroll
offset settle. Readiness grants no capture or execution authority; a failed replay
shows safe status instead of exposing a misleading partial reconstruction.

Expanded output initially follows. **Beginning**, **Earlier**, **Middle**, and
**Later** replay a prefix to a rendered-row endpoint. Adjacent windows advance
`maxLines - rows - 2` row advances (178 with stock expanded geometry), with overlap
inside the finite buffer. Native feed can stop within a stored chunk, so a long
unbroken soft-wrapped line cannot skip a window. Beginning and middle are real
prefix reconstructions, not cursor labels over a tail. Earlier/later controls and
local scrolling provide access beyond evicted native scrollback, without one
retained checkpoint/widget per chunk. Middle uses the furthest rendered extent
observed by this reader; Follow output first catches up to include newer history.

Inspection explicitly selects the projection's always-follow policy: it is a
small live recent-output preview, not an independent historical reader. Vertical
scroll gestures remain available to the surrounding card instead of latching the
preview into history mode. Selection and explicit safe copy remain available,
but selection does not stop the preview's feed. Show more opens the historical
reader; the preview has no separate Follow action.

Expanded output selects interactive follow. User scrolling away freezes native
feed synchronously, before delayed reads or notifications can move or evict the
inspected region. Selection also protects that region. Observation continues,
coalescing committed state/extent. A user wheel/drag return to the rendered end
of a paused live-tail projection resumes from its exact applied cursor and
intra-chunk offset, drains committed backlog, and reports replay until caught up.
The rendered end accounts for blank fixed-geometry screen padding; programmatic
scrolling, layout, and restoration never count as user return.

Beginning/Earlier/Middle/Later deliberately select an explicit historical window.
Scrolling to that window's local bottom does not resume live following. The
down-arrow **Follow output** action leaves that mode, clears the protected
selection, and catches up to live output. One retained boolean distinguishes
paused live-tail intent from an explicit window; remount restores that distinction
alongside the bounded reading position. Both presentations remain independent,
so the preview continues advancing while the expanded reader inspects history.

### Presentation lifetime and failures

Switching tabs inside the same expanded Session console keeps recently selected
Command Output readers warm within the host's bounded resident working set. The
same evaluator/widget, generated watch, page drain, emulator/parser, viewport,
selection, reading mode, and accepted cursor/intra-chunk offset survive. A following
hidden resident can consume later committed output; a paused or historical reader
keeps its frozen position while observing newer extent. Reselecting a warm tab or
repeating Show more does not recreate the reader or replay its prefix. Hidden
residents have no selected interaction authority; old action callbacks remain
revoked after reselection. Interactive Terminal is selected-only and remains a
separate resource owner. The [host map](../../app/README.md#session-console) owns
the four-slot bound, selected-slot accounting, and short Flutter-disposal overlap.

Collapsing the console, Session departure or identity change, console unmount, or
host close ends the working set. Eviction, content close, and owner retirement
end the affected resident. These cold departures release its evaluator, watch,
page, and native projection. Surviving tabs retain bounded logical reading intent
plus a native scalar projection checkpoint: follow/policy flags, accepted text
extent, rendered extent, and viewport offset. Native changes checkpoint
synchronously without calling eval; a final native copy also precedes bridge
disposal. Detachment preserves the
last known offset. Neither callback delivery nor plugin `dispose` is required to
save an immediate scroll/selection freeze, a newer frozen offset, or a manual
live-end return before the tab hides.

The plugin reads that exact retained checkpoint on a cold remount. Native accepted
text extent is authoritative for the last revealed position even inside a chunk or
while a page read was in flight; logical live-tail versus explicit-history intent
remains plugin-owned. A pending historical destination and its requested offset
are saved separately from partially reconstructed native extent. Hiding again
before reveal therefore preserves the original destination, not the replay's
temporary progress.
Following during programmatic prefix replay is not interpreted as new live-tail
intent. A fresh projection reconstructs the accepted prefix before restoring a
frozen position or catching up live;
it never resumes an old cursor against an empty surface. Prefix reconstruction
is incremental and cancellable, but costs O(prefix length) on historical seeks
and cold remounts. This deliberately basic history UI has no search, export,
virtualized transcript scrollbar, or durable emulator checkpoints.

The native checkpoint belongs to the exact retained content owner, not its key
string. Each mounted view acquires a new lease; stale view checkpoints cannot
overwrite a replacement, and removing content permanently clears the record.
No transcript, evaluator, widget, controller, or callback is retained in that
record. Revocation remains immediate: copying already-owned native state does
not permit plugin effects, backend reads, or deferred eval saves after revocation.

Closing a card or output tab detaches only that presentation. Admitted tabs
survive card closure; closing them requires no process confirmation, cannot
cancel execution/capture, and does not delete stored output. Completion does not
remove an output tab. Output tabs belong only to their originating Session,
unlike interactive Terminal's Environment eligibility, and the console remains
confined to the Session workbench.

Missing backends, read/watch/decoder failures, and incomplete capture produce
bounded safe states. No exception dump or native Command fallback is shown.
Retired access never selects a replacement generation; closing and explicitly
opening again may acquire fresh permitted access. Stored history needs only the
compatible Command backend and Project storage, not Git activation or Environment
materialization. Generic safe Future settlement is supplied by the own-backend
bridge, not Session execution authority.

Generated EVC subscriptions already contain cancellation cleanup rejection and
timeout at the interpreted subscription adapter. Reader failure/disposal can
detach observation without turning cleanup failure into an entire-presentation
error; native callers retain their native cancellation error semantics. Focused
tests cover rejecting and timed-out cleanup through both the generated stock
reader and the own-backend EVC fixture, including unaffected sibling readers.

### Preparation and evidence

`app/tool/tool_inspection_frontend_compiler.dart` builds the stock compact,
Inspection, and output entrypoints with the generated evaluator contract and
compile-only own-backend, console, and terminal-projection declarations. The
same `tools/stock_frontend_descriptors.dart` metadata drives normal preparation
and maintained fixtures; generated native contract siblings remain ignored.

Focused generated-client EVC behavior belongs to
`app/test/command_output_frontend_eval_test.dart`; the real normal-application
path belongs to `app/test/core/normal_chatgpt_run_integration_test.dart`. The
latter uses local deterministic model responses and socket-gated Command/Git AOT
output before completion, two identical invocations, simultaneous card/console
views, two warm output tabs with hidden committed output and unchanged
tab/mount/emulator identity, selected interactive Terminal coexistence, Session
departure revocation and cold historical reconstruction, and fresh Project/backend
reopen without Git. `command_output_capture_integration_test.dart` retains the
independent full-volume capture proof. See the maintained
[validation map](../../docs/development/testing.md#focused-command-output-checks)
for proportional commands and evidence boundaries.
