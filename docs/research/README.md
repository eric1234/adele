# ADELE Research

Role: Non-normative research and investigation.

This directory contains dated/versioned evidence, counterexamples, and design
pressure used to inform ADELE architecture and implementation decisions. Research
does not define accepted APIs or architecture. Source/tests define current
implementation; accepted cross-system constraints belong in
[architecture](../architecture/), and durable decision rationale belongs in
[ADRs](../adr/README.md) when appropriate. See the
[documentation policy](../README.md) for the full authority model.

Research is normally a snapshot of an investigation, not a continuously rewritten
current-state document. Preserve the date, inspected versions/revisions, and
limitations of the evidence. When evidence changes materially, prefer a new
follow-up, clearly identified addendum, or research pass that relates its findings
to the earlier snapshot. Recheck time-sensitive evidence before relying on it;
implementation progress alone is not a reason to modernize old survey terminology.

## Surveys

- [Agent harness semantic boundaries](agent-harness-semantic-boundary-survey.md): Session/Run ownership, tools, approvals, execution identity, provider-neutral orchestration, and generation safety.
- [Model-provider semantic boundaries](model-provider-semantic-boundary-survey.md): request/stream semantics, provider-native continuation, tool replay, terminal/error behavior, and pressure on ADELE's first common model-provider capability.
- [OpenAI provider integration](openai-provider-integration-survey.md): Responses protocol evidence, provider-native replay, and distinctions between public API behavior, Codex internals, and third-party interoperability.
- [ChatGPT/Codex authentication and configured instances](openai-chatgpt-auth-integration-survey.md): authentication, credential lifecycle, configured-instance routing, and limits of evidence for the experimental subscription-backed integration.

The model-provider survey builds on the broader harness survey rather than replacing it.

## Development investigations

- [CI performance baseline and optimization candidates (2026-11-26)](ci-performance-2026-11-26.md), including the [desktop test ownership audit](ci-desktop-test-ownership-2026-11-26.md).
- [Invocation-scoped reuse of compiled test artifacts (2026-11-27)](test-artifact-reuse-2026-11-27.md): per-worker inventory, Git AOT pilot, correctness gates and hosted CI trend.
- [Verified host-only reuse in desktop workers (2026-11-28)](desktop-host-reuse-2026-11-28.md): complete shard-4 comparison, validation costs and reasons to keep desktop fresh.
- [Verified AOT observation costs (2026-11-28)](verified-aot-observations-2026-11-28.md): measured compiler/provenance overlap, checksum batching, and the subsequent decision to retire test AOT reuse.
- [Workflow-scoped generated contract sources (2026-11-28)](workflow-generated-artifacts-2026-11-28.md): preparation across independent runners, producer placement and the source-only handoff experiment.
