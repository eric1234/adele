# Model-Provider Semantic Boundary Survey

## Status

**Research / non-normative**

This document records the source research that informed ADELE's first common model-provider capability before Phase IV-B2 implementation.

It does not define a stable public API. Exact Dart types, capability identifiers, persistence schemas, provider configuration, authentication, and future capability-major evolution remain implementation decisions. Accepted current behavior belongs in `docs/architecture/`; durable architectural decisions belong in ADRs where useful.

This survey builds on [`agent-harness-semantic-boundary-survey.md`](agent-harness-semantic-boundary-survey.md). The earlier survey established the broad provider boundary:

```text
semantic model request
    ↓
provider/model-specific lowering
    ↓
protocol / route / live client
    ↓
provider stream
    ↓
normalized model events/items
    ↓
outer orchestration
```

The research here asks the narrower question needed by IV-B2:

> What information and lifecycle semantics must cross ADELE's first plugin-facing model-provider capability without making that capability OpenAI-shaped, Anthropic-shaped, Gemini-shaped, or fixture-shaped?

## Research method

Two source passes were performed on 2026-08-14.

### Pass 1 — cross-project provider-boundary survey

Eight checked-out agent harnesses were inspected at exact clean revisions:

| Project | Revision |
| --- | --- |
| OpenAI Codex | `646f7c0a91b8e327d263335da68ae8ef212895ce` |
| OpenAI Agents Python | `e3d7c1727bf43761afbb7954651b7f908a973a3b` |
| Gemini CLI | `cf22ac7e86f3dcf528e3ae591fec1c03090a49f8` |
| OpenCode | `38e10eb1408feb700021b8e8766fb0ab41bf84e2` |
| Goose | `064244e6bddf641876676f054a006b7da1da5182` |
| Cline | `b3cee3f973ffe9d023a10c5c414deba68cd6e09d` |
| OpenHands Software Agent SDK | `be6cd3b80b706bb14c91e604581a8de75cad61cc` |
| Aider | `5dc9490bb35f9729ef2c95d00a19ccd30c26339c` |

ADELE itself was inspected at `5d8c4c4b61edf21d8722867f629c8d1c69492232`.

For the primary projects, the pass traced an actual model invocation through orchestration, common request representation, provider lowering, transport/client, stream normalization, tool proposal handling, tool-result continuation, and subsequent invocation. Tests were used heavily for ordering, retry, cancellation, and continuation behavior.

### Pass 2 — Anthropic and ADELE-generator pressure test

The first pass left a small number of questions whose answers depended on a concrete provider and ADELE's generated-contract representation. Anthropic was selected as a deliberately non-OpenAI pressure source, not as a permanent provider priority.

Official SDKs were pinned and inspected:

| Source | Revision |
| --- | --- |
| Anthropic Python SDK | `ad53cac8eeeb1608c162081f883755427ac3a26f` (`v0.122.0`) |
| Anthropic TypeScript SDK | `64a1e8e285bbcc4cef2b15ebcadccd8e5f6987ff` (`sdk-v0.117.1`) |

OpenCode, Goose, Cline, and OpenHands were cross-checked for native or adapted Anthropic behavior. Official Anthropic documentation was used where SDK source did not establish server protocol rules.

Two disposable candidate ADELE contract shapes were also run through the real `contract_codegen` implementation. No production source was modified.

## Evidence cautions

The surveyed projects use different meanings for terms such as provider, model, response, item, message, turn, and request.

Important distinctions repeatedly observed are:

```text
provider implementation
configured provider/account/endpoint
model identity
protocol/API family
route/base URL
live client
logical model invocation
provider HTTP request
provider response/message
provider output item
provider tool call
```

These are not interchangeable even when one project collapses several of them into one string or object.

Some projects delegate protocol behavior to LiteLLM, AI SDK, or official provider SDKs. Claims in this document distinguish repository-visible semantics from behavior hidden behind those dependencies.

# Cross-project findings

## The common boundary must not be `role + String`

Typed heterogeneous content is the normal case in mature harnesses.

Codex and OpenAI Agents use Responses-style typed input/output items. Gemini uses heterogeneous `Content`/`Part` values. OpenCode has typed text, reasoning, media, calls, and results. Goose uses typed content blocks. Cline uses typed runtime parts. OpenHands carries typed messages and tool structures.

Aider is the useful limiting counterexample: its broad provider reach is built largely on OpenAI-shaped dictionaries and an overloaded model string, and its general tool-continuation semantics are correspondingly weak.

