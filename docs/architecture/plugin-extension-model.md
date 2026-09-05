# Plugin Extension Model

## Status

**Accepted architectural direction; implementation is partial and most public extension APIs remain unimplemented.**

This document defines ADELE's long-term composition model for plugins and plugin-defined extension ecosystems. It records architectural boundaries rather than a frozen Dart API. Names such as `ExtensionPoint`, `Extension`, and the example interfaces below remain provisional until concrete implementation requires them.

The maintained repository already proves source plugins, interpreted frontend execution, AOT backend execution, generated typed transport, active capability registration/resolution, configured provider contexts, provider-neutral agent execution, provisional Project/Task/Environment lifecycle and Session authority, and the first generic registration/liveness slice. That slice supports typed extension points, activation-scoped registrations, exact-generation bindings, and a public contextual model-tool contribution point. The statically composed stock Filesystem Tools source module is its first consumer and owns `read_file` and `apply_patch`; this is not production plugin discovery. ADELE does **not** yet implement the broader recursive extension system described here, production plugin-facing UI composition, generic commands/keybindings, production product persistence, the orchestration-strategy registry/public execution facade, or most of the expected stock plugin topology.

The generic registry deliberately defines only registration, discovery, retirement, and binding liveness. Model-tool composition defines its own zero-or-many composition and alias-collision semantics. Priority, applicability languages, ordering, and universal failure behavior remain deferred. `EnvironmentRuntime` remains a provisional application/domain implementation rather than a template for extension runtimes.

See also:

- [`contracts-and-capabilities.md`](contracts-and-capabilities.md) for implemented contract and capability boundaries;
- [`profiles-and-configuration.md`](profiles-and-configuration.md) for contextual activation, configuration, and provider preference;
- [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md) for Run/model/tool execution semantics;
- [`stock-plugin-direction.md`](stock-plugin-direction.md) for the deliberately speculative default plugin composition;
- [`../mockups/README.md`](../mockups/README.md) for the expected stock development UX.

---

# 1. Architectural thesis

ADELE is not intended to be a fixed application with a narrow plugin API around the edges. Its intended shape is recursively extensible:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

Core owns durable host and domain invariants. Plugins provide much of the concrete product behavior and may define more specific concepts that remain extensible by other plugins.

For example:

```text
ADELE core Session lifecycle
    -> orchestration-strategy extension point
        -> Chat strategy
        -> Goal strategy
        -> other strategies

ADELE Main Content
    -> Agent Interaction plugin
        -> selects/hosts registered strategy presentation

Chat strategy
    -> prompt-accessory extension point
        -> Agent control UI
        -> Model control UI
        -> other Chat-specific extensions
```

The orchestration-strategy extension point belongs to core because Session creation/restoration must authoritatively validate and retain the bound strategy even when no optional Agent Interaction presentation is active. The Agent Interaction plugin can present strategy selection and common hosting UI without owning the strategy registry itself.

ADELE core does not need to understand a Chat prompt accessory merely because a plugin defines that concept.

The primary rule is:

> Keep durable host/domain invariants in core while allowing concrete behavior, presentation, policy input, provider choice, workflow, tooling, and progressively more specific product concepts to be supplied and composed by plugins.

---

# 2. Core and plugin ownership

Core should remain comparatively small, but some concepts require stable ownership so unrelated plugins can cooperate.

Core directionally owns:

- plugin installation/build/runtime lifecycle;
- frontend/backend hosting and generated transport infrastructure;
- activation contexts and generation safety;
- typed extension registration/discovery infrastructure;
- contextual default-provider resolution where appropriate;
- profiles and general configuration infrastructure;
- host persistence facilities;
- Project, Task, Session, Run, and Environment identities/lifecycle;
- the minimal orchestration-strategy registration/discovery/binding contract required by Session lifecycle;
- provider-neutral agent execution mechanics in the internal `agent_kernel` plus a narrow public plugin-facing execution boundary for orchestration plugins;
- final security/policy/approval arbitration;
- the host workbench shell;
- application Command registration, Command Palette, and keybinding resolution.

Plugins normally own provider-specific, workflow-specific, tool-specific, integration-specific, and specialized presentation behavior. Expected examples include model providers, Environment implementations, Git integration, editors, Diff/Review, terminals, agent orchestration strategy implementations, model tools, model/agent policy, accounting, TODO/progress, and context monitoring.

