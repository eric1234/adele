# ChatGPT/Codex Authentication and Configured-Instance Integration Survey

## Status

This document is a **non-normative implementation-research synthesis** for ADELE.

It distills the Phase IV-B5 authentication research performed after the first
real OpenAI API-key provider was merged. It exists to preserve the current
technical evidence and the architectural pressure it creates without making
source-visible OpenAI Codex behavior into an ADELE contract or claiming that an
undocumented third-party integration is officially supported.

Current ADELE source and accepted ADRs remain authoritative.

The research basis was:

- ADELE `main` at `3ab5ee997eca47a3a58a9ccb6060592b8f0baadd`;
- OpenAI Codex `main` at `49db349ffdd888f5e3c91abf9b7519d8631e6e9a`;
- OpenCode `dev` at `4643e65ad6334de3e4e68dedc201d5fbb828c9fe`;
- KiloCode `main` at `c8271ad6f4b9d8a33da2485202af17ab07563c63`;
- Cline `main` at `8bbdde2a5c1f972864fe1b954f639c21fac61a40`.

Inspection occurred on 2026-08-15 US Eastern time. The inspected worktrees were
reported clean and pinned to the revisions above.

This survey should be rechecked against current OpenAI documentation and source
before shipping or materially extending the integration because authentication
and Codex backend behavior are time-sensitive.

---

# 1. Executive conclusions

The durable conclusions from the B5 research are:

1. **The existing B4 OpenAI Responses implementation is the correct foundation
   for ChatGPT/Codex-backed inference.** The first subscription-backed slice
   should reuse the private request/item codec, HTTP/SSE transport, canonical
   `store:false` replay, encrypted/native reasoning preservation, tool
   continuation, terminal handling, and cancellation already proven in B4.

2. **The minimal ChatGPT path remains browser authorization-code OAuth with PKCE,
   followed by ordinary bearer access-token authentication plus a bound
   `ChatGPT-Account-ID` against the ChatGPT/Codex Responses route.**

3. **Agent Identity is not required for the first ADELE subscription-backed
   configured instance.** At the inspected Codex revision it was an
   under-development, default-off path for normal managed ChatGPT sessions, and
   Codex retained ordinary bearer operation and explicit bearer fallback for
   transient Agent Identity bootstrap failure.

4. **Device/headless login is not required for the first desktop slice.**
   Browser OAuth is the smaller ADELE desktop vertical.

5. **Model discovery/catalog infrastructure is not required before inference.**
   A known configured model ID can be sent directly; the backend remains the
   authority for entitlement/model availability errors.

6. **Refresh state belongs to the configured provider instance, not the semantic
   model request.** Each configured instance needs its own credential state,
   account binding, refresh/mutation serialization, and revision guard.

7. **A refresh mutex alone is insufficient.** A refresh result must only commit
   if the exact configured instance and credential revision captured at refresh
   start are still current. This prevents stale network completions from
   resurrecting credentials after logout or overwriting a relogin/account
   switch.

8. **A narrow durable credential-store boundary is required, but a broad ADELE
   auth framework is not.** In-memory storage is appropriate for deterministic
   tests; a development-only local file store can prove the self-hosting
   vertical while secure OS storage remains replaceable behind the same private
   interface.

9. **There is one capability-runtime prerequisite before implementing two OpenAI
   configured instances in one plugin generation.** ADELE currently preserves
   provider identity in the registry but does not carry configured-instance
   identity through the backend transport. Two descriptors for the same
   service in one plugin generation would reach the same backend service unless
   a binding-owned route is added.

10. **No semantic `dev.adele.model.provider` contract change is required.**
    The routing prerequisite is transport/runtime metadata below generated
    contract payloads, not new model invocation semantics.

11. **OpenAI product authorization remains unresolved.** The direct OAuth/Codex
    backend path is technically visible in first-party source and independently
    reproduced by other clients, but the inspected official material does not
    provide a general arbitrary-third-party OAuth registration mechanism or
    document `chatgpt.com/backend-api/codex` as a public API for independent
    clients.

The recommended implementation sequence is therefore:

```text
IV-B5a
configured-instance transport routing
    ↓
prove two instances of one capability in one plugin generation

IV-B5b
experimental ChatGPT configured OpenAI instance
    ↓
browser OAuth + durable account-bound credentials + refresh
    ↓
same B4 Responses machinery
```