ADELE does not need to implement every media/content type in IV-B2. The evidence instead says that the **fundamental provider request must be typed and ordered**, even if capability major 1 initially supports only text content plus tool interactions.

## Instructions are distinct from chronological conversation

Every strong provider boundary has a separate concept for privileged instructions/system context, even when protocol lowering varies.

Anthropic uses top-level `system`; Gemini uses `systemInstruction`; Responses APIs expose instructions separately; OpenCode may lower chronological system updates differently when a protocol cannot preserve their authority.

This distinction matters because ADELE context assembly includes Agent instructions, project/task context, and workflow-step instructions that should not become ordinary user conversation merely to fit a provider API.

## Provider instance and model identity are separate

No mature architecture supports collapsing configured provider and model identity into one durable concept.

Examples include:

- OpenCode's catalog provider/model, wire API model ID, protocol route, endpoint, and credentials;
- Codex's provider metadata versus `ModelInfo.slug` and server-reported reroute information;
- Cline's configured identity versus gateway-resolved provider/model;
- OpenHands' configured model alias versus canonical capability model.

The requested model may also differ from the effective model. Routing, aliases, reusable prompts, provider defaults, proxies, or server-side model selection can make the actual model known only after invocation.

Therefore a common request should identify the selected/requested model while response metadata may optionally report an effective model.

## Model invocation is lifecycle-bearing streaming

All deeply traced mature implementations stream internally. Streams carry more than token deltas:

- completed semantic items;
- tool-call formation/completion;
- usage;
- reasoning or provider-native state;
- retry/rate-limit observations in some implementations;
- provider errors;
- authoritative terminal settlement.

The strongest repeated finding is that **transport stream exhaustion is not equivalent to semantic success**.

Gemini validates that an exhausted stream is not empty, blocked, malformed, or thinking-only. OpenAI Agents requires a terminal response event. Codex treats missing/incomplete completion as failure. OpenCode has explicit step/response settlement. Goose is the notable simpler counterexample that largely treats stream exhaustion as completion and therefore loses terminal semantics.

ADELE should preserve an explicit semantic terminal event rather than inferring success from generated stream `onDone`.

## Live observations and authoritative items are different

Text/reasoning/tool-input deltas are generally transient. Completed text, completed tool proposals, and terminal settlement are authoritative.

OpenHands makes this distinction especially explicit: streaming deltas are nonpersistent while the reassembled final response and Action/Observation events are durable authority. OpenCode similarly separates live deltas from persisted completed blocks/calls. Gemini can expose partial content from an attempt that is later retried, while only the successful validated turn enters history.

This is important for ADELE's UI direction: Chat should be able to display live model output without treating every token as canonical Session history.

### IV-B2 implication

Capability major 1 should include a nonauthoritative text-delta observation because ADELE's planned running Chat UX expects live streaming and adding a new event category later would require capability evolution. Completed text remains the authoritative semantic output.

No current consumer justifies reasoning deltas, tool-argument deltas, or generic provider-attempt activity in v1.

# Tool semantics at the model-provider boundary

## Tool definitions have a small common core

Across providers, ordinary model-visible function tools repeatedly require:

```text
model-visible name
human/model description
structured argument schema
```

Semantic ADELE `ToolId`, executable bindings, policy, approval, effects, and generation ownership remain host/kernel concerns. They should not cross the common model-provider contract as provider semantics.

The current ADELE resource-inspector schema lowers unchanged to Anthropic's ordinary tool shape. Anthropic's SDK expects an object-root JSON Schema and permits the fields currently used by ADELE, including `required`, `properties`, `additionalProperties`, and the `uri` string format.

Provider adapters remain responsible for validating provider/model name restrictions and unsupported schema combinations. Host-side argument normalization remains authoritative after model output.

## Multiple tool proposals are fundamental provider semantics

Every primary harness supports more than one model tool call per invocation. Aider is the weak exception.

ADELE's current development strategy supports only one proposal per model invocation, but that is an orchestration limitation. The common provider contract must not encode it.

The provider stream should therefore support ordered multiple completed tool proposals, each with a stable provider call ID.

## Proposal formation is not execution authority until completion

Providers may stream partial JSON/tool-input fragments, but orchestration generally executes only a completed proposal with:

```text
stable call ID
model-visible tool name
final structured arguments
```

The timing of “completed” varies. Codex/OpenCode can make completed calls actionable before the entire provider response terminates. Gemini and OpenAI Agents conservatively wait for whole-response validation.

The common contract should represent a completed proposal independently from terminal settlement, but the first ADELE workflow may conservatively wait for semantic terminal success before performing side effects.

