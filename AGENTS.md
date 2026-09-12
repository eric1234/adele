# ADELE Agent Guidance

ADELE is an extensible, cross-platform desktop environment for building, running, inspecting, and extending agent systems, with the long-term goal of developing ADELE through ADELE itself.

Read `README.md` for current capabilities and `docs/architecture/overview.md` for the maintained system model and links to deeper architecture. `docs/architecture/dependency-rules.md` defines package and plugin dependency boundaries. Architectural decisions live in `docs/adr/`.

## Development principles

Inspect the current repository before changing it. Current source and maintained documentation take precedence over assumptions, old plans, or inferred structure.

Prefer existing ownership boundaries, extension points, lifecycle mechanisms, and repository conventions over introducing parallel mechanisms or bypasses.

Make the smallest coherent change that fully satisfies the current requirement. Do not generalize infrastructure, create abstractions, or resolve deferred architectural questions without a concrete present need.

Preserve explicit boundaries and failure semantics. Do not add silent fallback, substitution, or cross-layer access merely to make an implementation convenient.

Keep sources of truth singular. Reference or extend maintained configuration, registries, and architecture documents rather than duplicating their information elsewhere.

Do not broaden the requested scope incidentally. Record worthwhile follow-up work instead of folding unrelated redesign into the current change.

## Repository organization

`app/` is the Flutter application and composition root. `packages/` contains shared public/plugin-facing APIs and internal host packages. `plugins/` contains stock and reference plugin implementations. `docs/architecture/` and `docs/adr/` contain maintained architecture. `tools/adele.dart` is the maintained repository tooling entrypoint.

Plugins use deliberately public APIs and must not depend on application code or internal host implementations such as `agent_kernel`. Follow `docs/architecture/dependency-rules.md` when changing dependencies or ownership.

When adding a package or plugin, verify workspace membership and the maintained test/analysis discovery in `tools/adele.dart`; passing direct package tests alone does not establish repository or CI integration.

For generated contracts or transport, modify the source-of-truth inputs and use the maintained generation workflow rather than treating generated output as the design source. See `packages/contract_codegen/README.md` and `contract_codegen.yaml`.

## Working and validation

Inspect the relevant architecture and neighboring implementation before editing. Prefer targeted discovery over reconstructing the whole repository when maintained documentation already identifies the relevant area.

Keep tests aligned with the boundary being changed. Verify integration/discovery when the change affects composition or repository wiring, not only the local implementation.

If behavior, architecture, or current capabilities materially change, reconcile the maintained documentation that describes them.

Prefer focused tests and analysis for changed areas, using maintained targets in `tools/adele.dart` where available. Run broader validation when the scope warrants it. Format changed Dart files and run `git diff --check` before considering source work complete.
