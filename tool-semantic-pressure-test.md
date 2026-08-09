# ADELE Tool Semantic Model Pressure Test

This is a disposable architecture experiment. It is not accepted ADELE architecture, and the scratch types intentionally do not modify production APIs.

## Method

Evidence sources were kept distinct:

- **Existing ADELE evidence:** current `main` at `ce92f8a`, especially `packages/capabilities`, `packages/plugin_runtime`, generated contracts, and `ResourceRef`.
- **Provisional evidence:** `phase-4-agent-run` at `9457bfa`, inspected but not used as the experiment base. Its `AgentRun`, model, message, approval, and tool types are treated as replaceable.
- **Experiment behavior:** compileable Dart in `experiments/tool_semantics`, with fake executors and lifecycle tests for exactly the six requested tools.
- **Interpretation:** conclusions drawn from those observations. These are recommendations for synthesis, not production decisions.

The branch `experiment/tool-semantics` was created from current `main` in a separate worktree. No ADELE production source or ADR was changed. The root workspace manifest only admits the isolated experiment package.

The experiment traces discovery, availability, immutable materialization, model projection, proposal normalization, validation, effect description, policy, approval, binding validation, execution, progress/cancellation, terminal outcome, resource/result retention, model continuation, and generic host consumption. It deliberately uses one invocation identity and no execution-attempt identity.

## Current ADELE constraints observed

### Existing ADELE evidence

- Plugins are registered lifecycle/deployment units. Capabilities are semantic contracts resolved independently of plugin identity.
- `CapabilityKey` is semantic identity plus major version. `ProviderDescriptor` separately identifies a provider, plugin, service, rank, and capability.
- `CapabilityRegistry.resolve` returns a `ProviderBinding` retaining the exact active registration object. Closing that registration makes an old binding stale. A newly registered provider generation is not substituted into it.
- Generated typed contracts and request channels are the existing invocation mechanism. Nothing in the experiment requires replacing them.
- `ResourceRef` already demonstrates storage-independent resource identity, but only contains a URI and optional media type; it does not express versions, runtime ownership, or lifecycle.
- `agent_kernel` on `main` is intentionally empty. Plugins therefore have no dependency on it.

### Provisional branch evidence

- The old Phase IV adapter correctly retained capability bindings from composition through execution rather than re-resolving by provider ID.
- Its tool definition used model-visible name as identity, indexed executors by that name, approved every proposal, represented results as one string, and classified outcomes only as success/error/rejected.
- Its approval retained the tool object in memory, but approval data itself named only call ID, tool name, and arguments. It did not explicitly expose semantic identity, exact binding generation, derived effects, or an argument digest.
- These limitations are useful negative evidence; the experiment does not preserve these provisional abstractions.

### Interpretation

Capability binding is a reusable precedent for generation-bound executables. It is not evidence that every model tool should be a capability. A composition adapter can project a concrete capability binding into a tool binding, while a dynamic MCP adapter can create generic tool bindings without generating an ADELE capability per external tool.

## Candidate semantic model

The smallest model that remained clean in the experiment consists of:

| Boundary | Scratch representation | Purpose |
|---|---|---|
| Durable semantics | `ToolId` | Stable tool meaning, independent of provider and model name |
| Discoverable definition | `ToolDefinition` | Description, input schema, conservative static effects |
| Current availability | `ToolCatalog` registration | Mutable set of currently usable definitions and bindings |
| Exact executable | `ExecutableBinding` + `BindingId` | Retained provider/connection generation and executor |
| One model request | `MaterializedToolSet` | Immutable visible names, schemas, identities, and retained bindings |
| Provider projection | `ModelToolDefinition` | Provider-safe name and schema; not durable identity |
| Concrete proposal | `ToolInvocation` | Normalized call, arguments, semantic identity, retained binding, lifecycle |
| Invocation-specific preflight | `EffectDescription` | Targets, versions, likely effects, uncertainty |
| Policy decision input | `PolicyInput` | Identity, binding, arguments, context, static and derived effects |
| Approval interruption | `ApprovalInterruption` | Exact invocation, tool, binding, argument digest, effects |
| Live observations | `ToolProgress` | Ordered nonterminal status/output/partial results |
| Terminal fact | `ToolOutcome` | Typed terminal classification and generic content envelope |
| Generic output | `ToolContent` | Model blocks, structured host data, resources, artifacts, truncation |
| Durable runtime handle | `RuntimeResourceRef` | Addressable resource whose lifetime differs from invocation lifetime |

