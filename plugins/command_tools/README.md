# Command Tools

Command Tools is an independently installed stock plugin that contributes
`run_command` (`dev.adele.plugin.command-tools.run-command`) and
`search_command_output` (`dev.adele.plugin.command-tools.search-command-output`).
Run Command runs either one foreground executable directly with verbatim arguments
or a verbatim script through the selected Environment's shell. Both forms use the
same tool identity, capture path, and conservative process authorization. It never
detects shell syntax in direct arguments or implicitly converts them into a script.
The root `command_tools_plugin` package owns the semantics;
`packages/backend` (`command_tools_backend`) reuses them through public generated
model-tool and Environment transport plus `adele_plugin_backend_support`. Its
entrypoint is `packages/backend/bin/command_tools_backend.dart`. Validation, effect
description, capture, and terminal output bounds are not duplicated
in the backend adapter.

## Execution forms

Direct execution retains the existing canonical shape:

```json
{"program":"git","arguments":["diff","--check"],"workingDirectory":"","timeoutSeconds":30}
```

When the captured Environment advertises a shell profile, the same `run_command`
also accepts:

```json
{"shellCommand":"git status --short && git diff --check","workingDirectory":"","timeoutSeconds":30}
```

Exactly one of `program` or `shellCommand` must be present. `arguments` is valid
only with `program`, including when explicitly empty. Program must be a nonempty
string; shell text must contain non-whitespace text and at most **16,384 UTF-16
code units**. Shell text is never trimmed, split, quoted, or otherwise rewritten.
Embedded newlines, surrounding whitespace, pipes, redirection, and quoting reach
the provider unchanged. NUL, malformed Unicode, unknown keys, wrong field types,
Environment selectors, and environment overrides are rejected. Direct argv entries
remain ordered verbatim strings, with an omitted list normalized to `[]`.

Both forms normalize omitted working directory to `""` (Environment root), remove
redundant `/` and `.` segments, and reject absolute paths and parent traversal;
the Environment provider retains filesystem confinement responsibility. Defaults
are included in canonical arguments. The model never supplies a shell profile ID.
The schema uses an object root, ordinary properties and `additionalProperties:
false`, not a root-level union unsupported by some model providers. Property and
tool descriptions explain the alternatives; semantic validation authoritatively
enforces mutual exclusion. The OpenAI adapter forwards that schema unchanged with
explicit `strict: false`, preventing Responses from normalizing optional sibling
fields into an incompatible all-required shape.

