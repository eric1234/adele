# ADELE Architecture Overview

Role: Canonical architecture

This is the cross-system map, not a feature inventory or implementation ledger.
Read it after the [documentation map](../README.md), then follow the relevant
architecture and local source anchors below. Accepted architecture can be ahead
of implementation; source and tests establish what works today.

## ADELE at a glance

ADELE separates shared product semantics and host responsibilities from the
concrete behavior supplied by plugins:

| Domain | Responsibility |
| --- | --- |
| Desktop composition root (`app/`) | Compose host systems, desktop integration, and the workbench shell. |
| Public/plugin-facing architecture (`packages/`) | Define product identities, plugin/extension contracts, capabilities and transport contracts, Environment, orchestration, model tools/providers, and semantic UI roles. |
| Internal host/runtime (`packages/`) | Implement plugin hosting, generic agent execution mechanics, and build/preparation tooling behind public boundaries. |
| Plugins (`plugins/`) | Supply stock and reference providers, strategies, tools, integrations, and presentation using public contracts. |

Core owns shared invariants and generic infrastructure, not a required set of
stock implementations. A valid application may have zero installed plugins;
missing plugin functionality remains unavailable rather than being replaced by
built-in implementations. The [architectural principles](principles.md) and
[dependency rules](dependency-rules.md) constrain all of these domains.

<a id="core-product-domain-direction"></a>

## Product domain

```text
Project
    |
    v
   Task
    +-- Environment(s)
    +-- Session(s)
            |
            v
           Run(s)
```

These are relationships, not a storage or runtime-object hierarchy. The
[product model](product-model.md) is the canonical home for their semantics,
core/plugin ownership, Session-to-Environment authority, and the distinction
between stable identities and live bindings.

## Plugin and composition model

A source plugin may have shared contract, backend, and frontend components.
Backend and frontend availability is independent: a plugin can execute without
presentation, or contribute a frontend without a backend. An operation that needs
both still requires its exact live counterparts. Current hosting uses interpreted
Flutter frontends and native AOT backends in a shared child runtime; source
preparation is separate from runtime activation.

