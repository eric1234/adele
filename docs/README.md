# ADELE Documentation

Role: Canonical documentation map and maintenance policy.

Read this guide before architecture work or creating/updating documentation.
Documentation should convey information that cannot efficiently be reconstructed
from one source file: cross-system ownership, architectural invariants and
boundaries, durable decision rationale, product/UX direction, reviewed future
technical direction, research and experimental evidence, repository-development
workflow, and local component ownership/maps. It should not become a duplicate
source listing or a development-history journal.

## Authority

Document role determines how to read a claim, not just its directory or filename.
The legacy-path exceptions below apply during migration.

| Role / home | Authority |
| --- | --- |
| Current implementation: source and tests | Authoritative for what exists and behaves today. Local READMEs must describe their current component accurately, but source/tests win when those descriptions are stale. |
| [Architecture](architecture/) | Accepted cross-system architecture: ownership, semantic boundaries, lifecycle, authority, dependency direction, identities, and invariants future implementation must preserve. |
| [ADRs](adr/README.md) | Why durable decisions were made, with their historical context. Not the canonical description of current architecture; later decisions explicitly supersede or amend earlier records rather than rewrite history. |
| [Product](product/README.md) | Intended product/user experience, which may deliberately be ahead of implementation. Implementation progress alone is not a reason to change product direction. |
| [Direction](direction/README.md) | Reviewed technical/design hypotheses useful enough to guide future work, but explicitly open to change under implementation pressure. |
| [Development](development/README.md) | Current repository working procedure: toolchain, build/bootstrap/generation, testing, local workflows, and development/self-hosting execution where appropriate. Must track operational reality. |
| [Research](research/README.md) | Dated/versioned, non-normative investigation and evidence. Informs architecture but does not define it. |
| [Experiments](experiments/README.md) | Retained empirical spikes/proofs worth preserving because reproducing a result may be useful or expensive. Evidence, not specifications or phase logs. |
| Local application/package/plugin READMEs | Maps of local ownership and non-ownership, important entrypoints and invariants, dependencies/boundaries, focused validation, and links to global architecture. They do not redefine global architecture. |

Architecture may contain accepted constraints that are only partially implemented
or not implemented yet. Absence from source does not automatically make an
architecture statement obsolete. Investigate apparent contradictions between
source and accepted architecture: distinguish an implementation gap or regression,
a stale description, and a decision needing review. Do not silently assume that
one category always wins.

> Architecture means ADELE has accepted the constraint/shape.
>
> Direction means this is ADELE's best reviewed current hypothesis, but
> implementation may legitimately change it without an architectural reversal.

## Reading path

The normal orientation path is:

```text
README.md
    -> docs/README.md
    -> docs/architecture/overview.md
    -> task-relevant architecture/direction/product docs
    -> relevant package/plugin README(s)
    -> source and tests
```

Start with the [repository introduction](../README.md), this guide, and the
[architecture overview](architecture/overview.md). Consult ADRs, research,
experiments, and development docs according to the question, not exhaustively.

