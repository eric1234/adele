# Durable Architectural Principles

These principles constrain future design. Several runtime boundaries are now
implemented by the maintained foundation, while statements about profiles,
packaging, preference policy, cross-platform behavior, and production support
remain intended architecture rather than validated behavior.

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
11. Events report facts that have occurred.
12. Plugins communicate through public contracts and capability discovery, not dependencies on other plugin implementations.
13. More than one plugin may provide the same action or service.
14. Capability resolution is one-to-many. Callers must not assume exactly one provider exists.
15. Callers can check whether a capability is available, enumerate compatible providers, invoke the deterministic default, and explicitly select another provider; richer preference policy remains future work.
16. ADELE owns preferred-provider resolution. A provider cannot unilaterally declare itself globally primary.
17. Provider selection may eventually consider user preferences, profile preferences, project/resource overrides, availability, suitability, and other host-owned policy. Exact matching remains future work.
18. ADELE core owns lifecycle, routing, persistence, agent execution mechanics, and host integration.
19. Provider-specific, tool-specific, UI-specific, and workflow-specific behavior generally belongs in plugins.
20. Plugin installation, plugin activation, plugin runtime instances, configured capability instances, and temporary runtime resources are distinct concepts.
21. Installing a plugin does not imply that it is globally enabled.
22. A plugin normally has one runtime instance per activation context.
23. A single plugin runtime may expose multiple named and configured capability instances, such as accounts, providers, clusters, connections, endpoints, or devices.
24. Multiple configured capability instances do not require multiple plugin installations or multiple copies of the plugin backend.
25. Temporary resources such as terminal sessions, browser sessions, documents, and active processes are runtime resources, not plugin instances or persistent provider configurations.
26. Profiles are sparse named composition layers rather than copies of complete application/plugin configuration.
27. One context may use an ordered stack of profiles; later profiles may override earlier explicit decisions where the relevant domain uses normal precedence semantics.
28. Profiles remain flat and explicit: profiles do not include/inherit other profiles, and the architecture should not impose an arbitrary small profile-stack limit.
29. Plugin versions belong to the installation/toolchain environment rather than becoming profile-specific cascade values.
30. Ordinary configuration may resolve through user, ordered-profile, project, and narrower subject-specific layers, but scopes are setting-dependent rather than universal.
31. Activation, ordinary configuration, provider preference, security/policy, workbench state, and runtime state remain separate domains even when they evaluate against related context.
32. Effective plugin activation is contextual. A disabled plugin's normal product/settings contributions should be absent from that context without deleting dormant persisted configuration.
33. Settings have stable technical owners/identities, but the normal Settings UI should be organized by product concepts rather than plugin ownership.
34. Custom plugin settings UI must edit through host-owned configuration/persistence semantics rather than establishing a parallel persistence system.
35. Credentials/secrets are not ordinary serialized configuration values; configuration should reference managed credentials or configured instances.
36. Shareable/project configuration should support stable human-readable serialization, while local operational state may use different persistence mechanisms.
37. Open windows own independent live workbench state. UI-state changes may update remembered defaults for future windows without rearranging already-open windows.
38. Persisted workbench updates should be fine-grained enough that unrelated changes from multiple windows do not overwrite one another through stale full-state snapshots.
39. Execution-sensitive work should use stable resolved configuration/context boundaries where live mutation would make behavior unpredictable or irreproducible.
40. The maintained runtime may use one implicit default development profile, but APIs must not prevent future ordered multi-profile support.
41. Pure-Dart implementation packages should remain usable and testable without Flutter.
42. The architecture must support Windows, macOS, and Linux desktop.
43. Public plugin-facing APIs are experimental during the proof-of-concept stages.
44. Prefer small, working boundaries over speculative abstraction.
45. Do not create packages solely for hypothetical reuse.
46. Do not claim that unproven runtime mechanisms have been validated.