A strategy plugin must not import the internal `agent_kernel`. It consumes a public provider-neutral orchestration/execution API backed by core/kernel implementation. The exact public package/type surface remains deferred until a concrete strategy implementation requires it.

One plugin may register several independent extensions into different systems. Splitting those registrations into separate plugins should not fundamentally change the extension mechanisms involved.

---

# 3. Extension points are the general composition concept

An **Extension Point** is a typed place where active plugins may register participation. The owner may be core or another plugin.

One registered participant is called an **Extension** in this document. Final public terminology remains open.

Each Extension Point defines the semantics relevant to that interaction, potentially including:

```text
interface/data shape
zero/one/many registrations
context supplied to implementations
applicability rules
selection/defaulting
ordering/priority
composition/merge behavior
failure behavior
lifecycle/generation behavior
```

There is intentionally no universal merge algorithm or universal applicability language.

An extension normally registers generally. The specific Extension Point determines how applicability is evaluated. Depending on the contract, an implementation may answer `supports(...)`, return no contribution for an irrelevant operation, or always participate when that extension point is composed.

---

# 4. Capabilities are callable extension semantics

The existing Capability concept remains useful, but it is one semantic pattern within the broader extension model.

A Capability represents functionality that can be requested from compatible providers. Existing public semantics distinguish:

- **Action** — brokered one-shot request/response operation;
- **Service** — sustained typed functionality;
- **Event** — fact notification.

Actions and Services naturally act as callable extension points.

Examples of expected callable interfaces include:

```text
DisplaySourceFile
    Internal Source Editor
    External Editor

EnvironmentProvider
    Git Worktree
    Docker
    Remote VM
```

Callers must tolerate zero, one, or many providers. Zero providers is normally a valid composition state; the corresponding operation or affordance is simply unavailable.

---

# 5. Prefer interface discovery over runtime plugin dependencies

ADELE should avoid activation dependency chains where possible.

A Diff plugin should not require the Internal Source Editor plugin. It should understand a `DisplaySourceFile`-shaped interface and adapt to whichever providers are active:

```text
no provider
    file still displays in Diff, but source-display action is unavailable

Internal Source Editor
    click displays/focuses internally

Internal Source Editor + External Editor
    normal action uses the contextual default
    alternate action may expose both
```

Likewise, Chat remains a technically valid strategy even if the user disables every model tool. A strategy plugin may be active even when no presentation plugin currently exposes it to the user.

The stock installation should provide a useful default composition. ADELE should not silently activate arbitrary plugins to manufacture usefulness.

## 5.1 Shared API knowledge is not an activation dependency

Independently authored plugins still need a shared definition of the interface they both understand.

That shared API may be:

- a sufficiently general core/public ADELE interface; or
- a contract/API published by the plugin that defines a more specific ecosystem.

Depending on that API definition is acceptable. Depending on a particular implementation plugin being installed or active is usually not.

For example, a Chat strategy may publish `ChatPromptAccessory`. An Agent-control plugin can compile against that API and register an implementation. If Chat is inactive, the registration is simply unconsumed.

Likewise, a Chat strategy implementation can compile against ADELE's future public orchestration/execution API without depending on the internal `agent_kernel` package that implements core execution semantics.

This distinction enables recursive plugin-defined extension ecosystems without requiring a complex runtime activation dependency graph.

## 5.2 Core lifecycle invariants imply core-owned minimal extension contracts

A plugin may define an extension point for concepts that exist only within that plugin's ecosystem. Chat prompt accessories are a good example.

The ownership rule changes when core must authoritatively persist, restore, validate, or route a core-domain identity using that extension.

Session strategy binding is such a case:

```text
Session
    stores bound strategy identity
        -> core-owned orchestration-strategy registry validates/resolves it
            -> strategy implementation plugin
```

An optional Agent Interaction UI may consume that registry to offer strategy selection or host a strategy surface, but Session validity cannot depend on that UI plugin being active. Core therefore owns the minimal public registration/binding contract; strategy implementations remain plugins.

---

# 6. Composition is live; resolved operations remain stable

Extension discovery is not only startup-time discovery.

Future operations and visible affordances should generally react when compatible extensions appear or disappear. A Diff view can enable source links when an editor provider becomes active and disable them when it disappears.