---

# 2. Evidence classification

The underlying research deliberately separated evidence into categories.

## Public OpenAI behavior

Current first-party OpenAI documentation is the strongest source for behavior
that may be treated as publicly supported.

Relevant official material inspected by the research included:

- OpenAI Codex authentication documentation;
- Codex CLI documentation;
- "Using Codex with your ChatGPT plan";
- "Sign in with ChatGPT";
- Codex App Server documentation;
- Codex SDK documentation;
- CI/CD Codex account-auth documentation;
- applicable OpenAI terms/service terms.

Important distinction:

> OpenAI officially supports ChatGPT sign-in for OpenAI Codex surfaces and
> selected/supported external applications, but the inspected material did not
> publish a general self-service OAuth client-registration process for arbitrary
> third-party desktop software using the Codex subscription backend.

That is an absence of documented public support, not proof that OpenAI would
never authorize such an integration.

## OpenAI Codex source

`openai/codex` is first-party implementation evidence for:

- OAuth endpoints and parameters;
- client identity used by Codex;
- credential storage;
- token refresh;
- account extraction/fencing;
- request authentication;
- ChatGPT/Codex route selection;
- Agent Identity;
- model catalog behavior;
- failure/rate-limit handling.

Source-visible behavior is not automatically a third-party API contract.

## Third-party source

OpenCode, KiloCode, and Cline independently reproduce direct ChatGPT bearer +
account-ID traffic to the Codex Responses backend. They also provide useful
evidence of real implementation failures around:

- refresh races;
- stale credentials;
- missing account headers;
- route/auth leakage;
- backend-specific request-field rejection;
- encrypted reasoning replay.

They prove technical interoperability observed by those projects, not
authorization or stability.

## ADELE source

ADELE source and accepted ADRs remain authoritative for ADELE ownership and
semantic boundaries.

---

# 3. Current ADELE baseline

Phase IV-B4 merged as:

```text
3ab5ee997eca47a3a58a9ccb6060592b8f0baadd
```

B4 established:

- `plugins/openai/`;
- one API-key-backed `dev.adele.model.provider` implementation;
- direct `dart:io` HTTP/SSE;
- public `/v1/responses`;
- `store:false`;
- canonical ordered replay;
- native reasoning/compaction envelopes;
- function tools and correlated function outputs;
- explicit semantic terminals;
- cancellation/backpressure preservation through the generated transport;
- deterministic AOT model → ADELE tool → model continuation;
- opt-in live OpenAI validation.

The B4 provider currently owns one fixed API key and one endpoint for the
lifetime of the backend provider object. That is sufficient for one development
instance but not for multiple durable Work/Personal configured instances.

The selected model is already separate from provider binding/auth state, which
is the correct ownership boundary.

---

# 4. Configured-instance routing prerequisite

The B5 research exposed a concrete runtime gap independent of OAuth.

## Accepted ADELE model

ADELE already distinguishes:

```text
plugin installation
activation/plugin generation
configured capability instance
runtime resource
```

One plugin runtime is expected to be able to expose several configured
instances, for example:

```text
OpenAI plugin generation
├── Work / API key
└── Personal / ChatGPT subscription
```

## Current transport behavior

At the inspected ADELE revision:

- each `ProviderDescriptor` has its own `ProviderId`;
- `PluginCapabilityActivation.register()` registers every provider from one
  plugin connection with an `AdeleRequestChannelEndpoint`;
- every such endpoint exposes the same raw `PluginBackendConnection` channel;
- `ProviderBinding.requestChannel` returns that raw connection;
- generated clients send only their generated method ID and semantic payload;
- `ModelProviderServiceClient` sends `modelProvider.invoke`;
- the backend host forwards the request/stream into the plugin isolate with
  method and payload, but no configured-provider target;
- a generated dispatcher owns one concrete service implementation.

Therefore two provider descriptors for the same generated service can be
distinguished in the registry but cannot yet be distinguished at backend
dispatch.

## Architectural consequence

Configured-instance routing must be added **below generated semantic contract
payloads**.

Conceptually:

```text
ProviderBinding
    ↓
generation-bound CapabilityEndpoint
    ↓
opaque configured-instance route
    ↓
PluginBackendConnection
    ↓
backend-host envelope
    ↓
plugin configured-instance router
    ↓
selected generated dispatcher/service
```

