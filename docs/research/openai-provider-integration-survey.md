# OpenAI Provider Integration Survey

## Status

This document is a **non-normative implementation-research synthesis** for ADELE.

It distills two targeted research passes performed on 2026-08-15 against current
OpenAI documentation, OpenAI Codex source, three third-party agent harnesses,
and ADELE's model-provider boundary.

It is intended to preserve:

- provider/protocol constraints discovered from current implementations;
- failure modes and design pressure worth carrying forward;
- the distinction between public OpenAI API behavior and Codex implementation
  details;
- the concrete ADELE implications that motivated Phase IV-B3 and guide the
  first real OpenAI provider;
- unresolved questions that should not be accidentally treated as settled.

It is **not** an ADR and should not override current ADELE source, architecture
documents, or accepted ADRs. Other projects are evidence of working approaches,
quirks, and mistakes; their abstractions are not assumed to be optimal.

Where the two research rounds disagree, **Round 2 supersedes Round 1**.

At the time of this synthesis, the major Round-2 contract correction has already
been implemented by Phase IV-B3 and recorded normatively in
[`../adr/0025-ordered-provider-native-model-items.md`](../adr/0025-ordered-provider-native-model-items.md).

---

# 1. Evidence hierarchy

The research deliberately distinguishes four kinds of evidence.

## OpenAI public documentation

Current first-party documentation defines supported public Responses behavior.
This is the strongest source for what ADELE may rely on as public API semantics.

Round 2 used:

