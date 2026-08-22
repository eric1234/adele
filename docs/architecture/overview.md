# ADELE Architecture Overview

## Status

ADELE's maintained Linux x64 foundation proves source compilation, generated
unary and server-streaming/cancellation transport, interpreted frontend
execution, active capability routing, and the complete Phase IV execution and
source-inspection vertical. It includes the real OpenAI ModelProvider,
generation-bound configured provider contexts, an explicitly experimental
ChatGPT configured instance, and a bounded read-only DevelopmentSource
capability. Together these prove model invocation, ADELE source search/read
through generation-bound tools, model continuation, and a final answer.

Plugin-facing APIs remain experimental. Plugin discovery, packaging, profiles,
sandboxing, final Workspace semantics, and cross-platform release behavior are
not implemented or proven.

## System shape

ADELE has one Flutter desktop application, `adele_desktop`, under `app/`. The
application owns the shell, theme, private widgets, desktop integration, and
composition of host systems. It is a composition root rather than the primary
home of core logic.

Host implementations are split into small pure-Dart packages where Flutter is
not required:

| Package | Planned responsibility |
| --- | --- |
| `plugin_runtime` | Plugin discovery, lifecycle, artifact selection, runtime coordination, and failure reporting |
| `plugin_builder` | Source resolution, contract generation coordination, backend and frontend builds, diagnostics, provenance, and caching |
| `plugin_backend_host` | Shared child-process entrypoint and one external AOT isolate group per active plugin |
| `agent_kernel` | Provider-neutral Session/Run boundaries, context/model/tool semantics, interruptions, structured outcomes, and typed execution observation |

These are internal packages. Plugins must not import them.

The proposed plugin system uses source as its canonical distribution format. A
source plugin is split into contract, backend, and frontend Dart packages. The
intended dual-runtime model is:

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

This shape is proven only on Linux x64 Flutter profile mode. Direct external AOT
loading inside stock Flutter failed. Backend isolation is not a claim of
security sandboxing.

Contract source can be shared by the frontend and backend. Generated transport
hides ports, serialization, request IDs, subscriptions,
cancellation, dispatch, and structured transport errors behind typed async
proxies and dispatchers. Values crossing a runtime boundary are reconstructed
values, not shared object identities, and should normally be immutable
snapshots.

## Capabilities and providers

Contracts describe how typed communication occurs. Capabilities describe what
can be requested and which compatible provider may handle it:

| Concept | Meaning |
| --- | --- |
| Action | Brokered one-shot request/response operation |
| Service | Sustained typed capability |
| Event | Fact that has occurred |

Capability resolution is one-to-many. Several plugins may provide the same
action or service, and one plugin runtime may expose multiple named,
configured instances of a capability. The host-owned active registry implements
provider discovery/enumeration, deterministic default resolution, explicit
selection, exact-major matching, and exact generation-bound routing. One plugin
generation may route several providers through separate configuration contexts.
Persistent preferences, profile-aware routing, richer compatibility
negotiation, and dynamic suitability policy remain deferred. ADELE, not a
provider, owns preferred-provider resolution.

The intended runtime model is one plugin runtime per activation context;
activation-context lifecycle is not implemented. The maintained runtime proves
that one plugin generation can manage multiple configured accounts, providers, clusters,
connections, endpoints, or devices without requiring another plugin install
or backend copy. Temporary resources such as documents, terminal sessions,
browser sessions, and processes are runtime resources, not configured
capability instances or plugin runtimes.

## Profiles, configuration, and agents

ADELE profiles are planned sparse named composition layers, not complete copies
of application or plugin state. One window/context may eventually use an
ordered stack such as `Developer + Work` or `Developer + Personal`; profiles may
contribute plugin activation decisions, ordinary configuration overrides,
provider availability, and provider preferences. They are not implemented, and
the maintained development runtime still uses one implicit development profile.