The route must be supplied by the binding/endpoint that was resolved from the
registry.

It must not be selectable through:

- `ModelProviderRequest`;
- `providerOptions`;
- model ID;
- native state;
- Session history;
- generated request payload.

This makes account selection unspoofable by semantic invocation data.

## Identity

`ProviderId` is the natural candidate for this route because it already names a
configured provider exposed by a plugin generation.

A different transport-route identity is only justified if a concrete future
case proves `ProviderId` insufficient.

Keep these identities distinct:

```text
plugin ID
provider/configured-instance ID
service ID
generated method ID
model ID
```

## Contract consequence

This is **not** a change to `dev.adele.model.provider`.

The common model-provider request/event schema remains sufficient.

The change belongs to:

- capability endpoint/runtime routing;
- plugin transport envelope;
- backend-host/plugin-isolate dispatch.

Generated clients should remain unaware of configured-instance routing.

This clarification matters because the research report's shorthand answer
"no common capability change" should be read as:

> no semantic capability or generated ModelProvider contract change; a small
> common capability-runtime transport change is required for multiple
> configured instances in one generation.

---

# 5. Current Codex browser OAuth flow

The inspected Codex browser flow remains an authorization-code flow with PKCE.

Source areas include:

```text
codex-rs/login/src/server.rs
codex-rs/login/src/pkce.rs
codex-rs/login/src/token_data.rs
codex-rs/login/src/auth/manager.rs
```

At the pinned revision the source-visible flow used:

- issuer: `https://auth.openai.com`;
- authorization endpoint: `/oauth/authorize`;
- token endpoint: `/oauth/token`;
- a source-visible Codex client ID;
- loopback callback on localhost;
- PKCE S256;
- random state/CSRF value;
- offline access;
- ID, access, and refresh tokens;
- account/workspace information extracted from ID-token claims.

The source-visible Codex client ID is implementation evidence only. Its presence
in an open repository does not establish that ADELE may ship using it.

## Account binding

The ID token supplies or supports derivation of account-related state including:

- ChatGPT account/workspace ID;
- ChatGPT user ID;
- email;
- plan information;
- FedRAMP/account-routing flag.

The account identity is not incidental metadata. It is part of the configured
provider's binding and must fence refresh and request routing.

## Legacy API-key exchange

Current Codex may best-effort exchange OAuth identity for an OpenAI API key as
legacy/auxiliary material.

That key is not the authoritative inference credential for managed ChatGPT
model traffic.

Managed ChatGPT model requests continue to use the ChatGPT OAuth access token
and Codex backend route.

ADELE B5 should not make OAuth-to-API-key minting part of its minimal path.

---

# 6. Device/headless login

Current Codex also has a device/headless flow intended for environments where
loopback browser login is unsuitable.

It adds:

- device authorization ID;
- user code;
- verification URL;
- polling;
- server-provided PKCE material;
- separate callback/exchange behavior.

It does not add model protocol capability after login.

For ADELE desktop:

```text
browser PKCE first
device flow later
```

is the smaller sound slice.

A real headless/remote ADELE use case can justify device auth later.

---

# 7. Credential state and ownership

The smallest sound ADELE configured ChatGPT instance should own conceptually:

```text
ConfiguredOpenAiInstance
├── stable instance ID
├── auth kind
├── route profile
├── bound ChatGPT account identity
├── durable CredentialRecord
│   ├── ID token
│   ├── access token
│   ├── refresh token
│   ├── last refresh / expiry input
│   └── account/FedRAMP data
├── credential revision
└── one mutation/refresh gate
```

This state must not enter the semantic model request.

## Lifetimes

Recommended ownership:

| State | Owner/lifetime |
| --- | --- |
| configured-instance ID, label, auth kind | durable provider configuration |
| account binding | configured instance |
| access/refresh/ID tokens | durable credential record |
| credential revision | durable credential record/store |
| refresh/mutation serialization | live configured instance |
| browser PKCE verifier/state | one login attempt |
| HTTP request/SSE subscription | one invocation |
| selected model | caller/provider adapter request configuration |
| Session/Run history | ADELE host/kernel |

PKCE verifier/state should disappear after successful/cancelled login.

---

# 8. Refresh semantics

Refresh is one of the highest-risk parts of the B5 implementation.

## Current Codex evidence

