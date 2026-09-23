# OpenAI Contract

`openai_contract` is the pure-Dart Contract component of
`plugins/openai/packages/{contract,backend,frontend}`. It owns shared identities
and payload schema only. It contains no raw-item parsing, reasoning classification,
projection, truncation, or display-escaping algorithms, and depends on neither
Backend, Frontend, Flutter, app, nor kernel.

## Identities And Schema

| Purpose | Kind | Version |
| --- | --- | --- |
| Raw Responses item, unchanged | `openai.responses.item.v1` | 1 |
| Safe reasoning-summary presentation | `openai.responses.reasoning-summary.v1` | 1 |

`lib/openai_contract.dart` exports the raw constants `openAiResponsesItemKind` and
`openAiResponsesItemVersion`, plus `openAiReasoningSummaryPresentationKind` and
`openAiReasoningSummaryPresentationVersion` for safe presentation. Raw envelope
compatibility and item data remain the backend's exact native replay representation.
The safe kind is a separate presentation identity, not a replacement raw kind or
a replay format.

Safe presentation `data` contains exactly:

```text
{
  'summaryParts': List<String>,
  'truncated': bool,
}
```

Parts are ordered, trimmed, nonblank provider-supplied summary text. `truncated`
reports loss from the full display bound, not merely compact-heading shortening.
The versioned presentation kind identifies this schema; no raw item, compatibility
map, native item ID, or encrypted content belongs in it.

## Ownership

[Backend](../backend/README.md) owns raw Responses classification, safe summary
projection, all processing bounds, and exact native preservation. It emits
generated `adele_model_provider.ModelProviderNativePresentation(kind, compactText,
data)` through required nullable `ModelProviderOutput.nativePresentation`. Null
means semantic absence; the generated key is still required. The generic app
adapter maps these fields to immutable orchestration `ModelNativePresentation`
on optional `ModelNativeOutput.presentation`, without OpenAI interpretation.

[Frontend](../frontend/README.md) renders only the safe payload and escapes full
display text. Generic Chat escapes compact display text and derives activity
presence from non-null presentation, independently of rich frontend activation.
Production `app/lib/**` imports no plugin packages, including OpenAI Contract.
Prepared presentation activation is generic and descriptor/catalog-driven through
[`ApplicationFrontendBootstrap`](../../../../app/lib/frontend/application_frontend_bootstrap.dart).
Build/preparation tooling supplies stock identities through
[`stock_frontend_descriptors.dart`](../../../../tools/stock_frontend_descriptors.dart);
that is not production application activation. Generic adapters and presentation
hosts carry public semantic presentation data without OpenAI interpretation.

Raw `nativeMetadata` remains exact and the only native replay source. Safe
presentation is never replayed, added to canonical Chat history, or persisted by
this boundary. Encrypted reasoning remains private replay data, not user-facing
content or hidden chain-of-thought disclosure.