## Tool-result lowering is provider-specific; correlation is common

The same portable semantic interaction lowers very differently:

- OpenAI Chat uses assistant `tool_calls` followed by role `tool` messages;
- Responses uses `function_call` and `function_call_output` items;
- Gemini uses model `functionCall` followed by user `functionResponse` parts;
- Anthropic uses assistant `tool_use` followed immediately by a user message containing `tool_result` blocks.

The common semantic is not a provider role. It is:

```text
completed assistant tool proposal
    identified by provider call ID
        ↓
correlated tool outcome
```

ADELE's existing `ProviderToolProposal`, `SemanticToolProposalInput`, and `SemanticToolOutcomeInput` already capture the essential ordinary-tool correlation needed by Anthropic. Anthropic's exact `tool_use.id` is the value that must be retained; message ID and stream block index are not needed for ordinary tool replay.

# Provider-native continuation state

## Canonical ADELE history remains the authority

Mature harnesses repeatedly retain a provider-neutral/canonical representation while optionally using provider-native continuation state when compatible.

Examples include:

- Responses `previous_response_id` or server conversation state;
- provider response/item identifiers;
- encrypted/signed reasoning/thinking metadata;
- Gemini thought signatures;
- protocol-specific message metadata.

Switching provider/model generally requires explicit semantic replay or a compatibility-aware projection rather than pretending native continuation is portable.

ADELE should therefore treat native continuation as optional **provider-owned compatibility-bound state**, never as the sole representation of conversation meaning.

## Anthropic proves that item-level native metadata is sometimes required

The Anthropic thinking-tool workflow resolved an important open question.

When extended/adaptive thinking participates in a tool-use turn, Anthropic requires every `thinking` and `redacted_thinking` block to be returned complete, unmodified, and in the original order relative to `tool_use` blocks. Response types include:

```text
thinking {
  thinking: String
  signature: String
}

redacted_thinking {
  data: String
}
```

The opaque signature/redacted data are JSON-compatible strings, so ADELE does not currently need binary contract support.

Invocation-level opaque state alone is an awkward representation because provider-native blocks occupy precise positions around semantic tool items. A common v1 therefore benefits from **optional provider-native metadata attached to completed/input items**.

This metadata does not become common reasoning semantics. The provider implementation owns its meaning and replay rules.

## Invocation-level native state is still useful

Other providers use state that is naturally invocation-level: response IDs, conversation IDs, or continuation tokens.

The v1 boundary should therefore reserve both:

```text
optional item-level provider-native metadata
optional invocation-level provider-native state
```

Both can be represented as JSON-compatible opaque data with a small compatibility/ownership envelope. Reuse should be bound conservatively to the exact configured provider instance and compatible provider/model/protocol context. On incompatibility, the provider state is discarded and canonical semantic history is replayed.

# Identity and metadata

## Tool call ID, output item ID, response ID, and request ID are different

Cross-project source shows distinct purposes:

- **tool call ID** correlates proposal to tool outcome and is required common semantic data;
- **item/output ID** can correlate partial/completed output and retain item-native replay metadata, but providers may not expose one;
- **response/message ID** can be diagnostics or provider-native continuation state;
- **HTTP request ID** generally identifies one transport attempt and is diagnostic.

These should not be collapsed into one generic identifier.

Anthropic reinforces this directly: `tool_use.id` must survive tool continuation; message ID does not. `request-id` is useful for support/diagnostics but not semantic replay.

## Requested and effective model identities should remain distinct

Anthropic requires a model in the request and returns a required model string on a valid response Message. Other surveyed systems show aliases, routing, prompts, and proxies can make requested/effective identity differ or make effective identity unavailable.

Therefore selected model is common request semantics and effective model is optional response/terminal metadata.

# Usage and terminal semantics

## Usage has a common core, not a universal taxonomy

Input and output token counts have the strongest cross-provider meaning. Cache-read/cache-write and reasoning-token fields are useful when supplied but provider semantics differ.

Anthropic, for example, reports cache creation/read separately from `input_tokens`, and stream usage updates are cumulative rather than incremental.

A provider-neutral v1 can therefore carry optional common input/output/cache counts while retaining provider-specific usage detail in an opaque structured map. ADELE must not silently redefine provider accounting categories.

## Terminal classification should be coarse and behavior-driven

Provider stop/finish reasons disagree substantially. A large closed enum copied from one protocol would age poorly.

Anthropic's stop reasons include ordinary completion, tool use, output limits, context exhaustion, refusal, and hosted-tool pause behavior. Other providers use different names and groupings.

