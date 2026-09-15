# OpenAI Activity Frontend

`openai_frontend` owns interpreted, read-only Inspection of provider-supplied
OpenAI reasoning summaries. Its `lib/openai_frontend.dart` entrypoint is
`buildOpenAiReasoningInspection`. It depends on Flutter and public `adele_ui`,
not the OpenAI backend, app, kernel, or headless Chat implementation. Normal app
composition loads prepared EVC rather than importing this widget as a native view.

## Projection Boundary

The sibling pure-Dart `openai_native_activity` package owns
`openAiResponsesItemKind = 'openai.responses.item.v1'`, version 1, and
`projectOpenAiReasoningSummary(ModelNativeEnvelope)`. Its projector recognizes
supported reasoning items and nonblank `summary_text` parts, independently of
Flutter or backend activation. Unsupported kinds/versions, compaction or other
item types, malformed summaries, and empty summaries return no projection.

The projection's compact heading is capped at 160 Unicode code points, including
an ellipsis when truncated. Full display text retains at most 32,768 code points
across 128 trimmed, nonblank parts; `truncated` reports loss from that full display
bound, not merely shortening the compact heading. Before trimming or Unicode
iteration, the projector declines input above 1,024 parts or 262,144 aggregate
UTF-16 code units. Within that input budget it validates even discarded suffix
parts, so truncation cannot hide malformed summary structure. These limits apply
only to presentation, never native replay.

Stock composition wraps the result in public
`ModelNativeActivityProjection(compactText, data)` with recursively immutable safe
data. It applies the existing display-control escaping to compact Chat text and
reapplies its 160-code-point cap after escaping. The full safe payload is unchanged
and is escaped separately by the interpreted Inspection view. Only this map
crosses the native-activity EVC bridge:

```text
{
  'summaryParts': List<String>,
  'truncated': bool,
}
```

The EVC does not receive the raw native envelope, compatibility metadata,
encrypted content, native item IDs, Run/kernel/controller objects, or execution
and approval authority. The backend and full Run retain exact native/encrypted
replay untouched. The summary is provider-supplied visible text, not hidden
chain-of-thought disclosure or an attempt to decode encrypted reasoning.

`buildOpenAiReasoningInspection` reads the map through
`readModelNativeActivityData`, validates its shape before showing any parts, and
renders a `Reasoning summary` heading, ordered plain-text parts, and an explicit
truncation indicator when needed. Its defensive UTF-16 ceiling accommodates the
projector's Unicode code-point bound. `inspectionDisplayText` escapes unsafe
display characters without changing replay data. The card has no tool controls,
approval buttons, model calls, or continuation actions.

## Composition And Lifetime

`app/lib/plugins/stock_openai_activity_frontend.dart` registers
`ModelNativeActivityPresentationContribution(nativeKind, project,
createInspection)` at public `modelNativeActivityPresentationContributions`.
The `project(ModelNativeOutput)` callback uses the owning pure-Dart projector;
`createInspection(projection)` hosts this EVC through existing `PreparedFrontend`.
Generic Chat and Inspection never parse OpenAI fields.

`ModelNativeActivityPresentationResolver` matches exact native kind. Zero matches
leave the item opaque and omitted, one matching projector may decline, and many
matches are explicitly ambiguous without priority or trying projectors in order.
The OpenAI presentation activates independently of model backend readiness,
credentials, Chat, and tool frontend support. Missing/corrupt EVC, malformed data,
and bounded projector/factory/interpreted failures do not fail the Run or trigger
source compilation or a native card fallback. Exact-generation retirement removes
the old view and invalidates its resources; replacement requires fresh resolution,
never stale-resource retargeting.

Chat creates one group for a successfully completed invocation with tools or
presentable native activity. The heading prefers tool-batch narration, then native
compact text, then tool count. Reasoning-only activity appears before canonical
final assistant text. Inspection interleaves tools and native activity by exact
`output.sequence`. Groups are retained for the controller lifetime, including
follow-up prompts, not persisted into canonical Chat history.

## Prepared Artifact

The Linux launcher prepares `openai.evc` as the fourth stock frontend artifact
alongside Chat, Filesystem Tools, and Command Tools. It passes the absolute path
as compile-time deployment define `ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT`.
The build-time entrypoint is `app/tool/compile_openai_activity_frontend.dart`.
From `app/`, with an existing output parent directory:

```sh
ADELE_REPOSITORY_ROOT="$(git rev-parse --show-toplevel)" \
ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT="/absolute/path/to/openai.evc" \
flutter test --no-pub --concurrency 1 tool/compile_openai_activity_frontend.dart
```

The two environment variables are compiler inputs, not runtime configuration or
model options. See [app frontend preparation](../../../../app/README.md#prepared-chat-frontend)
for all four artifacts, the selected Flutter/eval pin, independent activation,
and source-checkout path limitations. Installation/discovery and portable
packaging remain deferred.

## Validation Scope

The package is a Flutter workspace analysis target. Pure-Dart projection tests
belong to `openai_native_activity`; prepared-EVC and product tests belong to the
app. E3's maintained validation boundary includes real prepared artifacts with a
local fake Responses endpoint, mixed reasoning/tool activity across approvals,
safe-map-only display, exact native/encrypted replay, a separate reasoning-only
final response, generation retirement/replacement, and bounded failure paths.
This deterministic scope does not establish live-provider summary support.

Hidden chain-of-thought and encrypted reasoning are never user-presented.
Reasoning deltas, compaction/configuration UI, nested
inspection, Source/Diff/Console navigation, terminal/PTY/full-output views, and
activity persistence remain deferred. Summary request support is provider-local
and narrowly guarded, as documented in the [backend README](../backend/README.md).