Ordinary configuration is intended to resolve through eligible layers such as
user/all-profiles configuration, the ordered active profile stack, project
configuration, and narrower resource-specific layers when a setting supports
them. Activation, ordinary configuration, provider preference, security/policy,
workbench state, configured capability instances, and runtime resources remain
distinct domains rather than one universal last-writer-wins plugin state.

An effectively disabled plugin should remove its normal product and settings
surface from that context without deleting dormant persisted configuration.
Workbench presentation state is likewise separate from ordinary configuration:
open windows keep independent live layout state while local remembered state can
seed subsequently opened windows.

The intended direction, including settings UX, persistence, profile stacking,
window behavior, and deferred decisions, is recorded in
[`profiles-and-configuration.md`](profiles-and-configuration.md).

`agent_kernel` is a provider-neutral execution substrate. Concrete
models, tools, editors, Git integrations, terminals, UI, and specialized agent
workflows belong in plugins rather than in the kernel.

Phase IV uses a bounded development-only application strategy and the common
ModelProvider capability to prove generation-safe model/tool/model cycles
through real AOT providers. The strategy is not the definition of Run or a
general Workflow system. The kernel model port is stream-shaped, and the
application adapter consumes providers through generated typed streaming while
preserving exact generation binding and consumer cancellation. Live text
observations remain separate from completed output, semantic terminal
settlement is explicit, and opaque ordered item metadata survives tool
continuation.

`dev.adele.openai` implements the public OpenAI API-key Responses HTTP/SSE route
with `store:false` canonical ordered replay. The same plugin generation exposes
API-key and ChatGPT configured instances through separate configuration
contexts. The ChatGPT subscription-backed route is explicitly experimental:
its successful live smoke is positive interoperability evidence, not a
documented or stable OpenAI third-party integration contract.

The provisional DevelopmentSource plugin exposes bounded read-only source
search and reads under one configured root. Application composition projects
that sustained capability into model tools rather than treating each tool as a
separate capability. Deterministic integration uses the real shared AOT host,
OpenAI and DevelopmentSource plugins, capability registry, adapters, tools, and
development strategy against the ADELE checkout; only remote model responses
come from a local fake Responses endpoint. The opt-in live ChatGPT
source-coding smoke has also run successfully. This is the first real
self-inspection coding vertical, not self-modification or final Workspace
behavior.

The long-term self-hosting goal is for ADELE to develop ADELE itself. That goal
does not change the rule to prefer small, working boundaries and avoid
speculative APIs.

## Remaining runtime validation

Linux x64 Flutter profile mode proves the core vertical path. Remaining work is:

| Risk | Current status |
| --- | --- |
| Local backend AOT compilation | Proven with the temporary matched SDK. |
| Shared process-host loading | Proven on Linux x64 profile mode. |
| Eval compilation and rendering | Proven with pinned eval dependencies and documented workarounds. |
| Generated typed communication | Proven across maintained unary and streaming plugin contracts. |
| Typed server-streaming and cancellation | Proven through generated transport and the common ModelProvider path with one-item flow control. |
| Active capability/configuration routing | Proven for deterministic discovery, explicit selection, exact generations, and separate OpenAI configuration contexts. |
| Real OpenAI provider | Deterministic HTTP/SSE and shared-AOT integration are proven; live network tests remain explicit opt-ins. |
| Experimental ChatGPT configured instance | Auth/routing tests and a successful opt-in source-coding smoke provide interoperability evidence, not a stable third-party contract. |
| Model-to-source continuation | Proven against the ADELE checkout through the real read-only DevelopmentSource capability path. |
| Rebuild and reload | Proven for three cycles without orphan host processes. |
| Cross-platform and release behavior | Unproven on Windows, macOS, and release mode. |
| Packaging and sandboxing | Unproven; process isolation is not a sandbox. |

## Undefined workspace semantics

The shell text `No workspace is open` is only a static shell status. It does
not define workspace identity, ownership, roots, persistence, selection, or
lifecycle. `workspace`, `project`, `environment`, and `profile` are not
interchangeable, and workspace semantics remain intentionally undefined.
