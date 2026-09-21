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