Core/runtime owns generic registries, lifecycle, routing, and hosting. Concrete
behavior belongs to plugins, which cooperate through deliberately public typed
interfaces rather than dependencies on another plugin's implementation. Production
`app/lib` does not link concrete plugin packages, including their contracts.
The temporary provider-selection identity exception is documented in
[application composition boundaries](dependency-rules.md#application-composition);
it does not permit plugin imports or implementation dependencies.

An **Extension Point** is broader than a **Capability**: callable Action/Service
provider resolution is one composition pattern, not the universal shape of UI,
strategy, or other contributions. Each point owns its selection, composition, and
failure semantics. Installation does not imply activation; live registrations
establish availability. New composition may discover changed registrations, but
captured executable bindings retain their exact generation and must not silently
migrate when it retires.

See the [plugin system](plugin-system.md),
[dependency rules](dependency-rules.md), [plugin layout](plugin-layout.md), and
[contracts and capabilities](contracts-and-capabilities.md) for the deeper rules.

## Agent execution

A strategy-bound Session supplies the context for a bounded Run. A Run is an
execution episode, not the Session's durable strategy state and not one model
invocation. It may contain multiple model/tool turns and interruptions.

A model invocation produces output, potentially including tool proposals. A
proposal is not tool execution or authorization: the host resolves and validates
it against captured tools and applies policy and any required approval before
execution. Provider-neutral mechanics keep invocation, proposal, execution,
outcome, and observation distinct from a provider's protocol details.

Strategy plugins own their Session semantics, input projection, and sequencing.
The public orchestration facade exposes the execution operations they need;
internal `agent_kernel` supplies generic mechanics without owning Chat history
or concrete provider/tool behavior. Plugins do not import the kernel.

See [agent execution semantics](execution-model.md) for the detailed
model, [orchestration](../../packages/orchestration/README.md) for the public
boundary, and [application execution](../../app/README.md#normal-chat-interaction)
for current Run composition and approval policy.

## Presentation and UI

UI presents and invokes functionality; displaying a control does not make it the
semantic owner of the operation. Plugin frontend presentation is dynamically
hosted with its own lifecycle. Semantic UI roles describe meaning rather than
physical center/right/bottom placement, allowing layout to change independently.
The host retains common execution, authority, approval, and lifecycle duties.

<a id="session-presentation"></a>

Session presentation is optional and does not own Session identity or strategy
state. Public [`adele_ui`](../../packages/ui/README.md) defines the implemented
semantic contracts; the [UI extension architecture](plugin-system.md#ui-and-presentation)
sets the broader boundary. [Product direction](../product/README.md) and the
[stock development UX](../product/development-workflow/README.md) describe intended experiences, not
fixed core layout or claims that every surface is implemented.

<a id="activity-inspection"></a>
<a id="model-native-activity-presentation"></a>

For activity presentation, follow the local maps for
[Inspection composition](../../app/README.md#activity-inspection) and
[model-native presentation](../../app/README.md#model-native-activity-presentation).
These views observe execution evidence; they neither define canonical strategy
state nor grant execution or approval authority.

## Configuration and persistence

Profiles and general configuration are accepted architecture but largely
unimplemented. Project identity/source, Tasks, and Environment semantic records
and provider-state snapshots use host-owned per-Project SQLite with provider-selected
backing. Environment materialization stays lazy/runtime-only; Sessions, Runs, Chat,
and general plugin state remain non-durable. The live product graph is still in
memory. Configuration, durable product state, plugin-owned state, live runtime
state, security policy, and
workbench state are separate concerns, not one generic settings object. See
[profiles and configuration](profiles-and-configuration.md),
[Project storage](product-model.md#project-storage) and
[product state boundary](product-model.md#durable-semantic-data-and-live-runtime-objects).

## Source map

| Concern | Primary anchors |
| --- | --- |
| Product identities and immutable values | [`packages/product/`](../../packages/product/) |
| Product lifecycle and Session/Environment authority | [`app/lib/core/product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `ProductLifecycleCoordinator` |
| Private Project storage | [`app/lib/core/project_database.dart`](../../app/lib/core/project_database.dart), `ProjectDatabase`, `MigrationCoordinator` |
| Extension registry and binding liveness | [`packages/plugin_api/`](../../packages/plugin_api/) |
| Core-owned Project selection/backing contracts | [`packages/core_extensions/`](../../packages/core_extensions/) |
| Capability routing and transport contracts | [`packages/capabilities/`](../../packages/capabilities/), [`packages/contract/`](../../packages/contract/) |
| Environment contract | [`packages/environment/`](../../packages/environment/) |
| Orchestration and Run hosting | [`packages/orchestration/`](../../packages/orchestration/), [`app/lib/core/orchestration_host.dart`](../../app/lib/core/orchestration_host.dart) |
| Model providers and tools | [`packages/model_provider/`](../../packages/model_provider/), [`packages/model_tool/`](../../packages/model_tool/) |
| Internal execution mechanics | [`packages/agent_kernel/`](../../packages/agent_kernel/) |
| Backend runtime | [`packages/plugin_runtime/`](../../packages/plugin_runtime/), [`packages/plugin_backend_host/`](../../packages/plugin_backend_host/) |
| Desktop composition | [`app/lib/core/adele_runtime.dart`](../../app/lib/core/adele_runtime.dart), `AdeleRuntime` |
| UI semantic contracts and frontend hosting | [`packages/ui/`](../../packages/ui/), [`app/lib/frontend/`](../../app/lib/frontend/) |
| Source preparation and generation | [`tools/adele.dart`](../../tools/adele.dart), [`packages/plugin_builder/`](../../packages/plugin_builder/), [`packages/contract_codegen/`](../../packages/contract_codegen/) |
| Stock and reference implementations | [`plugins/`](../../plugins/) |

## Where to read next

- **Who owns Project, Task, Environment, Session, or Run?** [Product model](product-model.md).
- **How is stock Local Directory Project selection and native picking hosted today?**
  See [Project opening](../../app/README.md#b1-project-opening) and the
  [Local Directory Project](../../plugins/local_directory_project/README.md).
- **Where should an extension live and what may it depend on?** [Plugin system](plugin-system.md) and [dependency rules](dependency-rules.md).
- **How do plugin preparation, routing, and authority work?** [Plugin layout](plugin-layout.md) and [contracts and capabilities](contracts-and-capabilities.md).
- **What must execution preserve?** [Agent execution semantics](execution-model.md), then the relevant orchestration/kernel/tool/provider README and tests.
- **What is intended rather than implemented?** [Profiles and configuration](profiles-and-configuration.md), [product direction](../product/README.md), and [technical direction](../direction/README.md), with their stated qualifications.
- **How do I work on the checkout?** [Development documentation](../development/README.md), [application README](../../app/README.md), and the relevant local package/plugin README.