`ToolInvocation` receives a run-local ADELE identity at normalization. The provider call ID remains correlation data. The experiment uses only invocation identity for proposal, interruption, execution, progress, and terminal outcome; none of the six cases required a second execution-attempt identity.

The central lifecycle never casts to a read/search/process-specific result. It handles `ToolContent` uniformly. Tool-specific presentation can inspect a semantic data contract outside the central lifecycle.

## Six tool walkthroughs

### 1. `read_file`

**Experiment behavior:** `dev.adele.workspace.read-file/v1` materializes as `read_file`. The invocation validates `uri`, derives a `ResourceTarget` with optional version, runs without approval, and returns a `ResourceBlock` for model content plus structured URI/version/range data for the host.

**Interpretation:** semantic ID and model name must differ. Text is useful model content but insufficient host data. Resource URI and observed/requested version belong in structured fields. Policy can inspect workspace, target URI/range/version, read effect, binding, and arguments before execution. Navigable presentation consumes structured resource data without parsing prose.

### 2. `search_text`

**Experiment behavior:** the executor emits one optional partial-result progress event, then returns compact model text, structured match records, and a first-class `Truncation(returned, total, reason)`.

**Interpretation:** structured matches and model compression are separate projections of the same outcome. Truncation is outcome metadata, not a sentence convention. Progress is useful for expensive searches or incremental UX, but a bounded search remains one invocation and may emit no progress. A specialized renderer consumes match records directly.

### 3. `apply_patch`

**Experiment behavior:** static metadata says workspace mutation; preflight derives exact target URI, base version, and change summary from arguments. Policy interrupts. Approval binds invocation ID, semantic tool ID, exact provider generation, canonical argument digest, and described effects. Invalidating generation 7 before decision produces `staleBinding`; generation 8 is never substituted. Success returns concise model text and a structured change set with base/new workspace versions.

**Interpretation:** approval is authorization for the exact normalized proposal and described execution, not permission to invoke any implementation of a similarly named tool. Stale workspace input is a domain/conflict outcome such as `stale_resource_version`; stale provider generation is a binding outcome. A change set is ordinary structured outcome/provenance unless it is independently stored/addressable, in which case it additionally gets an `ArtifactRef`. It is not automatically a runtime resource.

### 4. `run_command`

**Experiment behavior:** static effects conservatively include workspace mutation and external I/O. Preflight adds command/cwd summary and explicit uncertainty. Execution emits stdout and stderr progress. Cancellation after process start returns a terminal cancelled outcome with `effectMayHaveOccurred: true`, no known exit code, and structured termination status.

**Interpretation:** static metadata can state broad effect classes, but arguments and environment determine cwd, executable, network posture, targets, and likely effects. Policy needs both. Stdout/stderr chunks are progress observations; exit code, timeout, cancellation disposition, and final captured output metadata are terminal data. Nonzero exit after successful process execution is normally a successful tool execution whose domain payload has `exitCode != 0`, not an infrastructure failure. Lost transport after a command may have acted must be indeterminate.

### 5. `start_process`

**Experiment behavior:** the invocation terminates successfully while returning `RuntimeResourceRef(id: proc-9, kind: process, environmentId, owner: execution-environment)`. Model content also says that the process started.

**Interpretation:** this case justifies a first-class runtime-resource reference. The creating invocation cannot own cleanup because it has already terminated, and the Run may end while the process remains useful. The execution-environment/resource service should own lifecycle, leases, observation, and cleanup policy. The kernel needs generic references and provenance, not terminal/process implementation details. Reading output, sending input, waiting, stopping, and inspecting are later operations, normally new tool invocations against the resource. Cancellation of `start_process` concerns creation; stopping the surviving process is a resource operation.

