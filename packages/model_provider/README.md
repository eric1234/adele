# ADELE Model Provider

This public, pure-Dart package owns two separate provider-neutral contracts:

- [`adele_model_provider.dart`](lib/adele_model_provider.dart): the existing
  streaming `ModelProviderService.invoke` inference contract.
- [`adele_model_catalog.dart`](lib/adele_model_catalog.dart): optional unary
  `ModelCatalogService.listModels`, Capability `dev.adele.model.catalog` major 1,
  generated service `modelCatalog`.

Neither contract imports concrete providers or host implementations. An inference
provider need not advertise a catalog, and the application needs no catalog to run.

## Reasoning Effort

`ModelProviderRequest.reasoningEffort` carries the provider-neutral
`ModelReasoningEffort` values `none`, `minimal`, `low`, `medium`, `high`, `xhigh`,
and `max`. Null means unspecified and leaves provider defaults unchanged; `none`
is an explicit request, not absence. An explicit value must be honored or fail,
never silently ignored, downgraded, or replaced. The vocabulary does not guarantee
that every provider, route, or model supports every value. Concrete lowering and
support failures belong to the provider.

Effort is independent of model identity, reasoning-summary presentation, and
output-token limits. Equal enum values do not promise equal computation, latency,
or cost across providers. It is invocation configuration, not tool authority,
an orchestration strategy, or Session identity.

Effort uses the existing generated inference transport, separate from
`providerOptions`, routing affinity, native continuation state, and catalog
metadata. The wire carries the exact enum name or explicit null and rejects
unknown values or malformed types. Request collection and structured-data
snapshots retain their existing immutability guarantees.
Like other nullable generated DTO fields, the constructor argument and wire key
are required; callers supply null when unspecified. Prepared consumers must be
rebuilt together under the existing pre-release transport policy, without
mixed-schema compatibility fallbacks.

The application adapter captures effort immutably alongside its selected model
and forwards it for every invocation, including tool continuations; new adapters
capture independently. This adds no Session preference, model preset, persistence,
selection UI, or catalog support inference. See the
[model invocation boundary](../../docs/architecture/execution-model.md#model-invocation).

## Model Catalog

`listModels()` takes no arguments. Its exact resolved Capability binding selects
the provider configuration; request data cannot select an account, credential,
endpoint, or configuration context. The result is one finite observation, not a
global registry, permanent startup snapshot, or promise of future availability.
Repeated calls can observe new data without an application restart. Future live
reconfiguration can publish new registrations through the ordinary registry;
captured access never migrates to a replacement generation.

`ModelCatalogSnapshot.models` preserves provider order in a defensive unmodifiable
copy. Each `ModelCatalogEntry` has the exact inference `modelId` and nullable
provider-supplied `displayName` and `description`. IDs are case-sensitive and never
trimmed, normalized, or treated as global identities. Null metadata stays unknown;
catalog inclusion does not establish ADELE text/tool inference compatibility.

Bounds are 1,024 entries, 1,024 UTF-16 code units per ID, 256 per display name, and
4,096 per description, with 1,048,576 total UTF-16 code units across all text fields.
The aggregate bound leaves room for worst-case JSON escaping and transport envelopes
within the existing backend frame limit. Supplied strings must be nonblank and
contain no NUL; IDs additionally reject ASCII control characters. Optional metadata
uses explicit null when absent, including on the generated wire. Exact duplicate
IDs and excessive values reject the whole result, never silently truncate it. An
empty successful snapshot is valid, not a representation of unsupported or failed
discovery.

`ModelCatalogFailure` uses ADELE's declared `code`/`message`/`details` convention.
Providers classify authentication, rate limiting, unsupported discovery,
unavailability, transport, malformed provider responses, or other provider failures
using the documented codes, caller-safe messages, and empty details. Do not copy
backend exceptions, credentials, endpoints, HTTP bodies, or sensitive diagnostics
into declared failures. Unexpected exceptions remain sanitized by generated
transport. Malformed generated values are protocol failures, and missing or stale
Capability resolution is separate from provider discovery failure.

## Association And Consumption

A catalog exposure is the source of an `AdeleProviderAssociation` naming its exact
sibling ModelProvider Capability ID, major, and Provider ID in the same activation.
The plugin owns the semantic account relationship; the host validates registration
provenance and retains the exact pair. Matching IDs, plugin identity, or context
strings alone do not establish that relationship. See the canonical
[catalog and binding semantics](../../docs/architecture/contracts-and-capabilities.md#model-catalog).

An independent prepared backend declares the catalog in `consumesCapabilities`,
discovers providers with `AdeleCapabilityConsumer`, resolves an explicit provider
and `modelCatalogServiceId`, and constructs `ModelCatalogServiceClient` over its
request-only channel. Release the access when finished. Catalog access supplies
neither inference execution nor credential/authentication authority.

The stock [OpenAI backend](../../plugins/openai/packages/backend/README.md#configured-model-catalogs)
implements this contract for record-backed API-key instances, associating each
catalog with its own configured inference provider. Its endpoint derivation,
credential/HTTP lifecycle, safe failures and metadata limitations are provider-owned;
legacy environment-key and experimental ChatGPT routes remain inference-only.

## Validation

After the repository's pinned-toolchain bootstrap, use
`dart tools/adele.dart generate --check` and
`dart tools/adele.dart test --target adele_model_provider` from the repository root.
The application backend-capability integration suite owns the independently
prepared AOT provider/consumer proof. Generic association and consumer lifetime
checks remain with their existing runtime and backend-support owners.
