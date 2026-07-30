# ADELE Architecture Overview

## Status

ADELE's Phase I foundation proves source compilation, typed transport, and
interpreted frontend execution on Linux x64 Flutter profile mode. It does not
implement plugin discovery, packaging, capability routing, profiles, sandboxing,
or agent execution. Plugin-facing APIs remain experimental.

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
| `agent_kernel` | Provider-neutral sessions, runs, model/tool coordination, approval, cancellation, persistence, replay, and execution events |

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

Contract source can be shared by the frontend and backend. Future generation
is intended to hide ports, serialization, request IDs, subscriptions,
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
configured instances of a capability. ADELE, not a provider, owns preferred
provider resolution. Availability queries, provider enumeration, preference
matching, explicit selection, and routing are future requirements only.

The default runtime model is one plugin runtime per activation context. That
runtime can manage multiple configured accounts, providers, clusters,
connections, endpoints, or devices without requiring another plugin install
or backend copy. Temporary resources such as documents, terminal sessions,
browser sessions, and processes are runtime resources, not configured
capability instances or plugin runtimes.

## Profiles and agents

ADELE profiles are planned named collections of plugin activation, optional
configuration overrides, and provider preferences. They are not implemented.
Configuration is shared across profiles by default; effective configuration is
conceptually shared plugin configuration plus optional profile overrides.
The maintained development runtime uses one implicit development profile
without introducing profile-management APIs.

The future `agent_kernel` is a provider-neutral execution substrate. Concrete
models, tools, editors, Git integrations, terminals, UI, and specialized agent
workflows belong in plugins rather than in the kernel.

The long-term self-hosting goal is for ADELE to develop ADELE itself. That goal
does not change the Phase 0 rule to prefer small, working boundaries and avoid
speculative APIs.

## Remaining runtime validation

Linux x64 Flutter profile mode proves the core vertical path. Remaining work is:

| Risk | Current status |
| --- | --- |
| Local backend AOT compilation | Proven with the temporary matched SDK. |
| Shared process-host loading | Proven on Linux x64 profile mode. |
| Eval compilation and rendering | Proven with pinned eval dependencies and documented workarounds. |
| Typed request/response communication | Proven manually for the workspace reference fixture. |
| Rebuild and reload | Proven for three cycles without orphan host processes. |
| Cross-platform and release behavior | Unproven on Windows, macOS, and release mode. |
| Packaging and sandboxing | Unproven; process isolation is not a sandbox. |

## Undefined workspace semantics

The shell text `No workspace is open` is only a static Phase 0 status. It does
not define workspace identity, ownership, roots, persistence, selection, or
lifecycle. `workspace`, `project`, `environment`, and `profile` are not
interchangeable, and workspace semantics remain intentionally undefined.
