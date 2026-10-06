# OpenAI Model Provider Backend

`openai_model_provider_backend` is the pure-Dart OpenAI Responses implementation
of public `adele_model_provider`. It runs as a prepared AOT backend through the
shared plugin host, not as linked Flutter application code. It supports the
public API-key route and a separately configured, explicitly experimental ChatGPT
subscription-backed classic Responses route. The latter is interoperability
support, not a stable third-party OpenAI integration contract.

Normal stock composition exposes only the ChatGPT context; other consumers may
activate the API-key context or both. Credential loading belongs to this backend.
See [app configuration](../../../../app/README.md#chatgpt-source-checkout-configuration)
and [ADR 0028](../../../../docs/adr/0028-experimental-chatgpt-openai-configured-instance.md)
for startup/auth ownership and limitations.

## Reasoning Summary Requests

The backend requests provider-supplied reasoning summaries with
`reasoning: {'summary': 'auto'}` only for its narrow exact-model support set in
`lib/openai_model_provider_backend.dart`:

- `gpt-6-astra`
- `gpt-5.6-sol`
- `gpt-5.6-terra`
- `gpt-5.6-luna`
- `gpt-5.5`
- `gpt-5.4`

This guard applies to both existing request profiles. Other IDs, including
unlisted aliases or snapshots, retain the prior request policy without the
`reasoning.summary` field. It is not a prefix rule, a complete model catalog, an
assertion that every model supports summaries, or a new provider-neutral model
option. It changes neither reasoning effort nor context policy. There is no
automatic retry that removes the option after a provider error.

The request choice is based on OpenAI's current
[reasoning-summary guide](https://developers.openai.com/api/docs/guides/reasoning#reasoning-summaries)
and [Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create).
The guide documents explicit opt-in, model-dependent support, and `auto` selecting
the most detailed supported summarizer. First-party
[Codex source at commit `7f01a84effccef40d4726c3ca12e6c839ec98d7a`](https://github.com/openai/codex/tree/7f01a84effccef40d4726c3ca12e6c839ec98d7a),
including its model catalog and classic Responses lowering, supplies additional
evidence for the experimental ChatGPT route. These external references are not
ADELE live-call results or a guarantee that an account/model will return nonempty
summary text. No E3 live-provider validation is claimed.

Existing `store: false`, `stream: true`, `parallel_tool_calls: true`, and
`include: ['reasoning.encrypted_content']` remain in place. Parallel tool calls
permit multiple proposals in one response, not concurrent ADELE tool execution.

## Session Routing, Run State, And Cache Usage

For the experimental ChatGPT profile, a supplied `ModelProviderRequest.affinity`
maps its opaque live-Session routing ID to the literal `session-id` HTTP header.
The same Session keeps that ID across Runs, but each Run starts with null provider
turn state. Different live Sessions use different IDs; neither identity nor state
is persisted. A standalone single-Run caller can allocate its own routing ID.
The backend captures the first usable `x-codex-turn-state` header from a successful
HTTP response before consuming SSE. It returns that token only through
`ModelProviderTerminal.affinityState`, including on incomplete, refused, failed,
and malformed/transport stream terminals when available. Later requests replay
the first token unchanged within that Run; later response headers do not rotate
it. The next Run retains the Session routing ID but must not send the preceding
Run's token. Cancellation without a terminal does not publish state.

The caller owns this ephemeral state for one live Run and exact provider/model
binding. There is no backend affinity table or durable state. The private envelope
is bound to the supplied scope, requested model, configured auth instance, and
endpoint. Unsupported or incompatible envelopes fail explicitly before HTTP.
Affinity-bearing requests do not follow redirects to another route.
Account or FedRAMP routing changes clear the old token before sending, including
the existing pre-output 401 recovery path; ordinary same-account token refresh
preserves it. IDs and tokens are bounded safe header values. Affinity tokens and
account routing stay out of usage, native replay metadata, history, and ordinary
diagnostics; failure text and diagnostic IDs redact known affinity values.

Null affinity and the API-key profile add no affinity headers. This policy changes
neither request bodies nor ordered replay: `nativeState` remains null,
`providerOptions` remain unsupported, and no `prompt_cache_key`,
`previous_response_id`, retention setting, or additional retry is introduced.
Affinity is a locality hint, not an assertion of cache residency or a cache hit.
The interoperability basis is pinned Codex
[ChatGPT session routing and turn lifetime](https://github.com/openai/codex/blob/ade17c62b0caf6fb1354eb7f3bc25853f44656ab/codex-rs/core/src/client.rs),
[HTTP first-value capture](https://github.com/openai/codex/blob/ade17c62b0caf6fb1354eb7f3bc25853f44656ab/codex-rs/codex-api/src/sse/responses.rs),
and [same-turn HTTP regression](https://github.com/openai/codex/blob/ade17c62b0caf6fb1354eb7f3bc25853f44656ab/codex-rs/core/tests/suite/turn_state.rs).

Both profiles preserve reported `usage.input_tokens_details.cached_tokens` and
`cache_write_tokens` as nullable read/write counts. A reported zero remains zero;
missing, null, or invalid counters remain unreported rather than fabricated zero.
The [public prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)
and [Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create)
document these fields. Public API automatic caching does not establish identical
ChatGPT routing or billing: [Codex pricing](https://developers.openai.com/codex/pricing#token-rates)
explicitly distinguishes subscription credit billing from API-key pricing.

## Replay And Presentation

The pure-Dart sibling [Contract](../contract/README.md), `openai_contract`, owns
identities and payload schema only, with no algorithms. Its shared raw constants
`openAiResponsesItemKind = 'openai.responses.item.v1'` and
`openAiResponsesItemVersion = 1` are unchanged. This backend imports them rather than
duplicating the native-envelope identity. Provider-native reasoning and compaction
items remain opaque to common model/orchestration consumers. Supported native
items, including encrypted content, retain their exact data and order for replay;
presentation does not sanitize, truncate, replace, or otherwise rewrite them.

`lib/src/openai_native_presentation.dart` owns
`projectOpenAiReasoningSummary(ModelProviderNativeEnvelope)`, including raw Responses
classification and processing bounds. `lib/openai_model_provider_backend.dart`
attaches the safe result while preserving exact native metadata. It accepts nonblank
`summary_text` parts of reasoning items and emits generated
`ModelProviderNativePresentation(kind, compactText, data)` with safe kind
`openai.responses.reasoning-summary.v1`, version 1, from Contract's
`openAiReasoningSummaryPresentationKind` and
`openAiReasoningSummaryPresentationVersion` constants. This identity is distinct
from the raw item kind. Safe `data` contains only `summaryParts` and `truncated`.
Unknown kinds/versions, other native item types, malformed summaries, and empty
summaries produce `nativePresentation: null`. Input validation is bounded to 1,024
parts and 262,144 aggregate UTF-16 code units before expensive text processing;
oversized input also yields no presentation without changing replay. Within that
budget all parts are validated, including suffixes later discarded by display
bounds. No encrypted content is decoded or hidden chain of thought exposed.

Full display text retains at most 32,768 Unicode code points across 128 trimmed,
nonblank parts. `truncated` reports full-text loss, not merely compact shortening.
Compact text uses the first retained part and is capped at 160 code points,
including an ellipsis when compact or full text is truncated. These algorithms
belong here, not in Contract or app activation. Generic Chat escapes compact
display controls and reapplies its compact cap after escaping; the OpenAI frontend
separately escapes full display text.

`ModelProviderOutput.nativePresentation` is required but nullable. Semantic
optionality is represented by `null`, not by omitting the generated key; the
existing coherent-schema convention remains unchanged. Text/tool outputs and
native items without a supported safe summary carry null. The generic app adapter
maps the DTO to immutable orchestration `ModelNativePresentation` with the same
fields on optional `ModelNativeOutput.presentation`; it does not interpret OpenAI.

Raw `nativeMetadata` stays exact and is the only native replay source. Safe
presentation is never replayed, and no canonical history or persistence change is
introduced. The backend and full Run retain native/encrypted evidence independently
of presentation activation. Only the safe presentation data enters the
separate [OpenAI frontend EVC](../frontend/README.md). Raw native envelopes,
compatibility metadata, encrypted content, and execution/approval authority do
not cross that presentation bridge. The frontend depends on neither this backend
implementation nor model readiness. Generic Chat and Inspection never parse OpenAI.
Missing or failed rich presentation does not remove safe Chat activity.
Malformed/unsupported summary input yields no presentation, while factory/EVC
failures remain presentation-local. Neither changes Run settlement or replay
validity; backend request/replay errors retain their existing explicit failure
semantics.

## Validation Scope

The maintained pure-Dart targets are:

```sh
dart tools/adele.dart test --target openai_model_provider_backend
dart tools/adele.dart test --target openai_contract
```

Run these from the repository root. Contract tests cover stable identities, not
algorithms. Backend tests in `test/openai_native_presentation_test.dart` and
`test/openai_model_provider_backend_test.dart` cover raw classification,
projection, processing bounds, preservation, guarded summary request lowering in
both profiles, unchanged requests for unlisted models,
ordered native/encrypted replay, safe projection, malformed/unsupported/empty
summaries, and compact/full display bounds. The separate app
`test/core/normal_chatgpt_run_integration_test.dart` uses real host/Git/OpenAI
artifacts and prepared frontends against local fake Responses for mixed
reasoning/tool approvals and a separate reasoning-only final response.

Backend affinity tests use local fake HTTP/OAuth endpoints to check first-token
retention, scope/model/endpoint/account isolation, auth recovery, cancellation and
failure settlement, redaction, unchanged bodies/replay, and nullable cache usage
across both profiles and semantic settlements. They do not assert real cache hits.

Local fake endpoints and temporary fake credentials require no live account or
API key. Existing opt-in live smokes remain separate and do not establish summary
support. Generated transport and app adapter tests cover safe-payload mapping,
the required nullable key, and raw-only replay. Hidden chain-of-thought and
encrypted reasoning are never user-presented. Reasoning deltas, compaction UI,
provider/model configuration UI, and broader Source/Diff/Console,
terminal/PTY/full-output presentation remain deferred.
