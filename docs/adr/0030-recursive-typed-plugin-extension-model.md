# ADR 0030: Recursive typed plugin extension model

## Status

Accepted as architectural direction; general implementation deferred

## Context

ADELE's implemented capability registry already proves one-to-many runtime provider discovery for typed callable functionality, but the long-term product needs broader composition. Plugins need to contribute UI, commands, settings, tools, inference material, policy input, and other typed behavior. Plugins also need to define more-specific extension ecosystems that other plugins can participate in without requiring ADELE core to understand every concept.

A runtime dependency graph in which enabling one plugin automatically enables specific complementary implementations would make composition brittle. For example, a Diff viewer should be able to display files even when no editor provider is active, then gain file-display affordances when a compatible editor appears. A Chat strategy should remain a valid registration even if no tools are installed or no active UI consumes it.

Likewise, arbitrary mutable callbacks such as `beforeInference(request)` would make ordering, conflicts, provenance, failure handling, and stable execution boundaries difficult to reason about.

## Decision

ADELE adopts a recursive typed extension model.

1. An **Extension Point** is the broad architectural concept: a typed place where active plugins may register participation. The owner may be core or another plugin.
2. A plugin may define public extension APIs for concepts it owns. Other plugins may depend on those API definitions without depending on a particular implementation plugin being active.
3. Runtime composition should prefer discovery of compatible interfaces over activation dependency chains. Zero, one, or many compatible registrations may be valid depending on the extension contract.
4. Existing Actions and Services are callable extension semantics. The implemented capability-provider model remains the basis for one-to-many callable provider resolution.
5. ADELE owns contextual default-provider selection where an extension point represents interchangeable providers. A provider cannot make itself globally primary. Callers may expose explicit alternatives.
6. Extension discovery is live for future composition. New or removed registrations may change future affordances/operations, but already-resolved operations retain exact generation-bound bindings and do not silently migrate.
7. **Events** remain read-only notifications of facts that occurred. Event consumers cannot change whether the event occurred, and subscriber failure normally does not retroactively fail the producer. Events do not imply durable replay/history.
8. Operation-modifying participation uses structured typed composition rather than arbitrary mutation of opaque host objects. Core inference preparation will use structured buckets whose conflict/merge rules are domain-specific.
9. Ordering, when required, should normally use numeric priority plus deterministic tie-breaking rather than direct `before X` / `after Y` references that couple extensions by identity.
10. Failure semantics belong to each extension contract. Decorative UI, selected providers, mandatory policy contributors, and Event subscribers need not share one failure rule.
11. Plugin-facing UI extension points should describe semantic roles rather than current physical placement. The host may change or make workbench placement configurable without changing the semantic extension identity.
12. ADELE core owns application Command registration, Command Palette/search, keybinding resolution, and user overrides. Plugins register Commands and suggested bindings; UI affordances should normally invoke the same domain/Command behavior rather than define UI-only functionality.
13. UI is presentation/controller over domain behavior. A plugin rendering an action does not become the semantic owner of the underlying operation merely because it displays the control.

The detailed direction is recorded in `docs/architecture/plugin-extension-model.md`.

## Implementation status

Only part of this model is currently implemented:

- generated typed contract transport is implemented for the maintained supported shapes;
- active one-to-many capability registration/resolution and exact generation bindings are implemented;
- model-tool materialization and provider-neutral agent execution semantics are implemented internally;
- profile-aware preference and generic extension-point registration are not implemented;
- plugin-defined extension APIs, production UI composition, Commands/keybindings, generic Event subscription, and structured multi-plugin inference composition remain future work.

This ADR accepts the architectural direction without claiming those mechanisms are proven.

## Consequences

- Plugins can cooperate through shared typed interfaces without creating activation chains to specific implementations.
- A plugin may expose several independent extension roles and may itself host further plugin-defined extension points.
- The stock installation can provide a coherent default experience while ADELE still permits technically valid but weak compositions.
- Capability routing remains a specialized callable part of a broader extension architecture rather than being stretched into a universal registry for UI, events, and composition.
- Future implementation should introduce the smallest extension mechanism required by each concrete vertical instead of building a speculative universal framework in advance.
- Existing ADR 0005 Action/Service/Event semantics and ADRs 0006/0021 multiple-provider capability resolution remain valid and are not superseded by this decision.
- ADR 0012 remains valid as a deferral of a **concrete plugin-facing UI API**; this ADR establishes UI composition direction without selecting that API.