- [Responses create/reference](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [Reasoning models](https://developers.openai.com/api/docs/guides/reasoning)
- [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [Streaming Responses](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Responses WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode)
- [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [Compaction](https://developers.openai.com/api/docs/guides/compaction)
- [Conversations API](https://developers.openai.com/api/reference/resources/conversations)

These APIs evolve. Future implementation work should re-check current docs
instead of treating this survey as a permanent wire specification.

## OpenAI Codex source

Current `openai/codex` source shows what OpenAI's own Codex clients actually do,
including implementation details not necessarily documented as stable
third-party contracts.

Codex source is particularly useful for:

- ChatGPT-authenticated routing and headers;
- token refresh/storage behavior;
- model catalog and subscription quota handling;
- request construction and Responses parsing;
- retry/fallback behavior;
- concrete ordering of reasoning, message, and function-call items.

Codex source does **not** by itself prove that arbitrary third-party software is
authorized to reuse Codex's OAuth client or ChatGPT backend route.

## Third-party source

OpenCode, Kilo, and Cline prove that other products have reproduced parts of the
Codex login/backend behavior and reveal practical failure modes.

They are useful evidence for interoperability pressure such as:

- sending a ChatGPT token to the wrong endpoint;
- losing the ChatGPT account header;
- refresh-token races;
- direct-API model metadata leaking into subscription-backed models;
- backend-specific request fields being rejected;
- encrypted reasoning or item identity being lost during replay.

Their source does not establish product authorization or API stability, and
their architecture should not be copied merely because it works.

## ADELE source and accepted ADRs

ADELE source is authoritative for ADELE's implemented behavior. Research should
pressure-test that architecture but not silently redefine it.

---

# 2. Inspected revisions

Two research rounds were performed.

## Round 1

| Repository | Branch | Commit |
| --- | --- | --- |
| `eric1234/adele` | `main` | `3e125b88a68e4fbcb699d5c1e7aed775ad1c1306` |
| `openai/codex` | `main` | `899d1715c87a504ce4c9ec85c2fd7753e33a7be4` |
| `anomalyco/opencode` | `dev` | `4643e65ad6334de3e4e68dedc201d5fbb828c9fe` |
| `Kilo-Org/kilocode` | `main` | `c8271ad6f4b9d8a33da2485202af17ab07563c63` |
| `cline/cline` | `main` | `8bbdde2a5c1f972864fe1b954f639c21fac61a40` |

OpenCode's upstream development/default branch was `dev`; assuming an absent
`main` would have inspected the wrong revision.

## Round 2

| Repository | Branch | Commit |
| --- | --- | --- |
| `eric1234/adele` | `main` | `3e125b88a68e4fbcb699d5c1e7aed775ad1c1306` |
| `openai/codex` | `main` | `b3cc21737803549679e2009193c04205f7d8d19c` |
| `anomalyco/opencode` | `dev` | `4643e65ad6334de3e4e68dedc201d5fbb828c9fe` |
| `Kilo-Org/kilocode` | `main` | `c8271ad6f4b9d8a33da2485202af17ab07563c63` |
| `cline/cline` | `main` | `8bbdde2a5c1f972864fe1b954f639c21fac61a40` |

Codex advanced between rounds by unrelated code-mode transport commits; the
Responses/auth paths under study were unchanged.

After the research, Phase IV-B3 implemented the ordered-native-item correction
and merged as PR #13. Future readers should use current `main` and ADR 0025 for
the actual contract shape.

---

# 3. Executive conclusions

The durable conclusions are:

1. **OpenAI API-key and ChatGPT/Codex subscription paths share important
   Responses wire machinery but are not the same provider route with a
   different credential.** Authentication, endpoint selection, required
   headers, model catalogs, entitlements, quota interpretation, and some
   accepted request fields differ.

2. **Protocol reuse is below provider identity.** The likely reusable unit is
   Responses request/item encoding, SSE/WebSocket event decoding, function-call
   correlation, usage/error parsing, and transport primitives. It is not a
   universal "OpenAI provider" abstraction.

3. **ADELE should keep the first Responses implementation private to the OpenAI
   plugin.** A second concrete provider should pressure-test what, if anything,
   deserves extraction. No public generic OpenAI-compatible package is justified
   by this research.

4. **Stateless HTTP/SSE canonical replay is a sound correctness baseline.**
   `previous_response_id`, WebSocket mode, Conversations, prompt-cache controls,
   and compaction may provide latency/state/context advantages but are not
   required for the first model/tool/model vertical.

5. **OpenAI Responses history contains independent ordered provider-native
   items.** Reasoning and compaction cannot always be represented as metadata
   attached to a neighboring semantic message or tool call. This was the
   material Round-2 correction.

6. **ADELE therefore needs an opaque ordered provider-native-only item, not an
   OpenAI-specific reasoning type.** Phase IV-B3 implemented this as
   `nativeItem` plus matching kernel types; ADR 0025 is the normative record.

7. **The provider stream must preserve the difference between live
   observations, authoritative completed output items, and semantic terminal
   settlement.** EOF is not success.

8. **Hidden retries must stop once anything observable crosses ADELE's provider
   boundary.** Without attempt identity/retraction, even a text delta makes a
   whole-invocation retry potentially duplicative or contradictory.

9. **Codex app-server is the wrong boundary for ADELE's `ModelProvider`.** It
   exposes Codex's own thread/turn/tool/sandbox/workflow semantics rather than a
   low-level model invocation, which would surrender authority that ADELE's
   kernel intentionally owns.

10. **ChatGPT/Codex OAuth remains a separate shipping-policy question.** Source
    visibility and third-party reimplementations demonstrate technical
    feasibility, not a documented right for ADELE to ship using OpenAI's Codex
    OAuth client/backend.

---

# 4. Public OpenAI Responses semantics versus Codex-specific behavior

Round 1 over-classified several concepts as Codex-private. Round 2 corrected
this against current first-party documentation.

## Public Responses concepts

The following are current public Responses features, sometimes with model or
route constraints:

| Concept | Research classification |
| --- | --- |
| `previous_response_id` | Public Responses API; available beyond WebSocket |
| Responses WebSocket mode | Public, route constrained |
| `response.create` | Public WebSocket client event |
| `generate:false` | Public WebSocket-only warmup behavior |
| encrypted reasoning | Public Responses item field |
| `reasoning.context` | Public, model constrained |
| `prompt_cache_key` | Public cache/routing hint |
| prompt cache options/breakpoints | Public, model constrained |
| `store:false` continuation | Public; full ordered replay is supported |
| Conversations API | Public durable conversation state |
| server-side compaction | Public Responses context-management feature |
| `/responses/compact` | Public stateless compaction endpoint |
| assistant `phase` | Public message field for relevant models |

The architectural consequence is important: ADELE should not model these merely
as "Codex hacks." They are provider-native/public Responses mechanisms that may
become useful later even on the ordinary OpenAI API-key path.

## Remaining ChatGPT/Codex backend differences

Current Codex source shows real managed-backend differences centered on:

- base route `https://chatgpt.com/backend-api/codex`;
- OAuth/PAT/identity authentication instead of an ordinary public API key;
- `ChatGPT-Account-ID` and FedRAMP account metadata;
- Codex originator/client/version and session/thread/turn metadata;
- `x-codex-turn-state` and other managed routing hints;
- subscription-specific model catalog/entitlement filtering;
- `x-models-etag` refresh behavior;
- subscription quota/rate-limit families;
- backend/model-specific request acceptance quirks.

These are provider-instance/auth/routing/catalog concerns. They should not be
pushed into ADELE's common semantic invocation contract merely because both
routes speak Responses-shaped traffic.

Useful Codex source areas from the inspected revisions include:

- `codex-rs/model-provider-info/src/lib.rs`
- `codex-rs/model-provider/src/auth.rs`
- `codex-rs/core/src/client.rs`
- `codex-rs/codex-api/src/endpoint/responses.rs`
- `codex-rs/codex-api/src/endpoint/responses_websocket.rs`
- `codex-rs/codex-api/src/sse/responses.rs`
- `codex-rs/models-manager/src/manager.rs`
- `codex-rs/codex-api/src/rate_limits.rs`

---

# 5. API-key and ChatGPT/Codex routes

## Public API-key route

The public route observed in Codex defaults to:

```text
https://api.openai.com/v1/responses
```

It uses bearer API-key authentication and does not require the ChatGPT account
identity/routing metadata used by the subscription path.

The public API-key route shares Responses request/event structures, SSE parsing,
tool-call forms, usage/error decoding, and much of the transport lifecycle with
the ChatGPT route.

## ChatGPT/Codex subscription route

Current Codex chooses:

```text
https://chatgpt.com/backend-api/codex/responses
```

for ChatGPT/Codex-backed model traffic.

Current source applies account-aware authentication and managed-backend
metadata. Third-party implementations independently reproduce the same broad
route distinction.

This means a future ADELE OpenAI plugin can reasonably have multiple configured
instances such as:

```text
OpenAI plugin runtime
├── Work / API-key instance
└── Personal / ChatGPT subscription instance
```

without confusing configured account/auth state with model identity or semantic
request state.

The implementation should share the wire machinery that is genuinely common,
while route/auth/catalog policy remains specific to the configured instance.

---

# 6. Responses request and stream authority

The research supports a three-layer interpretation that aligns with ADELE's
existing model-provider boundary.

## Live observations

Text deltas are useful live observations.

They are not authoritative canonical history. They may update the UI while the
provider stream remains active.

Whitespace-only deltas are meaningful and should not be discarded merely
because trimming makes them empty.

## Authoritative completed items

Completed Responses output items are the authority for replayable output.

Examples include:

- completed assistant messages;
- completed function calls;
- independent reasoning items;
- provider-native compaction items.

Completed text should be taken from the authoritative completed message item,
not reconstructed solely from visible deltas.

Completed function-call arguments should likewise come from the completed
function-call item.

The provider's item ID and tool `call_id` are distinct identifiers and must not
be conflated.

## Semantic terminal

`response.completed` or another explicit Responses terminal condition settles
the invocation.

A completed message or function call is not the invocation terminal.

TCP close and SSE EOF are not semantic success. If the stream ends before ADELE
has observed a valid provider terminal, the provider must report failure rather
than manufacture completion.

After a valid semantic terminal has been emitted, later transport teardown
cannot replace that settlement.

This maps naturally onto ADELE's existing distinction among:

```text
ModelProviderObservation
ModelProviderOutput
ModelProviderTerminal
```

---

# 7. Ordered provider-native items: the Round-2 correction

Round 1 incorrectly concluded that item-native metadata attached to semantic
messages/tool calls was enough for encrypted reasoning replay.

Round 2 disproved that assumption.

## Public replay rule

For stateless reasoning-model continuation, current OpenAI guidance requires the
client to preserve and replay every relevant output item in order.

The top-level Responses history is an ordered sequence of peer items such as:

```text
message
reasoning
function_call
function_call_output
```

Reasoning is not inherently an attribute of a neighboring function call or
assistant message.

Compaction adds another independent opaque item shape.

## Source evidence for ordering pressure

Codex's `ResponseItem` union represents messages, reasoning, function calls,
function outputs, compaction, and other items as ordered peers.

Inspected tests/source demonstrated or accepted sequences including:

```text
reasoning
assistant message
response terminal
```

```text
reasoning
function call
response terminal
```

```text
reasoning
function call
assistant message
response terminal
```

and fixtures/history capable of placing reasoning after semantic items as well.

Multiple function calls are also explicitly supported and order-preserved.

No sound ADELE representation should rely on an undocumented assumption that
there can be at most one reasoning item or that it always occurs immediately
before one particular semantic item.

Useful Codex evidence paths include:

- `codex-rs/protocol/src/models.rs`
- `codex-rs/codex-api/src/sse/responses.rs`
- `codex-rs/core/src/session/turn.rs`
- `codex-rs/core/src/stream_events_utils.rs`
- `codex-rs/core/tests/suite/tool_lifecycle.rs`
- `codex-rs/core/tests/suite/pending_input.rs`
- `codex-rs/core/tests/suite/tool_parallelism.rs`

## Why neighbor metadata is insufficient

Consider these provider sequences:

```text
reasoning, function_call
```

```text
reasoning, message, reasoning, function_call
```

```text
message, reasoning, function_call
```

```text
reasoning-A, reasoning-B, function_call
```

Attaching reasoning to the "nearest" semantic item invents provider-neutral
ownership that does not exist.

Prefix/suffix arrays or an invocation-level raw history fragment can preserve
bytes only by recreating a more complicated ordering protocol.

The smallest sound representation is therefore one opaque provider-native-only
item occupying its own ordered position.

## ADELE consequence

This research requirement is no longer pending.

Phase IV-B3 and ADR 0025 introduced:

```text
ModelProviderInputKind.nativeItem
ModelProviderOutputKind.nativeItem

SemanticNativeInput
ModelNativeOutput
```

The native item carries:

- optional provider item ID;
- required compatibility-bound native envelope;
- no ADELE-semantic text/tool payload.

Metadata attached to a semantic item remains valid for provider-native data
that intrinsically belongs to that semantic item, such as a provider message
attribute. Independent reasoning/compaction state uses an independent ordered
native item.

The kernel does not acquire OpenAI reasoning semantics.

---

# 8. Canonical replay and provider-native continuation

The research supports keeping **ADELE canonical semantic history as authority**.

For the first real OpenAI vertical:

```text
HTTP/SSE
store:false
full ordered replay
nativeState: null
```

is a sound correctness baseline after B3.

## Why `previous_response_id` is not required initially

`previous_response_id` is a public Responses feature, but current Codex uses
incremental response chaining only under compatibility conditions.

The inspected Codex path compares request properties and requires prior input
plus completed output to form a compatible prefix. Connection errors/reconnect
can clear the reuse baseline and fall back to full replay.

That is evidence that native chaining is an optimization/state-management path,
not the only correctness mechanism.

ADELE therefore does not need adapter-local "last response" state.

Any future invocation-native reuse needs explicit Session/Run ownership and
compatibility policy covering at least the configured provider instance,
account, route/protocol, model, request controls, tools, and canonical prefix.

## Item-native versus invocation-native state

The distinction remains useful:

- **item-native state** belongs at a specific position in replay history;
- **semantic-item metadata** belongs intrinsically to one semantic item;
- **invocation-native state** represents provider continuation/session
  optimization outside the ordered history itself.

Encrypted reasoning is item-level replay state. A response-chain ID or physical
WebSocket predecessor is invocation/transport state.

Do not collapse these categories.

---

# 9. First transport choice: HTTP/SSE

Round 2 found no correctness requirement forcing WebSocket or server-owned
conversation state into the first implementation.

HTTP/SSE with canonical replay supports:

- user → completed text;
- user → function proposal;
- tool outcome → model continuation;
- encrypted reasoning continuity after B3;
- semantic terminal/usage/errors;
- cancellation by closing the active HTTP operation.

This conclusion applies directly to the public API-key route from first-party
Responses documentation.

Current Codex plus OpenCode/Kilo/Cline source also demonstrates HTTP/SSE use
against the ChatGPT/Codex backend, but that route remains a source-visible
integration rather than a documented third-party contract.

## Deferred performance/state features

The following may become valuable later but are not first-vertical
requirements:

- Responses WebSocket mode;
- `previous_response_id`;
- `generate:false` warmup;
- Conversations API;
- prompt-cache controls;
- server-side compaction;
- invocation-native continuation reuse.

Implementation should measure actual self-hosting pressure before adding their
state/lifecycle complexity.

---

# 10. Retry boundary

Codex itself has layered retry behavior, including retry after a stream has
started. ADELE should not copy that policy blindly because Codex owns more of
the surrounding session/history machinery.

For ADELE's provider boundary, the conservative rule derived in Round 2 is:

> An internal retry may occur only while no ADELE observation, output, or
> terminal has crossed the provider boundary, and only if replay is otherwise
> known safe.

Once any ADELE event escapes, the provider cannot transparently retract or
identify the failed attempt.

This includes text deltas. Although a text delta is non-authoritative history,
it is still observable output and retry may duplicate or contradict what the
user has already seen.

Representative behavior:

| Failure point | Internal whole-invocation retry |
| --- | --- |
| Before request/stream establishment | Potentially safe if bounded |
| After internal `response.created`/`in_progress`, before ADELE output | Potentially safe if request is replay-safe |
| After text delta emitted | No |
| After completed native item emitted | No |
| After completed text emitted | No |
| After completed function call emitted | No |
| After valid semantic terminal | Never |
| EOF before terminal, with no ADELE event | Optional bounded retry; otherwise fail |
| EOF before terminal, after ADELE event | No; fail same invocation |

The first OpenAI implementation can be even simpler and perform **no automatic
retries**. That is preferable to prematurely encoding the wrong policy.

---

# 11. Function-call semantics

Responses function calls map cleanly to ADELE's existing common boundary.

Important identities remain distinct:

```text
provider response ID
provider output item ID
function call_id
ADELE semantic tool identity
model-visible function name
exact executable provider generation
```

The provider plugin should translate:

```text
Responses function_call
    ↓
ModelProviderToolProposal
```

without executing the tool itself.

ADELE's host/kernel owns:

- semantic tool resolution;
- schema/canonical argument validation;
- policy;
- approval;
- exact generation-bound execution;
- effect/outcome semantics.

Continuation lowers the corresponding tool outcome to:

```text
function_call_output
```

correlated by `call_id`.

A provider item ID must not be used as the tool-call correlation ID.

The common provider contract can represent multiple proposals even though the
current provisional development loop deliberately executes at most one per
model invocation. That strategy restriction should not be generalized into
OpenAI wire semantics.

---

# 12. Refusal, incomplete responses, failures, and usage

The existing common settlement/failure vocabulary was broadly sufficient after
the native-item correction.

## Refusal

Public Responses refusal appears as content in an output message.

For the current development strategy, it is acceptable for the OpenAI provider
to project the refusal explanation into completed assistant text and then emit
a `refused` semantic terminal.

A future richer content model may distinguish refusal content from ordinary
text, but current evidence does not justify expanding the common contract only
to mirror OpenAI spelling.

## Incomplete responses

Current public examples/research support mapping:

```text
max_output_tokens
    → incomplete / outputLimit

other provider incomplete reasons
    → incomplete / other
```

The exact provider reason can remain in provider stop/details.

Do not expand ADELE enums merely to reproduce every provider-specific reason.

## Failures

Representative coarse mappings:

```text
401 → authentication
403 → permission
429 → rateLimited
network/TLS/socket → transport
malformed provider/SSE/JSON → malformedResponse
server/provider error → unavailable or providerFailure as appropriate
```

Structured provider codes/messages and request IDs should be retained in
provider-specific detail where safe.

## Usage

Common fields can retain:

- input tokens;
- output tokens;
- cache-read tokens;
- cache-write tokens.

Provider-specific totals/reasoning accounting may remain in
`usage.providerDetails`.

No arithmetic relationship between the counters should be assumed.

---

# 13. Authentication findings for the later ChatGPT/Codex slice

The first OpenAI provider should prove the public API-key Responses route before
adding subscription auth. The research nonetheless captured several durable
requirements for the later auth slice.

## Browser and device flows

Current Codex implements managed ChatGPT login using:

- browser authorization-code flow with PKCE and loopback callback;
- an OpenAI-specific headless/device flow;
- refresh-token-based credential renewal.

Exact endpoints, scopes, client IDs, and parameters are time-sensitive and
should be re-read from current first-party docs/current Codex source before B5.

Round-1 source locations include:

- `codex-rs/login/src/server.rs`
- `codex-rs/login/src/pkce.rs`
- `codex-rs/login/src/device_code_auth.rs`
- `codex-rs/login/src/auth/manager.rs`
- `codex-rs/login/src/auth/storage.rs`
- `codex-rs/login/src/auth/revoke.rs`

## Account identity is part of provider-instance state

Current Codex extracts ChatGPT account/workspace/plan-related identity and
fences refresh/login behavior against silent account switching.

The research conclusion for ADELE is that the configured provider instance,
rather than a Session or model invocation, should own this state.

Conceptually:

```text
configured provider instance
├── auth kind
├── account binding
├── durable credential record
└── live auth session / refresh coordination
```

A model invocation should never contain credentials.

## Refresh tokens should be treated as rotating

Current source and third-party fixes show that refresh may replace both access
and refresh tokens.

The safe pattern is:

1. serialize refresh per configured instance;
2. reload the latest durable credential state;
3. refresh using the latest token;
4. atomically persist returned credentials;
5. reject stale commits if logout/relogin/account generation changed;
6. publish an immutable new live snapshot.

The synchronization key should be the **configured ADELE provider instance**,
not merely provider ID `openai`, account ID, Session, model, or individual
invocation.

Different configured instances such as Personal and Work should refresh
independently.

## Credential state separation

The research suggests four distinct layers:

| Layer | Example state |
| --- | --- |
| Provider-instance configuration | label, auth mode, endpoint/account binding, model defaults |
| Secret persistence | access token, refresh token, expiry, account fence, credential revision |
| Live auth session | immutable snapshot, refresh single-flight/mutex, timers/errors |
| Model invocation | semantic request, ordered replay, request/response IDs |

Credentials and refresh synchronization must not enter:

- Session history;
- native item envelopes;
- provider options;
- model invocation state;
- ordinary diagnostic logs.

This does not justify generalized ADELE auth infrastructure before the OpenAI
implementation creates the concrete persistence/UX requirement.

---

# 14. Third-party implementation lessons

The third-party projects differ architecturally, which is useful precisely
because their common failures reveal requirements independent of one design.

## OpenCode

At the inspected revision, ChatGPT auth is represented as an OAuth mode on the
OpenAI provider and the implementation uses a custom fetch layer around the
OpenAI AI SDK.

Observed lessons include:

- remove/replace SDK authorization correctly for OAuth traffic;
- route subscription traffic to the Codex backend rather than public OpenAI;
- preserve `ChatGPT-Account-Id`;
- avoid auth-transition leakage;
- preserve error/status/header information across WebSocket wrapping;
- retain compatible encrypted/item-native state;
- coalesce concurrent refresh.

The integration accumulated enough shims and fixes to be evidence against
assuming that route/auth differences can be hidden by one trivial fetch rewrite.

## Kilo

Kilo carries OpenCode-lineage integration code but adds stronger refresh
coordination, including cross-process locking.

Useful lessons:

- rotating refresh credentials create real concurrency hazards;
- copied provider integrations can retain branding/persona assumptions that do
  not belong in the protocol layer;
- sharing source lineage does not prove the abstraction boundary is clean.

Kilo uses dedicated integrations for several providers even where protocols are
similar, reinforcing that wire compatibility alone does not establish provider
identity.

## Cline

Cline uses more explicit provider identities:

- `openai-codex`;
- `openai-native`;
- `openai-compatible`;
- local Codex CLI integration.

Both subscription and native OpenAI Responses paths share lower-level SDK
machinery, while routing/options/catalog behavior remains distinct.

Useful lessons include:

- subscription-backed models should not inherit direct-API metadata blindly;
- the ChatGPT backend may reject nominal public fields such as output caps;
- credential writes/refresh need explicit safety;
- provider-managed tools and host-managed tools should remain distinct.

The tradeoff is that explicit provider identity can duplicate configuration.
ADELE need not copy that presentation model; the evidence is mainly that
identity/auth/catalog differences are real.

## Cross-project recurring failures

The repeated failure classes are more important than any one project's class
hierarchy:

- ChatGPT OAuth token sent to `api.openai.com`;
- normal API-key authorization leaking into OAuth traffic;
- missing ChatGPT account identity;
- rotating refresh races/stale token commits;
- direct API model/context assumptions applied to subscription models;
- backend-specific rejection of nominal request fields;
- stale provider item IDs under stateless replay;
- lost/malformed encrypted reasoning;
- stream wrappers losing structured error metadata;
- "OpenAI-compatible" endpoints rejecting OpenAI-specific fields.

These are test cases and boundary checks ADELE should learn from, not reasons to
copy the surrounding architecture.

---

# 15. What appears reusable, and what does not

## Strong candidate for future reuse

A future second Responses-compatible provider may justify reuse of:

- Responses JSON request/item structures;
- SSE framing and event decoding;
- authoritative completed-item reconstruction;
- function call/result encoding;
- item ID / call ID / response ID separation;
- usage/error decoding;
- terminal validation;
- EOF-without-terminal failure;
- cancellable HTTP streaming primitives;
- possibly WebSocket primitives later.

## OpenAI-specific concerns that should remain outside the shared wire layer

- OpenAI API key and ChatGPT OAuth behavior;
- account identity;
- public versus ChatGPT/Codex route selection;
- subscription entitlement/catalog/quota;
- originator/FedRAMP/Codex routing headers;
- model-specific field acceptance;
- OpenAI model discovery;
- provider defaults and model-family quirks;
- conversion between ADELE native envelopes and OpenAI item/state semantics.

## Why not extract a public package yet

The inspected systems show significant leakage in so-called compatible layers:

- provider name checks;
- URL heuristics;
- deleting first-party fields for non-OpenAI routes;
- provider-specific SDK wrappers;
- dedicated Azure/OpenRouter/xAI integrations;
- model/request exceptions.

ADELE currently has only one concrete consumer.

The sound first step is therefore:

```text
OpenAI plugin
└── private Responses modules with clean responsibilities
```

not:

```text
public universal OpenAI-compatible framework
```

After the OpenAI provider works, a second concrete provider can reveal whether
reuse should be source sharing, a private library, a public package, or a
different boundary entirely.

---

# 16. Codex app-server is not the ModelProvider boundary

The research explicitly examined whether ADELE could avoid implementing
OpenAI/Codex transport by spawning or embedding `codex app-server`.

The answer was negative for the `ModelProvider` role.

App-server exposes Codex concepts such as:

- threads;
- turns;
- items;
- model configuration;
- tools;
- approvals/permissions;
- sandbox/environment behavior;
- persistence;
- workflow orchestration.

It does not expose a narrow public "invoke this semantic model request" boundary
that leaves ADELE's orchestration authoritative.

Using it as the model provider would therefore make ADELE a client of Codex's
agent kernel and surrender control over boundaries ADELE intentionally owns:

- canonical Session history;
- Run lifecycle;
- context assembly;
- tool catalog/materialization;
- policy/approval;
- tool execution;
- provider-neutral workflow semantics.

Codex app-server may still be useful someday as an intentionally full external
agent backend, but that is a different capability/product integration from
ADELE's common `ModelProvider`.

Useful source areas:

- `codex-rs/app-server-protocol/src/protocol/common.rs`
- `codex-rs/app-server/src/request_processors/turn_processor.rs`
- `codex-rs/app-server/src/lib.rs`
- `codex-rs/app-server/src/in_process.rs`

---

# 17. Smallest justified OpenAI plugin decomposition

The research suggests responsibility boundaries rather than mandatory public
interfaces.

## Configured-instance/auth owner

Owns:

- configured ADELE provider-instance identity;
- API-key or ChatGPT auth mode;
- account binding;
- refresh/revocation;
- per-instance refresh synchronization.

Must not leak credentials into semantic requests or Session history.

## OpenAI route/model policy

Owns:

- public API versus ChatGPT/Codex route;
- required headers;
- accepted/default request fields;
- OpenAI model/catalog/entitlement quirks;
- subscription-specific quota behavior.

This layer is OpenAI-specific.

## Responses request/item codec

Owns:

- ADELE semantic input → Responses input;
- ordered semantic/native replay;
- function tool lowering;
- function-call output correlation;
- provider item metadata needed for stateless replay.

This is the clearest candidate for future compatible-provider reuse, but should
remain private initially.

## HTTP/SSE invocation

Owns:

- `/responses` HTTP operation;
- SSE framing;
- Responses event decoding;
- cancellation;
- structured HTTP/protocol failures;
- semantic-terminal-versus-EOF handling.

It should not own account refresh, model catalogs, or Codex workflow semantics.

## ADELE event normalization

Owns the projection into:

- live observations;
- completed text;
- tool proposals;
- provider-native-only output;
- semantic terminal/failure/usage.

Raw OpenAI event types should not leak into `agent_kernel`.

---

# 18. Near-term implementation sequencing

The research supports this sequence.

## Phase IV-B3 — completed

Real Responses replay exposed an ADELE semantic gap: independent native items
could not be represented losslessly.

Phase IV-B3 added the provider-native-only ordered item and corresponding kernel
types.

Normative decision:

[`../adr/0025-ordered-provider-native-model-items.md`](../adr/0025-ordered-provider-native-model-items.md)

## Phase IV-B4 — public API-key OpenAI provider

The first real provider vertical should use:

```text
OpenAI API key
HTTP /responses
SSE streaming
store:false
full ordered canonical replay
no WebSocket
no previous_response_id optimization
no invocation-native reuse
```

The goal is to prove:

```text
ADELE semantic request
    ↓
OpenAI Responses request
    ↓
streamed observations
    ↓
ordered native/text/function-call outputs
    ↓
semantic terminal
    ↓
ADELE tool execution
    ↓
function_call_output + canonical replay
    ↓
second Responses invocation
    ↓
final assistant output
```

This should use deterministic local HTTP/SSE fixtures in normal tests, with any
real OpenAI API call kept explicitly opt-in.

No common `adele_model_provider` expansion is currently expected.

## Phase IV-B5 — ChatGPT/Codex configured instance

After Responses transport is proven, extend the same OpenAI provider with:

- ChatGPT browser/device auth as justified;
- token storage/refresh;
- account binding/fencing;
- ChatGPT/Codex backend route;
- subscription catalog/entitlement/quota quirks.

This keeps OAuth/backend-policy risk separate from first-time Responses
transport debugging.

---

# 19. Explicit non-conclusions

The research does **not** establish that:

- OpenAI's Codex OAuth client is authorized for arbitrary third-party software;
- the ChatGPT/Codex backend is a stable public third-party API;
- every OpenAI-compatible service accepts the same request fields;
- provider wire compatibility implies provider identity;
- WebSocket is required for correct coding-agent behavior;
- `previous_response_id` is required for correct continuation;
- Conversations API should own ADELE Session state;
- Codex retry behavior is appropriate for ADELE;
- provider-native reasoning should become a common ADELE reasoning semantic;
- all unknown provider output items may safely be treated as opaque replay;
- model catalog/quota/auth state belongs in `ModelProviderRequest`;
- a general credential framework is required before the first configured
  subscription instance;
- a public reusable Responses package is justified before a second real
  provider exists.

Future changes should be driven by a concrete provider/self-hosting requirement,
not by completeness.

---

# 20. Unresolved questions

## ChatGPT/Codex authorization and product policy

The largest non-technical blocker remains:

> May ADELE ship a third-party integration using the OAuth client/backend
> behavior visible in current Codex source, and under what requirements?

Source inspection cannot answer that question.

Before shipping the subscription path, obtain authoritative current guidance on
client registration, allowed backend use, branding/originator requirements,
distribution constraints, and stability expectations.

## Credential storage UX

The research establishes state/race requirements but does not decide:

- which platform credential store ADELE should use;
- what fallback policy is acceptable;
- how configured Work/Personal instances are created and edited in product UI;
- how logout/account switching interacts with running plugin generations.

Those should be resolved when B5 creates the real configured-instance
requirement.

## Model catalog surface

The first API-key provider can use caller-selected model identity without
building a full catalog framework.

Later UX may need:

- available models;
- context limits;
- feature/capability metadata;
- subscription entitlement;
- direct-API versus ChatGPT availability.

That likely belongs in a separate provider/catalog surface rather than bloating
every model invocation.

## Native-state optimization

Invocation-native response chaining remains deliberately deferred.

If later performance pressure justifies it, compatibility must be explicit and
fallback to canonical replay must remain available.

## Second-provider extraction

Do not decide the reusable public Responses boundary until another concrete
provider pressures the OpenAI implementation.

Candidate future pressure tests include OpenRouter, xAI, Azure-style OpenAI
routes, or another provider with real Responses compatibility. The purpose
would be to discover the actual common boundary, not to maximize reuse in
advance.

---

# 21. Reproducibility and future reading order

When future work needs implementation details:

1. read current ADELE `main`;
2. read current accepted architecture/ADRs, especially ADRs 0024 and 0025;
3. use this document for the synthesized research findings;
4. re-check current first-party OpenAI documentation because the API is
   time-sensitive;
5. inspect current `openai/codex` source for source-only ChatGPT/Codex behavior;
6. revisit the pinned third-party revisions above when investigating historical
   failure modes;
7. prefer current upstream source over assumptions preserved in this survey.

Useful upstream source clusters from the research:

### OpenAI Codex

- `codex-rs/login/`
- `codex-rs/model-provider-info/`
- `codex-rs/model-provider/`
- `codex-rs/codex-api/`
- `codex-rs/core/src/client.rs`
- `codex-rs/core/src/session/`
- `codex-rs/models-manager/`
- `codex-rs/app-server/`

### OpenCode

- `packages/opencode/src/plugin/openai/`
- `packages/opencode/src/provider/`
- `packages/llm/src/protocols/openai-responses.ts`

### Kilo

- `packages/opencode/src/plugin/openai/`
- `packages/opencode/src/kilocode/provider/codex-refresh.ts`
- `packages/opencode/src/provider/`

### Cline

- `sdk/packages/core/src/auth/codex.ts`
- `sdk/packages/llms/src/vendors/openai.ts`
- `sdk/packages/llms/src/providers/`
- provider settings/runtime OAuth storage code

The exact upstream files may move. The recorded commits preserve the evidence
basis; current source should govern new implementation work.

---

# 22. Bottom line

The shortest sound OpenAI path for ADELE is:

```text
common ADELE ModelProvider semantics
        ↓
bespoke OpenAI provider plugin
        ├── configured-instance auth/route policy
        └── private Responses wire implementation
                ↓
        HTTP/SSE + canonical ordered replay first
```

The first production slice should prove the public API-key Responses path.
ChatGPT/Codex auth should then be added as a distinct configured-instance
auth/routing mode over the same proven Responses machinery.

The research supports designing the private Responses code so later extraction
is possible, but it does not support standardizing a generic
OpenAI-compatible provider framework today.

Provider-native state should be preserved only at the level that owns it:

- intrinsic semantic-item metadata stays attached to that semantic item;
- independent provider items retain their own ordered native position;
- invocation/transport continuation remains separate and optional.

That boundary keeps ADELE's Session, Run, tool execution, approval, and workflow
semantics authoritative while still allowing the OpenAI provider to preserve
the exact provider state required for high-quality stateless continuation.
