# ADELE Research

This directory contains non-normative source research used to inform ADELE architecture and implementation decisions.

Research documents record evidence, counterexamples, and design pressure. They are not accepted APIs or architecture specifications. Accepted current behavior belongs in `docs/architecture/` and durable architectural decisions belong in `docs/adr/` when appropriate.

## Surveys

- [`agent-harness-semantic-boundary-survey.md`](agent-harness-semantic-boundary-survey.md) — broad survey of agent-harness semantic boundaries including Session/Run ownership, tools, approvals, execution identity, provider-neutral orchestration, and generation safety.
- [`model-provider-semantic-boundary-survey.md`](model-provider-semantic-boundary-survey.md) — focused survey of model-provider request/stream semantics, provider-native continuation, tool replay, terminal/error behavior, and the pressure those findings place on ADELE's first common model-provider capability.

The model-provider survey builds on the broader harness survey rather than replacing it.