The portable host behavior is closer to:

```text
successful settlement
incomplete settlement
refused/declined settlement
failed invocation
```

with provider-native reason/detail retained separately.

The exact Dart decomposition should be chosen during IV-B2 implementation. The research scratch enum layout is evidence, not a required API.

# Failures, retries, and cancellation

## Common failure grouping should reflect host behavior

Provider exception taxonomies are too detailed and unstable to expose directly as the common contract.

The source evidence supports a deliberately coarse grouping along the lines of:

```text
invalid request / unsupported request
authentication
permission
rate limited
unavailable
context/request/output capacity
transport/network/timeout
malformed provider response/protocol
provider-declared failure
unknown
```

Provider code, message, retry-after information, and detailed fields remain supplemental provider detail.

Cancellation is not required to appear as a provider failure. Consumer cancellation is fundamentally a host/transport lifecycle operation.

## Retryability is not an intrinsic error property

The survey found retries at multiple layers. Some providers/harnesses hide them; Gemini exposes retry events; Codex has several retry layers; OpenAI Agents explicitly limits replay after output or side effects; OpenCode retries pre-stream transport but not after parsing begins.

Whether replay is safe depends on escaped output, provider-side state, and side effects—not merely an HTTP status.

IV-B2 should therefore not make a required `retryable` boolean part of common semantics and should not add generic provider-attempt events without a concrete consumer.

Provider plugins may internally retry safe pre-output failures. Once meaningful output has escaped, hidden whole-invocation replay should be conservative.

## Consumer cancellation must propagate through the server stream

All mature harnesses propagate cancellation from orchestration into active model transport via tokens, abort signals, task cancellation, or stream teardown.

ADELE Phase II-B already provides generated consumer cancellation and exact-generation stream lifetime. The common model-provider operation should remain server-streaming so cancellation reaches the plugin producer.

No provider-generated cancellation terminal is required after the consumer has cancelled the stream.

# Provider disappearance and generation safety

ADELE's capability runtime provides an additional semantic requirement not present uniformly in the surveyed harnesses: exact provider generations.

A provider binding retained for one model operation must not silently migrate to a restarted generation.

Provider disappearance can occur before any event or after partial/completed output. The dead provider cannot emit a semantic terminal, so disappearance belongs primarily to generated transport/runtime failure. The application adapter maps a preterminal disappearance into kernel invocation failure while retaining already delivered observations/items as non-successful partial work.

If a provider has already emitted an authoritative semantic terminal, later connection loss does not retroactively make that completed invocation fail.

# Capability discovery

The research did not find a universal capability-negotiation object.

Feature support is commonly derived from some combination of:

- configured model metadata;
- provider catalogs;
- model-family predicates;
- account/endpoint configuration;
- route/protocol implementation;
- runtime validation;
- provider APIs.

For IV-B2, full capability/model discovery is not needed. The first provider path can use configured model metadata/host configuration and reject unsupported invocation features explicitly.

A future model-descriptor/catalog capability can be introduced when context budgeting, model selection, media support, or UI needs become concrete.

# ADELE contract-generator pressure test

## Current constraints

At the inspected revision, `contract_codegen` supports one generated service per declaration library, unary `Future<T>`, server-streaming `Stream<T>`, final flat annotated values, enums, lists, nullable required fields, and JSON-compatible `Map<String,Object?>` values.

It does not provide first-class sealed/tagged unions. Unknown/missing record fields and unknown enum values are rejected, so additive fields/variants are not same-major compatible.

These limitations are deliberate scope choices rather than immutable platform restrictions. ADELE can extend the generator when a concrete requirement justifies it.

## Disposable event-shape experiment

Two research-only candidate contracts were generated and analyzed successfully.

### Shape A — one flat discriminated event

A single event record held event kind plus roughly 17 payload-dependent nullable fields.

Results:

```text
source:     181 lines / 4,460 bytes
generated:  1,498 lines / 47,639 bytes
analysis:   no issues
```

It is compact in generated size but permits many nonsensical combinations and pushes validation into one large switch.

### Shape B — category envelope with nested payloads

The outer event separated:

```text
event
├── observation?
├── output?
└── terminal?
```

with smaller nested records for observation/output/terminal data.

Results:

```text
source:     220 lines / 5,240 bytes
generated:  1,605 lines / 51,393 bytes
analysis:   no issues
```

The roughly eight-percent generated-size increase is negligible. Authority categories are more visible, validation is more local, and item-native metadata naturally belongs on completed output.

### Conclusion