In-flight work must not silently migrate:

```text
live composition
    current providers/contributors may change

resolved operation
    exact selected/materialized bindings remain stable
```

This preserves the existing generation-bound execution rule. A new provider generation can participate in a future materialization, but an already-resolved model/tool operation retains its original binding and fails explicitly if that binding becomes stale.

---

# 7. Host-owned contextual defaults

For interchangeable providers, the common ADELE convention is:

> ADELE owns contextual default-provider selection; consumers may expose explicit alternatives when useful.

Configuration/profile/project policy may influence the default. A provider cannot globally declare itself primary.

Examples:

```text
DisplaySourceFile
    default: Internal Source Editor
    alternate: VS Code

EnvironmentProvider
    default: Git Worktree
    alternate: Docker
```

The host may provide reusable UI for a primary default action plus alternatives. Plugins may still use bespoke UI when the experience benefits from it.

Provider default selection is distinct from extension ordering. An ordered list of UI fragments and a preferred implementation of a callable interface solve different problems.

---

# 8. Events are read-only fact notifications

Events remain a distinct semantic concept even if they share registration infrastructure with other extension mechanisms.

An Event communicates a fact that has occurred, for example:

```text
TaskCreated
SessionCreated
RunStarted
ModelInvocationSettled
ToolInvocationSettled
ChatTurnCompleted
ReviewCommentAdded
```

Core defines broadly useful domain events. Plugins may define their own events and other plugins may subscribe if they understand those APIs.

The important guarantee is:

> Event consumers cannot change whether the announced fact occurred.

Subscriber failures are normally isolated from the producer and do not retroactively fail the originating operation.

Events therefore resemble instrumentation rather than mutating lifecycle callbacks.

An Event does not imply a durable replay log. Historical access is a separate domain concern and may be provided by query/history Services. An Accounting plugin may combine historical inference queries with live usage events, or it may only know usage from the point it began observing if no durable history exists.

---

# 9. Structured operation composition

Some extensions need to influence an operation **before** it occurs. These should not receive arbitrary mutable host objects.

Avoid APIs conceptually equivalent to:

```text
beforeInference(request) {
    mutate anything
}
```

Instead, the owner defines structured buckets that plugins can populate. Inference preparation is the clearest example:

```text
inference intent/context

+ strategy/history material
+ context material
+ agent instructions/state
+ model/provider preferences and constraints
+ reasoning/provider-option preferences
+ tool availability/materialization
+ policy constraints
+ other typed buckets

        -> host-owned resolution/composition
        -> stable semantic inference snapshot
        -> provider invocation
```

Core defines broad provider-neutral inference buckets because it owns the invocation boundary. A plugin hosting a more specific ecosystem may define its own structured extension points.

The buckets must be extensible enough for future concepts without collapsing into unrestricted object mutation.

Conflict resolution is domain-specific. Restrictions may compose conservatively, preferences may use configured precedence/default rules, and context material may use ordered/provenance-preserving composition. There is no universal merge rule.

---

# 10. Priority and ordering

When an Extension Point needs ordering, numeric priority is preferred over direct `before X` / `after Y` references.

Relative ordering creates knowledge of another extension and can evolve into an implicit dependency graph. Numeric priority lets extensions express approximate placement independently. An owner may define priority bands such as early/normal/late when useful.

Equal priorities must have deterministic secondary ordering, such as stable extension identity.

Not every Extension Point needs ordering.

---

# 11. Failure semantics belong to the extension contract

There is no universal extension failure policy.

Examples:

- Event subscriber failure normally does not fail the producer.
- Decorative UI extension failure may omit that fragment while keeping the parent surface usable.
- Failure of the selected Environment provider means that Environment lifecycle operation failed.
- A mandatory security/policy participant failing may make it unsafe to continue.
- A nonessential inference-context extension may or may not be omittable depending on the contract.

Each Extension Point must define failure semantics appropriate to its role.

---

# 12. UI extension points are semantic, not positional

The host owns the current physical workbench geometry, but plugin-facing UI contracts should normally describe **meaning**, not today's coordinates.

Expected semantic surfaces include concepts such as:

```text
MainContentView
NavigationView
SessionStatusContribution
InspectionPresentation
StreamView / ConsolePresentation
ContextStatusContribution
Settings contributions
```