The inspected Codex implementation:

- refreshes at `auth.openai.com/oauth/token`;
- proactively refreshes near token expiry;
- also performs guarded unauthorized recovery;
- treats returned ID/access/refresh fields as potentially rotating/optional;
- serializes refresh inside one `AuthManager`;
- reloads durable state before refresh;
- checks account identity;
- saves updated credentials before publishing the new in-memory snapshot;
- distinguishes permanent versus transient refresh failures;
- revokes best-effort on logout.

Third-party clients independently accumulated fixes for the same race classes.

## ADELE invariant

The durable invariant should be stronger and explicit:

> A refresh result may be committed only if the configured instance and exact
> credential revision captured when refresh began are still current.

Conceptually:

```text
load revision R
    ↓
refresh using credentials from R
    ↓
network completes
    ↓
compare-and-swap(expected R, new credential record)
    ↓
publish only if committed
```

If logout, relogin, account rebind, or another refresh changed the credential
revision meanwhile, the old network result must not overwrite the new state.

## Scope of synchronization

The synchronization key is the configured ADELE provider instance.

Not:

- OpenAI plugin ID;
- account ID globally;
- model;
- Session;
- Run;
- invocation.

Therefore Work and Personal can refresh independently.

## Multi-process coordination

The research does not justify cross-process refresh locking in the first B5
vertical if one plugin/backend process is the sole writer of one instance store.

The durable revision/CAS boundary should make future stronger coordination
possible without redesigning auth ownership.

---

# 9. Credential storage boundary

A broad generic ADELE credential framework is not required yet.

The OpenAI plugin needs a narrow private store conceptually equivalent to:

```text
load(instanceId)
    -> VersionedCredentialRecord?

compareAndSwap(
    instanceId,
    expectedRevision,
    newRecord
)
    -> committed/current

delete(instanceId, expectedRevision?)
```

## Deterministic tests

Use an in-memory implementation.

## Development/self-hosting implementation

A development-only local file store is acceptable if it has:

- restrictive permissions;
- atomic temporary-file replace;
- no token logging;
- explicit corruption behavior;
- one-writer semantics;
- revision-guarded mutation.

This should be presented as a development persistence mechanism, not the final
production security UX.

## Future secure storage

OS keyring/secrets storage may replace the development file store behind the
same private boundary.

That later change should not require rewriting the model-provider semantics or
refresh ownership.

---

# 10. ChatGPT model-request authentication

For ordinary managed ChatGPT bearer auth, the inspected Codex implementation
uses:

```text
Authorization: Bearer <access token>
ChatGPT-Account-ID: <bound account/workspace ID>
X-OpenAI-Fedramp: true    # conditional
```

against:

```text
https://chatgpt.com/backend-api/codex/responses
```

The exact route and headers must be reverified before implementation/shipping.

## Header ownership

Only headers needed for auth/account/backend correctness belong in the first
ADELE path.

Do not blindly copy Codex product/workflow metadata.

Examples to omit unless concrete evidence makes them required:

- Codex originator identity;
- Codex session/thread/turn IDs;
- Codex subagent markers;
- Codex turn-state;
- Codex routing hints;
- Codex beta-feature sets;
- installation/window metadata;
- Codex-specific tracing/product identity.

If ADELE needs an originator/User-Agent identity, it should identify itself
honestly as ADELE rather than impersonating Codex.

---

# 11. Agent Identity

Current Codex contains a newer Agent Identity mechanism.

It is significant enough to record, but it is not a current ADELE prerequisite.

## Shape

The inspected implementation can:

- generate Ed25519 key material;
- register an agent/runtime identity against the user's ChatGPT account;
- register a task;
- persist runtime/private-key/account/task state;
- generate per-request signed `AgentAssertion` authorization;
- continue sending account/FedRAMP identity.

The registration material contains Codex-specific harness/product identity,
which is itself a warning against copying it into ADELE.

## Current rollout evidence

At the pinned revision:

- managed Agent Identity bootstrap was behind an under-development feature;
- that feature was default-off for normal managed ChatGPT sessions;
- ordinary bearer auth remained valid;
- transient Agent Identity bootstrap failure explicitly caused Codex to fall
  back to ChatGPT bearer auth for the session.

Independent clients inspected in the research did not implement Agent Identity
and continued using bearer + account identity.

## ADELE decision

