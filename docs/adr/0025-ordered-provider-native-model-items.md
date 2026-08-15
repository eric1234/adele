# ADR 0025: Ordered provider-native model items

## Status

Accepted for Phase IV-B3

## Context

ADR 0024 established optional provider-native metadata attached to semantic
message and tool-proposal items. That remains the correct representation for
opaque state intrinsically belonging to one semantic item.

Follow-up research against real Responses providers exposed a distinct case:
provider-native reasoning and compaction items can be independent ordered peers
of assistant text, tool proposals, and tool outcomes. Canonical replay must
preserve their cardinality and exact relative order. Attaching them to a
neighboring semantic item cannot represent consecutive native items, native
items without a semantic neighbor, or native items on either side of a tool
proposal without inventing provider-specific ownership.

## Decision

The experimental `dev.adele.model.provider` capability remains at major 1 and
adds one native-only ordered input/output variant in place. The Dart enum value
is named `nativeItem` because `native` is a reserved Dart word.

A native-only item carries an optional provider item ID and one required
existing native envelope containing kind, compatibility, and opaque structured
data. It carries no model-visible text, tool proposal, tool outcome, reasoning,
or compaction semantics. Constructor validation enforces that shape.

`agent_kernel` mirrors the contract with `SemanticNativeInput` and
`ModelNativeOutput`. Application composition maps the values without
interpreting them, and the development tool loop replays each authoritative
native output in the same ordered position before appending the correlated tool
outcome.

Canonical Session meaning remains provider-neutral. Native-only items are
compatibility-bound provider state used by the current model/tool/model replay;
they are not Session messages, observations, artifacts, or invocation-native
continuation state.

## Consequences

- Independent and consecutive provider-native items retain their cardinality
  and order through generated transport and canonical semantic replay.
- Metadata attached to a semantic item remains valid for state intrinsically
  belonging to that item.
- No provider-specific reasoning or compaction model and no raw-provider-event
  abstraction is introduced.
- Automatic invocation-native continuation reuse and native-state persistence
  remain deferred.