The model description identifies the captured interpreter and dialect and instructs
the model to use that dialect. Shell behavior is not assumed POSIX. Command Tools
does not inspect `SHELL`, host OS, or interpreter names to choose an invocation
convention. The Environment owns interpreter selection, arguments, and profile
consistency; no `set -e`, `pipefail`, login or interactive flags are added. A normal
exit code is the interpreter's actual result, not proof every pipeline stage
succeeded. See the [Environment contract](../../packages/environment/README.md)
and [stock Git shell support](../git/README.md#noninteractive-shell-commands).

Explicit `shell_unavailable` discovery leaves a direct-only descriptor and rejects
`shellCommand`; it never triggers a fallback shell. Unexpected discovery failures
remain failures. A fresh catalog can capture a new profile; an existing tool does
not refresh its selection or automatically retry profile drift.

`timeoutSeconds` defaults to 120 and can be selected per invocation from 1 through
1800 seconds, using the public Environment foreground limit. Long-running builds
and tests should request a suitable foreground timeout rather than use `nohup`,
`setsid`, detached shells, or redirected temporary log files solely to bypass
timeouts or retrieve normal output. This does not extend the separate buffered
process timeout range or introduce background execution.

Normal startup loads `command-tools/backend.aot`; `AdeleRuntime` has no Command
activation or production implementation dependency/import and no in-process
fallback. The combined installation retains the existing PluginId
`dev.adele.plugin.command-tools` and an independently available `frontend.evc`.
There are no Command-specific startup arguments, configuration, or deployment
defines.

Readiness advertises two extensions at `dev.adele.extension.model-tools` through
the generated `modelTool` service in the same backend generation. The existing
`dev.adele.plugin.command-tools.model-tools` contribution retains configuration
context `default` and requests `authorizedEnvironmentProcess` plus
`authorizedEnvironmentShell`. Its only descriptor is `run_command`, requesting
both execution services when shell support was captured and only the process
service when it was unavailable. The separate
`dev.adele.plugin.command-tools.output-search` contribution uses
configuration context `command-output-search`, with `hostServices: []` and
`executionHostServices: []`, and materializes only `search_command_output`.
There are no capability exposures, additional backend processes, or independent
shell authorization policies. Exact context routing prevents duplicate aliases or accidental process
dependencies. Materialization and validation receive no host token; description
uses pure identity and argument data. Only approved Run Command execution receives
operation-scoped process/shell authority.

Shell-aware descriptor routes carry a versioned, canonical base64url encoding of
the captured `[profileId, interpreter, dialect]`, bounded to 24 KiB. Direct-only
routes retain the existing tool ID. Subsequent validation, description, and
execution reconstruct only that immutable description; there is no mutable current
shell or retained Session/profile registry. Routes carry neither Environment nor
Session selectors and grant no authority. The host retains the authoritative
captured profile and exact backend/provider bindings. Its authorized shell service
checks the submitted expected profile before forwarding; the provider checks actual
selection drift before launch. Retired bindings never migrate to a replacement.

Generated `AuthorizedEnvironmentProcessService.runForegroundProcess` reuses the
existing request/event DTOs with no authority-selection IDs.
`AuthorizedEnvironmentShellService.runShellCommand` similarly carries the exact
script and expected profile through the existing operation-scoped generated service.
Reverse server streaming uses one-item credit and cancellation. Settlement, cancellation, or
exact-generation retirement revokes authority immediately and cancels owned streams
with bounded cleanup; this neither rolls back process effects nor provides an OS
sandbox. See [remote model tools](../../docs/architecture/contracts-and-capabilities.md#remote-model-tools).

The tool exposes no Environment selector. Its effect targets the authorized
Environment as a whole and is marked as uncertain because arbitrary processes
can have secondary effects that this tool does not classify.
Both forms retain uncertain `processExecution` effects. Shell approval summaries
use bounded escaped text, identify the captured shell, and include working directory
and timeout. Full canonical script text remains available in escaped approval
arguments without weakening the host's unsafe-authority-text checks. Rejection or
policy denial allocates no capture and launches no process.
Environment stdout and stderr are captured by this plugin, not forwarded into
generic tool progress, RunJournal, or activity snapshots. The terminal model result
independently retains at most 8,192 UTF-16 code units per stream as a deterministic
4,096-unit head plus 4,096-unit tail, with surrogate-safe boundaries. Model-preview
truncation is not transcript truncation: full captured output remains available
to the user through Command Output and to the model through retained-output search.
Existing `stdoutTruncated` and
`stderrTruncated` host-data fields retain their names; `captureState` separately
reports capture completeness.

A completed tool invocation does not prove program or validation success. Inspect
termination and exit code: `termination: timedOut` means the program did not
complete normally, while a nonzero exit code is a process result, not necessarily
a tool-infrastructure failure. Both can retain the successful tool disposition
and complete capture; no command-specific test/build success is inferred.

## Full decoded-text capture

`lib/src/command_transcripts.dart` owns the relational schema, writer, validation,
read service, and notifications. The backend binds `ProjectStorageServiceClient`
once from its generation-scoped infrastructure context under the actual
`dev.adele.plugin.command-tools` owner, independently of each operation's process
token. Native callers explicitly inject `CommandTranscriptStore`; omission allows
materialization/description but rejects execution before process launch. There is
no default in-memory transcript or native application reader. Native callers retain
the existing run-only `activate` method and explicitly call `activateSearch` for
the independent search contribution with configured transcript storage. Each
registration has its own ordinary exact binding and retirement lifetime.
Native `CommandToolsPlugin(enableShell: true)` explicitly opts into the established
authorized shell description/execution facets, captured at materialization; its
default remains direct-only for existing in-process hosts. `commandToolRegistration`
also accepts optional `shellProfile`/`shell` values for shared adapter use.

The current v1 baseline has `adele_command_captures` headers keyed by the host's
existing Run-local tool-invocation ID with composite key `(invocation_id, run_id)`
and `adele_command_chunks` with composite primary key
`(invocation_id, run_id, position)`. Headers store Session/Run association, Environment and
command metadata, capture state, committed high-water/UTF-16 extent, version,
and known termination/exit facts. Session identity references the canonical Session
row; Run/invocation association does not reference terminal-only core history.
`ToolExecutionContext.toolInvocationId` is the opaque value of the existing public
orchestration identifier, not a new command identity or authority token.

Direct headers retain `program` plus a JSON argv array in `arguments_json`.
Shell headers use the selected interpreter as `program` and a tagged object in
`arguments_json`: `executionForm: "shell"`, exact `shellCommand`, and
`shellProfile: {profileId, interpreter, dialect}`. This is explicit shell metadata,
not an invented provider argv. Readers accept both shapes; historical v1 direct
captures remain readable without a migration or a second retention system. Shell
model results and structured host data identify shell execution and the captured
profile, with the same lifecycle, output previews, and retained-output reference;
they do not expose `program`/`arguments` as though this were direct execution.

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
| Provider/transport event | 16,384 UTF-16 code units; the provider separately bounds already-admitted pipe reads, see the [Git provider](../git/README.md). |
| Stored chunk | 4,096 UTF-16 code units; provenance is `stdout` or `stderr`. |
| Append batch | At most four chunks / 16,384 UTF-16 code units, one awaited transaction per writer, with one header update plus at most four inserts. |
| Flush delay | No intentional batching delay: even one received partial-line event is committed before requesting another. Actual latency includes storage/transport admission and commit. |
| Read page | At most 16 chunks / 65,536 UTF-16 code units; caller bounds may reduce both. The row limit is conservatively reduced by the maximum chunk size. |
| Metadata | At most 128 KiB encoded JSON at admission, ensuring individual headers remain readable within shared storage limits. |
| Model result | 8,192 UTF-16 code units per stream, independent head/tail calculation over all received output. |
| Watcher | One in-flight bounded state read, one admitted notification, and a dirty bit; paused changes coalesce rather than queue per append. |

The shell-script bound allows worst-case JSON escaping with ordinary profile and
identity metadata. The combined 128 KiB admission budget still applies: unusually
large interpreter, identity, or working-directory metadata can cause an otherwise
valid invocation to fail capture admission before any process is launched.

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

## Retained output search

`lib/src/command_output_search.dart` supplies the pure-Dart, backend-internal
`CommandOutputSearch` engine and immutable `CommandOutputSearchRequest`,
`CommandOutputSearchResult`, and `CommandOutputSearchLine` values. It accepts the
existing `CommandOutputService` reader, not a writer or Environment facet. Session
identity is supplied by a trusted caller; Run and invocation select the exact
retained capture through the reader's existing association checks. The shared
semantic model-tool adapter reuses this engine through ordinary generated
model-tool transport, not a second search service protocol. Both native and remote
registrations use the same schema, validation, effects, and outcome projection.

### Agent workflow and authority

1. Execute `run_command` normally, including host-owned approval. Read its actual
   termination, exit code, preview-truncation flags, and capture status.
2. Use the returned exact `runId` and `toolInvocationId` reference with
   `search_command_output` and a line-oriented regex `pattern` to inspect omitted
   text. Earlier Runs in the current Session are eligible too.
3. Read the returned matching and surrounding lines, capture/coverage status, and
   search stop reason. If a continuation cursor is returned, repeat the same
   reference, pattern, and options with that cursor to continue searching.

The stable model-visible reference is one JSON-valued line:

```text
Retained command output: {"runId":"original-run","toolInvocationId":"original-invocation"}
```

The same two fields appear at the top level of structured `hostData`. Neither
representation supplies a model-selectable Session or Environment.
The reference is historical evidence identity from the original
`ToolExecutionContext`, not a new Command ID, process handle, provider call ID,
execution token, or permission grant. Run Command only publishes it after capture
admission is acknowledged. Pre-admission rejection or lost acknowledgement does
not claim a searchable capture; a later failure retains the reference with an
explicit incomplete-capture warning.

Search takes no model-selectable Session, Environment, program, or host token.
Its authoritative Session comes from the actual search invocation's execution
context. Project Storage authorization and the reader's Session/Run/invocation
association checks remain in force; knowing another Session's reference cannot
authorize access. Search uses the generation's existing storage grant, never the
originating process invocation. It needs no Environment materialization or
process/filesystem/mutation facet, including after the originating command has
settled or its Environment provider has retired.

The effect is a certain `resourceInspection` of the selected retained command
output, not `sourceRead` or process execution. The normal host policy permits that
single read-only effect without command-execution approval; it still gates
processes/mutations and denies uncertain or mixed inspection effects.

The model schema is an object with only these fields and
`additionalProperties: false`:

| Field | Required | Meaning / limits |
| --- | --- | --- |
| `runId` | Yes | Original Run identity, string of 1 through 1,024 UTF-16 units. |
| `toolInvocationId` | Yes | Original Run-local invocation identity, string of 1 through 1,024 UTF-16 units. |
| `pattern` | Yes | Nonempty regex, at most 256 UTF-16 code units. |
| `before` | No | Integer 0 through 10; S1 default 3. |
| `after` | No | Integer 0 through 10; S1 default 5. |
| `maxMatches` | No | Integer 1 through 10; S1 default 10. |
| `cursor` | No | Opaque string, at most 196,608 units, returned by the previous search. |

S1 validates regex syntax and line-oriented restrictions as well as the declared
bounds. The cursor cannot change the reference,
Session, pattern, options, or captured snapshot.

### Model results and bounds

Search returns a compact JSON object in `modelContent`, not an internal engine
object dump. The reference, searched pattern and requested options accompany
`captureState`, known `termination`/`exitCode`, `committedOutputOnly`, `matchCount`,
`stop`, `reachedEnd`, `exhaustive`, `contextIncomplete`, cumulative
`unsearchedLongLines`/`regexTimeouts`, and per-call `scannedCodeUnits`/`storagePages`.
`lines` identifies `stdout` or `stderr`, one-based `lineNumber`, `isMatch`, first
match offsets, the bounded `text`, original `length`, `excerptOffset`, explicit
`truncatedBefore`/`truncatedAfter`, LF `terminated` status, and stable storage
`chunk`/`offset` locators. Text uses ASCII JSON escaping, including non-ASCII text,
Unicode line separators, and bidirectional controls. Decoding preserves the exact
excerpt without allowing invisible controls to change its displayed structure.

`continuation` distinguishes `available`, `none`, and
`unavailableModelResultLimit`; `cursor` appears only in model content, not a second
copy in `hostData`. Host data retains bounded summary/status fields, not duplicate
lines. `cursorTooLarge` explicitly identifies a token omitted for the model budget.
No-match results must be interpreted with `stop`, `reachedEnd`, `exhaustive`, and
capture completeness. A failed/interrupted capture can have an exhaustive search
of its retained prefix, never proof that uncaptured output lacked a diagnostic.
Absent/live captures and invalid/stale continuation are distinct domain failures;
storage, corrupt-capture, and infrastructure failures are not successful empty
searches. Invalid/stale cursors instruct a fresh search, not a command rerun.

The plugin limits one search model result to **256 KiB of UTF-8 JSON**, retaining
S1's bounded excerpts intact, and one model-facing cursor to **16,384 ASCII
characters**. These are model-context limits, not a claim that the generated
transport cannot carry S1's larger cursor. An oversized cursor is omitted whole,
with `cursorTooLarge: true`, `cursor: null`, and explicit guidance to start a fresh
search with narrower context or a more selective pattern. The actual engine stop
and coverage flags remain unchanged; this is neither a fabricated end nor a
silently truncated token. There is no alternate paging system or search-job state.

The shared backend transport bounds the entire encoded frame at **8 MiB** and
does not impose a smaller `modelContent` string limit. Tests measure encoded
outcomes including control-character escaping and cursor content, not just raw
excerpt lengths. Model continuation carries `modelContent`, not host-private
fields; repeated results still consume the normal accumulated context budget.
This feature does not compact history or guarantee provider-specific context
capacity.

Search admits terminal `complete`, `failed`, and `interrupted` capture snapshots.
`absent` and live `capturing` return distinct non-search statuses, not exhaustive
empty results. Failed/interrupted results explicitly report `committedOutputOnly`;
even exhaustive retained-output search says nothing about uncaptured output or
process success. Results expose only capture state and known termination/exit
facts, not potentially large command metadata or failure prose from the header.
Storage, association, backing availability, and malformed-record failures propagate
rather than becoming no-match results. Every page must retain
the initial state/version/extent, and each completed pipe pass checks the retained
UTF-16 total against its header. Search does not create capture rows, change
lifecycle, launch processes, subscribe to capture, or rerun a command. As with
existing passive reads, the reader may ensure its existing schema.

### Lines and results

Patterns use case-sensitive `RegExp(pattern)` with Dart's default flags, like the
stock filesystem Search tool. Empty patterns, literal NUL/CR/LF/U+2028/U+2029,
malformed regexes, invalid bounds, and empty or over-1,024-unit identity strings
are rejected before storage reads. Zero-width matches are supported. Regexes run
on individual logical lines, never across LF or between pipes; only the first
match on a line identifies a hit.

LF alone delimits a logical line and is excluded from its text. CR, including the
CR in CRLF, ANSI/control characters, NUL, and Unicode remain literal captured
content. Chunk boundaries have no line significance; a final unterminated line is
included, and trailing LF does not invent another empty line. This is not terminal
screen search. Stdout is searched first, then stderr, with independent one-based
line numbers and no claim of chronological ordering between pipes. Both passes
use bounded combined-storage pages; ignored other-pipe text counts toward scan
work, so a full traversal reads the committed extent twice.

Each returned line includes its stream, per-stream line number, starting storage
chunk ordinal and zero-based UTF-16 offset, original content length, LF-termination
flag, excerpt offset/text, and independent leading/trailing truncation flags.
Matching lines additionally carry the first match's UTF-16 start/end offsets;
`isMatch` distinguishes admitted hits from context. Excerpts center on the first
match where possible and do not split a surrogate pair. Context uses bounded
excerpts too, not unbounded complete lines. Overlapping windows share each line
once within a response; lines are ordered by pipe then line number.

| Search bound | Limit |
| --- | --- |
| Pattern | 256 UTF-16 code units. |
| Before/after context | Defaults 3/5 lines; each accepts 0 through 10. |
| Matching lines | Default and maximum 10; caller may request 1 through 10. |
| Returned text | At most 16,384 UTF-16 code units across all line excerpts, excluding metadata/cursor. |
| Individual excerpt | At most 512 UTF-16 code units, independently truncated. |
| Searchable logical line | At most 16,384 UTF-16 code units, excluding LF. |
| Scan work | At most 2,097,152 consumed UTF-16 code units per request, including other-pipe text and context lookahead. |
| Storage pages | At most 128 per request, each at most 16 chunks / 65,536 UTF-16 units using existing Command Output bounds. A final page can read ahead of the consumed scan budget. |
| Logical lines | At most 16,384 completed lines per request, also bounding work on empty/tiny lines. |
| Regex execution | Separate request-local Dart isolate; at most 250 ms per line and 1 second cumulative evaluation/RPC time per request. Startup has a separate 5-second handshake timeout; storage latency is not a wall-clock search deadline. |
| Continuation | At most 196,608 encoded code units, including worst-case JSON escaping of bounded partial-line/context text. |

Lines over the searchable-line bound are **not regex searched**, even if their
prefix would appear to match: applying an arbitrary regex to an incomplete line
could invent anchor/lookaround matches. Their length and LF boundaries are drained
incrementally without buffering the remainder. Cumulative `unsearchedLongLines`
reports this coverage gap, including when a request stops inside such a line.
A regex evaluation timeout kills its isolate, increments cumulative
`regexTimeouts`, and stops the response with that line explicitly unsearched;
continuation advances past it. Expiring the cumulative regex budget between lines
instead resumes the pending line without skipping it. These bounds avoid both
unbounded line buffers and catastrophic backtracking in the backend isolate.

### Continuation and completeness

`stop` identifies end, absence, live capture, or the match/text/scan/page/line/regex
limit. `reachedEnd` only means the terminal retained extent was traversed;
`exhaustive` additionally requires no oversized-line or regex-timeout coverage
gaps across the entire continuation chain. Thus an exhausted no-match scan is
distinct from a completed exhaustive no-match search. `contextIncomplete` reports
requested after-context cut short by a resource limit; reaching a pipe's real end
with fewer surrounding lines is not incomplete context.

The opaque cursor carries a bounded partial line, rolling before-context excerpts,
pending after-context, per-stream counts, source position, and cumulative coverage
gaps. It is bound to the exact Session/Run/invocation, pattern, context/match limits,
and capture
state/version/extent. Malformed, modified, unrelated, and stale tokens fail
explicitly. A cursor never supplies authority or overrides caller identities.
HMAC-SHA256 uses one random engine-instance key, with no cursor registry, persistent
search job, table, or index. Keep one engine for the backend generation; replacing
the engine invalidates its cursors and requires a new search. This deliberately
does not promise continuation across backend replacement, although fresh readers
can always search retained storage without the original writer.

After the match limit, bounded after-context lookahead does not consume future
hits: continuation replays from just after the last admitted match. A text-limited
response resumes before the line it could not admit. Context may consequently
repeat across responses or later become a hit, but admitted matching-line identities
are neither skipped nor repeated along a continuation chain. If context lookahead
cannot finish within the request budgets, `contextIncomplete` is explicit and the
cursor carries outstanding context into later pages, without readmitting old hits.
Already-returned context can repeat when replaying interrupted lookahead. Source
locators and per-stream line numbers remain stable through chunk, page, and request
boundaries.

The SQLite-backed `test/command_output_search_test.dart` exercises these semantics
through retained storage, including fresh readers, failure/corruption, bounded
multi-megabyte scans, continuation, and read-only behavior. The owning maintained
target is `dart tools/adele.dart test --target command_tools_plugin`.

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

Command-specific shell classification, background processes, stdin, signals, environment
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

The compact entrypoint remains a separate bounded direct-argv or shell summary. It does
not create an output reader, replay history, or request a terminal projection.
Common hosting owns inspect interaction and exact-invocation approval controls.
The card cannot execute, approve, rerun, send input, or materialize an Environment.
Opening it does not open the console.

Rich Inspection shows direct Program and individual argv entries, or shell text
with readable multiline layout. Control/bidirectional characters and literal
backslashes use safe display escapes; canonical execution text is unchanged.
Captured interpreter/dialect are shown only when available in outcome host data,
never fabricated for a pending invocation. Both forms retain working directory,
timeout, lifecycle, exact historical invocation selection, and the same output
projection and **Show more** behavior. Shell execution creates no interactive
Terminal resource or input controls.

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

Package-owned rich/compact Inspection coverage belongs to
[`command_tools_inspection_frontend_eval_test.dart`](packages/frontend/test/command_tools_inspection_frontend_eval_test.dart):
direct argv boundaries, safe metadata, factual lifecycle/process outcomes, live
identity, independent subscriptions/retirement, and no duplicate plaintext output.
Generated-client output presentation behavior remains in
[`command_output_frontend_eval_test.dart`](packages/frontend/test/command_output_frontend_eval_test.dart).
Both reuse the app compiler/host through development-only dependencies and run
once through the ordinary frontend target, from the repository root:

```sh
dart tools/adele.dart test --target command_tools_frontend
```

Mixed-plugin and generic Session/Inspection composition remains in
`app/test/tool_inspection_frontend_eval_test.dart`; the real normal-application
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