Do not implement Agent Identity in B5.

Revisit it only if a concrete trigger appears, such as:

- OpenAI provides an ADELE-specific supported registration contract;
- the backend explicitly requires an Agent Assertion for ADELE;
- bearer operation/fallback is removed for the relevant account/model path.

---

# 12. Model catalog and entitlements

Codex has a substantial `/models` catalog system with:

- authenticated model fetch;
- ETag refresh;
- plan filtering;
- visibility;
- reasoning/service-tier metadata;
- default selection;
- quota/rate metadata.

That infrastructure is not required before a Responses invocation.

The model request carries a model slug directly.

Therefore the first subscription vertical may use a configured model string.

The backend remains authoritative for:

- unknown model;
- unavailable model;
- plan entitlement;
- workspace policy;
- regional/account restriction.

ADELE should surface those through the existing failure vocabulary rather than
building a catalog merely to predict them.

Possible mapping remains coarse:

```text
model unsupported
    -> unsupportedRequest

workspace/plan entitlement denied
    -> permission

quota/throttle
    -> rateLimited

transient backend failure
    -> unavailable
```

Provider-specific codes/details can retain exact OpenAI information.

---

# 13. Request differences from the B4 API-key route

The first B5 ChatGPT route should continue sharing most of B4.

## Reuse unchanged

Keep:

- `model`;
- `instructions`;
- ordered semantic input;
- ordinary function tools;
- `tool_choice`;
- `parallel_tool_calls:false` while the current development strategy supports
  one proposal;
- `store:false`;
- `stream:true`;
- encrypted reasoning inclusion;
- assistant phase/native replay;
- canonical tool-result continuation;
- HTTP/SSE;
- semantic terminal authority;
- cancellation.

## Change through private route/profile policy

ChatGPT configured instance needs:

- ChatGPT/Codex endpoint;
- fresh bearer token;
- bound account header;
- conditional FedRAMP header;
- backend-specific accepted-field policy.

The research found current Codex/third-party evidence that the ChatGPT route may
reject `max_output_tokens`.

The first B5 profile should therefore fail a non-null common
`maxOutputTokens` as `unsupportedRequest` rather than silently changing request
semantics.

Do not change the common contract for that route-specific limitation.

## Defer

Do not add merely because Codex uses them:

- reasoning controls;
- prompt-cache key;
- service tier;
- client metadata;
- previous response ID;
- WebSocket;
- conversations;
- Codex turn state;
- Codex workflow metadata.

---

# 14. 401 recovery and retry boundary

B4 deliberately has no general hidden retries.

B5 creates one narrow justified exception:

```text
request receives unauthorized response
AND
no ADELE observation/output/terminal has escaped
AND
managed credential can be refreshed safely
    ↓
one guarded refresh
    ↓
retry once
```

This is auth recovery, not a general provider retry framework.

Do not retry after anything observable has crossed the provider boundary.

Do not retry repeatedly on persistent 401.

The refresh/retry must use the configured-instance credential revision rules
above.

---

# 15. Failure and account behavior

The existing common failure taxonomy remains sufficient.

Representative B5 mappings:

| Condition | ADELE result |
| --- | --- |
| refresh required and succeeds before output | internal recovery |
| permanent refresh failure | `authentication` |
| missing required account ID | `authentication` |
| configured account mismatch | `authentication` |
| Codex entitlement denied | `permission` |
| model unavailable for account/plan | `permission` or `unsupportedRequest` based on provider code |
| quota exhausted / throttled | `rateLimited` |
| transient auth/backend failure | `unavailable` or existing transport/provider failure |
| unsupported ChatGPT request field | `unsupportedRequest` |
| malformed stream/item | `malformedResponse` |

Never include token values in failure details.

Useful safe provider details may include:

- request ID;
- provider error code;
- provider message;
- selected model;
- quota window/reset;
- retry-after;
- account-routing category without credentials.

---

# 16. Third-party implementation lessons

## OpenCode

OpenCode's ChatGPT path uses direct OAuth bearer/account traffic to the Codex
backend and rewrites its OpenAI Responses transport accordingly.

Its historical fixes reinforce:

- refresh deduplication;
- correct account header ownership;
- no API-key auth leakage into OAuth traffic;
- route distinction;
- preserving encrypted reasoning/state.

## KiloCode

