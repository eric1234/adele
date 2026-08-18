# ADR 0028: Experimental ChatGPT OpenAI configured instance

## Status

Accepted for Phase IV-B5b

## Context

ADR 0026 established a real OpenAI API-key-backed Responses provider. ADR 0027
then established generation-bound configuration contexts so one plugin
generation can route several configured capability instances without putting
configuration identity in semantic requests.

The next self-hosting proof needs one OpenAI plugin generation to expose both
the existing public API-key route and a ChatGPT-subscription-backed route. The
two routes share Responses request, replay, streaming, output, and terminal
semantics, but they differ in credential ownership, endpoint, account routing,
refresh, support status, and accepted request fields.

Current first-party Codex source shows browser authorization-code OAuth with
PKCE, refresh tokens, account-bound bearer requests, and the managed
ChatGPT/Codex Responses route. It does not establish a general third-party OAuth
registration or backend-use contract. Source-visible Codex client identity and
product metadata therefore cannot be treated as stable ADELE contracts.

Refresh races are correctness-sensitive. A mutex or single-flight prevents
duplicate local work but does not stop an older network result from overwriting
logout, relogin, account switching, or a newer refresh. Configuration contexts
are also recreated with plugin generations and cannot serve as durable secret
identity.

## Decision

The OpenAI plugin may host two independently routed configured instances under
the same `dev.adele.model.provider` service:

- an API-key configured instance using the public `/v1/responses` profile; and
- an explicitly experimental ChatGPT configured instance using the current
  ChatGPT/Codex Responses profile.

Each configured OpenAI instance owns its authentication kind, endpoint/profile,
and account-routing state. Plugin ID, durable configured-instance identity,
generation-bound `ConfigurationContextId`, `ProviderId`, service ID, model ID,
and ChatGPT account ID remain distinct. The binding-owned configuration context
selects the live instance. Model request fields, provider options, model IDs,
native state, and history cannot select or override credentials, profile, or
account.

Durable ChatGPT credentials are keyed by a stable configured-instance identity,
not by `ConfigurationContextId`. A private OpenAI credential-store boundary
loads revisioned state, performs compare-and-swap updates, and records
revisioned tombstones on deletion. A refresh result is published only when a
CAS against the exact revision captured before network refresh commits. The
live instance coalesces same-instance refresh, while different configured
instances remain independent. Omitted optional refresh-token response fields
retain their prior valid values, and refreshed account identity must match the
bound account.

The first login path is desktop browser authorization-code OAuth with PKCE S256
and a loopback callback. Standard authorization URI fields, PKCE
verifier/challenge handling, callback state and OAuth error validation,
authorization-code exchange, and initial token parsing are delegated to
`package:oauth2`. ADELE owns browser launching, the loopback HTTP listener,
OpenAI-specific authorization parameters, and account-claim extraction and
binding. Wrong-path and wrong-state loopback requests remain non-terminal; the
library validates the legitimate callback. OAuth issuer, client identity,
redirect, and route data remain configurable. The development command prefers
an explicitly configured ADELE-authorized client identity, but may use the
current source-visible Codex public client as a loudly warned experimental
fallback.
The provisional pure-Dart desktop launcher delegates URL association to each
operating system: `xdg-open` on Linux, `open` on macOS, and the native Windows
Shell API through `package:win32`. It does not invoke a command shell or discover
browsers. A future Flutter login UI should own browser launching through
Flutter's official `url_launcher` rather than expanding this backend seam.
OpenCode, KiloCode, and Cline ship the same identity for their corresponding
ChatGPT integrations. The fallback is an interoperability choice, not an ADELE
OAuth registration or a stable OpenAI third-party contract. PKCE verifier and
state exist only for one in-memory login attempt. Device login is not included.
The normal backend does not silently select that identity: it requires either
`ADELE_OPENAI_CHATGPT_CLIENT_ID` or the explicit
`ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT=1` interoperability opt-in.