### 6. Dynamic MCP tool

**Experiment behavior:** semantic identity is `mcp://server-42/tools/weather.lookup`; model-visible name is sanitized/namespaced to `server_42__weather_lookup`; binding is connection generation 11. Removal invalidates the retained snapshot binding. Re-registration produces generation 12 but does not migrate the old proposal. Arbitrary JSON and multimodal-capable blocks pass through `ToolContent`; raw MCP data remains adapter metadata inside structured data.

**Interpretation:** server/connection identity, external tool identity, model-visible name, and executable generation are separate. The materialized set is immutable for a model request. Disappearance after proposal yields unavailable if no execution binding was retained, or stale binding when the retained connection generation is invalidated. MCP protocol details such as server capabilities, list-tools cursors, transport session, protocol result validation, and raw envelopes belong to adapter state, not generic tool semantics. Dynamic MCP tools fit without manufacturing ADELE Capabilities.

## Error/outcome matrix

An interruption is nonterminal. Every resumed/rejected proposal eventually receives one terminal invocation outcome. Infrastructure causality can coexist with a model-visible terminal summary. `effectMayHaveOccurred` distinguishes safe failure from uncertainty.

| Case | Invocation/Run classification | Model continuation | Infrastructure? | Indeterminate/effect note |
|---|---|---|---|---|
| Invalid model arguments | Terminal `invalidArguments` | Yes, structured validation feedback | No | No effect began |
| Tool no longer available before normalization/materialization | Terminal `unavailable` if tied to a proposal; otherwise catalog/materialization failure | Yes when a provider call exists | Sometimes discovery infrastructure caused it | No effect began |
| Stale executable/provider generation | Terminal `staleBinding` | Yes, retry may require a new model/materialization cycle | Binding/lifecycle condition | No silent migration; usually no effect began |
| Policy deny | Terminal `policyDenied` | Yes, minimally disclose denial | No | Not an interruption; no effect began |
| User rejection | Approval interruption followed by terminal `userRejected` | Yes | No | No effect began |
| File not found or stale resource version | Terminal `domainFailure` with domain code | Yes | No | Normal executor result |
| Command executes and returns nonzero | Normally terminal `success` with exit code and output; optionally a domain-status subtype | Yes | No | Execution succeeded; command reported failure |
| Transport/plugin failure before effect | Terminal `infrastructureFailure` | Yes, sanitized; detailed cause retained for host | Yes | Explicit `effectMayHaveOccurred: false` |
| Cancellation before effect | Terminal `cancelled` | Yes | No | `effectMayHaveOccurred: false` |
| Cancellation after external effect starts | Terminal `cancelled` | Yes | No | `effectMayHaveOccurred: true`; cancellation is a request, not rollback |
| Effect may complete but result is lost | Terminal `indeterminate` | Yes, warn against blind retry | Often yes | `effectMayHaveOccurred: true`; reconciliation may be needed |
| Result too large | Success or domain outcome with first-class `Truncation` | Yes, compact bounded content | No | Not itself an error |
| Malformed MCP/external result | Terminal `malformedResult` | Yes, sanitized | Adapter/provider protocol failure | If call was effectful, may also be indeterminate |

The necessary coarse taxonomy is: success, invalid arguments, unavailable, stale binding, policy denied, user rejected, domain failure, infrastructure failure, cancelled, indeterminate, and malformed external result. Domain codes carry specifics such as `file_not_found`, `stale_resource_version`, or timeout. A string message is optional presentation/detail, never the classifier.

Run terminalization is separate. A tool outcome can continue the Run to the model. The Run should fail only when its orchestration cannot continue or policy explicitly requires termination.

## Policy/effect analysis

Policy for one invocation needs:

- Semantic `ToolId` and exact `BindingId`, including provider/connection generation.
- Validated arguments, not only model JSON text.
- Run, Session, Agent, Workflow, Workspace, and Execution Environment context where present.
- Static conservative effect classes from the definition.
- Dynamically derived targets, versions, scopes, likely effects, uncertainty, network/environment implications, and resource creation/use.
- Provider attributes relevant to trust, supplied by composition as policy metadata rather than encoded into tool identity.

An explicit preflight/effect-description operation proved useful. Static metadata cannot say which files a patch targets, which cwd a command uses, or which runtime resource an operation addresses. Embedding derivation in policy would duplicate executor knowledge and couple policy to every tool's argument schema. `describe(arguments, context)` centralizes this knowledge beside the binding without performing the effect.

Preflight is not a promise that arbitrary commands have only the listed effects. It must support uncertainty and conservative broad effects. It must be pure/idempotent or clearly report that description itself requires external reads. Approval binds the resulting description, but generation and relevant resource versions are still revalidated immediately before execution.

The experiment's base64 JSON argument digest is only a stand-in. Production synthesis needs canonical validated arguments or a stable digest algorithm; raw map iteration/JSON encoding is insufficient for durable approval records.

## Runtime-resource analysis

`start_process` demonstrates a real semantic category: an addressable runtime entity created by one invocation whose lifetime and operations are independent of that invocation. Other likely examples are terminals, browser sessions, mounts, sandboxes, database transactions, and remote jobs.

The minimum generic kernel concept is a typed opaque reference with resource ID, kind, execution-environment identity, owner/lifecycle authority, and provenance back to its creating invocation. Resource state, output buffers, leases, stop semantics, and cleanup are capability/environment concerns exposed through typed operations or projected tools.

Ownership should sit with the execution environment or dedicated resource manager because it can outlive a Run. Runs may hold leases or request cleanup according to policy. Invocation cancellation does not imply deleting returned resources. Resource cleanup should be explicit and observable; abandonment policy remains unresolved.

A result is also a runtime resource when later operations address a live entity. A result is also an artifact when immutable or durable output is stored independently and can be retrieved by stable reference. Structured inline data is neither merely because it is large or semantically rich. Provenance links invocation, resources, artifacts, and workspace versions without conflating their identities.

## Presentation analysis

ADELE can always render generically from `ToolInvocation`, effects, progress, outcome, and content blocks:

- Compact running summary: semantic/display label, state, effect summary, elapsed/progress status.
- Expanded invocation: model name, semantic ID, provider generation, validated arguments, context, targets, and uncertainty.
- Approval body: exact binding, argument/effect fingerprint, resources/versions, and likely effects.
- Progress: ordered kind plus content blocks, including stdout/stderr distinction.
- Result: outcome kind/code, model blocks, generic structured-data inspector, truncation, resource and artifact links.
- Errors: typed category, safe message, effect certainty, retry/reconciliation guidance.

Specialized presentation should be a host contribution, not executor output and not a Flutter widget returned by execution. It should register against semantic `ToolId` (usually version-aware) and optionally a declared semantic result-data key/schema. Binding only by Dart runtime type is brittle across isolate/plugin boundaries; binding only by model name is incorrect. The renderer receives immutable semantic view models and falls back to generic rendering when absent or incompatible.

Examples include navigable file ranges for `read_file`, match lists for `search_text`, and a change-set view for `apply_patch`. MCP usually uses generic rendering unless a host contribution recognizes a stable server/tool semantic identity and data contract.

## Discarded alternatives