KiloCode builds on similar behavior but adds stronger refresh coordination,
including a cross-process file lock and re-reading newer rotated credentials.

That is useful evidence of the problem, but ADELE does not need cross-process
locking in a one-writer first vertical.

## Cline

Cline represents subscription-backed OpenAI separately from native API-key
OpenAI, uses browser PKCE, durable atomic credential persistence, single-flight
refresh, account headers, and Responses.

It also removes request fields rejected by the subscription backend, reinforcing
the need for an OpenAI route/profile policy rather than pretending the two
routes accept identical bodies.

## Common lesson

The recurring boundary is:

```text
shared Responses wire machinery
    +
configured-instance-specific auth / route / request policy
```

not one undifferentiated OpenAI provider configuration.

---

# 17. Official support status

This section is intentionally separate from technical feasibility.

The inspected official material established strong support for:

- ChatGPT authentication in OpenAI's Codex clients;
- automatic token refresh;
- Codex SDK/App Server integrations;
- Sign in with ChatGPT for participating/supported external applications.

The research did **not** find:

- a documented self-service OAuth client-registration path for arbitrary
  third-party desktop applications using the Codex subscription backend;
- official permission for arbitrary applications to reuse Codex's source-visible
  OAuth client ID;
- documentation that `chatgpt.com/backend-api/codex` is a public third-party API.

Therefore:

> The direct ADELE ChatGPT/Codex integration is technically well understood but
> should remain explicitly experimental/development-only until OpenAI confirms
> an authorized client/registration and backend-use path for ADELE.

This uncertainty should not be disguised as a protocol problem.

It is a product/support/shipping question.

---

# 18. Recommended Phase IV-B5a

Before OAuth, implement configured-instance routing in the common plugin runtime.

The target proof is:

```text
one plugin generation
├── configured provider A
└── configured provider B

same capability
same service ID
same plugin connection
    ↓
binding A routes only to service A
binding B routes only to service B
```

Requirements:

- route identity is binding/endpoint-owned;
- generated semantic payload remains route-free;
- request and stream-open both route correctly;
- stream credit/cancel remain request-ID based after open;
- stale-generation behavior remains unchanged;
- cancellation/backpressure remain unchanged;
- single-instance plugins need no unnecessary router logic;
- backend-host protocol must fail closed if a version mismatch could silently
  drop route identity.

This infrastructure is capability-generic and is justified by the concrete
OpenAI Work/Personal requirement.

---

# 19. Recommended Phase IV-B5b

After B5a is merged, implement one explicitly experimental ChatGPT configured
instance in the existing OpenAI plugin.

Conceptually:

```text
OpenAiConfiguredInstance
├── id
├── auth kind
├── route profile
├── OpenAiCredentialOwner
│   ├── browser OAuth login
│   ├── account binding
│   ├── credential store
│   ├── revision/CAS
│   ├── refresh gate
│   ├── one guarded 401 recovery
│   └── logout/revoke
└── OpenAiModelProvider
    ├── existing private Responses codec
    ├── existing HTTP/SSE transport
    ├── existing terminal/failure normalization
    └── existing cancellation
```

The first development instance should use:

```text
browser PKCE
managed OAuth tokens
bound ChatGPT account
Bearer + ChatGPT-Account-ID
conditional FedRAMP header
ChatGPT/Codex /responses route
HTTP/SSE
store:false
canonical ordered replay
```

Keep API-key and ChatGPT credentials impossible to cross-route.

---

# 20. B5b tests

Minimum deterministic coverage should include:

## Login

- authorization URL;
- PKCE S256;
- unique state;
- callback mismatch/error;
- token exchange;
- claim/account extraction;
- workspace/account mismatch;
- no secret logging.

## Credential lifecycle

- rotating refresh token;
- optional missing token fields preserve current values;
- proactive refresh;
- same-instance concurrent refresh coalesces;
- Work and Personal refresh independently;
- revision CAS prevents stale logout/relogin overwrite;
- store failure does not publish an uncommitted credential snapshot;
- logout/revoke clears local ownership.

## Routing/auth

- API-key binding reaches only API-key instance;
- ChatGPT binding reaches only ChatGPT instance;
- API key never reaches Codex route;
- OAuth token/account headers never reach public API route;
- account/FedRAMP headers are correct;
- semantic payload cannot select another configured account.

## Request policy