Current Codex source still sends refresh-token requests as JSON containing
`client_id`, `grant_type`, and `refresh_token`, while `package:oauth2` implements
the standard form-encoded refresh request. A small OpenAI-specific adapter
therefore retains that JSON exchange. The library is not allowed to refresh or
mutate durable credentials automatically. Initial library credentials and
custom refresh results are converted into ADELE's account-bound revision/CAS
record before publication.
Every successful refresh must explicitly return a valid access token; omitted
ID and refresh tokens may retain their account-bound prior values. Refreshed
access-token expiry derives only from lifetime information returned by that
refresh, never stale credential metadata. Token response bodies are bounded and
oversized successful responses fail as malformed without publication.
Permanent refresh-credential rejection is classified separately from OAuth
rate limiting, transient service failure, transport failure, and malformed
successful provider responses. Those failures retain the existing common model
provider kinds without introducing automatic refresh retries. Standard OAuth
`invalid_grant` and the known OpenAI refresh-token terminal reasons are
credential rejection. Provider bodies are not surfaced because token responses
may contain credentials.

The ChatGPT request uses its OAuth access token, exact bound
`ChatGPT-Account-ID`, and conditional `X-OpenAI-Fedramp: true`. These headers
cannot reach the API-key route, and API keys cannot reach the ChatGPT route.
Codex originator, session, turn, subagent, tracing, feature, installation, and
other product/workflow metadata are not emitted. ADELE does not impersonate
Codex.

Both profiles share the OpenAI plugin's private B4 Responses machinery for
ordered request/item lowering, canonical `store:false` replay, encrypted
reasoning/native items, function tools and outcomes, HTTP/SSE streaming,
completed-item authority, semantic terminals, cancellation/backpressure, and
common failure normalization. No public provider abstraction is introduced.
The API-key profile retains its B4 request and failure behavior.

The managed route does not currently have documented support for an explicit
`max_output_tokens` field. Until authorized documentation or validation proves
support, a non-null ADELE `maxOutputTokens` is rejected before transport as
`unsupportedRequest`; it is not silently omitted.

One narrow hidden recovery is allowed for the ChatGPT profile: an HTTP 401 may
refresh credentials and retry once only before any ADELE `ModelProviderEvent`
has escaped. Persistent 401 does not loop. No observation, native output, text
output, tool proposal, or terminal can be retracted, so no retry occurs after
one crosses the provider boundary. This is an auth exception, not a general
retry framework. Recovery retains the revision used by the rejected HTTP
attempt. If another invocation has already committed a newer revision, the
request retries that credential without rotating its refresh token again.

Logout authoritatively commits a local credential tombstone. Best-effort remote
revocation may be added later, but remote failure cannot preserve local login
state or allow a stale refresh to resurrect it. Local logout depends only on the
configured-instance identity and credential store, not OAuth client, issuer,
redirect, or browser configuration.

An in-memory store supports deterministic tests. A small local file store
provides provisional development persistence with explicit corruption failure,
atomic temporary-file replacement, and restrictive file permissions where
supported. Mutations remain serialized within each process and also coordinate
cooperating backend and development-command processes through a stable sidecar
filesystem lock. Revision comparison and atomic replacement occur while that
lock is held, and each replacement uses a unique temporary path. This is not a
production-grade distributed transaction store, final credential UX, or a
general ADELE secrets facility.
Corrupt credential content fails closed as a sanitized authentication-state
failure; ordinary filesystem access failures remain transport failures. Neither
case automatically deletes the local store.

The direct ChatGPT/Codex backend path remains experimental and
development-oriented until OpenAI provides an authorized client identity and a
general or ADELE-specific third-party integration contract. Exact route,
headers, OAuth parameters, claims, and accepted request fields must be
revalidated before shipping or material extension.

On 2026-08-16, the development command completed a real browser login, token
exchange, account-bound credential persistence, and a live streamed
`gpt-5.4` Responses invocation through the direct ChatGPT route. The provider
received an authoritative `OK` output and completed semantic terminal. This is
positive production-interoperability evidence for the current implementation;
it does not convert the source-visible route or client identity into a supported
third-party contract. The equivalent automated test remains explicitly opt-in
and requires a local credential file.

## Consequences

- B5a is proven with two independently authenticated OpenAI contexts in one AOT
  plugin generation sharing one service ID.
- Credentials and account routing remain configured-instance state rather than
  model semantics or session history.
- Revision/CAS fencing prevents stale refresh completion from overwriting
  logout, relogin, account switching, or newer credentials.
- API-key behavior keeps the B4 public Responses semantics and regression
  coverage.
- The experimental profile can evolve or be removed without changing the common
  model-provider contract.
- No generic ADELE OAuth capability, secrets framework, model catalog, UI,
  keyring integration, Agent Identity, device flow, or Codex workflow contract
  is introduced.
- No `agent_kernel` or common `adele_model_provider` semantic-contract change is
  required.