The current stock mockups render Main Content in the center, Session Status near the upper right, Inspection below it, and stream/console content at the bottom. Those placements are product/layout direction rather than API names.

A future layout may move those surfaces or allow user configuration without changing plugin interfaces.

Plugins can define further semantic regions inside their own UI. Chat can define prompt accessories, session-header additions, turn actions, or timeline decorations without ADELE core understanding those concepts.

## 12.1 Host-rendered and plugin-rendered UI

Host rendering is desirable for small structural pieces where it improves compiled performance, consistency, accessibility, and reuse. Examples include Command entries, compact status fragments, separators, provider-selection controls, and common settings editors.

Plugins may render bespoke UI when richer domain presentation is useful, including Chat, Diff, source editing, inspection bodies, plans/artifacts, and consoles.

---

# 13. Commands and keybindings are host infrastructure

ADELE core owns application Command infrastructure, including:

- stable Command identity and registration;
- applicability/enabled-state plumbing;
- Command Palette/search;
- keybinding registration and resolution;
- plugin-suggested/default keybindings;
- user/profile/project overrides where supported;
- dispatch from menus, buttons, keybindings, and other UI affordances.

Plugins provide Commands and suggested bindings. The host owns how they are discovered, presented, rebound, and invoked.

UI should normally invoke the same underlying Command/domain operation that could also be triggered from another surface. Rendering a button must not turn that widget into the definition of the domain behavior.

Application Commands are distinct from the model-callable Command Tool that executes external programs.

---

# 14. MVC-style separation of presentation and functionality

ADELE should preserve a model/view/controller-like separation:

> UI presents domain state and offers trigger points for functionality; it does not define that functionality merely because it exposes the control.

For example:

```text
Diff UI
    [Approve]
        -> review/SCM operation
            -> Git implementation stages the hunk
```

The same domain operation could later be triggered by a toolbar action, context menu, keybinding, Command Palette, model tool, or another plugin.

This keeps presentation replaceable and prevents UI widgets from becoming hidden cross-plugin APIs.

---

# 15. Plugin-owned state and persistence

ADELE should provide lifecycle-aware persistence facilities for plugin-owned state scoped to stable domain identities such as Project, Task, Session, or Environment where appropriate.

Plugins should not need to invent unrelated persistence systems merely to retain ordinary state.

This is a default facility, not an exclusivity rule. Some integrations intentionally use external systems whose persistence semantics are part of the feature:

```text
Chat strategy state
    likely ADELE-managed persistence

Session TODO/progress
    likely ADELE-managed persistence

Accounting aggregates
    likely ADELE-managed persistence

Git approved hunks
    Git index/staging is authoritative

Git worktree/branch
    Git/filesystem state is authoritative
    ADELE may persist associations/metadata
```

Persisted plugin state should normally survive plugin deactivation so reactivation can restore prior behavior.

---

# 16. Security authority remains host-owned

Plugins often understand an operation more deeply than core. They may validate arguments, interpret configuration, derive exact effect/target descriptions, or supply specialized policy input.

That does not grant authority.

The final allow/deny/ask decision remains host/core-owned. A Command Tool may understand whether the requested executable/subcommand is normally safe; core still owns authorization after combining all applicable policy.

Availability, visibility to an agent, policy, human approval, Environment isolation, and credential access remain separate questions.

---

# 17. Implementation guidance

This architecture is deliberately ahead of implementation.

Near-term work should **not** implement a universal extension framework merely because this document names one. Each new feature should introduce the smallest concrete typed boundary it needs while remaining compatible with these principles.

When deciding where a new interface belongs:

- put broadly reusable concepts in core/public APIs when unrelated consumers reasonably need them;
- if core must persist/restore/validate a core-domain binding through an extension, keep the minimal registration/binding contract core/public even when an optional plugin owns its UI;
- let a plugin define interfaces for concepts specific to the ecosystem it introduces;
- expose internal host/kernel behavior to plugins only through narrow public plugin-facing APIs rather than implementation-package dependencies;
- prefer interface discovery over implementation identity;
- allow zero/one/many implementations where the semantics permit it;
- keep operations stable once resolved;
- keep UI contracts semantic rather than tied to physical layout;
- make implementation/deferred status explicit in documentation.

The expected concrete application of these rules is maintained separately in [`stock-plugin-direction.md`](stock-plugin-direction.md).
