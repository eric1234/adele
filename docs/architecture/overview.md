# ADELE Architecture Overview

## Status

ADELE's maintained Linux x64 foundation proves source compilation, generated unary and server-streaming/cancellation transport, interpreted frontend execution, active capability routing, configured provider contexts, and the Phase IV/V-A source-inspection agent vertical. It includes the real OpenAI `ModelProvider`, generation-bound configured provider contexts, an explicitly experimental ChatGPT configured instance, provisional Project/Task/Environment and Session authority, generic extension/model-tool composition, a Git Environment provider, and independent stock Filesystem Tools and Search Tools plugins that own Session-authorized `read_file` and `search`.

Phase V-A is complete: deterministic real-model integration now crosses provisional app orchestration, generic model-tool extension composition, plugin-owned Search, Session-authorized Environment access, plugin-owned Read File, maintained ADELE source, and model continuation. Search is bounded native Dart traversal over authorized Environment directory/file reads, not an Environment provider method. These proofs do **not** yet implement ADELE's complete product/domain model, production orchestration-strategy registration/binding, a plugin-owned Chat strategy, or the general recursive extension system described by the current architecture.

The following remain largely or entirely unimplemented:

- Project/Task/Session/Environment product persistence and lifecycle;
- production orchestration-strategy registration;
- parent/child Session lifecycle;
- plugin-defined extension points beyond the initial registration/model-tool slice;
- production plugin-facing UI composition;
- application Command/Command Palette/keybinding infrastructure;
- profile-aware provider preference and general configuration services;
- additional Environment providers, Environment process execution, and mutable source tooling;
- the expected stock plugin topology;
- cross-platform release, packaging, and sandboxing.

Public plugin-facing APIs remain experimental.

## System shape

ADELE has one Flutter desktop application, `adele_desktop`, under `app/`. The application owns the current shell, theme, private widgets, desktop integration, and composition of host systems. It is a composition root rather than the primary home of core logic.

Host implementations are split into small pure-Dart packages where Flutter is not required:

| Package | Maintained/planned responsibility |
| --- | --- |
| `plugin_runtime` | Plugin lifecycle/runtime coordination, backend connections, and active capability routing adapters |
| `plugin_builder` | Source resolution, contract checks/generation coordination, backend/frontend builds, diagnostics, provenance, and caching |
| `plugin_backend_host` | Shared child-process entrypoint and one external AOT isolate group per active plugin backend |
| `agent_kernel` | Provider-neutral Run/model/tool semantics, interruptions, policy boundary, structured outcomes, and typed execution observation |

These are internal packages. Plugins must not import them.

The source-plugin runtime shape is:

```text
Flutter desktop host (main Flutter isolate)
  |
  +-- interpreted frontend from flutter_eval/dart_eval bytecode
  |
  +-- generated typed asynchronous transport
  |
  +-- one shared child dartaotruntime process
        |
        +-- one native Dart AOT isolate group per active plugin backend
```

This shape is proven only on Linux x64 Flutter profile mode. Direct external AOT loading inside stock Flutter failed. Backend process/isolate separation is not a security sandbox.

Contract source can be shared by plugin frontend/backend packages. Generated transport hides ports, serialization, request IDs, stream protocol, cancellation, dispatch, and structured transport errors behind typed proxies/dispatchers. Values crossing runtime boundaries are reconstructed rather than shared by identity and should normally be immutable snapshots.

## Recursive plugin extension direction

ADELE's accepted long-term model is recursively extensible:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

The broad rules are recorded in [`plugin-extension-model.md`](plugin-extension-model.md) and ADR 0030.

Core owns durable shared identities/invariants and host infrastructure. Plugins provide much of the concrete product behavior. Plugins may publish deliberately public extension APIs for concepts they own, and other plugins may implement those interfaces without depending on one specific implementation plugin being active.

Runtime composition should prefer typed interface discovery over hidden activation dependencies. Zero/one/many compatible registrations may be valid depending on the extension contract.

Capabilities remain the implemented callable-provider mechanism for Actions and Services. Events are read-only fact notifications. Other extension points may collect UI fragments or structured operation contributions without being callable capabilities.

Future extension discovery may react live to registrations appearing/disappearing, while already-resolved execution-sensitive operations continue to retain exact generation bindings.

