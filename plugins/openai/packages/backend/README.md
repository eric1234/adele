# OpenAI Model Provider Backend

`openai_model_provider_backend` is the pure-Dart OpenAI Responses implementation
of public `adele_model_provider`. It runs as a prepared AOT backend through the
shared plugin host, not as linked Flutter application code. It supports the
public API-key route and a separately configured, explicitly experimental ChatGPT
subscription-backed classic Responses route. The latter is interoperability
support, not a stable third-party OpenAI integration contract.

Normal stock composition exposes configured API-key records alongside the separately
configured ChatGPT context. Normal Chat still selects ChatGPT explicitly; there is
no Session provider picker. The backend owns OpenAI protocol/authentication behavior,
while the host owns record credential authorization and OS storage.
See [app configuration](../../../../app/README.md#chatgpt-source-checkout-configuration)
and [ADR 0028](../../../../docs/adr/0028-experimental-chatgpt-openai-configured-instance.md)
for startup/auth ownership and limitations.

## Declarative Configuration

The plugin-root [`records.schema.json`](../../records.schema.json) is the
authoritative data-only declaration for `dev.adele.openai.api-key` in the
`providers` collection. It declares a required display name and optional API
endpoint, plus an `api-key` credential slot separate from ordinary fields. No
secret or credential reference is embedded in the schema. Stock preparation copies
the authored bytes into the installation and references them through the optional
installation-level `recordsSchema`, independently of backend/frontend activation.
The catalog can discover this metadata without starting the backend or loading
credentials.

Stock preparation separately opts this backend into `dev.adele.openai.api-key`
startup metadata and only its `api-key` credential slot. The generic
[host-authorized credential client](../../../../packages/plugin_backend_support/README.md#credential-reads)
is available to an eligible generation; the backend uses it lazily for configured
provider invocations, never to preload secrets at startup.

The schema itself neither registers a provider nor selects a model. The backend
interprets captured nonsecret records into the routes below. Preparation belongs to the
[toolchain guide](../../../../docs/development/toolchain.md#local-plugin-compilation).
Nonsecret reference persistence and protected local credential bindings belong to
the [host association lifecycle](../../../../docs/architecture/profiles-and-configuration.md#record-association-lifecycle),
not this backend. No record files, credential references, protected envelopes, TOML
API or native keyring access are exposed to the AOT plugin.

## Configured API-Key Instances

[`OpenAiApiKeyConfiguration.fromRecords`](lib/src/openai_configured_provider.dart)
interprets only `providers` records of type `dev.adele.openai.api-key`. It retains
each stable record ID and configured display name. Display names must be nonblank
and contain no ASCII control characters. The Settings schema checks these two
conditions for the name and for any supplied endpoint. The backend independently
rejects invalid values and unknown fields rather than repairing the instance.
An absent `endpoint` uses `https://api.openai.com/v1/responses`. An explicit
endpoint must be an absolute HTTP(S) URI with a valid nonempty host, no user
information or fragment, and HTTP only for loopback destinations. An invalid supplied
endpoint never becomes the default. Rejection leaves healthy siblings and the
independent ChatGPT route eligible; rejected records are not advertised.
The entrypoint reports only the validated record ID and fixed rejection code
(`openai_record_invalid_values` or `openai_record_invalid_configuration`), never the
supplied endpoint, ordinary values or raw exception.

In **Global Settings > Providers**, choose **Add**. If a type choice appears,
select **OpenAI API**. Enter a nonblank **Name**. Leave **API endpoint** blank
for the default Responses endpoint, or enter a custom Responses URL. To return
to the default, clear the custom URL and save the record.
Choose **Create**, expand the saved record and select **Check credential status**
for its **API key** slot.
Use **Set credential** and then **Store credential** to attach the key. Check
the runtime application result; storing the key does not authenticate the account
or select it for a Session.

The Name determines the initial filename: `OpenAI Work` creates
`providers/openai-work.toml` if that filename is available. Editing the Name or
endpoint leaves the file in place. Settings generates the record ID independently
of the filename. To copy it, open **Advanced details** in Add
or expand the saved record's details. See the
[record editing guide](../../../../docs/architecture/profiles-and-configuration.md#creating-and-editing-records).
The plugin derives the inference `ProviderId` as `dev.adele.openai.api-key.<record-id>`,
independent of the display name, endpoint, key, credential reference or backend generation.

Provider IDs use the existing public validators. Startup records retain stable
record-ID advertisement order. `OpenAiConfiguredProviders` allocates a fresh opaque,
retireable route with `AdeleConfigurationContextRouter.registerContext` for every
configured revision, including startup revisions. Routes are not derived from record
IDs and are never rebound to new configuration. Separate inference/catalog dispatchers
share one revision's route, all in **one OpenAI AOT backend generation**.
The exact capability binding selects the context; generated model request payloads,
model IDs and provider options cannot select another account. Unknown contexts and
services fail closed. Duplicate record identities fail structural decoding rather
than selecting a winner. An empty record list creates no configured providers.

Advertisement establishes a valid configured route, not local credential presence
or successful OpenAI authentication. `OpenAiConfiguredModelProvider` creates a
single-subscription lazy stream. Every subscription requests exactly
`collection: providers`, `recordType: dev.adele.openai.api-key`, that configuration's
`recordId`, and `slot: api-key`. Startup revisions retain the original
`AdeleCredentialClient.readCredential` path through the generation's
`AdeleHostRequestMultiplexer` and infrastructure grant. Refreshed revisions instead
use an injected reader bound to their fresh `AdeleCredentialCapture`; failure never
falls back to startup authority. No uninvoked sibling is read and no HTTP begins until
the selected credential read succeeds. A logical provider does not retain a decrypted
key for reuse by later invocations.

Each invocation creates and owns a temporary `OpenAiModelProvider` and its HTTP
client, reusing the existing Responses implementation and generated dispatcher.
Output, observations and terminal events pass through that stream; pause/resume and
active-request cancellation propagate to it. Cancellation while a credential read
waits fences provider construction and late HTTP, without claiming to cancel the OS
prompt. Completion/cancellation releases the temporary provider. The entrypoint
handles reverse responses independently of forward dispatch, and closes its host
multiplexer before draining the router on shutdown. Configured requests do not
follow redirects to another endpoint or downgrade to HTTP.

The [configuration lifecycle](../../../../docs/architecture/profiles-and-configuration.md#configured-openai-providers)
supports explicit targeted refresh within that generation. Without refresh, a revision
keeps its immutable configuration and credential scope; a changed record can make later
credential reads fail stale rather than retarget the route. Already-started HTTP may
continue with a delivered key. Forget does not retract network authorization already
in flight, and dropping Dart strings is not a zeroization guarantee.

The legacy explicit development `OPENAI_API_KEY` / `ADELE_OPENAI_ENDPOINT` mode keeps
`dev.adele.openai.api-key` in the default context. Experimental ChatGPT keeps
`dev.adele.openai.chatgpt-experimental` in `chatgpt-experimental`, with its independent
credential-file/OAuth flow. Neither is a fallback for configured records, and records
cannot override their credentials or routes. `startupArgumentsOnly` continues to
suppress inherited environment configuration; `--chatgpt-only` constrains that legacy
startup path, not independently delivered records. The app's explicit ChatGPT
selection and the registry's provisional default rank/ID ordering are unchanged.

## Explicit Configured Refresh

[`OpenAiConfiguredProviders`](lib/src/openai_configured_refresh.dart) owns configured
revisions, their association-closed inference/catalog publication groups, and their
route/capture lifetimes. The [entrypoint](bin/openai_model_provider_backend.dart)
handles its control requests asynchronously so reverse host replies and data-plane
traffic continue. Startup does not request a live capture or eagerly adopt ready
groups: each original pair is adopted only when first targeted for replacement or
retirement, preserving its original exact registrations without consuming finite
publication handles for every untouched startup record.

Stock preparation declares this control in `backend.appliesRecordTypes` for
`dev.adele.openai.api-key`. [Global Settings](../../../../docs/architecture/profiles-and-configuration.md#applying-confirmed-record-changes)
uses that declaration, not an OpenAI-specific app adapter. The service is **not
advertised** as a Capability or granted to frontends or peer Capability consumers:

| Field | Exact Value |
| --- | --- |
| Service | `dev.adele.openai.configuration` |
| Configuration context | The backend connection's default context, not a configured record route |
| Unary method | `refreshConfiguredProvider` |
| Payload | Exactly `{"recordId":"work-openai"}`, with the selected portable record ID |

The app validates the exact `InstalledBackendActivation` before dispatch and after
the await. It uses the connection's declared-handler path, not an ordinary service
channel, Provider ID lookup or replacement backend. No host invocation context,
credential, endpoint, scope handle, or additional payload field is accepted. This
plugin-local control adds no framework or production application plugin import; see
the [control boundary](../../../../docs/architecture/contracts-and-capabilities.md#dynamic-capability-publication).

Each eligible refresh captures current nonsecret records and fresh credential
authority together, then prepares only the selected valid record's revision. It
performs no credential read, keyring unlock, model-list request or inference HTTP.
Inference and catalog share that revision's scoped reader and read lazily per operation.
Record edits and credential-only replacement both require a fresh revision even when
ordinary values compare equal. Forget leaves a valid record publishable but its next
credential read fails `notConfigured`; confirmed record deletion retires its pair.
Partial observations that omit the target fail, never treating omission as deletion.
The canonical [lifecycle rules](../../../../docs/architecture/profiles-and-configuration.md#configured-openai-providers)
define publication ordering, preflight failure, uncertainty and admitted-work behavior.

Every unary control result contains exactly `status`, a fixed snake_case `code`, and
Boolean `cleanupPending`, never record values, endpoint, credential/reference, capture
handle, native exception or response body:

| Status | Meaning / Representative Codes |
| --- | --- |
| `applied` | Confirmed `added`, `replaced` or `retired` publication. Not proof of authentication. |
| `noChange` | `already_absent`: complete observation confirms absence and no current revision exists. Equal ordinary values alone never produce this status. |
| `failed` | Rejected request, configuration, capture or preflight, such as `invalid_request`, `invalid_record_id`, `invalid_configuration` or `incomplete_observation`. |
| `unavailable` | Missing grants, shutdown, exhausted refresh admission, unavailable replacement or uncertain publication; no fallback or automatic retry. |

Capture and publication failures use fixed `credential_capture_` and `publication_`
code prefixes; raw host diagnostics never become codes. `publication_outcome_unknown`
requires restart, not a speculative retry.

`cleanupPending` reports outstanding retired-route drain or unconfirmed cleanup,
not whether configuration publication succeeded. It can be true on an `applied`
result while old work finishes; a cleanup failure keeps it true for the generation.
Reference-counted capture leases are released only after every owning revision's
exact route drains, including admitted inference streams and catalog calls. Refresh
does not wait in its queue for old HTTP or paused streams to finish.

Refreshes are serialized with at most **32 outstanding requests**, including the active
one. The host's **8-scope capture bound** counts retained refreshed revisions and
pending/draining captures, not just requests in this queue; startup authority is
separate. The existing [publication bounds](../../../../docs/architecture/contracts-and-capabilities.md#dynamic-capability-publication)
also apply. Exhaustion fails without eviction, startup fallback or forced retirement
of healthy siblings. Each targeted refresh currently retains one batch for its paired
services. If all eight scopes belong to active refreshed records, even a later
replacement or deletion cannot first capture fresh authority; restart is required.
Transient exhaustion from draining work may clear when that work settles.
An uncertain publication outcome blocks all further configured
refresh until backend restart; unrelated inference/catalog, legacy and ChatGPT routes
remain available. Restart captures persisted records without preserving live scopes.

## Configured Model Catalogs

Every valid record-backed API-key instance additionally advertises the optional
`dev.adele.model.catalog` Capability, major 1, implemented by
[`OpenAiConfiguredModelCatalog`](lib/src/openai_model_catalog.dart). Legacy
environment-key and experimental ChatGPT routes remain inference-only. A missing
or failed catalog does not remove or select an inference provider.

| Example record ID | Catalog `ProviderId` | Associated Inference `ProviderId` |
| --- | --- | --- |
| `work-openai` | `dev.adele.openai.model-catalog.work-openai` | `dev.adele.openai.api-key.work-openai` |
| `personal-openai` | `dev.adele.openai.model-catalog.personal-openai` | `dev.adele.openai.api-key.personal-openai` |

Catalog identity is deterministically `dev.adele.openai.model-catalog.<record-id>`,
independent of name, endpoint, credential and generation. Its namespace is disjoint
from inference identity. Each catalog declares an `AdeleProviderAssociation` naming
`dev.adele.model.provider`, major 1, and its own exact inference Provider ID. Normal
host activation verifies and retains the exact sibling registrations; matching
text or sharing a context is not association evidence. Both services share their
revision's fresh opaque context in the existing router, with distinct generated
`modelCatalog` and `modelProvider` service identities. Refresh keeps these semantic
Provider IDs but publishes fresh exact registrations and a fresh association.

### Endpoint Policy

Discovery uses only the selected configuration's validated Responses URI. For a
query-free path ending in `/responses`, replace only that terminal segment with
`models`, retaining scheme, authority, port and path prefix:

```text
https://api.openai.com/v1/responses -> https://api.openai.com/v1/models
http://127.0.0.1:8080/work/responses -> http://127.0.0.1:8080/work/models
```

Other paths, trailing slashes, and **any query component, including an empty `?`**,
produce `unsupported_discovery` before credential access or HTTP. Queries can select
API versions/routes or carry routing tokens; neither silently dropping them nor
assuming they apply to another operation is safe. No extra configuration field,
alternate-path probe, public-endpoint fallback, redirect, or HTTP downgrade is used.
The existing endpoint validation still requires HTTPS except for loopback HTTP,
and rejects userinfo, fragments, invalid hosts and invalid ports. An inference-valid
but nonderivable endpoint keeps its inference registration and advertises a catalog
that explicitly reports unsupported discovery.

### Observation And Lifetime

Parameterless `listModels()` reads only the selected record's `providers` /
`dev.adele.openai.api-key` / `<record-id>` / `api-key` credential through the same
revision-bound reader as inference: startup authority for untouched routes, the
captured scope for refreshed routes. Both paths reuse API-key validation; discovery
also requires printable ASCII before using a key as an HTTP header. Advertisement,
metadata discovery and association verification read no credentials. Each operation
reads afresh; no credential or catalog cache, account fallback, automatic retry,
polling or background refresh is introduced.

After credential success, one operation-owned HTTP client issues **GET** with
`Authorization: Bearer <key>` and `Accept: application/json`. A 30-second opening
deadline spans connection acquisition through response headers. A separate absolute
30-second completion deadline bounds the successful body, not a rolling inactivity
timer. At most **4 MiB** of decoded HTTP body bytes are accumulated, enforced before
appending each chunk, regardless of Content-Length. Strict UTF-8 and JSON decoding
require `object: "list"`, a `data` array, and model objects with `object: "model"`
and string `id`. Entry and snapshot constructors enforce the shared identifier,
duplicate, count (1,024), and aggregate text bounds. Any violation rejects the whole
observation; oversized lists are never truncated. HTTP 200 with an empty list is
successful empty discovery.

The [OpenAI models list reference](https://developers.openai.com/api/reference/resources/models/methods/list)
supplies IDs and basic metadata, not friendly display names, descriptions or effort
sets. Rows retain exact IDs in provider order; display name and description are null.
Additional fields (including owner, timestamps and shutdown metadata) are ignored,
not exposed as account information or authority. Reflected API keys or complete
configured/catalog endpoints in IDs reject the result rather than rewriting IDs.
Catalog inclusion **does not prove compatibility with ADELE's Responses-based
text/tool execution**.

Success, failure and backend shutdown fence callbacks, abort requests, force-close
the operation's client and cancel its response subscription, with a one-second
cleanup wait. Shutdown closes catalogs before draining generated dispatchers;
pending credential completions cannot initiate late HTTP. Late connection acquisition
is aborted before authorization headers are submitted. Platform connection acquisition
or cancellation can outlive their wait, but cannot publish data or retry. OS credential
waits are outside HTTP deadlines; backend-generation retirement fences them rather
than claiming to cancel a keyring prompt. Graceful configured-route retirement instead
drains admitted calls. Already transmitted authorization cannot be retracted.

Repeated calls query current server data without restarting ADELE. Provider records
and credential authority belong to the selected immutable revision, not whichever
record now has the same ID. Explicit refresh makes a new catalog available to fresh
resolution; old held bindings fail rather than follow it. Catalog calls admitted
before route retirement can settle on their original dispatcher and captured scope.

### Documented Reasoning Efforts

Only the public `https://api.openai.com/v1/responses` API-key route (default or
explicit) annotates returned IDs with `supportedReasoningEfforts`. The set is
documentation-backed, not reported by `GET /v1/models` or probed by inference.
The public API model cards below enumerate the supported explicit values and
identify the model, its documented aliases and any included default snapshot:

| OpenAI model cards | Explicit `reasoning.effort` values |
| --- | --- |
| [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) | `low`, `medium`, `high`, `xhigh`, `max` |
| [GPT-6.1 Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra), [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol), [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), [GPT-5.6 Sol (including `gpt-5.6`)](https://developers.openai.com/api/docs/models/gpt-5.6-sol), [GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna) | `none`, `low`, `medium`, `high`, `xhigh`, `max` |
| [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5), [GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4), [GPT-5.4 mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini), [GPT-5.4 nano](https://developers.openai.com/api/docs/models/gpt-5.4-nano) | `none`, `low`, `medium`, `high`, `xhigh` |
| [GPT-5.5 Pro](https://developers.openai.com/api/docs/models/gpt-5.5-pro), [GPT-5.4 Pro](https://developers.openai.com/api/docs/models/gpt-5.4-pro) | `medium`, `high`, `xhigh` |
| [GPT-5](https://developers.openai.com/api/docs/models/gpt-5) | `minimal`, `low`, `medium`, `high` |
| [GPT-5 Pro](https://developers.openai.com/api/docs/models/gpt-5-pro) | `high` |

The lookup is exact and deliberately incomplete. Unlisted spellings, including
unlisted snapshots and fine-tunes, remain unknown (`null`), not known-empty.
Custom endpoints always return unknown, even for an identical ID. No row is
added if the selected account does not list it. These hints neither choose a
default nor validate, rewrite or retry [inference requests](#reasoning-effort-requests).

### Safe Failures

Declared `ModelCatalogFailure` messages are fixed and `details` is empty. Failures
never include raw exceptions, endpoints, credentials, headers or response bodies;
non-200 bodies and redirect destinations are not interpreted. Generated transport
retains its opaque handling of unexpected exceptions.

| Outcome | Catalog Code |
| --- | --- |
| Any host credential denial/retrieval failure, invalid delivered API key, or closed catalog | `unavailable` (before HTTP, not a remote authentication rejection) |
| Nonderivable configured endpoint | `unsupported_discovery` (before credential access or HTTP) |
| HTTP 401 or 403 | `authentication` |
| HTTP 429 | `rate_limited` |
| Other non-200 status, including redirects, 404 and 5xx | `provider_failure` |
| Network/TLS/HTTP failure, opening or body deadline | `transport` |
| Invalid UTF-8/JSON/list/model structure, reflected private values, or body/contract limit | `malformed_response` |

These outcomes never consult another account, the environment key, or ChatGPT, and
never mutate inference selection or the generated inference request.

## Credential Failures

Host credential failures become one safe failed model-provider terminal before HTTP,
with fixed messages and no references, envelopes, native errors or secrets. Provider
codes use the `openai_credential_` prefix:

| Host Outcome | Provider Code Suffix | Required Recovery / Meaning |
| --- | --- | --- |
| `notAuthorized` | `not_authorized` | The exact record/slot access is not authorized. |
| `notConfigured` | `not_configured` | Attach the record's API key in Global Settings and check the runtime apply outcome. |
| `missingLocally` | `missing_locally` | The referenced key is absent on this machine; recover through Settings. |
| `storageUnavailable` | `storage_unavailable` | OS storage or strict authority validation is unavailable. |
| `invalidCredentialBinding` | `invalid_binding` | The stored protected binding is invalid; no repair is attempted. |
| `reconciliationRequired` | `reconciliation_required` | Explicit Settings reconciliation is required. |
| `staleConfiguration` | `stale_configuration` | Explicitly refresh or restart to capture current record/credential state; old bindings are not repaired. |
| `generationUnavailable` | `generation_unavailable` | The generation cannot use its credential grant. |
| `credentialAccessFailed` | `access_failed` | Credential access could not be completed. |

`notAuthorized` maps to the existing `ModelProviderFailureKind.permission`; the
other credential outcomes map to `unavailable`, not `authentication`. These are
pre-HTTP failures, not remote OpenAI authentication responses. An incompatible
delivered API-key value also uses `unavailable`, with `openai_credential_invalid_api_key`;
unexpected wrapper failures use `openai_configured_invocation_failed` without raw
exception text. No failure automatically retries, reconciles storage, consults the
environment key or switches to another record/ChatGPT. Existing OpenAI HTTP failures
remain separate outcomes after a request actually reaches the endpoint.

## Streaming Reliability

Each logical `ModelProviderService.invoke` uses a separate HTTP-attempt lifecycle
inside this provider. Production defaults are a **30-second response-opening
deadline**, a **five-minute rolling SSE inactivity deadline**, a **200 ms transport
retry delay**, and a **one-second cleanup wait**. Constructor-injected durations
support deterministic local tests; these are not generalized provider settings.

The opening deadline spans connection acquisition (`postUrl`), request submission,
and response-header waiting, independently of SSE consumption. Once headers arrive,
every received byte resets inactivity before UTF-8, line, or SSE decoding. Comments,
`keepalive`, metadata, and partial records therefore keep slow reasoning alive.
There is no total-inference deadline. Downstream pause propagates to the response
subscription and suspends the SSE timer; resume starts a fresh idle interval.
Non-success HTTP bodies retain their existing size bound and additionally have a
30-second capture deadline; body failure cannot turn a known HTTP rejection into a
transport retry.

At most **one transport retry** is allowed, and only before any semantic event has
been published. Eligible interruptions are socket/HTTP transport exceptions,
timeouts (including SSE inactivity), and EOF at a complete SSE-record boundary
without a semantic terminal. Malformed JSON/SSE, incomplete SSE records, invalid
UTF-8, unsupported events/items, explicit provider error terminals, TLS handshake
errors (which may indicate certificate/configuration problems), and unrecognized
exceptions are nonretryable. HTTP statuses do not trigger transport retries.
The existing ChatGPT 401 authorization recovery remains independently at most
once. Together these permit **at most three Responses HTTP attempts**, without
resetting either allowance. Redirects are disabled for both profiles, including
ChatGPT without affinity, so redirects cannot escape the endpoint or attempt bound.

**Any observation or completed output is a publication barrier**, including text
deltas, native reasoning, and tool proposals. A subsequent interruption preserves
that evidence, emits one failed terminal, and never retries. Ignored metadata and
keepalives are not publication. There is no output buffering/rollback, model
fallback, tool execution, or orchestration retry. A retry reuses the already encoded
request and captured endpoint, model, configuration and authorization; only the
explicit 401 path may recover that same authentication instance. It neither creates
another model invocation/Run nor reloads context or repeats earlier tool effects.
Configured API-key invocations retain one credential read and one temporary client
through their internal attempts, releasing the client at completion/cancellation.

Each abandoned attempt is fenced before cleanup or replacement. Request abort and
subscription cancellation are initiated, and cleanup is awaited up to its bound;
late cleanup errors are contained. Cancellation/provider disposal fences delayed
retries. No attempt force-closes a client shared with unrelated invocations.
**Residual limitation:** Dart exposes no per-request cancellation handle while
`postUrl` is acquiring a connection (including DNS). The invocation's wait is
bounded, but that underlying acquisition can remain pending; a late request is
aborted before headers/body submission. Likewise, a platform cancellation future
may outlive the cleanup wait, but has no publication or retry authority. Credential
store/OS-prompt and ChatGPT authorization/refresh waits are outside these inference
transport deadlines; this is not bounded application shutdown or Run cancellation.

Failures retain the existing semantic kinds and OpenAI-owned codes:

| Provider Code | Meaning |
| --- | --- |
| `sse_inactivity` | No received SSE transport bytes before the rolling deadline. |
| `response_open_timeout` | HTTP response opening exceeded its deadline. |
| `stream_transport` | A response-stream exception, distinct from inactivity. |
| `missing_terminal` | Premature EOF without semantic settlement; retains `malformedResponse`. |
| `invalid_utf8`, `unterminated_sse_event`, other strict parser codes | Nonretryable malformed/unsupported protocol. |
| `invalid_response_headers` | Ambiguous diagnostic headers; nonretryable, with response cleanup. |
| `network_error`, `http_transport`, `tls_error`, `transport_error` | Classified opening failure; TLS and unknown errors are not retried. |

Failure `providerDetails` adds fixed `transportStage`, classified `cause`,
`httpAttemptCount`, `transportRetryCount`, and `outputPublished`, with an optional
numeric `osErrorCode` for socket failures. Existing safe HTTP/authentication details
remain. Diagnostic strings are capped at 4,096 UTF-16 code units after full-secret
redaction; semantic/native output is not truncated. Raw exception messages/stacks,
credentials, request/native payloads and affinity tokens are not diagnostic fields.
The host's existing model-invocation
activity and Session Evaluator evidence retain these details without a new schema.
Failed-Run presentation may show safe classification/message/code from that Run's
last failed model invocation, explicitly labeled as such rather than claiming
unproven causality through the remote strategy failure.

## Function Tool Schemas

Both API-key and experimental ChatGPT request profiles send provider-neutral
function tools with explicit `strict: false` and their `argumentsSchema` unchanged.
The [OpenAI strict-mode guide](https://platform.openai.com/docs/guides/function-calling#strict-mode)
documents that Responses attempts strict normalization when `strict` is omitted,
including making every property required. Opting out preserves omission-sensitive
optional fields; the backend does not make them required or replace absence with
`null`. Tool argument validation remains authoritative in the tool implementation,
not in provider schema rewriting or model adherence to the schema.

## Reasoning Effort Requests

Both API-key and experimental ChatGPT profiles lower explicit
`ModelProviderRequest.reasoningEffort` through the same Responses request path to
`reasoning.effort`, using the exact strings `none`, `minimal`, `low`, `medium`,
`high`, `xhigh`, and `max`. Null omits the effort key and leaves the provider's
model-dependent default intact; it is not an alias for explicit `none`.
Effort is independent of the exact-model summary policy below: an explicit value
combines with `summary: 'auto'` only for that existing set, and otherwise sends
an effort-only reasoning object. Null with an unlisted model omits `reasoning`
entirely, not an empty object.

The current public [Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create)
and [reasoning guide](https://developers.openai.com/api/docs/guides/reasoning#reasoning-effort)
document these wire values and model-dependent support/defaults. Inference does
not consult the catalog, infer support from prefixes or use the summary set to
validate effort. It forwards an explicit choice unchanged, including `none`, and lets
the selected endpoint reject unsupported combinations. HTTP 400 retains the
existing failed `invalidRequest` terminal; no downgrade, option removal, model
substitution, or retry follows that rejection. Nonempty `providerOptions` remain
unsupported, and the ChatGPT profile still rejects an explicit output-token cap.

### Experimental ChatGPT: Requests And Catalog Evidence

ChatGPT effort support is based on first-party interoperability evidence, not an
assumption that the public API documents the subscription endpoint. At Codex
commit `7f01a84effccef40d4726c3ca12e6c839ec98d7a`,
[`Reasoning` and `ResponsesApiRequest`](https://github.com/openai/codex/blob/7f01a84effccef40d4726c3ca12e6c839ec98d7a/codex-rs/codex-api/src/common.rs)
carry optional effort alongside summary;
[`ReasoningEffort`](https://github.com/openai/codex/blob/7f01a84effccef40d4726c3ca12e6c839ec98d7a/codex-rs/protocol/src/openai_models.rs)
serializes all seven exact strings. The shared
[`build_reasoning`, `build_responses_request`, and `stream_responses_api`](https://github.com/openai/codex/blob/7f01a84effccef40d4726c3ca12e6c839ec98d7a/codex-rs/core/src/client.rs)
path carries effort into classic HTTP Responses with ChatGPT authentication, and
the [client tests](https://github.com/openai/codex/blob/7f01a84effccef40d4726c3ca12e6c839ec98d7a/codex-rs/core/tests/suite/client.rs)
cover the ChatGPT HTTP route (`chatgpt_auth_sends_correct_request`) and explicit
`max` serialization (`includes_configured_max_effort_in_request`). This supports
using ADELE's existing shared lowering rather than rejecting all explicit effort
for ChatGPT. It does not establish every account/model/effort combination, a stable
third-party contract, or live-provider acceptance. ADELE does not copy Codex's
default selection, effort normalization, Responses Lite, or workflow policies.

**ADELE advertises inference only for `dev.adele.openai.chatgpt-experimental`.**
The [backend entrypoint](bin/openai_model_provider_backend.dart) registers no
associated Model Catalog for this context. A preset can still name a model and
leave effort unset or specify it manually. Absence of a catalog means unknown
support, not an empty model list or a reason to query a different account.

**What Codex observes.** At `openai/codex` revision `9c5ebee9dfdbb07591ec22679a3650f15d1eb49c`
(2026-11-23), the [default ChatGPT base](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/model-provider-info/src/lib.rs)
and [models client](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/codex-api/src/endpoint/models.rs)
give `GET https://chatgpt.com/backend-api/codex/models?client_version=...`.
The [bearer profile](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/model-provider/src/bearer_auth_provider.rs)
carries the access token, bound `ChatGPT-Account-ID` and conditional
`X-OpenAI-Fedramp`. The response is `models[]`, not the API-key `data[].id` list.
Each [model descriptor](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/protocol/src/openai_models.rs)
has an exact `slug`, visibility, `supported_reasoning_levels` (effort/description
pairs) and a separate optional `default_reasoning_level`. The default is not the
set of supported values. For example, the [bundled catalog](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/models-manager/models.json)
lists `low` as the default for `gpt-6-astra` and `ultra` among its choices;
[Codex resolves `ultra` locally](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/protocol/src/openai_models/reasoning_effort.rs).
It is not an ADELE wire effort. Codex's [catalog manager](https://github.com/openai/codex/blob/9c5ebee9dfdbb07591ec22679a3650f15d1eb49c/codex-rs/models-manager/src/manager.rs)
can use bundled fallback or a versioned, identity-scoped cache with ETag refresh.
Neither the bundle nor a picker result proves current account entitlement or
acceptance by ADELE's classic Responses route.

**The documented third-party route is different.** OpenAI's ChatGPT plan preview
for open-source, locally hosted apps requires [registration and consent](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
with a host ID, an issued user/workspace-bound client ID and the granted
`chatgpt.tokens.use.direct` scope. Its [models and inference guide](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
uses the selected account's plan access token at `https://api.openai.com/v1/models`,
shows `visibility: "list"`, `display_name` and `slug`, and refreshes choices on
account switch. It specifies public `/v1/responses`, **not** ChatGPT `backend-api`.
This neither documents per-model effort sets for that preview nor authorizes
using ADELE's existing Codex-profile credentials there.

ADELE's [credential owner](lib/src/openai_chatgpt_auth.dart) loads an instance's
account-bound authorization and can rotate tokens under a credential-revision
check. A custom Responses URL does not specify a catalog URL. Inference auth is
not a grant to probe a sibling URL, follow a redirect, switch to the public
route, or import Codex's cache. Discovery would need an authorized catalog route,
bounded reads and timeouts, and a check before returning results that the live
provider and account still match after logout, relogin or retirement. This source
evidence is not a live ADELE catalog observation or validation of an effort.

## Reasoning Summary Requests

The backend requests provider-supplied reasoning summaries with
`reasoning: {'summary': 'auto'}` only for its narrow exact-model support set in
`lib/openai_model_provider_backend.dart`:

- `gpt-6-astra`
- `gpt-5.6-sol`
- `gpt-5.6-terra`
- `gpt-5.6-luna`
- `gpt-5.5`
- `gpt-5.4`

This guard applies to both existing request profiles. Other IDs, including
unlisted aliases or snapshots, retain the prior request policy without the
`reasoning.summary` field. It is not a prefix rule, a complete model catalog, an
assertion that every model supports summaries, or an effort-support allowlist.
Summary opt-in changes neither reasoning effort nor context policy. There is no
automatic retry that removes the option after a provider error.

The request choice is based on OpenAI's current
[reasoning-summary guide](https://developers.openai.com/api/docs/guides/reasoning#reasoning-summaries)
and [Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create).
The guide documents explicit opt-in, model-dependent support, and `auto` selecting
the most detailed supported summarizer. First-party
[Codex source at commit `7f01a84effccef40d4726c3ca12e6c839ec98d7a`](https://github.com/openai/codex/tree/7f01a84effccef40d4726c3ca12e6c839ec98d7a),
including its model catalog and classic Responses lowering, supplies additional
evidence for the experimental ChatGPT route. These external references are not
ADELE live-call results or a guarantee that an account/model will return nonempty
summary text. No E3 live-provider validation is claimed.

Existing `store: false`, `stream: true`, `parallel_tool_calls: true`, and
`include: ['reasoning.encrypted_content']` remain in place. Parallel tool calls
permit multiple proposals in one response, not concurrent ADELE tool execution.

## Response Metadata Compatibility

Both profiles explicitly accept `response.metadata` as nonterminal sideband, not
as model output, a tool proposal, or a replay item. Informational response fields,
reported-model/routing headers, account-verification recommendations
(`openai_verification_recommendation`), and opaque moderation/presentation data
(`openai_chatgpt_moderation_metadata`) are discarded without forwarding their
contents to model context, Run history, UI diagnostics, or logs. They do not change
authentication, the requested model, or affinity. Terminal metadata still comes
from the explicit terminal; completed output items remain authoritative.

This decision follows first-party Codex's
[Responses parser](https://github.com/openai/codex/blob/cfc11bfab31c6885ec8213ece435fc3347eda7a4/codex-rs/codex-api/src/sse/responses.rs)
and its consumers. Verification is advisory account-access guidance, not an
authorization grant; moderation metadata is presentation sideband, not a substitute
for refusal, failure, or incomplete settlement. SSE turn state comes from the HTTP
header, unlike Codex's WebSocket metadata-header capture.

Safety-buffering status is also nonauthoritative. An absent, null, or false
top-level `safety_buffering` marker is inactive and does not interrupt processing.
Active notifications are recognized as either a top-level `safety_buffering`
object on any supported event or a `response.metadata` event whose `metadata`
object has `type == 'safety_buffering'`. Both forms require `use_cases` and
`reasons` arrays containing only strings (including empty arrays), and accept an
absent, null, or string `retry_model`. Additional informational fields are allowed
but never interpreted or forwarded. The
[Codex structure](https://github.com/openai/codex/blob/cfc11bfab31c6885ec8213ece435fc3347eda7a4/codex-rs/codex-api/src/common.rs)
and parser separate these notifications from the underlying response event:
text deltas, completed items, and explicit terminals still process normally.

ADELE discards valid notification payloads without creating output, proposals,
replay items, or artificial terminals, and without changing affinity, account
routing, authentication, or model selection. Codex uses them for waiting-status UI
and optionally confirmed retry on another model, not client-side output/tool
buffering. ADELE currently offers neither a dedicated waiting-status interface nor
optional model-retry controls, and never automatically retries or switches models
because of this metadata.

Malformed active payloads fail with fixed `invalid_safety_metadata` diagnostics.
Unlike Codex's permissive parsing, ADELE validates both locations independently:
an inactive or valid top-level marker cannot hide malformed typed safety metadata.
Other `metadata.type` variants are rejected as `unsupported_response_metadata`;
non-null, non-object metadata is rejected as `invalid_response_metadata`.
Diagnostics never include notification payload values. Untyped informational keys
are not interpreted; this is not a guarantee of support for future metadata
directives or other unknown events.

Strict authoritative-event/item validation, hosted-tool rejection, streaming
observations and explicit terminals remain in place. Metadata itself never requests
a retry or model switch; transport recovery follows the publication rules above.

## Session Routing, Run State, And Cache Usage

For the experimental ChatGPT profile, a supplied `ModelProviderRequest.affinity`
maps its opaque live-Session routing ID to the literal `session-id` HTTP header.
The same Session keeps that ID across Runs, but each Run starts with null provider
turn state. Different live Sessions use different IDs; neither identity nor state
is persisted. A standalone single-Run caller can allocate its own routing ID.
The backend captures the first usable `x-codex-turn-state` header from a successful
HTTP response before consuming SSE, including an attempt that later needs a
pre-publication transport retry. Subsequent attempts replay that first usable token
unchanged; an unusable first header does not prevent a later usable capture. It
returns that token only through
`ModelProviderTerminal.affinityState`, including on incomplete, refused, failed,
and malformed/transport stream terminals when available. Later requests replay
the first token unchanged within that Run; later response headers do not rotate
it. The next Run retains the Session routing ID but must not send the preceding
Run's token. Cancellation without a terminal does not publish state.

The caller owns this ephemeral state for one live Run and exact provider/model
binding. There is no backend affinity table or durable state. The private envelope
is bound to the supplied scope, requested model, configured auth instance, and
endpoint. Unsupported or incompatible envelopes fail explicitly before HTTP.
Affinity-bearing requests do not follow redirects to another route.
Account or FedRAMP routing changes clear the old token before sending, including
the existing pre-output 401 recovery path; ordinary same-account token refresh
preserves it. IDs and tokens are bounded safe header values. Affinity tokens and
account routing stay out of usage, native replay metadata, history, and ordinary
diagnostics; failure text and diagnostic IDs redact known affinity values.

Null affinity and the API-key profile add no affinity headers. This policy changes
neither request bodies nor ordered replay: `nativeState` remains null,
`providerOptions` remain unsupported, and no `prompt_cache_key`,
`previous_response_id` or retention setting is introduced. Neither response IDs
nor retries authorize remote conversation resumption.
Affinity is a locality hint, not an assertion of cache residency or a cache hit.
The interoperability basis is pinned Codex
[ChatGPT session routing and turn lifetime](https://github.com/openai/codex/blob/ade17c62b0caf6fb1354eb7f3bc25853f44656ab/codex-rs/core/src/client.rs),
[HTTP first-value capture](https://github.com/openai/codex/blob/ade17c62b0caf6fb1354eb7f3bc25853f44656ab/codex-rs/codex-api/src/sse/responses.rs),
and [same-turn HTTP regression](https://github.com/openai/codex/blob/ade17c62b0caf6fb1354eb7f3bc25853f44656ab/codex-rs/core/tests/suite/turn_state.rs).

Both profiles preserve reported `usage.input_tokens_details.cached_tokens` and
`cache_write_tokens` as nullable read/write counts. A reported zero remains zero;
missing, null, or invalid counters remain unreported rather than fabricated zero.
The [public prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)
and [Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create)
document these fields. Public API automatic caching does not establish identical
ChatGPT routing or billing: [Codex pricing](https://developers.openai.com/codex/pricing#token-rates)
explicitly distinguishes subscription credit billing from API-key pricing.

## Replay And Presentation

The pure-Dart sibling [Contract](../contract/README.md), `openai_contract`, owns
identities and payload schema only, with no algorithms. Its shared raw constants
`openAiResponsesItemKind = 'openai.responses.item.v1'` and
`openAiResponsesItemVersion = 1` are unchanged. This backend imports them rather than
duplicating the native-envelope identity. Provider-native reasoning and compaction
items remain opaque to common model/orchestration consumers. Supported native
items, including encrypted content, retain their exact data and order for replay;
presentation does not sanitize, truncate, replace, or otherwise rewrite them.

`lib/src/openai_native_presentation.dart` owns
`projectOpenAiReasoningSummary(ModelProviderNativeEnvelope)`, including raw Responses
classification and processing bounds. `lib/openai_model_provider_backend.dart`
attaches the safe result while preserving exact native metadata. It accepts nonblank
`summary_text` parts of reasoning items and emits generated
`ModelProviderNativePresentation(kind, compactText, data)` with safe kind
`openai.responses.reasoning-summary.v1`, version 1, from Contract's
`openAiReasoningSummaryPresentationKind` and
`openAiReasoningSummaryPresentationVersion` constants. This identity is distinct
from the raw item kind. Safe `data` contains only `summaryParts` and `truncated`.
Unknown kinds/versions, other native item types, malformed summaries, and empty
summaries produce `nativePresentation: null`. Input validation is bounded to 1,024
parts and 262,144 aggregate UTF-16 code units before expensive text processing;
oversized input also yields no presentation without changing replay. Within that
budget all parts are validated, including suffixes later discarded by display
bounds. No encrypted content is decoded or hidden chain of thought exposed.

Full display text retains at most 32,768 Unicode code points across 128 trimmed,
nonblank parts. `truncated` reports full-text loss, not merely compact shortening.
Compact text uses the first retained part and is capped at 160 code points,
including an ellipsis when compact or full text is truncated. These algorithms
belong here, not in Contract or app activation. Generic Chat escapes compact
display controls and reapplies its compact cap after escaping; the OpenAI frontend
separately escapes full display text.

`ModelProviderOutput.nativePresentation` is required but nullable. Semantic
optionality is represented by `null`, not by omitting the generated key; the
existing coherent-schema convention remains unchanged. Text/tool outputs and
native items without a supported safe summary carry null. The generic app adapter
maps the DTO to immutable orchestration `ModelNativePresentation` with the same
fields on optional `ModelNativeOutput.presentation`; it does not interpret OpenAI.

Raw `nativeMetadata` stays exact and is the only native replay source. Safe
presentation is never replayed, and no canonical history or persistence change is
introduced. The backend and full Run retain native/encrypted evidence independently
of presentation activation. Only the safe presentation data enters the
separate [OpenAI frontend EVC](../frontend/README.md). Raw native envelopes,
compatibility metadata, encrypted content, and execution/approval authority do
not cross that presentation bridge. The frontend depends on neither this backend
implementation nor model readiness. Generic Chat and Inspection never parse OpenAI.
Missing or failed rich presentation does not remove safe Chat activity.
Malformed/unsupported summary input yields no presentation, while factory/EVC
failures remain presentation-local. Neither changes Run settlement or replay
validity; backend request/replay errors retain their existing explicit failure
semantics.

## Validation Scope

`test/openai_configured_refresh_test.dart` owns controller lifecycle checks. The app's
`test/core/openai_record_startup_integration_test.dart` exercises Global Settings
and explicit control against the prepared backend, with real inference/catalog
publication, credential capture and route replacement.

`test/openai_model_catalog_test.dart` covers finite HTTP decoding, exact IDs and
bounds, documented public-route efforts versus unknowns, safe failures, endpoint
derivation, no fallback, fresh reads and cleanup using controlled HTTP/credential
fixtures. The configured startup/AOT suites also
assert the complete inference/catalog exposure sets and explicit associations.
The app's `test/core/openai_record_startup_integration_test.dart` invokes the real
prepared OpenAI catalogs through an independently prepared public Capability consumer,
real host credential authority and loopback model lists, alongside Responses inference.
The generic consumer/authority matrix remains in
`app/test/core/backend_capability_integration_test.dart` rather than being duplicated.

After bootstrap/current generation, focused catalog checks are:

```sh
# Repository root
dart tools/adele.dart test --target openai_model_provider_backend
dart tools/adele.dart test --target adele_model_provider
# app/
flutter test --no-pub --concurrency 1 test/core/openai_record_startup_integration_test.dart test/core/backend_capability_integration_test.dart
```

`test/openai_streaming_reliability_test.dart` uses controlled HTTP objects, explicit
gates, and short deadlines for inactivity, opening waits, retry/publication bounds,
pause/resume, late completion, cleanup faults, concurrent invocations, authentication
recovery, affinity, and safe diagnostics. The desktop
`test/core/durable_chat_session_integration_test.dart` additionally exercises real
AOT Chat/OpenAI and host authorization through a local HTTP continuation retry after
an approved tool turn, preserving the model budget, history/context capture, and
one tool outcome. `test/session_execution_test.dart` covers failed-Run presentation
from public activity, including Run/Session isolation and remote failure conversion.

The maintained pure-Dart targets are:

```sh
dart tools/adele.dart test --target openai_model_provider_backend
dart tools/adele.dart test --target openai_contract
```

Run these from the repository root. Contract tests cover stable identities, not
algorithms. `test/openai_configured_provider_test.dart` owns record interpretation,
endpoint validation, safe credential failures and per-invocation resource lifecycle.
Configured-record startup and real AOT routing belong to
`test/openai_record_startup_test.dart` and
`test/openai_configuration_context_integration_test.dart`. The app's
`test/core/openai_record_startup_integration_test.dart` additionally uses maintained
stock metadata, real TOML records and protected associations through host credential
authorization, with deterministic storage and loopback HTTP. See
[configured-provider checks](../../../../docs/development/testing.md#configured-openai-provider-checks)
for ownership, lifecycle/failure coverage and commands; these are not live OpenAI or
real Secret Service tests.

Backend tests in `test/openai_native_presentation_test.dart` and
`test/openai_model_provider_backend_test.dart` cover raw classification,
projection, processing bounds, preservation, all seven explicit effort values and
null across both profiles and summary/non-summary models, exact request bodies and
auth headers, rejected options, HTTP 400 without retries, guarded summary lowering,
ordered native/encrypted replay, safe projection, malformed/unsupported/empty
summaries, and compact/full display bounds. The separate app
`test/core/normal_chatgpt_run_integration_test.dart` uses real host/Git/OpenAI
artifacts and prepared frontends against local fake Responses for mixed
reasoning/tool approvals and a separate reasoning-only final response.

Backend affinity tests use local fake HTTP/OAuth endpoints to check first-token
retention, scope/model/endpoint/account isolation, auth recovery, cancellation and
failure settlement, redaction, unchanged bodies/replay, and nullable cache usage
across both profiles and semantic settlements. They do not assert real cache hits.
Metadata fixtures cover both profiles before/between/after output, inactive and
valid active safety-buffering forms, explicit terminals and premature EOF,
malformed safety and unknown typed payloads, and unchanged strict output validation
and replay. The normal Chat AOT fixture also includes safety-buffering notifications
without changing its expected history, tool approvals, or HTTP affinity.

Local fake endpoints and temporary fake credentials require no live account or
API key. Existing opt-in live smokes remain separate and do not establish summary
support. Generated transport and app adapter tests cover safe-payload mapping,
the required nullable key, and raw-only replay. Hidden chain-of-thought and
encrypted reasoning are never user-presented. Reasoning deltas, compaction UI,
Session provider/model selection UI, and broader Source/Diff/Console,
terminal/PTY/full-output presentation remain deferred.
