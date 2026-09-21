# Retained Experiments

Role: Non-normative empirical evidence.

Retain an experiment document only when a technical spike or proof produces
lasting evidence worth preserving because reproducing it may be useful or
expensive. An ordinary implementation milestone or successful PR is not enough.
Experiments are evidence, not architecture, specifications, or phase logs. See
the [documentation policy](../README.md) for placement and authority.

A useful retained experiment should normally capture:

- The question being tested.
- Environment, toolchain, and revision where relevant.
- Approaches tried and the procedure.
- Observed results, including failures, and limitations of the evidence.
- Architectural or product implications, if any, without declaring them accepted.
- Reproducibility pointers such as branches, commits, and tests.

## Current contents

[Phase I runtime findings](phase-1-runtime-findings.md) retain evidence about
external AOT loading and the shared backend-host approach, with original
experiment branches and revisions. The historical filename and document remain
unchanged here; they are retained for their evidence, not as a phase-history log.
