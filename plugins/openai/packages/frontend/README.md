# OpenAI Activity Frontend

`openai_frontend` owns interpreted, read-only Inspection of provider-supplied
OpenAI reasoning summaries. Its `lib/openai_frontend.dart` entrypoint is
`buildOpenAiReasoningInspection`. It depends on Flutter and public `adele_ui`,
not the OpenAI backend, app, kernel, or headless Chat implementation. Normal app
composition loads prepared EVC rather than importing this widget as a native view.

## Safe Presentation Boundary

OpenAI follows the canonical Contract/Backend/Frontend split. Pure-Dart
[`openai_contract`](../contract/README.md) owns identities and payload schema only,
with no algorithms. Raw identity remains `openai.responses.item.v1`, version 1;
this frontend is registered for safe presentation kind
`openai.responses.reasoning-summary.v1`, version 1. The backend owns raw Responses
classification and projection of supported nonblank `summary_text` parts.
Unsupported kinds/versions, compaction or other item types, malformed summaries,
and empty summaries produce no safe presentation, without affecting raw replay.

The projection's compact heading is capped at 160 Unicode code points, including
an ellipsis when truncated. Full display text retains at most 32,768 code points
across 128 trimmed, nonblank parts; `truncated` reports loss from that full display
bound, not merely shortening the compact heading. Before trimming or Unicode
iteration, the backend declines input above 1,024 parts or 262,144 aggregate
UTF-16 code units. Within that input budget it validates even discarded suffix
parts, so truncation cannot hide malformed summary structure. These limits apply
only to presentation, never native replay.

Backend emits generated `ModelProviderNativePresentation(kind, compactText, data)`
through required nullable `ModelProviderOutput.nativePresentation`. Null denotes
semantic absence, but generated keys remain required. The generic app adapter maps
the same fields to immutable orchestration `ModelNativePresentation` on optional
`ModelNativeOutput.presentation`. No UI projection DTO or projector callback is
involved. Generic Chat applies display-control escaping to compact text and
reapplies its 160-code-point cap after escaping, independently of OpenAI activation.
The full safe payload is escaped separately by this interpreted Inspection view.
Only this map crosses the native-activity EVC bridge:

```text
{
  'summaryParts': List<String>,
  'truncated': bool,
}
```

The EVC does not receive the raw native envelope, compatibility metadata,
encrypted content, native item IDs, Run/kernel/controller objects, or execution
and approval authority. Raw `nativeMetadata` remains exact and the only native
replay source; safe presentation is never replayed. The summary is provider-supplied
visible text, not hidden chain-of-thought disclosure or an attempt to decode
encrypted reasoning.

`buildOpenAiReasoningInspection` reads the map through
`readModelNativeActivityData`, validates its shape before showing any parts, and
renders a `Reasoning summary` heading, ordered plain-text parts, and an explicit
truncation indicator when needed. Its defensive UTF-16 ceiling accommodates the
backend's Unicode code-point bound. `inspectionDisplayText` escapes unsafe
display characters without changing replay data. The card has no tool controls,
approval buttons, model calls, or continuation actions.

## Composition And Lifetime

`app/lib/plugins/stock_openai_activity_frontend.dart` registers
`ModelNativeActivityPresentationContribution(presentationKind, createInspection)`
at public `modelNativeActivityPresentationContributions`. The factory has type
`Widget Function(ModelNativePresentation)` and hosts this EVC through existing
`PreparedFrontend`. Stock activation imports Contract identity, loads the prepared
artifact, registers the factory, and retires its registration/resources only. It
owns no projection, raw interpretation, or display-safety algorithms and is
explicitly provisional until discovery/profiles replace hard-coded selection.
Generic Chat and Inspection never parse OpenAI fields.

`ModelNativeActivityPresentationResolver` matches exact safe presentation kind.
Zero matches make rich Inspection unavailable while safe activity still exists,
one supplies a retained binding, and many are explicitly ambiguous without priority.
The OpenAI presentation activates independently of model backend readiness,
credentials, Chat, and tool frontend support. Missing/corrupt EVC, malformed data,
and bounded factory/interpreted failures do not fail the Run or trigger
source compilation or a native card fallback. Exact-generation retirement removes
the old view and invalidates its resources; replacement requires fresh resolution,
never stale-resource retargeting.

Chat creates one group for a successfully completed invocation with tools or
native `output.presentation != null`, independently of rich frontend activation.
No Chat negative projection cache or registry-change retry is needed. The heading
prefers tool-batch narration only when tools are present, then safe compact text,
then tool count. Reasoning-only activity appears before canonical
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
model options. The `app/tool` compile harness is checkout tooling standing in for
future installation/update preparation, not runtime activation. See
[app frontend preparation](../../../../app/README.md#prepared-chat-frontend)
for all four artifacts, the selected Flutter/eval pin, independent activation,
and source-checkout path limitations. Installation/discovery and portable
packaging remain deferred.

## Validation Scope

The package is a Flutter workspace analysis target. Pure-Dart classification,
projection, bounds, and native-preservation tests belong to Backend; prepared-EVC
and product tests belong to the app. The regression boundary includes real prepared
artifacts with a local fake Responses endpoint, mixed reasoning/tool activity across approvals,
safe-map-only display, exact native/encrypted replay, a separate reasoning-only
final response, generation retirement/replacement, and bounded failure paths.
Chat and adapter tests separately cover safe activity without this frontend,
generic DTO mapping, and raw-only replay.
This deterministic scope does not establish live-provider summary support.

Hidden chain-of-thought and encrypted reasoning are never user-presented.
Reasoning deltas, compaction/configuration UI, nested
inspection, Source/Diff/Console navigation, terminal/PTY/full-output views, and
activity persistence remain deferred. Summary request support is provider-local
and narrowly guarded, as documented in the [backend README](../backend/README.md).
