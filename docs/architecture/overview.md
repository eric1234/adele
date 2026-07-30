# ADELE Architecture Overview

## Status

ADELE Phase 1 preserves the Phase 0 boundaries and records a partial
dual-runtime experiment. Source compilation, typed transport, EVC persistence,
and interpreted Flutter rendering were proven. Same-process backend loading
failed in Flutter 3.38.10 Linux profile mode. A shared child Dart backend-host
subsequently completed the Linux profile walking skeleton while keeping one
isolate group per active plugin. That architecture remains proposed pending
broader validation. Discovery, capability routing, profiles, and agent execution
remain unimplemented.

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
| `plugin_backend_host` | Shared process entrypoint and per-plugin external AOT isolate ownership |
| `plugin_builder` | Source resolution, contract generation coordination, backend and frontend builds, diagnostics, provenance, and caching |
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
  +-- native Dart AOT backend outside the main Flutter isolate
```

The interpreted frontend and locally compiled AOT backend are proposed Phase 1
mechanisms, not working or validated Phase 0 behavior. Backend isolation is
expected to use a separately loaded isolate group if the toolchain and
platforms support it, but the launcher and fallback design are intentionally
uncommitted.

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
Phase 0 and the initial Phase 1 proof use one implicit development profile
without introducing profile-management APIs.

The future `agent_kernel` is a provider-neutral execution substrate. Concrete
models, tools, editors, Git integrations, terminals, UI, and specialized agent
workflows belong in plugins rather than in the kernel.

The long-term self-hosting goal is for ADELE to develop ADELE itself. That goal
does not change the Phase 0 rule to prefer small, working boundaries and avoid
speculative APIs.

## Phase 1 risk register

Every dual-runtime item below is unproven and must be validated end to end:

| Risk | What Phase 1 must establish |
| --- | --- |
| Local backend AOT compilation | Plugin backend source can be compiled locally and reproducibly with the pinned SDK. |
| Loading the AOT backend | A compiled backend can be launched outside the main Flutter isolate in profile or release operation. |
| Eval frontend compilation | Supported frontend source can be compiled into compatible `dart_eval`/`flutter_eval` bytecode. |
| Rendering interpreted Flutter UI | The host can safely render and lifecycle-manage interpreted plugin widgets. |
| Frontend/backend communication | Typed async requests, responses, streams, cancellation, and structured errors work across the chosen boundary. |
| Rebuild and reload | An active development plugin can stop, rebuild, reconnect, and reload without stale artifacts or leaked resources. |
| Cross-platform behavior | Compilation, loading, communication, and reload behave acceptably on Windows, macOS, and Linux. |

## Undefined workspace semantics

The shell text `No workspace is open` is only a static Phase 0 status. It does
not define workspace identity, ownership, roots, persistence, selection, or
lifecycle. `workspace`, `project`, `environment`, and `profile` are not
interchangeable, and workspace semantics remain intentionally undefined.