- **Model-visible name as identity:** fails namespacing/sanitization, aliases, provider constraints, and dynamic MCP collisions.
- **Every model tool is an ADELE Capability:** creates capabilities for arbitrary external MCP definitions and confuses semantic interoperability with model composition. Capability implementations may be projected into tools instead.
- **Tool equals executor:** prevents immutable definition snapshots and clean separation of availability, policy, approval, and execution.
- **Resolve provider at execution time:** silently migrates approved work to a new generation.
- **Approval binds only call ID/name/arguments:** omits semantic identity, exact binding, derived effects, and resource versions.
- **One `error: String`:** cannot distinguish retry-safe validation, denial, domain failure, infrastructure failure, cancellation, or potentially completed effects.
- **Text-only result:** forces UI parsing, loses multimodal/structured data, and cannot represent resources, artifacts, or truncation.
- **Tool-specific generic result classes in the central lifecycle:** requires casts and makes dynamic tools impossible. Generic content/data envelopes plus optional semantic presentation contracts were sufficient.
- **Progress is partial terminal result:** fails stdout/stderr and status observations that have no terminal meaning. Progress is ordered, nonterminal, and lossy/replayable according to transport policy.
- **Created process as ordinary result data:** gives no durable target for later operations or lifecycle ownership.
- **Invocation owns process cleanup:** fails when resource lifetime exceeds invocation or Run.
- **Separate execution-attempt identity:** none of the six cases required it. One invocation has one execution phase. A retry after indeterminate effects should normally be a new invocation, not a hidden attempt.
- **Executor supplies UI widgets/presentation:** violates host/plugin boundaries and couples execution to Flutter/UI lifecycle.
- **Separate top-level `ToolInvocationState` value object:** an enum/state transition on invocation was enough for this experiment. Durable event sourcing may later justify a richer type.
- **Distinct public `ToolPolicyInput` hierarchy per tool:** one common envelope with static and derived effects was enough. Tool-specific policy can inspect namespaced structured effect facts if later required.

## Conclusions

1. **Minimum stable identity:** a namespaced semantic `ToolId` including a compatibility/version boundary. It identifies meaning, not installation, provider generation, model alias, or individual invocation.
2. **Model-visible name:** separate and snapshot-local. It is a provider-safe projection used to map a provider call back to one materialized entry.
3. **Tool versus Capability:** orthogonal. A capability implementation may be projected into a model tool; dynamic/generic tools need not be capabilities. Existing typed contracts remain invocation mechanisms where applicable.
4. **Contribution shape:** model tools should be contributions to catalog/provider composition rather than capabilities by default. A plugin can contribute an adapter/catalog source while the host owns resolution and materialization.
5. **Immutable model snapshot:** yes. One model invocation needs an immutable materialization of visible definitions, aliases, semantic IDs, and exact executable bindings.
6. **`ToolInvocation`:** the normalized provider proposal after model-name lookup, carrying a run-local invocation ID, provider call correlation, semantic tool entry, exact binding, validated arguments, context linkage, effects, state, progress, and terminal outcome.
7. **Approval binding:** invocation, semantic identity/version, exact executable generation, canonical validated arguments, derived effects/targets/resource versions, and relevant context/environment.
8. **Exact implementation retention:** materialization captures a binding object/token. Proposal and approval retain it; execution validates that same binding immediately before use and never re-resolves by semantic/provider ID.
9. **Execution-attempt identity:** unnecessary in all six cases. Explicit retries should create new invocations and provenance links. Add attempts only if durable resume/retry executes the same approved invocation multiple times.
10. **Policy information:** semantic identity, binding/provider trust, validated arguments, full execution context, static effects, derived targets/effects/uncertainty, and resource/environment details.
11. **Explicit preflight:** useful and justified by patch/command/resource cases. It keeps effect derivation near executor knowledge and feeds both policy and approval.
12. **Progress versus result:** progress is ordered, nonterminal observation and may be partial/lossy; result is exactly one terminal semantic outcome with retained structured data.
13. **Cancellation:** a request to prevent/start termination, not rollback. Terminal outcome records whether effect began or may have occurred and whether a surviving resource exists.
14. **Terminal taxonomy:** success, invalid arguments, unavailable, stale binding, policy denied, user rejected, domain failure, infrastructure failure, cancelled, indeterminate, malformed result, plus domain codes and effect certainty.
15. **Indeterminate effects:** explicit terminal kind with `effectMayHaveOccurred`, known observations, resource/provenance links, and reconciliation guidance. Do not auto-retry.
16. **Data sent to model:** compact ordered content blocks plus typed outcome metadata correlated by provider call ID. Include only policy-safe structured/multimodal content, not host-only diagnostics.
17. **Host/UI data:** full structured outcome data, effects, progress, truncation, resources, artifacts, provider/binding metadata, and provenance remain available independent of model projection.
18. **Resource/artifact boundary:** a result is a Resource when it names an addressable live entity; an Artifact when independently persisted/retrievable; otherwise it remains inline structured outcome data.
19. **RuntimeResource:** yes, `start_process` justifies a first-class generic reference.
20. **Resource ownership:** execution environment/resource manager, with Run leases/policy and explicit cleanup operations; not the completed invocation.
21. **Dynamic MCP:** fits cleanly when connection identity, semantic tool identity, model alias, snapshot, and generation binding remain separate and generic content allows arbitrary schemas/results.
22. **Presentation binding:** host contributions keyed by version-aware semantic tool/result identity or declared semantic data schema, with unconditional generic fallback.
23. **Unnecessary abstractions:** execution-attempt identity, tool-as-capability, executor-owned presentation, text-only message/result wrappers, tool-specific central result casts, and a separate rich invocation-state object were unnecessary in this test.
24. **Material unresolved issues:** durable canonical approval fingerprints, schema dialect/validation ownership, materialization behavior across multiple provider model calls, runtime resource leases/recovery, progress durability/backpressure, result-data schema identity, and reconciliation of indeterminate effects.

