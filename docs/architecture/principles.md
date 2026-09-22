# Durable Architectural Principles

Role: Canonical architecture

These cross-system design rules constrain subsystem evolution. Detailed semantics
belong to the canonical owners linked below; source and tests establish current
behavior. Accepted constraints are not claims that every mechanism is implemented
or validated.

## Core and plugin ownership

1. Core owns shared identities, invariants, and generic host infrastructure needed
   by unrelated plugins, not a required set of stock implementations.
2. Concrete provider, tool, strategy, workflow, integration, and presentation
   behavior normally belongs to plugins.
3. Plugins cooperate through deliberately public typed interfaces, not dependencies
   on implementation packages. An API dependency does not require one particular
   implementation to be active.
4. A valid ADELE application can exist without stock plugins. Missing functionality
   remains unavailable rather than acquiring hidden core fallbacks or silently
   activating another implementation.

## Composition and binding

5. Extension Point is the broad composition concept; Capability is one callable
   specialization, not the universal shape of participation.
6. Each extension point owns its cardinality, selection/composition, ordering,
   applicability, and failure semantics. Generic infrastructure must not impose one
   universal policy.
7. Prefer structured typed composition over arbitrary mutation hooks into opaque
   host objects.
8. Discovery may be live, but captured executable bindings retain their exact
   generation and never silently retarget replacements. Captured immutable data
   has its own contract-defined lifetime; retirement does not promise rollback of
   effects already started.
9. Semantic identity is not proof of liveness. Availability and declared
   dependencies are not execution authority.

## Product and execution

Project, Task, Environment, Session, and Run are shared product concepts with the
meanings defined in the product model, not plugin-specific synonyms.

10. Project is not intrinsically a local directory. Replaceable providers supply
    concrete selection and association behavior.
11. Task is durable user intent, not execution progress. Successful Runs or tools
    do not themselves establish Task completion.
12. A Session retains its semantic strategy binding; its strategy-owned state is
    distinct from bounded Run execution.
13. Environment represents the practical source/filesystem and process context.
    Do not claim stronger isolation than its provider supplies.
14. Strategy owns sequencing and Session semantics. Host/core owns generic
    execution mechanics, policy, approval, and final authorization.

## Presentation

15. UI presents and invokes behavior. Rendering a control does not confer semantic
    ownership of the operation.
16. Plugin-facing presentation contracts describe semantic roles rather than
    current physical placement, so layout can evolve independently.
17. Read-only presentation and observation grant neither execution nor approval
    authority.

## Configuration and state

18. Installation, activation, configuration, configured instances, live runtime
    state/resources, security/policy, and workbench state are distinct concerns.
    Shared context does not make them one state object or one precedence algorithm.
19. Plugin-owned state remains semantically owned by the plugin even when host
    persistence facilities store it; storage does not transfer its schema to core.
20. Credentials and secrets are not ordinary serialized settings. Configuration
    should reference managed credentials or configured instances instead.

## Engineering discipline

21. Prefer the smallest concrete boundary justified by current needs. Do not create
    packages, frameworks, or abstractions merely for hypothetical reuse.
22. Public/plugin-facing APIs remain experimental before release; do not imply a
    compatibility promise that has not been established.
23. Keep Flutter out of non-UI semantic boundaries. Pure-Dart packages should remain
    usable and testable without Flutter where Flutter is not intrinsic to their
    purpose.
24. Do not claim unproven runtime behavior as validated. State the scope and limits
    of the evidence separately from accepted architecture.
25. Desktop architecture must remain portable across Windows, macOS, and Linux,
    even where current implementation and validation are narrower.

## Canonical detail

- [Product model](product-model.md): shared product meanings and state ownership.
- [Plugin system](plugin-system.md): typed composition, lifecycle, and hosting.
- [Contracts and capabilities](contracts-and-capabilities.md): transport, routing,
  and invocation authority.
- [Execution model](execution-model.md): Run, model, tool, policy, and approval
  semantics.
- [Profiles and configuration](profiles-and-configuration.md): configuration,
  activation, configured instances, and persistence boundaries.
- [Dependency rules](dependency-rules.md): concrete package and import guardrails.
