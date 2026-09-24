# Architectural Decision Records

Role: Durable decision rationale and historical context.

Write an ADR when there are meaningful alternatives, a durable architectural
decision, and a likely future reason to ask "why?" A routine refactor, individual
PR, package move, or API detail does not by itself warrant an ADR. Explain the
context, alternatives, decision, and consequences rather than summarize the work.

## History and authority

Accepted ADR bodies are historical records. Acceptance does not imply complete
implementation. Later decisions should explicitly supersede or amend earlier
records, not silently rewrite their rationale. Link the related decisions and
identify the replaced scope and any constraints that still apply; an explicit
amendment should leave the original decision visible.

Current architecture belongs in [architecture docs](../architecture/overview.md),
not in an inferred reading of "the latest ADR." See the
[documentation policy](../README.md) for the authority model.

## Existing records

Numbered records remain in this directory with their existing filenames. Continue
the `NNNN-descriptive-title.md` numbering convention for new records. Read each
record's own status and supersession/amendment notes: historical wording includes
proposed, deferred, qualified acceptance, and partial supersession, not a uniform
status taxonomy to normalize during documentation reorganization.

The latest record is [ADR 0033: Durable Project storage and provider-selected
backing](0033-durable-project-storage-and-provider-backing.md), following
[ADR 0032](0032-remote-backend-extensions-use-operation-scoped-host-services.md).
It amends ADR 0031's Project opening/storage boundary while preserving product
semantic ownership and the distinction between durable data and live bindings.
