# Plugin Extension Model

## Status

**Accepted architectural direction; implementation is partial and most public extension APIs remain unimplemented.**

This document defines ADELE's long-term composition model for plugins and plugin-defined extension ecosystems. It records architectural boundaries rather than a frozen Dart API. Implemented APIs such as `ExtensionPoint` remain experimental; other example interfaces below remain directional until concrete implementation requires them.

The maintained repository includes source plugins, interpreted frontend execution, AOT backend execution, generated typed transport, active capability registration/resolution, configured provider contexts, provider-neutral agent execution, initial Project/Task/Environment lifecycle, canonical strategy-bound Session creation with separate Environment authority, and generic registration/liveness. The registry supports typed extension points, activation-scoped registrations, exact-generation bindings, public contextual model-tool contributions, executable orchestration-strategy contributions, instruction-only inference-context sources, and Project selector contributions. Stock Filesystem Tools, Search Tools, and Command Tools own `read_file`/`apply_patch`/`create_file`/`delete_file`, `search`, and `run_command`. Headless stock Chat uses public `adele_orchestration` and remains in process alongside Filesystem Tools, Command Tools, and Local Directory Project Selector: four static activations in shared `AdeleRuntime`. The root-level AGENTS.md source and Search run through prepared `agents_md_backend` and `search_tools_backend` packages, reusing their pure-Dart root semantics without production app imports/dependencies or static activation. Host-rendered Project opening is minimal, not a general UI API. ADELE does **not** yet implement the broader recursive extension system described here, general plugin-facing workbench composition, generic commands/keybindings, product/Chat persistence, broader inference material or other context sources, or most of the expected stock plugin topology.

The generic registry deliberately defines only registration, discovery, retirement, and binding liveness. Model-tool composition defines its own zero-or-many composition and alias-collision semantics. Strategy resolution requires exactly one current contribution for an explicit semantic ID, with unavailable/ambiguous errors rather than defaults or tie-breaking. Instruction-context composition defines its own zero-or-many capture, deterministic identity ordering, and required/optional source failure behavior; it has no numeric priority. Generic priority, applicability languages, and universal ordering/failure rules are not supplied by the registry. `EnvironmentRuntime` remains a provisional application/domain implementation rather than a template for extension runtimes.

Project selectors are independent actions: zero means unavailable, one or multiple
means one button per contribution in registry registration order. They have no
priorities, defaults, categories, or applicability rules. Cancellation is a
successful `null` result, distinct from selector or lifecycle failure.

Public Flutter `adele_ui` supplies typed Session, compact activity, tool Inspection,
and model-native activity presentation contributions on the same registry. Session and tool
presentation resolve exact strategy or Tool ID with explicit unavailable/ambiguous
states. Rich native Inspection resolves exact safe presentation kind: zero leaves
rich presentation unavailable without hiding safe activity, one supplies a retained
binding, and many are explicitly ambiguous. There is no priority-based selection
or substitution. Compact resolution uses factual common fallback
when unavailable or ambiguous. Stock Chat single activities and groups open
common host-owned retained Inspection cards with interpreted Apply Patch, Run
Command, and OpenAI provider-supplied reasoning-summary bodies.
This is a bounded presentation surface, not the general workbench extension
system below.