## Open questions

- Is `ToolId` globally namespaced with a major version, URI-shaped, or a structured `(namespace, name, contractVersion)` value? MCP identity especially needs rules across server reconfiguration.
- Does a materialized tool snapshot live for one provider request only, or for all continuation calls until the model proposes/exhausts those definitions? A provider may refer to prior names in later turns.
- Where is canonical argument validation performed when JSON Schema dialects differ across model providers and MCP servers?
- Can preflight perform reads, and if so how are its own failures/effects and time-of-check/time-of-use races represented?
- Which workspace/resource versions must be included in approval and revalidated, and what changes are material enough to invalidate approval?
- How are progress ordering, retention, truncation, backpressure, and replay handled across plugin process boundaries?
- Should successful nonzero command exit be `success` plus command status, or a distinct domain-failure outcome for model policy? The experiment favors success plus status.
- What authority issues runtime-resource IDs, how are leases transferred across Runs, and what startup recovery/garbage collection exists?
- How does the host safely expose arbitrary MCP multimodal content and structured data to models and renderers?
- What is the stable identity/versioning mechanism for specialized result-data presentation contracts?
- When an executor loses contact after an effect, what capability performs reconciliation and links the resolution to the original invocation?
- Does durable Run replay require immutable lifecycle events rather than the experiment's mutable in-memory invocation state?
- Are parallel calls independently approved/executed, or can one interruption authorize an atomic group? None of the six cases establishes grouped semantics.

## Recommended questions for architecture synthesis

1. Define the compatibility and namespace rules for semantic `ToolId`, including dynamic MCP instances.
2. Specify the lifetime and persistence boundary of a `MaterializedToolSet` across model continuation calls.
3. Specify the executable-binding contract that adapters use to retain and validate capability or connection generations.
4. Decide the canonical validated-argument and approval-fingerprint format.
5. Define preflight purity, uncertainty, version checks, and time-of-check/time-of-use behavior.
6. Ratify a terminal outcome taxonomy with independent effect certainty and retry/reconciliation guidance.
7. Define generic content blocks and structured result-data schema/versioning without tying them to Flutter or Dart runtime types.
8. Assign runtime-resource identity, ownership, lease, cleanup, recovery, and provenance responsibilities.
9. Decide progress transport guarantees and what is durable in a Run record.
10. Define catalog contribution and host composition APIs while preserving generated capability contracts and keeping plugins independent of `agent_kernel`.
11. Define presentation contribution lookup, compatibility fallback, and trust boundaries for arbitrary MCP content.
12. Determine whether durable retries ever execute one invocation more than once; introduce execution-attempt identity only if that concrete requirement exists.