| Question | Read |
| --- | --- |
| What does ADELE currently implement? | Source/tests and local READMEs, reached through the [architecture source map](architecture/overview.md#source-map) |
| Who owns a concept / what boundary must be preserved? | [Architecture](architecture/) |
| Who owns Project, Task, Environment, Session, and Run semantics? | [Product model](architecture/product-model.md) |
| How do plugins participate, compose, and retain live bindings? | [Plugin system](architecture/plugin-system.md) |
| What must Run/model/tool/policy/approval execution preserve? | [Execution model](architecture/execution-model.md) |
| Why was a design decision made? | [ADRs](adr/README.md) |
| What UX are we aiming for? | [Product](product/README.md) |
| What future technical shape are we considering? | [Direction](direction/README.md) |
| What evidence informed a design? | [Research](research/README.md) / [experiments](experiments/README.md) |
| How do I build/test/generate/run the checkout? | [Development](development/README.md) |
| How does one package/plugin work locally? | Its README, then source/tests |

## Placement and updates

Choose the document role before writing. Implementation PRs should not reflexively
update every global document.

| Need to document | Home | Create/update when |
| --- | --- | --- |
| Cross-system ownership/lifecycle/invariants implementation must respect | `architecture/` | An accepted architectural boundary/model changes or is newly established. |
| Intended end-user/product behavior | `product/` | Intended product behavior or UX changes. |
| Reviewed future technical design that remains a hypothesis | `direction/` | Intended future technical direction changes, including changes justified by implementation pressure. |
| Rationale for a durable architectural choice | `adr/` | A durable decision warrants a record, or explicit supersession/amendment is needed. |
| External/source investigation and evidence | `research/` | A worthwhile investigation produces evidence; prefer a dated follow-up/addendum for material new evidence, not routine implementation maintenance. |
| Current build/test/tooling/developer workflow | `development/` | Actual repository working procedures change. |
| Results of a retained technical spike/proof | `experiments/` | Empirical results merit retention; rarely as routine implementation maintenance. |
| Local component ownership/API map | Local `README.md` | Local ownership, contracts, or workflows change. |
| One implementation detail obvious from source | Usually no documentation | Keep the explanation with source if needed. |
| A record that a phase/PR happened | Git/PR history, not maintained docs | Do not create a maintained phase-summary document. |

Progress from "not implemented" to "implemented" does not by itself require a
product/direction update unless the design itself changed.

## Maintenance rules

- **One canonical home.** A semantic fact has one primary explanatory home in
  documentation. Other docs link rather than restate it. The
  [product model](architecture/product-model.md) owns shared product-domain
  semantics; Chat and other local docs should explain how they participate rather
  than redefine Session.
- **Stable source anchors.** Prefer package/directory and library paths,
  class/type and method/function names, or extension-point/capability identities.
  Avoid source line numbers. References help navigation; they do not replace an
  explanation of the cross-system concept.
- **Maps, not source narration.** Architecture explains relationships and
  invariants, then points to code anchors. Do not reproduce algorithms or
  exhaustively narrate functions/classes understandable from one local source file.
- **History in its proper home.** Use ADRs for durable decision history,
  research/experiments for retained evidence, and Git/PR history for implementation
  chronology. Do not maintain a general phase-history documentation stream.

Avoid phase-completion logs, PR summaries copied into architecture, current test
counts, transient artifact/provider/plugin counts unless the number itself is an
invariant, duplicated descriptions with competing canonical homes, and broad
"Deferred" inventories repeated across documents.

## Role headers

Global docs should make their role obvious near the top with a short `Status`,
`Role`, or `Status and purpose` section. Where useful, state implementation status
separately from architectural authority. For example:

```text
Role: Canonical architecture
Implementation status: Partial
```

```text
Role: Reviewed technical direction
```

```text
Role: Non-normative research
```

These are semantic cues, not machine-readable frontmatter or a rigid status
taxonomy. Preserve section-level qualifications; one header cannot make every
detail accepted or implemented. Do not retrofit the existing corpus wholesale.

## Staged migration

The current directory layout is being migrated in focused slices. For now, read
these existing locations according to their semantic roles, not their paths:

| Existing location | Role and migration |
| --- | --- |
| [`docs/mockups/**`](mockups/README.md) | Product direction: reviewed development-workflow UX, largely to be preserved and later moved under `docs/product/`. |
| [`docs/architecture/agent-tooling-direction.md`](architecture/agent-tooling-direction.md) | Technical direction; later move under `docs/direction/`. |
| [`docs/architecture/stock-plugin-direction.md`](architecture/stock-plugin-direction.md) | Technical direction; later move under `docs/direction/`. |
| [`docs/architecture/toolchain.md`](architecture/toolchain.md) | Primarily development workflow/policy; later move under `docs/development/`. |
| [`docs/experiments/phase-1-runtime-findings.md`](experiments/phase-1-runtime-findings.md) | Retained experiment evidence; preserve its current path and contents in this slice. |

The remaining architecture corpus will be reconciled in later focused slices.
These classifications do not rewrite existing claims or their qualifications;
existing major paths remain valid.

**Do not create duplicate copies at the target location while an existing
canonical document remains at its legacy path. Link to the existing document
until its migration slice occurs.**
