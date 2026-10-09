# ADELE Plugin System

Role: Canonical architecture

Implementation status: Partial

This document defines plugin ownership, identity, lifecycle, and recursive typed
composition. ADELE implements generic registration/discovery/liveness and several
concrete extension-point families. The broader recursive ecosystem, general
profile/activation management, general contextual plugin Commands/keybindings, and
full plugin-management and productization remain incomplete. Public plugin APIs remain experimental.
Source/tests establish current behavior; [ADR 0030](../adr/0030-recursive-typed-plugin-extension-model.md)
records the recursive extension decision and its rationale.

## Core and plugin ownership

A plugin is an independently identified unit of product behavior whose active
components participate through public typed interfaces. ADELE is not a fixed
application with plugins confined to its edges: plugins can introduce more
specific concepts and deliberately public extension APIs of their own.

Core owns stable concepts and generic infrastructure needed by unrelated plugins:
shared product identities, registration/discovery/liveness, host lifecycle and
routing, final authorization, and generic hosting/composition. Plugins own concrete
behavior where no shared core semantic owner is required. For example, Chat owns
its strategy state, while Git supplies an Environment implementation; neither
behavior belongs in the universal product schema.

A valid application can exist with zero installed plugins. Core/application code
must not require concrete stock implementations; missing plugin behavior stays
unavailable rather than acquiring a built-in substitute. Plugins cooperate through
deliberately public typed APIs, not dependencies on one another's implementation
packages. Exact package and application boundaries, including the temporary
provider-selection identity exception, belong to [dependency rules](dependency-rules.md).
The [product model](product-model.md) owns shared product semantics.

## Identity and lifecycle distinctions

These concepts must not be inferred from one another:

| Concept | Meaning |
| --- | --- |
| Plugin semantic identity | `PluginId` names the plugin independently of its implementation packaging and live generations. |
| Dart/package/source identity | Package names, source directories, repositories, and artifact locations organize implementation and preparation, not plugin semantics. |
| Installation | Makes an implementation available to ADELE; does not establish contextual participation or live readiness. |
| Activation context | The host context in which an installed plugin participates. Activation is contextual, not an intrinsic installed-metadata flag. |
| Runtime generation | One live activation/component generation and its owned registrations/resources. A replacement is not the same executable object even if all semantic IDs match. |
| Configured capability instance | A named account/provider/endpoint or similar configuration exposed by a runtime, not another installation or necessarily another runtime. |
| Temporary runtime resource | A process, terminal/browser session, open document, active connection, or other temporary object created and disposed during operation. |

`PluginId` is not a Dart package name, repository directory, artifact filename,
display name, Capability ID, Extension ID, or configured instance ID.
[ADR 0010](../adr/0010-plugin-identity-differs-from-dart-package-identity.md)
records why plugin and package identities are separate.

Installation does not activate a plugin in every context. Deactivation ends its
participation in that context without uninstalling it or deleting dormant
persisted configuration. The intended default is one plugin runtime per activation
context; one runtime may expose multiple configured capability/provider instances.
Generation-bound configuration routing handles are not persistent instance records.

Complete installation/update management and profile-aware activation are not
implemented. Current prepared startup composition does not establish those
systems. [Profiles and configuration](profiles-and-configuration.md) owns the
deeper activation, configured-instance, configuration, and runtime-state model.

## Source and prepared components

Plugin source is the canonical distribution form. A source plugin may contain
independently relevant shared contract, backend, and frontend components; it need
not supply both an executable backend and frontend to be useful.

Frontend and backend implementations do not depend directly on one another.
Shared typed declarations belong in deliberate contract/public API packages.
Shared transport contracts are pure Dart and depend on neither implementation nor
Flutter. The separation follows [ADR 0003](../adr/0003-separate-contract-frontend-and-backend-packages.md),
without requiring every plugin to implement all three roles.

Source/build preparation and runtime activation are separate concerns. Normal
activation consumes prepared artifacts, not source compilation. Prepared frontend
and backend availability, failure, and retirement can be independent; an operation
that needs both still requires its exact live counterparts. See
[plugin layout](plugin-layout.md) for source/prepared component boundaries and
[development documentation](../development/README.md) for the build workflow.

## Recursive typed extension points

An **Extension Point** is a typed place where active components may register
participation. Its semantic owner may be core or a plugin/domain package:

```text
core typed extension point
    -> plugin behavior
        -> deliberately public plugin-owned extension point
            -> other plugin contributions
```

An owner defines the public semantic contract, not a required implementation.
Another plugin may depend on that API without requiring one particular
implementation plugin to be active:

| Dependency | Meaning |
| --- | --- |
| Interface/API dependency | Knowledge of a deliberately public semantic contract. |
| Implementation/activation dependency | Requiring one concrete implementation plugin to be active. |

ADELE favors interface discovery over hidden activation dependency chains. An
unconsumed contribution or an unavailable integration can be valid; the host must
not silently activate another plugin to manufacture availability. One plugin may
contribute to several independent extension points without multiplying runtimes.

Where core must authoritatively validate or route a shared product identity, core
owns the minimal public extension contract needed to preserve that invariant.
For example, optional Session presentation cannot own the strategy-binding contract
required by Session lifecycle. More-specific plugin ecosystems retain their own
API owners. Introduce the smallest concrete typed boundary needed, not a universal
framework or new API package solely for hypothetical future reuse.

### Capability is a specialization