The current generator is awkward but sufficient for IV-B2. First-class tagged unions would improve type coherence and generated validation, but no self-hosting capability is blocked without them.

Under ADELE's scope goals, generator work should therefore be deferred for IV-B2 rather than performed only to make one experimental contract prettier. If another concrete contract repeats the pressure or a future semantic cannot be expressed cleanly, adding a deliberately constrained sum-type feature remains reasonable.

# IV-B2 semantic recommendations

These are research-derived recommendations, not the final public API.

## Include in capability major 1

The evidence supports a first common ModelProvider capability with one generation-bound cancellable server-streaming invocation whose request can represent:

```text
selected model
privileged instructions
ordered typed input
    user/assistant text
    prior completed tool proposal
    correlated tool outcome
model-visible function tool definitions
minimal tool choice: automatic / none
optional maximum output ceiling
provider-owned options
optional invocation-level native state
```

The stream should be able to expose:

```text
live observation
    text delta

authoritative completed output
    completed text
    completed tool proposal
        optional provider output/item ID
        required tool call ID
        optional provider-native item metadata

semantic terminal settlement
    coarse completion state
    coarse failure category when applicable
    provider code/message/details
    optional usage
    optional effective model
    optional response ID
    optional request ID
    optional invocation-level native state
```

Multiple completed proposals must be valid even if the first ADELE workflow executes only one.

The public contract must not import `agent_kernel`. The desktop/application composition layer remains responsible for translating between public provider values and internal kernel semantics.

## Deliberately defer from major 1

The source evidence does not justify implementing these before self-hosting:

- image/resource input variants;
- structured-output constraints;
- reasoning summary or raw reasoning events;
- raw chain-of-thought;
- tool argument delta events;
- generic provider retry/attempt activity;
- hosted/provider-executed tool orchestration;
- named/required/parallel tool-choice algebra;
- exhaustive generation controls such as temperature/top-p/top-k;
- comprehensive model capability/catalog discovery;
- provider pricing/quota metadata;
- duplex tool-result injection into an active model stream.

Adding one of these later may require a capability-major evolution. That is acceptable for an experimental greenfield plugin surface; a clean small v1 is preferable to prebuilding every anticipated feature.

# High-value counterexamples retained for future design

Several findings are especially useful because they prevent apparently convenient abstractions from hardening incorrectly.

### Broad provider support does not prove a sound common boundary

Aider reaches many providers through LiteLLM while relying heavily on OpenAI-shaped dictionaries and model-name heuristics. This is useful evidence against treating protocol reach as semantic neutrality.

### A common IR can still be provider-shaped

Codex and OpenAI Agents have mature abstractions but their common representations are strongly Responses-shaped. ADELE should preserve their lifecycle lessons without copying Responses item names as its public vocabulary.

### Native continuation can be semantically required, not merely an optimization

Gemini thought signatures and Anthropic signed/redacted thinking demonstrate that replay may require opaque provider state even when visible reasoning is intentionally omitted.

### Completed tool arguments do not necessarily contain all replay state

Anthropic/Gemini reasoning metadata can surround a tool proposal. Therefore callable semantic arguments and provider-native replay metadata are separate concerns.

### Stream close is not completion

Gemini, Codex, OpenAI Agents, OpenCode, and Anthropic all provide evidence that semantic success requires more than EOF.

### A model may not be fully identifiable before invocation

Aliases, routing, proxies, prompts, and server reroutes mean requested and effective model identity should not be forced into one value.

# Remaining research and implementation boundary

The two provider-boundary passes identified no research blocker to IV-B2 implementation.

Remaining questions are either implementation-local or safe to defer, including:

- exact Dart names and constructor invariants for the nested event records;
- where provider-native metadata is persisted after process restart;
- richer provider/model capability discovery;
- image and structured-output semantics;
- reasoning presentation;
- provider-attempt activity;
- capability-major 2 evolution;
- whether recurring contract pressure later justifies generated tagged unions.

A separate future research pass should investigate **OpenAI/Codex subscription-backed authentication and transport** before implementing the first real OpenAI provider. That concern belongs to configured-provider authentication and routing, not to the common model semantic contract established here.

Likely subjects for that pass include ChatGPT/Codex OAuth flow, PKCE/browser/device mechanics, refresh-token lifecycle, credential persistence, account/workspace identity, subscription-backed request endpoints and headers, model selection, usage/rate-limit metadata, logout/revocation, and differences from API-key Responses access.

The intent is to make OpenAI subscription-backed access useful for ADELE self-hosting without contaminating `ModelProvider` invocation semantics with one provider's authentication mechanism.