The general extension-point runtime, plugin-defined UI extension APIs, generic Event subscription, Commands/keybindings, and multi-plugin inference composition are direction rather than implemented production systems.

## Contracts, capabilities, and providers

Contracts answer how typed communication crosses a runtime boundary. Capabilities answer which compatible provider handles a callable semantic request. Extension points are the broader architecture for typed plugin participation.

Implemented capability resolution is one-to-many. Several plugins may provide the same Action/Service, and one plugin runtime may expose multiple configured instances. The host-owned active registry implements provider discovery/enumeration, deterministic rank-based default resolution, explicit selection, exact-major matching, and exact generation-bound routing.

The rank-based default is a deterministic development fallback, not the final preference system. ADELE owns preferred-provider selection; future profile/project/user policy may select contextual defaults and expose explicit alternatives.

Configured capability instances such as `OpenAI Work` and `OpenAI Personal` are distinct from plugin installations/runtime instances. Temporary documents, terminals, browser sessions, and processes are runtime resources rather than configured providers.

See [`contracts-and-capabilities.md`](contracts-and-capabilities.md).

## Core product-domain direction

ADR 0031 accepts the following long-term shared domain identities:

```text
Project
└── Task
    ├── Environment(s)
    └── Session(s)
        ├── Run(s)
        └── child Session(s)
```

### Project

Project is an abstract core identity/lifecycle concept, not intrinsically a local directory. The expected stock development composition uses a local-directory `ProjectSelector`; future selectors may use recent projects, databases/catalogs, or remote/cloud systems.

### Task

Task is the durable ADELE-owned unit of user intent. Plugins may attach state and behavior without owning Task identity. Task workflow category/status remains user/domain-owned rather than being inferred automatically from execution success.

### Environment

Environment is initially the practical filesystem/source + process context used by Task work. A Git worktree-backed Environment may isolate source changes without isolating ports/databases/caches/etc.; Docker or remote providers may have different properties. ADELE does not claim stronger isolation than the selected provider actually supplies.

A separate first-class Workspace concept is not currently required architecture. It may return later if concrete requirements demonstrate an independent semantic identity.

A Task normally has one primary Environment and may own additional Environments for delegated child Session work.

### Session and Run

Session is a core identity/lifecycle container permanently bound to one orchestration strategy. Core does not assume every Session is chat history; strategy-specific state defines the Session's semantic contents.

Run remains the core unit of execution inside a Session. The maintained development proof currently uses a chat-shaped Session representation and bounded development strategy; that is implemented evidence, not the long-term universal Session definition.

A Session may create child Sessions for delegated work. Child Sessions may share an Environment or use another Task-associated Environment and are primarily surfaced through the parent Session/orchestration experience.

## Agent execution

`agent_kernel` remains an internal provider-neutral execution substrate. Concrete models, tools, editors, SCM integrations, terminals, orchestration strategies, and presentation belong outside the kernel.

The maintained `DevelopmentToolLoopStrategy` is a bounded development-only algorithm, not the definition of Run or a general workflow system.

The kernel model boundary is streaming-shaped. The common ModelProvider transport supports generated streaming/cancellation, ordered semantic input/output, live observations, terminal settlement, and provider-native item metadata. Materialized model/tool bindings remain exact-generation bound.

Tool availability, materialization, policy, optional approval interruption, execution, progress, structured outcome, and effect certainty remain distinct.

Future inference preparation should be structured composition rather than arbitrary request mutation. Agent policy, model routing, orchestration/history, context, tool availability, and other plugins should contribute typed material into provider-neutral buckets; resolution produces a stable invocation snapshot.

See [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md).

## Expected stock development composition

The default development UX is expected to be produced by a stock plugin/configuration set rather than by hard-coded ADELE core behavior. Directional stock responsibilities include:

- Local Directory Project Selector;
- Task Browser;
- Git/Worktree Environment provider;
- Agent Interaction + Chat strategy;
- Agent Configuration/Policy;
- Model Routing/Control;
- Context Monitoring/Compaction;
- Accounting/Usage/Quota;
- Filesystem/Search/Command/TODO/Plan tools;
- Diff/Review;
- Internal Source Editor;
- Console/Terminal;
- OpenAI provider.