- B4 API-key profile retains existing behavior;
- ChatGPT profile rejects unsupported output-cap requests;
- no Codex workflow/persona metadata leaks into ADELE requests.

## Responses

Run existing B4 semantics under the ChatGPT route profile:

- text;
- native reasoning;
- function proposal;
- function outcome;
- canonical ordered continuation;
- explicit terminal;
- malformed EOF;
- cancellation.

## Auth recovery

- one pre-observation 401 can trigger refresh and retry;
- no retry after any ADELE event;
- persistent unauthorized does not loop.

---

# 21. Explicit non-goals

Do not include in B5a/B5b unless a new concrete requirement appears:

- Agent Identity;
- device/headless login;
- personal access tokens;
- workload identity;
- arbitrary header auth;
- importing Codex auth files;
- production keyring UX;
- generic secure-storage framework;
- broad account-management UI;
- common ADELE auth capability;
- model catalog/model picker;
- WebSocket Responses;
- `previous_response_id`;
- Conversations ownership of ADELE Session;
- Codex turn-state;
- Codex app-server as ModelProvider;
- Codex workflow/tool authority;
- API-key minting as required OAuth behavior;
- general retries after observable output;
- public generic Responses package;
- universal OpenAI-compatible provider abstraction;
- ModelProvider semantic-contract changes;
- `agent_kernel` changes.

---

# 22. Final direct answers

## What current Codex auth flow should ADELE learn from?

Browser authorization code + PKCE/state at `auth.openai.com`, loopback callback,
managed ID/access/refresh tokens, ID-token account binding, then bearer +
`ChatGPT-Account-ID` against the ChatGPT/Codex Responses route.

## What changed materially since the earlier OpenAI research?

B4 is now implemented and reusable. Codex has also added a substantial Agent
Identity mechanism, but at the inspected revision it remained under-development
and default-off for ordinary managed ChatGPT use, with bearer fallback.

## Is ordinary bearer + account ID still enough for the first subscription path?

Yes, based on the inspected first-party and third-party evidence.

## Is Agent Identity required?

No.

## Browser or device login first?

Browser PKCE first.

## What must be persisted?

At minimum:

- configured-instance identity/auth kind;
- ID/access/refresh token set;
- bound ChatGPT account identity;
- FedRAMP/account-routing flag;
- useful user/workspace metadata needed for fencing/display;
- last refresh/expiry input;
- credential revision.

## How is refresh scoped?

One mutation/refresh single-flight per configured provider instance, plus
revision compare-and-swap on commit.

## Is model catalog required?

No.

## Can B4 Responses code be reused?

Yes. Route/auth/request-profile policy should be injected privately around the
existing codec/transport.

## Is a ModelProvider contract change required?

No.

## Is any common runtime change required?

Yes: configured-instance route identity must survive the capability endpoint /
plugin transport boundary before two instances of the same service can coexist
inside one plugin generation.

## What is officially supported versus source-visible?

ChatGPT authentication for Codex and selected supported external applications is
officially documented. The exact Codex OAuth constants, Codex backend route, and
Agent Identity are source-visible implementation details. General arbitrary-app
OAuth registration and reuse of Codex's client/backend for an independent ADELE
implementation were not documented in the inspected official material.

## What should B5 implement?

First B5a configured-instance routing, then B5b one experimental ChatGPT
configured OpenAI instance with browser PKCE, durable account-bound credentials,
race-safe refresh, and the existing B4 Responses stack.

## What should B5 not implement?

Agent Identity, device auth, catalog, WebSocket/stateful continuation, Codex
workflow metadata, broad auth/UI infrastructure, generic compatibility layers,
or common model-provider semantic changes.

---

# 23. Future revalidation triggers

Re-run focused research if any of these occur:

- OpenAI publishes a general third-party Sign in with ChatGPT registration
  process;
- ADELE receives an authorized OAuth client/product identity;
- Codex enables Agent Identity by default for ordinary ChatGPT model traffic;
- bearer fallback disappears;
- the ChatGPT/Codex route changes;
- the backend starts requiring Codex workflow metadata;
- the subscription route gains/losses relevant Responses fields;
- ADELE needs headless login;
- multiple processes need to mutate one configured credential store;
- persisted native model state crosses configured-instance/account boundaries.

Until one of those triggers appears, the implementation sequence above is the
smallest sound path supported by the current evidence.