Normal Task/primary Environment creation uses existing capability routing and
product lifecycle, not a new extension point or Task Browser API. Synchronous,
provider-free `AdeleRuntime()` owns generic application-lifetime backend bootstrap
on the same capability and extension registries. Startup first discovers a deterministic prepared
installation snapshot, then independently attempts every valid backend through
one shared host. Zero backend components needs no process. Installed metadata
does not activate plugins or declare exposures; backend entrypoints advertise
capabilities and extensions on the existing ready handshake. Generic
`PluginBackendActivation.registerAdvertised` coherently registers/rolls back/retires
both through the existing registries and exact-generation liveness. There is no required Git or
additional-OpenAI tier: local failure retires only that attempt, while shared-host
failure remains global. Self-hosting uses the same registration path with its own
explicit artifact/host/profile topology, without requiring normal discovery. See
[`dependency-rules.md`](dependency-rules.md#application-backend-composition) for
ownership and replaceability. The frontend owner consumes that same catalog and
registers strict prepared presentation descriptors independently of backend
readiness. Profiles, enable/disable management, version solving, watching, hot
upgrade, and production packaging remain deferred.

Internal `RemoteExtensionAdapterRegistry` supplies host adapters for known public
points, not plugin contributions or a second public registry.
`PluginExtensionActivation` registers exact-generation proxy contributions in the
existing `ExtensionRegistry`; unsupported points and invalid point-specific
metadata fail the backend attempt. The app's remote inference-source and model-tool
adapters preserve each public point's composition semantics rather than defining a
universal callback/object transport framework. Section 9 summarizes this boundary;
[`contracts-and-capabilities.md`](contracts-and-capabilities.md#extension-advertisements)
specifies advertisements, metadata, scoped host calls, and protocol compatibility.
Reverse streaming and general symmetric RPC remain deferred.

See also:

- [ADR 0032: Remote backend extensions use operation-scoped host services](../adr/0032-remote-backend-extensions-use-operation-scoped-host-services.md) for remote hosting and authority ownership;
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

A strategy plugin must not import the internal `agent_kernel`. The public registration/binding and narrow provider-neutral execution facade are implemented in the existing `adele_orchestration` package. Minimal semantic DTOs are shared from that package and reused by the kernel, not duplicated. Kernel model ports/streams/collectors, tool catalogs, policy gates, `AgentRun`, and journal objects remain internal; the public facade is not a re-export of kernel mechanics.

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

The implemented stock Chat strategy compiles against public `adele_orchestration` without depending on the internal `agent_kernel` package that implements core execution semantics.

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

The implemented binding spine separates durable product identity from live
registration identity:

```text
adele_product: Session(id, taskId, strategyId)
    -> semantic OrchestrationStrategyId
        != registration ExtensionId
        != exact activation-generation ExtensionBinding
```

`Session` is a final immutable value. `OrchestrationStrategyId` lives in
`adele_product` so product values do not depend on orchestration. Public pure-Dart
`adele_orchestration` defines
`OrchestrationStrategyContribution(strategyId, materialize)` and
`orchestrationStrategyContributions`, an
`ExtensionPoint<OrchestrationStrategyContribution>` over the existing
`ExtensionRegistry`. `OrchestrationStrategyResolver.resolve(id)` is a thin lookup,
not a second registry or materialization cache. It returns a
`ResolvedOrchestrationStrategy` retaining the exact `ExtensionBinding`, or throws
`OrchestrationStrategyUnavailable` or `AmbiguousOrchestrationStrategy`. Multiple
current contributions with the same semantic ID are ambiguous even when
registered under different extension
IDs; neither registration order nor deterministic tie-breaking selects one.

The application lifecycle coordinator validates the current strategy and a
same-Task Environment, then atomically publishes the canonical Session and its
separate Environment authority. Later strategy resolution uses the stored
canonical ID. `createSessionOrchestrationRun` in the application resolves the
canonical Session and exact contribution once per Run, then invokes
materialization against `KernelOrchestrationHost`. The callback receives
`OrchestrationStrategyHostContext(session, host)` and returns
`OrchestrationExecution` with `start` and `resolveApproval` entry points.

`OrchestrationExecutionHost` supplies lifecycle operations and binding validation,
`invokeModel(StrategyInferenceMaterial)`, `processProposal` against an opaque
`StrategyToolSnapshot` plus `ProviderToolProposal`, and approval resolution to
semantic continuation. Strategies own sequencing, not policy authority, tool
executables, or stream/journal mechanics. The application wrapper
`SessionOrchestrationRun` retains the exact execution/binding and exposes internal
evidence only to application callers. Core model/tool/policy and Environment
selection are unchanged.

`invokeModel` returns a `StrategyModelTurn` with ordered `ModelOutputItem` values,
settlement/metadata or failure, and the opaque snapshot. The host accepts a
proposal only once from its exact completed turn. It applies only the current
host-supplied approval resolution to the retained invocation, so sequencing does
not grant a strategy permission to approve itself.

Stock `ChatStrategyPlugin.activate` registers Chat under semantic ID
`dev.adele.strategy.chat` and extension ID
`dev.adele.plugin.chat-strategy.orchestration`, distinct from plugin ID
`dev.adele.plugin.chat-strategy`. Chat owns retained in-memory Session state and
private loop sequencing; neither the canonical Session nor the registration API contains Chat
history. See ADR 0031 for the creation boundary and deferred lifecycle scope.

## 5.3 B1 Project selector boundary

Tiny pure-Dart `packages/core_extensions` (`adele_core_extensions`) imports only
`adele_plugin_api`. It owns core extension contracts with no natural existing
public domain package, not a catch-all for extension APIs. Existing registry,
product, orchestration/context, tool, Environment, and plugin-ecosystem ownership
remains as defined in [`dependency-rules.md`](dependency-rules.md).

Its `ProjectSelectorContribution` contains only `String displayName` and
`Future<Uri?> Function() selectProject`. `projectSelectorContributions` is an
`ExtensionPoint<ProjectSelectorContribution>` at `dev.adele.extension.project-selectors`.
A selector returns a source URI or `null` for cancellation, never a Project or
host lifecycle context. `adele_product` remains unchanged and independent.

The stock Local Directory Project Selector uses the existing in-process
`activate(ExtensionRegistry)` registration convention; see
[`stock-plugin-direction.md`](stock-plugin-direction.md#31-local-directory-project-selector)
for its native-picker and headless import boundaries.

`AdeleRuntime` owns this fourth static stock activation on its existing registry and
retires it with the others in reverse order. Reduced composition omits only
Command Tools. `AdeleApplication` discovers selectors in `build`, invokes the
chosen contribution, then calls `runtime.lifecycle.createProject` for a non-null
URI. Lifecycle publishes and returns the canonical Project; `_project` in app
State is window-local presentation, not `runtime.currentProject`. No selector
owns product creation, derived Project metadata, persistence, or deduplication.

## 5.4 Task and Environment boundary

Task presentation calls `runtime.lifecycle.createTask(projectId: ..., title: ...)`
without a provider ID. The existing capability registry resolves the
Environment provider; stock Git is supplied by composition, not selected by
presentation. Providers own source validation, including non-Git rejection, while
Project selection/opening remains independent of backend readiness or failure.

Only lifecycle success presents the canonical Task and primary Environment;
selection is window-local. Readiness comes from the live exact binding, not
interpretation of opaque `providerState`. Normal Chat presentation separately
creates its canonical Session through lifecycle, independent of model availability,
and selects exact model/tools/approval-gated policy for each fresh Run. Window-local
approval cards resolve existing Run interruptions; they are neither canonical Chat
entries nor a new extension point. This adds no Task Browser or public UI/Command
API.

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

The same distinction applies to strategy execution. Retiring a contribution
makes its retained binding fail with generic `StaleExtensionBinding`. Host
validation covers subsequent operations, approval resume, and asynchronous
settlement: an old active Run fails explicitly instead of continuing through a
replacement. A later Run in the same Session may freshly resolve B under its
stored semantic ID. Missing or ambiguous availability does not trigger fallback
or rewrite that ID. Permanent Session strategy identity does not pin one
activation generation for the Session's life, and retirement does not roll back
already-started effects.

Instruction-context sources have a capture lifetime, not an executable lifetime.
The composer validates the exact binding before snapshot and after copying,
freezing, and validating all returned material, then commits immutable data.
There is no replacement fallback within that capture. Once safely captured, the
data no longer depends on binding liveness: source retirement during provider
execution does not invalidate the request. The next inference discovers current
sources, including replacements. This does not change executable model/tool or
strategy binding rules.

For B1 selection, the app retains the exact selector binding and validates it
after asynchronous selection before Project creation. It ignores late results
after disposal/exit and never tries a replacement contribution. Buttons are
disabled while selection is pending; cancellation is a no-op, and selector or
lifecycle failure stays inline without changing the presented Project.

Task establishment settlement is unchanged: provider success publishes the
Task and finalized primary Environment and records the exact materialization.
Successful provider state is intentionally retained even if its generation
retires immediately afterward; unavailable live readiness does not roll back that
state or permit presentation to migrate the old binding. Window lifetime guards
reject late updates after disposal/exit. Application close drains pending Task
establishment before runtime cleanup, even on failure, without cancellation or
rollback.

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

This direction does not add default routing to B1 Project selectors. Each
contribution is an explicitly invoked action, not a default/alternate provider.

Task creation uses the existing callable capability default: descending
provider rank, then ascending provider identity. It does not introduce an
ambiguous-multiple-provider rule, applicability matching, or a profile preference
resolver. Session strategy resolution's exactly-one semantics are distinct.

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

The implemented instruction-only slice starts with `StrategyInferenceMaterial`:
instructions plus an immutable ordered list of `SemanticModelInputItem` values
from strategy-owned projection and Run-local replay. Public `adele_orchestration`
provides `InferenceContextComposer` over the same `ExtensionRegistry`, composing
`inferenceContextSources` at point ID
`dev.adele.extension.inference-context-sources`. Final
`InferenceContextSourceContribution` requires `failureMode` and a `snapshot`
callback. Its `InferenceContextSourceContext` exposes canonical `Session`, `runId`,
and typed `requireHostService<T>()`, not a mutable request or untyped service map.
The fresh app context explicitly allowlists only
`AuthorizedEnvironmentFileReadFacet`, resolving it through the existing
Session-authorized model-tool host path. All other service types are rejected,
including mutation/process facets and broader Environment authority/filesystem
interfaces. Context sources inspect state; mutation and process execution remain
with the existing tool/policy/execution mechanisms.

The app's `RemoteInferenceContextSourceAdapter` maps generated remote source
results to those same native contributions. It captures canonical
`InferenceContextSourceContext` and exposes only its authorized Environment read service
for that operation. Transported Session/Run identifiers and ready metadata do not
grant authority or select another Environment. Runtime/host code owns exact-generation
routing and revocable service allowlists; the backend uses public generated
contracts and `adele_plugin_backend_support`, without internal host imports.
Remote hosting does not change composer ordering, required/optional failure, or
immutable capture semantics, and is not a sandbox. Wire and lifetime details are
specified in [`contracts-and-capabilities.md`](contracts-and-capabilities.md#operation-scoped-host-calls).

`RemoteModelToolAdapter` similarly registers native `ModelToolContribution`
proxies using public generated `adele_model_tool/remote_model_tool.dart` transport.
The existing composer retains zero-or-many tool composition and Tool ID/alias
collision rules. Point metadata is exactly `hostServices: []` or
`hostServices: ['authorizedEnvironmentRead']`: dependency requests, not grants or
Profiles. When requested, materialization captures the host's Session-bound read
facet and exact remote/Environment generations. Fresh contexts cover
materialize/describe and the execute stream; validation receives no authority.
The read service exposes only
the already-bound identity plus file/directory reads, never authority selection,
mutation, or processes. Search's backend reuses its root implementation through this
adapter. Filesystem, Command, and Chat remain in process; this is not a general
remote-object or orchestration framework.

The sealed `InferenceContextMaterial` root currently supports only final
`InferenceInstructionMaterial(key, text, revision?)`: source-local nonblank string
keys stable across captures of the same logical material, nonblank exact-byte text,
and optional opaque string revisions. The immutable
`InferenceContextSnapshot` preserves unchanged semantic input, typed strategy/source
instruction groups, and source results. It always retains `StrategyInstructionGroup`,
even for empty instructions; only `renderInferenceInstructions` omits empty strategy
text. Ordering is defined in section 10 below.

Each genuinely new inference, including Chat continuation, discovers and captures
current sources. Snapshot callbacks return current material according to source-owned
freshness through rereads, watches, caches, or versions; there is no generic refresh
API. Required failure stops composition
before invocation identity, model-start evidence, or provider work. Optional
failure omits the entire source and retains original diagnostics, distinct from
successful empty output. Capture validates all material, including duplicate local
keys, before committing any of that source's data; section 6 distinguishes its
lifetime from executable bindings.

The host constructs internal `SemanticModelRequest(context, invocationId, tools)`.
At the current app `ModelProviderCapabilityAdapter`, orchestration's
`renderInferenceInstructions` lowers groups to the unchanged
`ModelProviderRequest.instructions` string with blank-line separation and unchanged
zero-source bytes. Tools, policy, model controls, and Environment selection
retain their existing owners. Chat registers no context source and remains
AGENTS-unaware. Normal discovery and explicit development/self-hosting activate the
independent `agents_md_backend` through the same generic remote adapter, retaining
`agents_md_plugin` as its pure-Dart semantic implementation. Each snapshot rereads
root `AGENTS.md` through generated authorized reads backed by the captured Session's
`AuthorizedEnvironmentFileReadFacet`. Missing (`not_found`) and blank
files succeed empty; other read/service/authority errors fail the required source.
Exact file text and its revision form one material, separate from stable
plugin-owned explicit-user-precedence semantics, not generic ordering authority.
Exact fields and rendering rules are in
[`adele_orchestration`](../../packages/orchestration/README.md#inference-context).

Broader Reference/Observation material is directional, without placeholder public
APIs. Nested/scoped AGENTS.md, aliases/overrides, global/home files, imports,
AGENTS.md caching, other context sources, and provider-aware
projection/cache planning, token budgets, compaction, and context UI/persistence
remain deferred. AGENTS.md does not own Skills, roles, or maps; these remain
independent plugin concerns. The broader buckets below are not implemented by
this slice.

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

There is no universal priority mechanism. When an Extension Point specifically
needs contributor-selected placement, its contract may prefer numeric priority
over direct `before X` / `after Y` references.

Relative ordering creates knowledge of another extension and can evolve into an implicit dependency graph. Numeric priority lets extensions express approximate placement independently. An owner may define priority bands such as early/normal/late when useful.

If a contract defines numeric priority, equal priorities need deterministic
secondary ordering, such as stable extension identity.

Not every Extension Point needs priority or ordering. The implemented
`inferenceContextSources` contract has no numeric priority: strategy instructions
come first, then lexicographic source `ExtensionId` order with source-local order
preserved. Sorting makes composition reproducible; it is not semantic authority,
trust, conflict resolution, or an override rule.

B1 Project selector buttons instead preserve deterministic registry registration
order, with no selector priority or sorting by display name/extension ID.

---

# 11. Failure semantics belong to the extension contract

There is no universal extension failure policy.

Examples:

- Event subscriber failure normally does not fail the producer.
- Decorative UI extension failure may omit that fragment while keeping the parent surface usable.
- Failure of the selected Environment provider means that Environment lifecycle operation failed.
- A mandatory security/policy participant failing may make it unsafe to continue.
- Implemented inference-context sources explicitly declare required or optional failure behavior: required failure aborts preparation, optional failure omits the whole source with diagnostics, and successful empty output remains distinct.
- B1 Project selectors return `null` for cancellation; selector/lifecycle failure is an inline app error with no fallback or change to the presented Project.
- Local backend startup/advertisement/registration failure rolls back that attempt, including both capability and extension registrations; shared-host failure affects all backends. No live Environment provider leaves Task support unavailable without blocking Project opening; no active source contributes no instructions. An active required source that fails capture aborts preparation. Task establishment failure publishes no new Task/Environment and substitutes no provider.
- Missing, ambiguous, failed, or retired Session/tool presentation is visibly unavailable without invalidating headless execution. Independent prepared frontends do not substitute native views or compile source on failure.
- Native output without backend-supplied safe presentation stays opaque and omitted. Safe activity with no matching rich presenter remains visible, with rich Inspection unavailable; duplicate exact safe-kind registrations are explicitly ambiguous. Malformed summary input produces no presentation, and factory/EVC failures remain presentation-local without changing Run settlement or exact replay. No priority, raw-envelope rendering, or native fallback is introduced.

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

## 12.2 Implemented presentation boundaries

`SessionPresentationContribution(strategyId, createPresentation)` supplies a
`Widget Function(Session)` factory at typed `sessionPresentationContributions`.
`ToolActivityInspectionContribution(toolId, createPresentation)` supplies a
`Widget Function(ToolActivityInspectionSource)` factory at typed
`toolActivityInspectionContributions`. The source is a read-only `Listenable`
whose immutable `ToolInvocationActivity` snapshot belongs to public pure-Dart
`adele_orchestration`. Flutter `adele_ui` depends on that public activity API and
`adele_model_tool`, not kernel or application implementations.

These hosts use exact semantic identity matching and existing registry liveness.
They retain presentation resources across updates, remove retired widgets, and
select a replacement only through fresh resolution. Observation confers neither
tool execution nor approval authority.

`ToolActivityCompactPresentationContribution(toolId, createPresentation)` and
`ModelNativeActivityCompactPresentationContribution(presentationKind,
createPresentation)` provide the distinct compact semantic role. Factories receive
the same read-only tool source or safe native presentation, never navigation or
approval callbacks. Exact zero/one/many resolution and generation liveness mirror
rich presentation; missing, ambiguous, failed, or retired compact views leave a
bounded alias or provider-approved compact-text fallback, not native plugin-field
interpretation. Plugins retain bespoke interpreted widget composition.

Chat strategy owns grouping and timeline placement; the host owns inspect
interaction, newest-first window-local cards, independent collapse/dismiss chrome,
and tool/native compact-row composition by exact `output.sequence`. Individual
cards reuse compact headers and existing rich bodies. A group-row click prepends
an individual output target; no existing card is replaced or collapsed. Card IDs
are distinct from exact Session/Run/model/output targets, which resolve retained
live evidence rather than frozen copies. Tool frontends own field interpretation
over immutable structured transport and reuse `PreparedFrontend`. Dismiss removes
only the view, changing Session clears the stack, and responsive placement is not
public panel API semantics. Run/core owns evidence identity/order/lifecycle;
common host approval UI alone offers Allow/Deny. Detailed boundaries and deferred scope are maintained
in [`overview.md`](overview.md#activity-inspection).

`ModelNativeActivityPresentationContribution(presentationKind, createInspection)`
also belongs to `adele_ui`, with typed
`modelNativeActivityPresentationContributions` and
`ModelNativeActivityPresentationResolver`. Its factory is
`Widget Function(ModelNativePresentation)` over immutable public orchestration
data; there is no UI projection DTO or projector callback. Exact safe-kind
resolution has the zero/one/many semantics described above, not an ordered series
of applicability probes. Views retain exact bindings, retire with that generation,
and use fresh resolution for replacements rather than retargeting stale resources.

Backend supplies generated `ModelProviderNativePresentation(kind, compactText,
data)` through required nullable `ModelProviderOutput.nativePresentation`.
Nullability means semantic absence, not an omitted generated key. The generic app
adapter maps the same fields to immutable orchestration `ModelNativePresentation`
on optional `ModelNativeOutput.presentation`, without provider interpretation.
The coherent-schema convention and raw replay boundary remain unchanged.

Generic Chat and Inspection never parse OpenAI. OpenAI uses
`plugins/openai/packages/{contract,backend,frontend}`. Pure-Dart `openai_contract`
owns only shared identities/schema: raw `openai.responses.item.v1`, version 1,
and safe `openai.responses.reasoning-summary.v1`, version 1. Backend owns raw
classification, bounded summary projection, and exact native preservation;
Frontend renders the safe payload. Only
`{'summaryParts': List<String>, 'truncated': bool}` reaches its EVC, not raw
envelopes, compatibility metadata, encrypted content, or execution/approval
authority. Raw `nativeMetadata` is the only native replay source; safe presentation
is never replayed. This is provider-supplied summary presentation, not hidden
chain-of-thought recovery. Display controls are escaped by generic Chat for compact
text and the OpenAI frontend for full text, never by stock activation.

Generic frontend activation consumes OpenAI's prepared `modelNativeActivity`
descriptor from the same catalog, loads its EVC, and registers/retires exact
resources through `PreparedFrontend`, without stock identity imports or a PluginId
switch. Profiles remain separate and unimplemented; `app/tool` compilation remains
a checkout stand-in for installation preparation.
Chat counts each tool proposal and native output with `presentation != null`
within each successfully completed model invocation, independently of frontend
activation. Narration and opaque native outputs do not count. One occurrence uses
compact presentation directly; two or more use one group. Group headings prefer
tool-batch narration only when tools are present, then safe compact text, then
presentable operation count. The interpreted Chat bridge requests a native
inspectable activity-widget slot by a previously emitted opaque ID, not arbitrary
domain identities or plugin arguments. The slot hosts a separate plugin runtime.
Reasoning-only activity precedes canonical final text; retention is
controller-lifetime state, not persistence. Reasoning deltas,
compaction/configuration UI, arbitrary plugin drill-down, and Source/Diff/Console,
terminal/PTY/full-output surfaces remain deferred.

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

B1's host-rendered selector buttons are temporary presentation over the typed
callback and core Project lifecycle, not Command registration or a chooser
framework. Task presentation similarly invokes core Task lifecycle, not Git
directly. Command surfacing and Task Browser remain deferred; the minimal
Project/Task/Environment view and remaining scope are described in
[`overview.md`](overview.md#core-product-domain-direction).

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

Current Chat state is in memory: `ChatSessionStore.obtain(SessionId)` retains
`ChatSessionState`, with immutable snapshots of `ChatEntry` values
(`ChatUserMessage` and `ChatAssistantMessage`) reused across Runs. Only user/final
assistant messages are canonical; intermediate native/model output, proposals,
and tool results remain Run-local. Chat instructions and a positive invocation
budget are snapshotted per materialized Run. This does not implement the
persistence facilities described below, rich plugin-facing Chat UI, profiles, or
child Sessions. The normal app's minimal Chat surface consumes canonical snapshots
without moving history into product Session values.

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
