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

## Replay And Presentation

The pure-Dart sibling `openai_native_activity` owns the shared constants
`openAiResponsesItemKind = 'openai.responses.item.v1'` and
`openAiResponsesItemVersion = 1`. This backend imports those constants rather than
duplicating the native-envelope identity. Provider-native reasoning and compaction
items remain opaque to common model/orchestration consumers. Supported native
items, including encrypted content, retain their exact data and order for replay;
presentation does not sanitize, truncate, replace, or otherwise rewrite them.

`projectOpenAiReasoningSummary(ModelNativeEnvelope)` in that sibling package is a
separate read-only display projection. It accepts the owned kind/version and
supported nonblank `summary_text` parts of reasoning items, returning bounded
compact text and a safe map containing only `summaryParts` and `truncated`.
Unknown kinds/versions, other native item types, malformed summaries, and empty
summaries decline presentation. Input validation is bounded to 1,024 parts and
262,144 aggregate UTF-16 code units before expensive text processing; oversized
input also declines presentation without changing replay. It does not decode
encrypted content or expose hidden chain of thought.

The backend and full Run retain native/encrypted evidence independently of whether
the presentation contribution is active. Only the safe projection map enters the
separate [OpenAI frontend EVC](../frontend/README.md). Raw native envelopes,
compatibility metadata, encrypted content, and execution/approval authority do
not cross that presentation bridge. The frontend depends on neither this backend
implementation nor model readiness. Generic Chat and Inspection never parse OpenAI.
Malformed/declined display data and projector/factory/EVC failures do not change
Run settlement or replay validity; backend request/replay errors retain their
existing explicit failure semantics.

## Validation Scope

The maintained pure-Dart targets are:

```sh
dart tools/adele.dart test --target openai_model_provider_backend
dart tools/adele.dart test --target openai_native_activity
```

Run these from the repository root. The E3 regression boundary covers guarded
summary request lowering in both profiles, unchanged requests for unlisted models,
ordered native/encrypted replay, safe projection, malformed/unsupported/empty
summaries, and compact/full display bounds. The separate app
`test/core/normal_chatgpt_run_integration_test.dart` uses real host/Git/OpenAI
artifacts and prepared frontends against local fake Responses for mixed
reasoning/tool approvals and a separate reasoning-only final response.

Local fake endpoints and temporary fake credentials require no live account or
API key. Existing opt-in live smokes remain separate and do not establish E3
summary support. Hidden chain-of-thought and encrypted reasoning are never
user-presented. Reasoning deltas, compaction UI,
provider/model configuration UI, and broader Source/Diff/Console,
terminal/PTY/full-output presentation remain deferred.
