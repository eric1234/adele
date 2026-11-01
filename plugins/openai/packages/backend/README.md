# OpenAI Model Provider Backend

`openai_model_provider_backend` is the pure-Dart OpenAI Responses implementation
of public `adele_model_provider`. It runs as a prepared AOT backend through the
shared plugin host, not as linked Flutter application code. It supports the
public API-key route and a separately configured, explicitly experimental ChatGPT
subscription-backed classic Responses route. The latter is interoperability
support, not a stable third-party OpenAI integration contract.

Normal stock composition exposes configured API-key records alongside the separately
configured ChatGPT context. Normal Chat still selects ChatGPT explicitly; there is
no Session provider picker. The backend owns OpenAI protocol/authentication behavior,
while the host owns record credential authorization and OS storage.
See [app configuration](../../../../app/README.md#chatgpt-source-checkout-configuration)
and [ADR 0028](../../../../docs/adr/0028-experimental-chatgpt-openai-configured-instance.md)
for startup/auth ownership and limitations.

## Declarative Configuration

The plugin-root [`records.schema.json`](../../records.schema.json) is the
authoritative data-only declaration for `dev.adele.openai.api-key` in the
`providers` collection. It declares a required display name and optional API
endpoint, plus an `api-key` credential slot separate from ordinary fields. No
secret or credential reference is embedded in the schema. Stock preparation copies
the authored bytes into the installation and references them through the optional
installation-level `recordsSchema`, independently of backend/frontend activation.
The catalog can discover this metadata without starting the backend or loading
credentials.

Stock preparation separately opts this backend into `dev.adele.openai.api-key`
startup metadata and only its `api-key` credential slot. The generic
[host-authorized credential client](../../../../packages/plugin_backend_support/README.md#credential-reads)
is available to an eligible generation; the backend uses it lazily for configured
provider invocations, never to preload secrets at startup.

The schema itself neither registers a provider nor selects a model. The backend
interprets captured nonsecret records into the routes below. Preparation belongs to the
[toolchain guide](../../../../docs/development/toolchain.md#local-plugin-compilation).
Nonsecret reference persistence and protected local credential bindings belong to
the [host association lifecycle](../../../../docs/architecture/profiles-and-configuration.md#record-association-lifecycle),
not this backend. No record files, credential references, protected envelopes, TOML
API or native keyring access are exposed to the AOT plugin.

## Configured API-Key Instances

[`OpenAiApiKeyConfiguration.fromRecords`](lib/src/openai_configured_provider.dart)
interprets only `providers` records of type `dev.adele.openai.api-key`. It retains
each stable record ID and configured display name. Display names must be nonblank
and contain no ASCII control characters;
unknown fields and invalid ordinary values reject that instance rather than repair
it. An absent `endpoint` uses `https://api.openai.com/v1/responses`. An explicit
endpoint must be an absolute HTTP(S) URI with a valid nonempty host, no user
information or fragment, and HTTP only for loopback destinations. An invalid supplied
endpoint never becomes the default. Rejection leaves healthy siblings and the
independent ChatGPT route eligible; rejected records are not advertised.
The entrypoint reports only the validated record ID and fixed rejection code
(`openai_record_invalid_values` or `openai_record_invalid_configuration`), never the
supplied endpoint, ordinary values or raw exception.

The plugin owns this deterministic identity mapping, independent of display name,
endpoint, key, credential reference and backend generation:

| Record ID | Stable `ProviderId` | Live Configuration Context |
| --- | --- | --- |
| `work-openai` | `dev.adele.openai.api-key.work-openai` | `api-key-record:work-openai` |
| `personal-openai` | `dev.adele.openai.api-key.personal-openai` | `api-key-record:personal-openai` |

Provider IDs and context strings use the existing public validators. Records retain
stable record-ID advertisement order and separate dispatchers for
`modelProviderServiceId` within one
`AdeleConfigurationContextRouter`, all in **one OpenAI AOT backend generation**.
The exact capability binding selects the context; generated model request payloads,
model IDs and provider options cannot select another account. Unknown contexts and
services fail closed. Duplicate record identities fail structural decoding rather
than selecting a winner. An empty record list creates no configured providers.

Advertisement establishes a valid configured route, not local credential presence
or successful OpenAI authentication. `OpenAiConfiguredModelProvider` creates a
single-subscription lazy stream. On every subscription it uses `AdeleCredentialClient`
through the generation's `AdeleHostRequestMultiplexer` and infrastructure grant to
request exactly `collection: providers`, `recordType: dev.adele.openai.api-key`, that
configuration's `recordId`, and `slot: api-key`. No uninvoked sibling is read and no
HTTP begins until the selected credential read succeeds. A logical provider does not
retain a decrypted key for reuse by later invocations.

Each invocation creates and owns a temporary `OpenAiModelProvider` and its HTTP
client, reusing the existing Responses implementation and generated dispatcher.
Output, observations and terminal events pass through that stream; pause/resume and
active-request cancellation propagate to it. Cancellation while a credential read
waits fences provider construction and late HTTP, without claiming to cancel the OS
prompt. Completion/cancellation releases the temporary provider. The entrypoint
handles reverse responses independently of forward dispatch, and closes its host
multiplexer before draining the router on shutdown. Configured requests do not
follow redirects to another endpoint or downgrade to HTTP.

The [configuration lifecycle](../../../../docs/architecture/profiles-and-configuration.md#configured-openai-providers)
owns restart semantics: record creation/deletion, display name, endpoint, identity/type,
credential association, replacement and Forget require a new backend generation.
Restart ADELE to apply them. There is no live refresh or automatic restart; a later
credential read can fail stale instead of retargeting the old route. Already-started
HTTP may continue with a delivered key. Forget does not retract network authorization
already in flight, and dropping Dart strings is not a zeroization guarantee.

The legacy explicit development `OPENAI_API_KEY` / `ADELE_OPENAI_ENDPOINT` mode keeps
`dev.adele.openai.api-key` in the default context. Experimental ChatGPT keeps
`dev.adele.openai.chatgpt-experimental` in `chatgpt-experimental`, with its independent
credential-file/OAuth flow. Neither is a fallback for configured records, and records
cannot override their credentials or routes. `startupArgumentsOnly` continues to
suppress inherited environment configuration; `--chatgpt-only` constrains that legacy
startup path, not independently delivered records. The app's explicit ChatGPT
selection and the registry's provisional default rank/ID ordering are unchanged.

## Credential Failures

Host credential failures become one safe failed model-provider terminal before HTTP,
with fixed messages and no references, envelopes, native errors or secrets. Provider
codes use the `openai_credential_` prefix:

| Host Outcome | Provider Code Suffix | Required Recovery / Meaning |
| --- | --- | --- |
| `notAuthorized` | `not_authorized` | The exact record/slot access is not authorized. |
| `notConfigured` | `not_configured` | Attach the record's API key and restart. |
| `missingLocally` | `missing_locally` | The referenced key is absent on this machine; recover through Settings. |
| `storageUnavailable` | `storage_unavailable` | OS storage or strict authority validation is unavailable. |
| `invalidCredentialBinding` | `invalid_binding` | The stored protected binding is invalid; no repair is attempted. |
| `reconciliationRequired` | `reconciliation_required` | Explicit Settings reconciliation is required. |
| `staleConfiguration` | `stale_configuration` | Restart ADELE to capture current record/credential state. |
| `generationUnavailable` | `generation_unavailable` | The generation cannot use its credential grant. |
| `credentialAccessFailed` | `access_failed` | Credential access could not be completed. |

`notAuthorized` maps to the existing `ModelProviderFailureKind.permission`; the
other credential outcomes map to `unavailable`, not `authentication`. These are
pre-HTTP failures, not remote OpenAI authentication responses. An incompatible
delivered API-key value also uses `unavailable`, with `openai_credential_invalid_api_key`;
unexpected wrapper failures use `openai_configured_invocation_failed` without raw
exception text. No failure automatically retries, reconciles storage, consults the
environment key or switches to another record/ChatGPT. Existing OpenAI HTTP failures
remain separate outcomes after a request actually reaches the endpoint.

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

## Response Metadata Compatibility

Both profiles explicitly accept `response.metadata` as nonterminal sideband, not
as model output, a tool proposal, or a replay item. Informational response fields,
reported-model/routing headers, account-verification recommendations
(`openai_verification_recommendation`), and opaque moderation/presentation data
(`openai_chatgpt_moderation_metadata`) are discarded without forwarding their
contents to model context, Run history, UI diagnostics, or logs. They do not change
authentication, the requested model, or affinity. Terminal metadata still comes
from the explicit terminal; completed output items remain authoritative.

This decision follows first-party Codex's
[Responses parser](https://github.com/openai/codex/blob/cfc11bfab31c6885ec8213ece435fc3347eda7a4/codex-rs/codex-api/src/sse/responses.rs)
and its consumers. Verification is advisory account-access guidance, not an
authorization grant; moderation metadata is presentation sideband, not a substitute
for refusal, failure, or incomplete settlement. SSE turn state comes from the HTTP
header, unlike Codex's WebSocket metadata-header capture.

Safety-buffering status is also nonauthoritative. An absent, null, or false
top-level `safety_buffering` marker is inactive and does not interrupt processing.
Active notifications are recognized as either a top-level `safety_buffering`
object on any supported event or a `response.metadata` event whose `metadata`
object has `type == 'safety_buffering'`. Both forms require `use_cases` and
`reasons` arrays containing only strings (including empty arrays), and accept an
absent, null, or string `retry_model`. Additional informational fields are allowed
but never interpreted or forwarded. The
[Codex structure](https://github.com/openai/codex/blob/cfc11bfab31c6885ec8213ece435fc3347eda7a4/codex-rs/codex-api/src/common.rs)
and parser separate these notifications from the underlying response event:
text deltas, completed items, and explicit terminals still process normally.

ADELE discards valid notification payloads without creating output, proposals,
replay items, or artificial terminals, and without changing affinity, account
routing, authentication, or model selection. Codex uses them for waiting-status UI
and optionally confirmed retry on another model, not client-side output/tool
buffering. ADELE currently offers neither a dedicated waiting-status interface nor
optional model-retry controls, and never automatically retries or switches models
because of this metadata.

Malformed active payloads fail with fixed `invalid_safety_metadata` diagnostics.
Unlike Codex's permissive parsing, ADELE validates both locations independently:
an inactive or valid top-level marker cannot hide malformed typed safety metadata.
Other `metadata.type` variants are rejected as `unsupported_response_metadata`;
non-null, non-object metadata is rejected as `invalid_response_metadata`.
Diagnostics never include notification payload values. Untyped informational keys
are not interpreted; this is not a guarantee of support for future metadata
directives or other unknown events.

The existing strict authoritative-event/item validation, hosted-tool rejection,
streaming observations, explicit terminals, EOF-before-terminal failure, and
cancellation/retirement paths remain in place. No retry, model switch, desktop
error-presentation change, or provider-neutral contract change is introduced.

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
algorithms. `test/openai_configured_provider_test.dart` owns record interpretation,
endpoint validation, safe credential failures and per-invocation resource lifecycle.
Configured-record startup and real AOT routing belong to
`test/openai_record_startup_test.dart` and
`test/openai_configuration_context_integration_test.dart`. The app's
`test/core/openai_record_startup_integration_test.dart` additionally uses maintained
stock metadata, real TOML records and protected associations through host credential
authorization, with deterministic storage and loopback HTTP. See
[configured-provider checks](../../../../docs/development/testing.md#configured-openai-provider-checks)
for ownership, lifecycle/failure coverage and commands; these are not live OpenAI or
real Secret Service tests.

Backend tests in `test/openai_native_presentation_test.dart` and
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
Metadata fixtures cover both profiles before/between/after output, inactive and
valid active safety-buffering forms, explicit terminals and premature EOF,
malformed safety and unknown typed payloads, and unchanged strict output validation
and replay. The normal Chat AOT fixture also includes safety-buffering notifications
without changing its expected history, tool approvals, or HTTP affinity.

Local fake endpoints and temporary fake credentials require no live account or
API key. Existing opt-in live smokes remain separate and do not establish summary
support. Generated transport and app adapter tests cover safe-payload mapping,
the required nullable key, and raw-only replay. Hidden chain-of-thought and
encrypted reasoning are never user-presented. Reasoning deltas, compaction UI,
Session provider/model selection UI, and broader Source/Diff/Console,
terminal/PTY/full-output presentation remain deferred.