The detailed, deliberately speculative decomposition is in [`stock-plugin-direction.md`](stock-plugin-direction.md). The UX manifestation is in [`../mockups/README.md`](../mockups/README.md).

These documents are not implementation claims. The current app shell remains minimal and most listed plugins do not exist yet.

## Profiles, configuration, commands, and workbench state

Profiles are accepted as sparse named composition layers. One context may eventually use an ordered stack such as `Developer + Work`. They may contribute activation decisions, ordinary configuration overrides, provider availability, and provider preferences.

The maintained runtime still uses one implicit development profile. General profile/configuration persistence, UI, and provider preference resolution are not implemented.

Activation, ordinary configuration, provider preference, security/policy, workbench state, configured capability instances, and runtime state remain distinct domains.

An effectively disabled plugin should remove its normal product/settings surface without deleting dormant persisted configuration.

Core is expected to own application Commands, Command Palette/search, keybinding resolution, plugin-suggested defaults, and user rebinding. Those systems are architectural direction and are not yet a maintained production subsystem.

Workbench extension APIs should be semantic rather than physical. Concepts such as Main Content, Session Status, Inspection, Navigation, and Stream/Console presentation should remain stable if the physical layout moves or becomes configurable.

See [`profiles-and-configuration.md`](profiles-and-configuration.md) and [`plugin-extension-model.md`](plugin-extension-model.md).

## Maintained self-inspection vertical

`dev.adele.openai` implements the public OpenAI API-key Responses HTTP/SSE route with `store:false` canonical ordered replay. The same plugin generation exposes API-key and ChatGPT configured instances through separate generation-bound contexts. The ChatGPT subscription-backed route remains explicitly experimental interoperability evidence.

The stock Search Tools plugin contributes literal `search` and composes only the Session-authorized Environment filesystem's `readDirectory` and `readFile`; Filesystem Tools independently contributes `read_file`. The OpenAI API-key and experimental ChatGPT source-coding consumers use these plugin-contributed tools rather than the retired Phase IV DevelopmentSource capability.

Deterministic integration uses the real shared AOT host, OpenAI plugin, Git Environment provider, Project/Task/Environment lifecycle, Session authority, generic extension/model-tool composition, stock tools, and development strategy. Only remote model responses come from a local fake Responses endpoint. It proves recursive source discovery, model-visible Search-to-Read path flow, reading, and model continuation. Separate deterministic coverage proves Search-tool and Environment-provider replacement generations produce fresh tools while old tools remain stale. Opt-in live API-key and experimental ChatGPT source-coding smokes have also completed successfully through the same Environment tool topology.

This proves self-inspection, not the final Environment/source mutation model and not full self-hosting.

## Remaining runtime validation

| Risk | Current status |
| --- | --- |
| Local backend AOT compilation | Proven with the temporary matched SDK. |
| Shared process-host loading | Proven on Linux x64 profile mode. |
| Eval compilation/rendering | Proven with pinned eval dependencies and documented workarounds. |
| Generated typed communication | Proven across maintained unary and streaming plugin contracts. |
| Typed streaming/cancellation | Proven through generated transport and ModelProvider with one-item flow control. |
| Active capability/configuration routing | Proven for deterministic discovery, explicit selection, exact generations, and separate OpenAI configuration contexts. |
| Real OpenAI provider | Deterministic HTTP/SSE/shared-AOT integration proven; live network tests remain opt-in. |
| Experimental ChatGPT configured instance | Auth/routing tests and a successful migrated opt-in source-coding smoke provide interoperability evidence only. |
| Model-to-source continuation | Proven through Session-authorized Git Environment `search`/`read_file` composition for deterministic OpenAI integration and opt-in live API-key/experimental ChatGPT evidence. |
| Rebuild/reload | Proven for three cycles without orphan host processes. |
| General recursive extension system | Accepted architecture; not implemented. |
| Project/Task/Environment product model | Initial values, Task establishment, Git Environment materialization/restoration, and Session-authorized reads proven; persistence and complete lifecycle unimplemented. |
| Production orchestration/UI/Commands | Directional; not implemented. |
| Cross-platform/release | Unproven on Windows, macOS, and release mode. |
| Packaging/sandboxing | Unproven; process isolation is not a sandbox. |

The long-term goal remains for ADELE to develop ADELE itself. That goal does not change the preference for small working boundaries over speculative framework implementation.
