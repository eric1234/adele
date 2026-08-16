# ADR 0026: OpenAI API-key Responses provider

## Status

Accepted for Phase IV-B4

## Context

ADRs 0024 and 0025 established a provider-neutral streaming model capability
and ordered provider-native items. ADELE still needed a real provider to prove
those semantics against an external protocol while retaining ADELE authority
over canonical history, approval, tool execution, and continuation.

OpenAI's public Responses API supports bearer API-key authentication, HTTP/SSE
streaming, ordinary function tools, explicit semantic terminals, and stateless
ordered replay. Current public documentation also supports encrypted reasoning
items for `store:false` replay.

## Decision

The `dev.adele.openai` plugin is ADELE's first real ModelProvider
implementation. Phase IV-B4 exposes one development API-key configured
instance identified as `dev.adele.openai.api-key` and implements the existing
`dev.adele.model.provider` capability without changing its contract.

The concrete `openai_model_provider_backend` package uses `dart:io`
`HttpClient` directly to POST `/v1/responses` with `stream:true`, `store:false`,
and bearer authentication. It incrementally decodes SSE records and maps live
text deltas, authoritative completed items, usage, failures, and explicit
Responses terminals into ADELE events. EOF is never completion. Consumer
cancellation aborts invocation-owned request/response consumption; no terminal
is manufactured after cancellation.

ADELE canonical ordered replay remains authoritative. The provider lowers user
and assistant messages, ordinary function calls, function outputs, and tools.
Independent reasoning or compaction items use the private versioned
`openai.responses.item.v1` native envelope at their exact ordered positions.
Semantic message/function-call metadata retains only OpenAI attributes needed
for replay and cannot override common semantic fields.

The Responses codec and transport remain private to the OpenAI plugin. No
generic OpenAI-compatible provider, public Responses package, generalized
routing layer, or provider SDK is introduced. Unsupported authoritative hosted
tool output fails explicitly rather than bypassing ADELE tool authority.

HTTP/SSE is the initial transport. Responses WebSocket mode,
`previous_response_id`, Conversations, invocation-native continuation reuse,
and hidden whole-invocation retries are not required for the first correctness
proof. The provider performs no automatic retries.

The backend entrypoint reads `OPENAI_API_KEY` from its inherited environment as
a temporary development bootstrap seam. Deterministic tests also use the
inherited `ADELE_OPENAI_ENDPOINT` seam to target a local fake server. Production
code does not read `.env`; credentials never enter model requests, provider
options, native envelopes, diagnostics, or semantic state.

ChatGPT/Codex OAuth, account state, persistence, catalog behavior, and
`chatgpt.com/backend-api/codex` routing remain a later configured-instance slice
over this same OpenAI plugin implementation.

## Consequences

- ADELE now has deterministic evidence for a real Responses JSON/SSE,
  model/tool/model vertical through the generated AOT runtime.
- OpenAI types remain outside `agent_kernel` and the common capability.
- Native-only reasoning state preserves exact cardinality and order.
- API-key access is an initial development route, not a claim about final UX.
- A second concrete provider must pressure-test any future Responses code
  extraction.
