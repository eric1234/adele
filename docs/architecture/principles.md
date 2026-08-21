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
17. Provider selection may eventually consider user preferences, profile preferences, workspace overrides, resource type, media type, availability, and suitability. Exact precedence is deferred.
18. ADELE core owns lifecycle, routing, persistence, agent execution mechanics, and host integration.
19. Provider-specific, tool-specific, UI-specific, and workflow-specific behavior generally belongs in plugins.
20. Plugin installation, plugin activation, plugin runtime instances, configured capability instances, and temporary runtime resources are distinct concepts.
21. Installing a plugin does not imply that it is globally enabled.
22. A plugin normally has one runtime instance per activation context.
23. A single plugin runtime may expose multiple named and configured capability instances, such as accounts, providers, clusters, connections, endpoints, or devices.
24. Multiple configured capability instances do not require multiple plugin installations or multiple copies of the plugin backend.
25. Temporary resources such as terminal sessions, browser sessions, documents, and active processes are runtime resources, not plugin instances or persistent provider configurations.
26. Plugin configuration is shared across profiles by default.
27. A profile may optionally supply configuration overrides when the same plugin needs different behavior in different profiles.
28. Profiles should not duplicate a plugin's complete configuration unless necessary.
29. Effective plugin configuration is conceptually shared configuration plus optional profile overrides.
30. Compiled plugin artifacts should normally be reusable across profiles when their source and build context are identical.
31. The maintained runtime may use one implicit default development profile, but APIs must not prevent future multiple-profile support.
32. Pure-Dart implementation packages should remain usable and testable without Flutter.
33. The architecture must support Windows, macOS, and Linux desktop.
34. Public plugin-facing APIs are experimental during the proof-of-concept stages.
35. Prefer small, working boundaries over speculative abstraction.
36. Do not create packages solely for hypothetical reuse.
37. Do not claim that unproven runtime mechanisms have been validated.
