# Durable Architectural Principles

These principles constrain future design. Several runtime boundaries are now
implemented by the maintained foundation, while statements about profiles,
general extension points, product-domain lifecycle, packaging, preference
policy, cross-platform behavior, and production support remain intended
architecture rather than validated behavior.

1. Plugin source is the canonical distribution format.
2. Plugin backend source compiles to native Dart AOT in the development pipeline.
3. Plugin backends execute outside the main Flutter isolate in separately loaded isolate groups in the shared backend host.
4. Plugin frontend source compiles to eval bytecode and renders within the main Flutter application in the maintained reference path.
5. Plugin frontend and backend packages may share typed contract source.
6. Generated code hides ports, serialization, request IDs, subscriptions, cancellation, and transport details.
7. Values crossing runtime boundaries are reconstructed values, not shared object identities.
8. Contract values should normally be immutable snapshots.
9. Actions are brokered one-shot request/response operations.
10. Services are sustained typed capabilities.
11. Events report facts that have occurred; Event consumers do not retroactively change whether the fact occurred.
12. Plugins communicate through public typed interfaces and runtime discovery, not dependencies on other plugin implementations.
13. A plugin may define public extension APIs for concepts it owns; depending on such an API is distinct from requiring one specific implementation plugin to be active.
14. More than one plugin may provide the same action or service.
15. Capability resolution is one-to-many. Callers must not assume exactly one provider exists.
16. Callers can check whether a capability is available, enumerate compatible providers, invoke the deterministic default, and explicitly select another provider; richer preference policy remains future work.
17. ADELE owns preferred-provider resolution. A provider cannot unilaterally declare itself globally primary.
18. Provider selection may eventually consider user preferences, profile preferences, project/resource overrides, availability, suitability, and other host-owned policy. Exact matching remains future work.
19. Extension is recursive: core may define typed extension points, and plugins may define more-specific typed extension points consumed by other plugins.
20. Runtime composition should prefer zero/one/many compatible interface discovery over hidden plugin-activation dependency chains.
21. Operation-modifying integration should use structured typed composition rather than arbitrary mutation of opaque host objects.
22. Extension-point ordering, composition, applicability, and failure semantics are domain-specific; numeric priority is preferred over direct before/after coupling where ordering is needed.
23. Future composition may react to registrations appearing/disappearing, while already-resolved execution-sensitive operations retain stable exact bindings.
24. ADELE core owns lifecycle, routing, persistence facilities, agent execution mechanics, host integration, final authorization, and stable product identities that unrelated plugins must share.
25. Project, Task, Session, Run, and Environment are core domain concepts; owning the identities does not imply core provides most concrete behavior.
26. Project is not intrinsically a local directory. Concrete Project selection/association belongs to replaceable providers/plugins.
27. Task is the ADELE-owned durable unit of user intent; plugins may attach behavior/state without redefining Task identity.
28. Session is permanently bound to one orchestration strategy; strategy-specific state defines the Session's semantic contents rather than core assuming every Session is chat history.
29. Parent/child Sessions represent delegated agent work; a separate Subtask concept should not be introduced without concrete need.
30. Environment is initially the practical filesystem/source + process context for Task work. ADELE should not claim stronger isolation guarantees than the selected Environment provider actually supplies.
31. A separate first-class Workspace concept is not required architecture unless future concrete needs demonstrate an independent semantic identity.
32. Provider-specific, tool-specific, UI-specific, workflow-specific, and integration-specific behavior generally belongs in plugins.
33. Plugin-facing UI extension points should describe semantic roles rather than current physical placement so workbench layout can evolve independently.
34. UI presents and invokes domain behavior; rendering a control does not make that UI the semantic owner of the operation.
35. Core owns application Command registration, Command Palette/search, keybinding resolution, and user rebinding; plugins provide Commands and suggested bindings.
36. Plugin installation, plugin activation, plugin runtime instances, configured capability instances, and temporary runtime resources are distinct concepts.
37. Installing a plugin does not imply that it is globally enabled.
38. A plugin normally has one runtime instance per activation context.
39. A single plugin runtime may expose multiple named and configured capability instances, such as accounts, providers, clusters, connections, endpoints, or devices.
40. Multiple configured capability instances do not require multiple plugin installations or multiple copies of the plugin backend.
41. Temporary resources such as terminal sessions, browser sessions, documents, and active processes are runtime resources, not plugin instances or persistent provider configurations.
42. Profiles are sparse named composition layers rather than copies of complete application/plugin configuration.
43. One context may use an ordered stack of profiles; later profiles may override earlier explicit decisions where the relevant domain uses normal precedence semantics.
44. Profiles remain flat and explicit: profiles do not include/inherit other profiles, and the architecture should not impose an arbitrary small profile-stack limit.
45. Plugin versions belong to the installation/toolchain environment rather than becoming profile-specific cascade values.
46. Ordinary configuration may resolve through user, ordered-profile, project, and narrower subject-specific layers, but scopes are setting-dependent rather than universal.
47. Activation, ordinary configuration, provider preference, security/policy, workbench state, and runtime state remain separate domains even when they evaluate against related context.
48. Effective plugin activation is contextual. A disabled plugin's normal product/settings contributions should be absent from that context without deleting dormant persisted configuration.
49. Settings have stable technical owners/identities, but the normal Settings UI should be organized by product concepts rather than plugin ownership.
50. Custom plugin settings UI must edit through host-owned configuration/persistence semantics rather than establishing a parallel persistence system.
51. Credentials/secrets are not ordinary serialized configuration values; configuration should reference managed credentials or configured instances.
52. Shareable/project configuration should support stable human-readable serialization, while local operational state may use different persistence mechanisms.
53. ADELE provides lifecycle-aware persistence facilities for ordinary plugin-owned state, while domain-native external systems may remain authoritative where that is semantically part of the feature.
54. Open windows own independent live workbench state. UI-state changes may update remembered defaults for future windows without rearranging already-open windows.
55. Persisted workbench updates should be fine-grained enough that unrelated changes from multiple windows do not overwrite one another through stale full-state snapshots.
56. Execution-sensitive work should use stable resolved configuration/context boundaries where live mutation would make behavior unpredictable or irreproducible.
57. The maintained runtime may use one implicit default development profile, but APIs must not prevent future ordered multi-profile support.
58. Pure-Dart implementation packages should remain usable and testable without Flutter.
59. The architecture must support Windows, macOS, and Linux desktop.
60. Public plugin-facing APIs are experimental during the proof-of-concept stages.
61. Prefer small, working boundaries over speculative abstraction.
62. Do not create packages solely for hypothetical reuse.
63. Do not implement a generic extension framework merely because the long-term direction names possible future extension points; introduce the smallest concrete boundary required by current work.
64. Do not claim that unproven runtime mechanisms have been validated.
