# ADR 0027: Generation-bound plugin configuration contexts

## Status

Accepted for Phase IV-B5a

## Context

One plugin runtime may expose several configured capability instances. The
OpenAI API-key and future ChatGPT configurations made the missing runtime
boundary concrete, but the requirement is capability-generic. A configured
plugin state may expose several providers and services, so `ProviderId` cannot
also be the backend configuration-routing identity.

The capability registry could distinguish provider descriptors, but generated
request and stream clients previously reached one backend connection without
identifying the configured plugin state under which the operation should run.
Putting that identity in semantic request data would allow callers to redirect
an invocation by changing payload, provider options, model data, or native
state.

## Decision

Every capability invocation executes under exactly one
`ConfigurationContextId`. It is an opaque, generation-bound runtime handle for
configured plugin state. Configuration contents remain plugin-owned and do not
cross the transport boundary. The runtime handle does not define persistent
configuration identity, profile storage, account schemas, or configuration
lifecycle.

`ProviderId` continues to identify one exposed capability provider.
`ConfigurationContextId` identifies the configured plugin state under which
one or more providers and services execute. Several provider descriptors may
share one context, and one plugin generation may host several contexts.
`serviceId`, generated method ID, and semantic payload remain separate.

Capability registration explicitly associates each `ProviderDescriptor` with
one `ConfigurationContextId` through `PluginCapabilityExposure`. The resulting
endpoint owns a channel scoped to the exact plugin connection generation and
context plus the descriptor's exact `serviceId`. Generated clients still call
only `request(method, payload)` or `stream(method, payload)`; the concrete
channel adds `configurationContext` and `serviceId` to the request or
stream-open envelope.

The backend host requires and forwards context and service identity beside
method and payload.
The plugin-side `AdeleConfigurationContextRouter` validates the context,
selects the dispatcher by exact `(configurationContext, serviceId)`, removes
transport metadata, and
then delegates the original generated command shape to a generated dispatcher.
Generated contracts and dispatchers remain configuration-unaware. Missing,
malformed, and unknown contexts fail closed. Semantic payload cannot select or
override the context.

Stream credit and cancellation do not repeat the context. The router records
the dispatcher selected at stream open and routes later control commands by the
already-bound request identity. Existing one-credit backpressure,
cancellation, failure containment, and generation retirement semantics remain
unchanged.

Every plugin connection has one explicit default context. Single-configuration
plugins bind all capability exposures to it and validate its token in their
entrypoint router. Default means an explicitly supplied runtime context, not
absence of context. Plugin lifecycle and host-control operations remain scoped
to the plugin generation and do not require a capability configuration
context.

The initial backend-host framed protocol, version 1, makes context and service
identity mandatory for capability request and stream-open frames. Runtime and
backend-host artifacts fail startup on version mismatch and must be deployed
atomically. Plugin isolate startup separately acknowledges the initial generic
plugin-backend command protocol before the host publishes the generation as
ready, so an incompatible plugin artifact cannot silently ignore required
metadata.

## Consequences

- Provider discovery identity is not overloaded as configuration identity.
- One configured plugin state can back several capability providers/services.
- Bindings cannot migrate contexts when a plugin generation is replaced.
- Generated semantic contracts and ModelProvider semantics do not change.
- Existing single-configuration plugins use the same invocation invariant with
  one explicit default context.
- Dynamic configuration creation, persistence, profiles, credentials, and UI
  remain deferred.