A **Capability** is a callable Action/Service provider-selection semantic: Actions
are brokered one-shot operations; Services expose sustained typed functionality.
It is one specialization of broader composition. UI contributions, inference
sources, strategies, Commands, and other participation must not be forced through
Capability merely because its registry already exists. A generated callable
service is not automatically an advertised Capability.

Compatible providers may number zero, one, or many. Default-provider selection is
host-owned, not a provider's declaration that it is globally primary. Provider
resolution, generated transport, and remote invocation belong to
[contracts and capabilities](contracts-and-capabilities.md).

Callable providers can explicitly declare a direct sibling association within one
backend activation. The host captures the exact owned registrations, not a
same-plugin or same-configuration inference. This enables native/host-side
Environment eligibility without merging registries or granting invocation authority;
see [provider associations](contracts-and-capabilities.md#provider-associations-and-environment-eligibility).
An explicit native host admission can separately authorize one contextual unary
call over that selection, without importing the plugin-owned service contract;
see [contextual invocation](contracts-and-capabilities.md#contextual-unary-capability-invocation).
Mounted prepared Main Content consumers can use the same admission through a
separate explicit Environment-read declaration and presentation-bound bridge;
ordinary context-free Capability access remains unchanged. See
[prepared contextual reads](contracts-and-capabilities.md#prepared-contextual-environment-reads).

Events remain read-only fact notifications, not provider-selected calls or mutable
lifecycle hooks. Observers cannot change whether the announced fact occurred;
subscriber failures normally do not retroactively fail its producer. Events do
not themselves imply durable history or replay.

### Composition belongs to the extension point

Each owning contract defines its zero/one/many behavior, selection/composition,
ordering, applicability, and failure semantics. The generic registry does not
prescribe exactly one implementation, numeric priority, generic before/after
ordering, fallback, or one applicability/failure policy.

Examples illustrate different contracts, not a universal rule:

| Extension family | Composition owner and rule |
| --- | --- |
| Orchestration strategy | [Orchestration](../../packages/orchestration/README.md) requires exact unique resolution for an explicit strategy ID; missing and ambiguous are distinct failures. |
| Inference-context sources | [Inference context](../../packages/orchestration/README.md#inference-context) composes zero or many sources under its own capture, ordering, and required/optional failure rules. |
| Model tools | [Model-tool API](../../packages/model_tool/) defines contextual contributions; its composition has distinct tool-identity and model-alias collision semantics. |
| Project selectors | [Core extension contracts](../../packages/core_extensions/README.md) expose independent actions, not interchangeable default providers. |
| Project providers | The same public package defines backing preparation through an explicitly selected capability provider, without default substitution. |
| Commands | [Core extension contracts](../../packages/core_extensions/README.md#commands) compose independent semantic operations; duplicate Command IDs are ambiguous, and invocation revalidates the exact unique binding and current enabled state. |
| Task Browser | [UI](../../packages/ui/README.md#task-browser) requires exactly one active browser contribution; zero is unavailable and multiple are ambiguous, without fallback. |
| Main Content | [UI](../../packages/ui/README.md#grouped-main-content) composes independent ordered groups; each exact registration controls only its own contiguous panes. |

Prefer structured typed contributions when an extension influences an operation,
not opaque mutation of host objects through universal `beforeX`/`afterX` hooks.
Numeric priority may suit a particular domain, but it is not a universal
extension-system concept. Deterministic ordering does not confer authority.

## Live discovery and exact captured bindings

Registration and discovery are live. A fresh operation may discover current
contributions; a discovery snapshot is not a permanent startup inventory.
Consumers must distinguish:

| Identity | Meaning |
| --- | --- |
| Semantic identity | The plugin/provider/domain behavior being named, stable across live generations. |
| Registration identity | A named contribution at a typed point, such as an `ExtensionId`; not necessarily the domain identity it implements. |
| Exact live binding | One particular registration occurrence and its generation/liveness, retained by a resolved operation. |

Where execution correctness requires a live contribution, resolution/materialization
captures that exact binding. Consumers and host adapters validate it through the
relevant invocation and asynchronous settlement boundaries. Retirement makes the
captured binding stale; replacement registration never silently retargets it.
Reusing semantic IDs, registration IDs, or even a contribution object cannot make
an old binding live again. Cleanup likewise retires only owned registrations,
not replacements. Retirement does not promise rollback of effects already started.
`ExtensionBinding.onRetire` supplies synchronous exact-registration observation,
separately from asynchronous registry rediscovery, so presentation-owned authority
can be revoked before view reconciliation. This signal grants no cancellation or
rollback semantics to unrelated unary work.

Immutable capture has a different lifetime from executable binding. For example,
inference-source bindings are validated through capture; safely copied and
validated immutable material can outlive source retirement. The next capture may
discover replacements, but the current capture does not silently retry through one.

The public [extension registry API](../../packages/plugin_api/lib/src/extension_registry.dart)
defines `ExtensionRegistry`, `ExtensionBinding`, and `StaleExtensionBinding`.
[Capability bindings](../../packages/capabilities/README.md),
[execution semantics](execution-model.md), and the
[product model](product-model.md) explain their domain-specific lifetimes.

## Backend and frontend composition

### Backend

Current architecture runs native Dart AOT backends outside the Flutter isolate,
in separately loaded isolate groups within a shared child Dart runtime.
[ADR 0019](../adr/0019-shared-process-hosted-plugin-backends.md) records the hosting
decision. Process/isolate separation is not a security sandbox.

A backend may advertise public capability/extension contributions once ready.
The host validates and adapts them into the existing public registries with exact
generation liveness. Host adapters implement known public contracts; their adapter
lookup is not a second registry of plugin contributions or automatic transport for
every future plugin-defined interface. Activation owns registration rollback and
retirement. A failed backend does not imply a built-in substitute implementation;
shared-host failure can affect all backends it hosts.

### Frontend and collaboration

Prepared plugin frontends execute through the interpreted Flutter path in the
maintained design, preserving the [frontend/backend split](../adr/0002-split-interpreted-frontend-and-aot-backend.md).
Frontend contribution metadata can establish semantic presentation and behavioral
roles independently of backend readiness. The frontend owner activates prepared
generations from the same installation catalog and registers contributions in the
existing extension registry. Registration does not guarantee every view will
render successfully.

When frontend and backend cooperate, they use deliberate public/shared contracts
and host-provided bridges, not implementation imports or shared runtime objects.
The host may capture exact owning-backend selection where required. Belonging to
the same plugin does not grant a frontend arbitrary backend or host authority;
missing or retired counterparts fail explicitly rather than retargeting. See
[contracts and capabilities](contracts-and-capabilities.md) for own-backend requests,
operation-scoped host calls, service allowlists, and transport mechanics.

### Project selector ownership

Every prepared `PreparedProjectSelectorExtension` declares a required
`projectProviderId`. The corresponding `ProjectSelectorContribution` retains
`selectProject` for source selection, while the host resolves that provider's
Project capability. There is no optional affinity enum: all prepared selectors
require the exact ready backend belonging to the same
`PreparedPluginInstallation` as their frontend.

The host proves ownership through the backend's owned capability registrations,
using generic registration `.owns` checks. Matching `PluginId`, `ProviderId`,
endpoint metadata, or a contribution's value does not establish provenance.
Neither a foreign same-ID endpoint nor a replacement generation may satisfy an
already captured operation. Validate the selector/provider before picking, after
picking, and after provider preparation, before accepting backing for storage.

Frontend activation remains independent of backend readiness: a selector can be
registered but unable to open a Project. The Project provider can serve headless
callers without the frontend. The stock Local Directory plugin uses an interpreted
Flutter picker frontend and a pure-Dart AOT backing provider; production app code
links neither implementation. Its picker bridge conveys no Session/Environment
authority and the provider receives no host database handle. After successful
Project publication, neither component generation remains a permanent identity
pin. See [Project lifecycle/storage](product-model.md#opening-and-publication) and
the [public contract map](../../packages/core_extensions/README.md).

## Commands and input

A Command is a semantic user operation independent of its presentation or input
surface. Core owns its public domain in `adele_core_extensions`, including
composition, resolution, and dispatch admission through the existing
`ExtensionRegistry`. The application-owned global Command Palette is a consumer,
not the semantic owner. A keyboard binding, menu, or button can invoke the same
Command without a second operation contract. Commands are distinct from model
tools that execute external programs and from existing presentation-local
`MainContentAction` and `ConsoleCreationAction` contracts.

Stable `CommandId` names the operation independently of registration `ExtensionId`.
Zero Commands is valid; distinct identities coexist. Multiple live claims to one
Command ID are ambiguous, never resolved by priority or arbitrary selection.
Discovery excludes such identities from executable choices; ID resolution
distinguishes missing from ambiguous. A resolved Command retains its exact live
registration, which cannot revive or retarget after retirement or ID reuse.

Availability is a cheap synchronous side-effect-free evaluation: hidden means
irrelevant, disabled means relevant but currently non-invokable, and enabled
permits admission. Evaluation failures fail closed. Invocation revalidates exact
registration liveness, unique resolution to that binding, and current enabled
state immediately before calling the implementation. After admission, generic
Command infrastructure imposes no cancellation on retirement; completion follows
the implementation's owning-domain semantics. Consumers contain invocation
failures rather than exposing arbitrary exception text as user-facing output.

The current implementation accepts native/in-process contributions, context-free
backend Commands through ordinary backend-ready extension exposures, and prepared
frontend Commands through behavioral `frontend.extensions` descriptors, including
context-free operations and explicit contextual Console-action and Main Content
input-action adapters.
Application adapters register the same public contribution; the palette
does not distinguish its origin. Context-free backend-only and frontend-only
Commands need no Main Content, Console, Task Browser, or other presentation contribution.

For remote Commands, applicability means only that the exact contribution is live.
Availability validates local registration/backend liveness synchronously, without
an RPC, asynchronous cache, polling, or invalidation event. A backend that should
not expose a Command omits its advertisement for that generation. Dynamic
Project/Task/Session/Environment-sensitive backend availability remains deferred.
Invocation uses generated transport on the exact captured backend/configuration
route, with no replacement lookup, retry, or post-completion registration check.
Backend termination can naturally fail an admitted request. The call carries no
host invocation context or host-service grant; no generalized Command context
supplies authority. See [remote Command transport](contracts-and-capabilities.md#remote-commands)
and the [public API](../../packages/core_extensions/README.md#remote-commands).

Context-free prepared frontend Commands likewise expose only exact-registration
liveness as local synchronous availability. They do not evaluate frontend code or receive
Project/Task/Session/Environment state during availability. A frontend omits the
descriptor when it should not expose a context-free Command. Invocation captures
the exact frontend generation and runs the declared no-argument operation in a
fresh evaluator, accepting only void/null completion. The operation receives no
host/native authority, owning-backend access, or presentation state. Missing native
bridges and plugin failures propagate through ordinary Command invocation.
Retiring a frontend generation invalidates its owned evaluator operations under
existing frontend lifetime rules; an already-admitted operation may therefore fail.
It is not detached to outlive that generation and never retries through a replacement.
See [frontend behavioral operations](contracts-and-capabilities.md#frontend-behavioral-operations).

The contextual prepared Console-action adapter exposes one explicitly declared
sibling creation action as an ordinary Command. Activation validates the exact
same-component target, captures its live registration and action, and derives the
label from that action. The local action ID is not a global Command identity.
Stock Terminal's New Terminal is the first consumer: Console retains canonical
Session/Environment lookup, admission, bridge, resources, navigation behavior, and
cleanup. The adapter introduces no generalized Command context or native authority.
It is hidden without meaningful current Session context or a live target, disabled
when canonical Environment authority is unavailable or exact creation is pending,
and otherwise enabled independently of Console visibility. Invocation reveals a
collapsed Console before fresh admission to the same action used by its `+` menu.
Creation failures remain contained by Console's safe warning, not a second palette
diagnostic model. Retiring the target Console retires its dependent Command;
Command-only retirement leaves Console participation intact. Replacement requires
fresh bindings and never revives captured callbacks.

The Main Content adapter likewise captures one exact sibling contribution and
action, deriving its label without duplicating presentation metadata. The mounted
Session host owns current attachment and its single bounded input route. A narrow
window-local coordinator admits that exact action through the same method as its
visible button; it supplies no general Command context or widget service. The
Command is hidden when no current Session host exists or its target is retired. A missing, pending, or
failed attachment or occupied input route disables it. Admission revalidates the
exact action and completes after opening, without waiting for user input.
Factory failures retain Main Content's local unavailable presentation. Departure
or action retirement dismisses the captured input; returning may use fresh access
for the same contribution, never a replacement generation. Target retirement also
retires dependent Commands, including raw registration closure; Command-only
retirement leaves panes and buttons usable.

Stock Source Editor deliberately declares `dev.adele.source-editor.open-source`.
It and the existing button present the same `openSourceInput()` form. The Command
accepts no path and performs no file access; only the user's subsequent submission
invokes the existing `display` operation. Main Content retains captured
Session/Environment identity, Source retained state, and finite-operation file
authority. Neither availability nor input opening executes an Environment read,
and later display failures remain in the Source input UI.

Registry membership changes use existing `ExtensionRegistry.changes`. Consumers
reevaluate availability when presenting/refreshing and at admission, without
polling or a general state-notification/context-expression protocol. General
contextual frontend authority, Command arguments, and automatic projection
of presentation actions remain deferred.
The application implements one fixed desktop shortcut for Show Command Palette,
using the same live resolution and admission as its button, within shell-route
focus and modal ownership. This is an input consumer, not a public keybinding
domain. Keybinding registration, plugin-suggested/default bindings, deterministic
binding conflicts, user/Profile/Project overrides, Settings integration, and
additional binding scopes remain future work.
See the [public API map](../../packages/core_extensions/README.md#commands)
and [application hosting](../../app/README.md#command-palette).

## UI and presentation

Plugin-facing UI extension points describe semantic roles, not fixed physical
coordinates. Host-owned layout can evolve without redefining those contracts,
and plugins may define further semantic regions within their own presentation.
The host can render common structural elements while plugins supply richer views.

Rendering or invoking an operation does not make a plugin its semantic owner.
Common host lifecycle, execution authority, and approval semantics remain
host-owned. Read-only observation does not confer execution or approval power.
Rich presentation may disappear or fail without invalidating underlying safe
execution evidence where the specific contract defines that behavior; this is
not a universal fallback or failure policy.

The public [UI package](../../packages/ui/README.md) maps current semantic contracts;
the [application presentation map](../../app/README.md#activity-inspection) covers
implemented hosting. [Product direction](../product/README.md) describes intended
experiences rather than fixed extension coordinates.

UI affordances may consume the independent [Command domain](#commands-and-input);
they do not make Command registration or behavior presentation-owned.

### Grouped Main Content

Main Content composes independent pane groups for the presented canonical Session.
One group belongs to one exact contribution registration, not to a PluginId: a
plugin can supply multiple independent groups. Groups sort by ascending integer
`order`, then lexical ExtensionId. Each owner controls its local pane sequence;
the host flattens whole groups before layout so another group cannot interleave
their items. Ordering is composition, not authority or a reserved stock-kind enum.

All Main Content comes through real registrations. There is no injected strategy
renderer, reserved order-100 slot, or mandatory strategy pane. Stock Chat directly
registers an ordinary contribution at order 100 and decides its own applicability;
another plugin or arrangement can use the same composition contract. Zero panes
produce a generic empty workspace, not a native strategy substitute. Whether a
Session is presented is explicit canonical window state, independent of frontend
or backend availability. Missing strategy presentation does not turn that workspace
into Task Browser or remove independent Main Content contributions.

A contribution attaches to one exact registration and current Session object.
Its access can add, retitle, reorder, reveal/focus, and remove only its own panes.
Pane IDs are local data, not cross-group or global editor handles. Metadata/order
updates retain pane presentation identity. Common close chrome requests owner
closure; removal releases that pane independently of siblings. Departure,
registration retirement, and host shutdown end captured access. Fresh attachment
may discover a replacement, but old handles and callbacks never migrate to it or
to a newly opened pane reusing the same ID. Group/pane failures remain local, not
reasons to change canonical Session/strategy identity or retire healthy contributions.
Focus/reveal and geometry changes are not Session navigation. Revoking a presentation does not close its
independently hosted Run or universally dispose underlying domain resources.

Prepared contributions initialize through a short-lived operation runtime that
reads captured Session/strategy/Task/Environment identities through the collection
bridge, may open initial panes, and is disposed on settlement. The Environment
identity comes from canonical `SessionEnvironmentAuthority`, without provider
resolution or materialization, independently of any service, retention, or native
resource grant. The same identity context serves input/pane views and finite
operations; operation arguments remain separate copied data. Initialization obtains
no execution, backend, or file services, including when declared for later panes.
Each pane then has an independent presentation runtime whose bridge can manage
that same owned group.
Declared contribution actions remain discoverable even with zero panes; they open
fresh input presentations without manufacturing a pane or execution authority.
Descriptor-selected finite operations use fresh short-lived runtimes, not retained
callbacks. No initializer callback is retained as a factory, and no hidden evaluator
or background residency updates a collection after its views depart.

An explicit retention grant lets the host keep copied opaque plugin data and native
editor owners beyond a Session attachment. The plugin owns record meaning, document
identity, deduplication/order, baseline, and save/close policy; the host owns native
resource lifetime and exact access validation. Retained data contains no widgets,
evaluators, callbacks, or attachment access. Fresh attachment projects those records
with fresh view handles; old handles never revive. An admitted finite operation
may finish against its captured owner after navigation, but may not retarget its
Environment or focus an unrelated workspace. Native construction from supplied
text grants no filesystem authority; explicit user Environment access follows the
[narrow frontend grant](contracts-and-capabilities.md#frontend-behavioral-operations).

The public source-file display point resolves one exact registration, with absent,
ambiguous, and explicit-selection outcomes and no native fallback. Stock Source
uses it and its input action to reach the same plugin-owned operation. Window-local
retention is not durable workbench persistence. Pane close requests owner policy;
application-exit preflight also consults opted-in retained collections without
mounting hidden views, including while Task Browser is shown. Cancellation or
failure precedes irreversible frontend/execution revocation and leaves retained
documents available. Acceptance is not early disposal if another participant can
still refuse exit. These exit operations have no Session context or Environment
grant; hidden records and browser selection do not manufacture one. Plugins own
confirmation wording and discard decisions over generic host two-choice dialogs.
Forced teardown and plugin retirement are separate cleanup paths.

Execution and owning-backend services are explicit pane-scoped requests, not a
privileged presentation role. Neither is granted by default. The binder validates
the exact contribution, canonical Session, and any controller's captured strategy
binding. Requested backend access must belong to the exact prepared installation;
owning-backend affinity additionally requires the actual strategy registration's
origin, not matching IDs. Declared affinity alone is insufficient; missing or
incompatible services fail the requesting pane rather than selecting a substitute.
`PreparedSessionServices` binds these existing services; it is not a renderer
resolver or execution owner.

Cross-plugin Capability access is independent of owning-backend affinity. The
context-free `capabilities` descriptor grants no Environment authority. The separate
`environmentReadCapabilities` declaration permits only contextual unary reads from
an exactly associated backend provider. Native hosting captures the mounted pane's
canonical Session; each request receives its own grant and cannot follow later
navigation. Handle release and presentation retirement synchronously revoke those
grants without cancelling independently owned backend work. Initializers, input
actions, and finite operations receive neither Capability bridge. Selection,
settlement, and limitations belong to
[prepared Capability consumption](contracts-and-capabilities.md#prepared-frontend-capability-consumption).

Core retains Session execution controllers, Run lifecycle, policy, and approval
authority. Plugins choose where to place controls, including the existing native
Run status/approval UI exposed through `buildSessionExecutionStatus()`. Removing a
pane or retiring its frontend revokes its actions without closing the Run.

The public [UI map](../../packages/ui/README.md#grouped-main-content) owns API details,
the [prepared catalog](../../packages/plugin_runtime/README.md#prepared-catalog)
owns the data-only ABI, and the [application map](../../app/README.md#grouped-main-content)
owns layout and native binding mechanics. Stock ordering is
[product direction](../product/development-workflow/README.md#6-center-workspace--main-content-stock-layout)
layered over this extensible contract, not fixed core slots.

### Native editor primitive

The application owns the native editor implementation and its text/undo resources.
An interpreted frontend uses public [UI bridge contracts](../../packages/ui/README.md#interpreted-bridges)
with handles scoped to one presentation and one host-selected owner. Retired
handles cannot acquire a replacement editor. It receives no CodeForge types,
controllers, Rust handles, filesystem authority, or local-keystroke backend service.
The text/undo owner outlives its widget; native focus, clipboard, and composition
follow ordinary component behavior rather than a separate interaction protocol.
Bridge retirement ends interpreted access and observation, not already admitted
native work on that owner. Notification revisions and deliberate text snapshots
are not content versions, Environment revisions, or save acknowledgements.
Main Content hosting, file/save policy, diff, and LSP remain outside this primitive.
The [application map](../../app/README.md#native-code-editor) owns its current
single-view lifecycle and limitations.

### Task Browser presentation

Task Browser is a replaceable, frontend-only semantic role over one presented
Project. The public UI contract selects one exact live contribution, independently
of strategy or owning-backend affinity. Missing, ambiguous, retired, or failed
presentation remains unavailable; core does not supply a native Task form or
browser substitute. Its prepared metadata names presentation ABI, not a backend
dependency or authority grant.

The host projects canonical Project/Task/Environment/Session facts and mediates
selection, Task creation, Session creation, and opening an existing Session. Task
and Session IDs are lookup data, never authority to navigate another Project or
Task. Session creation uses an opaque handle retaining an exact executable strategy
binding from the orchestration registry, independent of UI registrations. Labels
come from the strategy's optional `displayName`, with its ID as fallback. The host
revalidates membership, uniqueness, and liveness before publication rather than
silently replacing a stale choice. Browser retirement revokes its reads, actions,
and subscriptions; late Task establishment may still publish canonical state, but cannot navigate a
retired view. Revocation is not rollback.

Canonical Sessions remain openable even without a frontend, backend, or Main
Content contribution. Navigation availability is separate from current strategy
execution availability and retained execution status. Browsing and opening a
retained Session neither materialize an Environment nor start a Run. The browser
does not receive provider state, plugin-owned Session content, database access, or
execution authority. Selection and presentation state are transient host/window or
view state, not additions to the product persistence schema. The
[UI contract map](../../packages/ui/README.md#task-browser-snapshot) owns the bridge
shape; the [application map](../../app/README.md#task-browser) owns host composition.

### Shared console

The console is a host-owned shared surface composing independent plugin content,
not a single selected Console/Terminal provider. Multiple `consoleContributions`
may supply creation actions and content. The host owns shared tabs, action
discovery, selection, visibility, confirmation, and bounded cleanup; plugins own
their content, eligibility, metadata, presentation, and resource-release behavior.
No contribution owns another contribution's tab or embeds the whole shared shell.

Creation captures an exact live contribution and host-selected Session context.
Already admitted asynchronous creation stays in that captured scope across
navigation; it cannot retarget or steal the new context's selection. Creation
access ends on action settlement, owner retirement, or host close; late content is
released rather than published. Retirement also removes exact owned content.
Replacement requires fresh access, never migration of old bindings.

An explicitly declared semantic Command may delegate to an exact sibling creation
action without changing this authority or public Console contract. The host takes
fresh current-context admission after revealing the surface, while pending work is
recognized by exact owner/action rather than a view-specific action binding.

Content registration is independent of mounted presentation: metadata and lifecycle
observation may continue while hidden. Presentation is selected-only by default;
content may explicitly opt into the host's bounded resident working set. Residents
are created lazily on selection, never merely because a tab exists. The selected
presentation counts toward the bound, and least-recently-selected hidden residents
are evicted when needed. The host neither eagerly mounts all tabs nor keeps one
working set per background Session.

Resident lifetime and selected interaction are separate grants. An opted-in hidden
resident may retain its evaluator, bounded renderer, allowlisted reads/watch, and
local state, but cannot accept pointer, focus, keyboard, selection/copy, or other
user interaction. Each selection issues a fresh interaction epoch; callbacks
captured under an earlier epoch remain revoked even after reselecting the same tab.
Resident callbacks still validate their exact resident and owner generation.
Collapsing the console, changing canonical Session identity (including null),
unmounting the console, or closing its host ends the entire working set. Eviction,
content removal, and owner retirement end the affected resident. Lightweight tabs,
selection, and bounded logical/checkpoint state can survive working-set departure,
not revoked executable grants. Application accounting and disposal timing belong
to the [console host map](../../app/README.md#session-console).

Read-only content can also be opened through an explicitly declared console target
from a rich Inspection. The host captures the target's exact registration within
the same installation/frontend generation and the canonical Session, rather than
letting transported IDs choose authority. An opaque content key deduplicates only
within that owner and Session; equal keys cannot replace an existing descriptor or
its logical state. Admission transfers bounded structured plugin data to a
host-owned declared factory, never a callback or evaluator runtime from the
originating view. The content can outlive that view; a warm selection reuses its
resident, while a cold presentation receives fresh access and reconstructs from
bounded logical/checkpoint state through its exact owned bindings.

Close advice is synchronous and advisory only, with no veto or asynchronous
settlement hook. Missing/failed advice triggers host confirmation. Confirmed close,
content-requested removal, retirement, and host shutdown release resources without
requiring a mounted view. Forced cleanup does not wait for a dialog or plugin
approval; timeout/failure reports a bounded safe warning rather than indefinitely
retaining a tab or asserting that execution stopped.

The current workbench exposes the console only while presenting a Session. Task
Browser has no console panel, toggle, or creation actions. Terminal content uses
the Session's canonical Environment association, not a primary-Environment guess;
that resource ownership is defined by the [product model](product-model.md#interactive-terminal-resources).
Read-only command output is independent contributed content with invocation
provenance, not a Terminal child. Concrete public types belong to
[UI](../../packages/ui/README.md#shared-console), prepared ABI to the
[catalog](../../packages/plugin_runtime/README.md#prepared-catalog), and stock
behavior to [Terminal](../../plugins/terminal/README.md) and
[Command Tools](../../plugins/command_tools/README.md).

### Activity Inspection

Tool Inspection observes one canonical Session/Run/tool-invocation occurrence.
Those immutable identities distinguish repeated aliases or provider call IDs and
remain factual data for both live and historical activity, not execution handles
or authority. Core supplies the occurrence and public execution evidence; plugins
own interpretation of their domain data and any fuller historical reads. Neither
Inspection nor a console becomes a second transcript store or canonical strategy
state owner.

Prepared rich Inspection may use explicitly allowlisted services on its exact
owning backend and open declared console content. These are separate read-only
hosting facilities, not Session strategy materialization, tool execution, or
approval authority. Missing backend observation preserves factual Inspection;
compact presentation remains factual and never acquires these facilities.
Own-backend routing follows [contracts and capabilities](contracts-and-capabilities.md#own-backend-frontend-requests).

Native read-only terminal projections are independent per-view renderers, separate
from interactive terminal resources. Each view owns a bounded parser/buffer and
viewport with revocable access. Local feed/reset, scroll, selection, and explicit
copy confer no input, paste, terminal-reply, resize, signal, process, or backend
authority. Plugin readers retain history semantics; renderer lifetime, hiding, or
closing cannot cancel independently owned capture. Warm resident observation and
programmatic reconstruction do not require a selected interaction grant; native
user gestures and asynchronous interaction completions do. Public API and bounds
belong to [UI](../../packages/ui/README.md#interpreted-bridges), not a Command-specific
contract in the app.

### Session presentation settlement

Actual Session departure may need contributed panes to settle pending local state
before their views are disposed. The existing public interpreted lifecycle bridge
permits one asynchronous prepare-to-deactivate callback per exact pane presentation;
the host aggregates the affected hooks, rather than consulting one selected renderer.
The host blocks input while awaiting acceptance but keeps settlement services live;
rejection or failure leaves live panes available for correction or retry. A missing
hook means nothing to flush. This does not transfer navigation ownership, plugin
state semantics, or storage codecs into the host, and is not a general plugin lifecycle hook system.

Accepted navigation revokes the departing panes' captured access and actions, and
clears Session-local Inspection and console context before changing selection.
It does not close the Session's execution owner: preparation, advancement,
approval waits, and terminal persistence may continue without a mounted view.
Pending local saves or message acceptance may still refuse deactivation for retry;
they must not turn that short settlement into a wait for the entire Run.
Reentry obtains fresh view-scoped handles and native action authority over the
same retained owner. Old actions remain revoked even after the same Session is
presented again. Presentation replacement and executable-generation replacement
are distinct; exact backend affinity is validated without migrating retained work.
Retirement cannot preserve or retarget an old hook. Exact
public names belong to [UI](../../packages/ui/README.md#interpreted-bridges); current
ordering and shutdown distinctions belong to the
[application lifecycle map](../../app/README.md#session-lifecycle).

## Plugin-owned state and persistence

Plugins retain semantic ownership of their domain-specific state. The implemented
[Project database](product-model.md#project-storage) hosts core records and
plugin-owned relational tables without absorbing plugin schemas into core. The
pure-Dart `adele_project_storage` contract supplies Session-scoped schema, query,
and transaction operations. SQLite, backing paths, and the single connection per
Project stay app-private; no key/value envelope, ORM, or public database handle is
introduced. Owner identity comes from the exact backend connection, not a caller
argument. [Storage access and limits](contracts-and-capabilities.md#session-scoped-relational-storage)
define the service boundary, including its deliberate lack of SQL row isolation.

Plugins own initialization SQL, relational constraints, validation, and migrations.
The host coordinates transactions and owner versions; the declared version is the
migration list length. Core `dev.adele.product`, execution `dev.adele.execution`,
and stock Chat
`dev.adele.plugin.chat-strategy` each have only the current version-1 baseline,
not an upgrade history of pre-release development schemas. Failed, malformed, or
newer unsupported state must not be reset or hidden behind an in-memory fallback.
Deactivation leaves tables and owner metadata intact. External systems may remain
authoritative where that is part of a plugin's domain.

Plugin state, ordinary configuration, activation, security/policy, temporary runtime
resources, and workbench/window state are distinct concerns, not one generic state
object. See the [product model](product-model.md) and
[profiles and configuration](profiles-and-configuration.md) for their ownership
and persistence boundaries.

### Command Tools participation

Command Tools owns its invocation-associated command headers, ordered decoded
stdout/stderr chunks, incremental capture/completeness, bounded model result,
historical reads, and live availability service. Its Inspection and console
presentations consume its generated own-backend contract, not a core transcript
repository or native Command codec. The Environment provider owns direct process
execution, decoding, bounded producer delivery, and cleanup. Core owns canonical
identities, storage/backing lifetime, exact-generation transport/authority, and
presentation hosting only.

The existing host-allocated tool-invocation identity is carried as opaque data in
native/remote tool context. It preserves Session/Run association before terminal
Run publication without manufacturing core records. Plugin append transactions
advance committed positions with their chunks; capture seals independently before
tool success, not inside the later generic Run transaction. Full transcript data
does not enter generic tool progress, RunJournal, or activity snapshots. Ordinary
bounded terminal evidence is not the authoritative transcript.

Plugin disablement does not delete these tables or activate a native reader.
History remains readable by a later compatible backend without Environment
materialization or old execution authority. Abandoned capturing rows are
interrupted/unconfirmed, not active or recoverable processes. Explicitly volatile
Projects use opt-in temporary on-disk plugin storage rather than unbounded memory;
that does not change their durability. Command schema, cursor/failure semantics,
and exact working limits belong to the [plugin map](../../plugins/command_tools/README.md).

### Chat participation

Chat is the concrete strategy consumer, not the owner of the shared service. Its
backend owns these version-1 tables:

| Table | Chat-owned meaning |
| --- | --- |
| `adele_chat_sessions(session_id, instructions, max_model_invocations, next_entry, draft_request)` | Configuration, entry counter, and current plain-text Draft Request, linked by foreign key to core Session identity. |
| `adele_chat_entries(session_id, sequence, entry_id, role, content, run_id)` | Ordered canonical user/assistant history, linked to the Chat Session row; nullable semantic Run association on user entries only. |

`ChatSessionStore` initializes or loads state only on first actual state access,
not at Project reopen or core Session creation. Defaults apply only to an
uninitialized Session, including an empty draft; existing history, configuration,
counter, and draft are validated and restored, never replaced on corruption.
The cache is generation-local; durable SQL state is the source of truth across
backend replacement. Missing Chat
does not prevent core graph restoration or cause its tables to be touched. A fresh
backend can later load that retained state through fresh resolution.

`run_id` is nullable and unique with `session_id`; assistant entries cannot carry
it. There is deliberately no foreign key to the core terminal Run table: Chat
associates the final history entry only when it is an unassociated user entry, after successful
execution materialization and before a terminal record exists. Association commits before
canonical and staged caches change. An association failure releases the newly
materialized execution and Session claim without publishing the association.
Unstarted, waiting, or unsuccessfully retained work can therefore have an
association without durable terminal evidence. The field identifies historical
activity; it is neither an opaque presentation handle nor execution authority.

User append commits its entry and counter together before cache mutation or
return, without changing the draft. Configuration commits both fields before
updating the cache and also preserves the draft. Draft replacement preserves exact
plain text, including whitespace. Draft submission rejects blank content and
atomically commits one user entry, the advanced counter, and an empty draft before
cache publication. These writes share the existing Session mutation/execution
claim. The full projected Session row, including draft, must fit the shared
bounded storage response so accepted state remains readable. Successful
assistant history remains staged until the existing host terminal `completed`
acknowledgement; Chat then commits SQL before merging into canonical cache and
returning. Execution or known storage failure does not publish staged history,
and there are no hidden retries. These are separate host Run and plugin-state
commit boundaries, not a distributed transaction: the host Run may already be
completed when Chat storage fails. Keep that terminal evidence honest and surface
the storage error rather than rolling back or rewriting the Run.

A lost transport acknowledgement after SQL commit leaves the caller uncertain;
do not infer rollback or silently retry. A fresh backend generation reloads the
durable source of truth. Direct `ChatSessionStore()` and `createProject` fixtures
are deliberately volatile. Remote Chat uses volatile state only after an explicit
`isDurableSession` false result, never because a lookup or storage call failed.
Live Run state, claims, approvals, and activity/native replay are not part of these
tables. Core-owned [terminal execution history](execution-model.md#terminal-execution-history)
is stored separately; Chat's association lets a fresh presentation request a
Session-validated read-only handle without rehydrating execution. See the
[Chat ownership map](../../plugins/chat_strategy/README.md)
for local entrypoints and [ADR 0034](../adr/0034-plugin-owned-relational-session-storage.md)
for the decision rationale.

## Authority remains host-owned

Plugin identity, extension registration, Capability ID, Session ID, Environment ID,
and an own-backend relationship do not themselves grant authority. Plugins may
supply domain knowledge, effect descriptions, or policy input; final allow/deny/ask
authorization remains host-owned.

Execution services remain appropriate to the current operation and exact
generation. Separately, an explicit
[generation-scoped infrastructure grant](contracts-and-capabilities.md#generation-scoped-infrastructure-access)
allows plugin storage outside execution, including snapshot and configuration
calls. It grants no orchestration, model, tool, Environment-facet, or filesystem
authority. A Session ID selects storage backing through the live product graph,
not execution authority. Revocation ends access, not effects already committed or
in flight. These are host-service boundaries, not an OS or malicious-plugin SQL
sandbox. [Operation-scoped host calls](contracts-and-capabilities.md#operation-scoped-host-calls)
and ADRs [0032](../adr/0032-remote-backend-extensions-use-operation-scoped-host-services.md)
and [0034](../adr/0034-plugin-owned-relational-session-storage.md) retain that distinction.

## Source map

| Concern | Primary anchors |
| --- | --- |
| Plugin identity / generic extension registry | [`packages/plugin_api/`](../../packages/plugin_api/) |
| Capability provider routing | [`packages/capabilities/`](../../packages/capabilities/) |
| Core-owned extension contracts without another domain owner | [`packages/core_extensions/`](../../packages/core_extensions/) |
| Domain extension points | [`packages/orchestration/`](../../packages/orchestration/), [`packages/model_tool/`](../../packages/model_tool/), [`packages/ui/`](../../packages/ui/) |
| Prepared/backend runtime | [`packages/plugin_runtime/`](../../packages/plugin_runtime/) |
| Shared backend process host | [`packages/plugin_backend_host/`](../../packages/plugin_backend_host/) |
| Shared plugin storage / app mediation | [`packages/project_storage/`](../../packages/project_storage/), [`app/lib/core/project_storage_host.dart`](../../app/lib/core/project_storage_host.dart) |
| Backend activation/composition | [`app/lib/core/application_plugin_bootstrap.dart`](../../app/lib/core/application_plugin_bootstrap.dart) |
| Frontend activation/composition | [`app/lib/frontend/application_frontend_bootstrap.dart`](../../app/lib/frontend/application_frontend_bootstrap.dart) |
| Source/prepared component boundaries | [`plugin-layout.md`](plugin-layout.md) |
| Concrete implementations | [`plugins/`](../../plugins/) |
