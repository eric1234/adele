# Contracts and Capabilities

## Separate questions

Contracts and capabilities solve different problems:

| Concern | Question |
| --- | --- |
| Contract | How do typed values and asynchronous operations cross a runtime boundary? |
| Capability | Which compatible provider handles a request? |

One generated typed request/response transport is implemented for
`workspace_demo`. General transport generation and capability resolution remain
unimplemented.

## Contracts

Plugin contract source is shared by frontend and backend packages and should
normally describe immutable snapshot values. A value received across a runtime
boundary is reconstructed; its object identity is not shared with the sender.

The Phase II internal generator provides a typed client, dispatcher, codecs,
request handling, and structured errors for the maintained fixture. Its scope is
one non-empty service per contract library and unary request/response only.
Values use one unnamed generative constructor with
required named parameters, schema enums and values must be declared in the
contract source library rather than imported, wire IDs use a conservative ASCII
segment grammar, and every transported double must be finite. Streams,
cancellation, events, and broader schema composition remain future work.
Generated code should hide ports, wire formats, request IDs, subscriptions, and
transport details from plugin code. Contract declarations remain lightweight
and independent of compiler or generation tooling.

The generated transport layers over the proven process-hosted communication
path through a transport-neutral request channel. Its annotations and generator
remain experimental; no general schema compatibility policy is accepted yet.
Dispatch explicitly decodes the envelope and method, decodes arguments, invokes
the service, and encodes the result as separate stages. Malformed requests are
`invalid_request`; every service-thrown undeclared exception, including
`AdeleProtocolException`, is `internal_error`; and backend results or declared
failure details that violate the generated response contract become opaque
`backend_contract_violation` failures. URI values, including `ResourceRef.uri`,
must be reconstructible absolute URIs.

Committed transport is checked in normal CI. Development plugin preparation
also checks the requested plugin independently: the manifest-selected contract
package's `pubspec.yaml` name determines `lib/<package-name>.dart`, and that
absolute source is passed explicitly to `contract_codegen --check --source`.
This keeps stale transport failure local to the plugin and ahead of compilation.

## Capability semantics

| Kind | Semantics | Examples |
| --- | --- | --- |
| Action | Brokered one-shot request/response operation | `EditResource`, `ViewResource`, `ShowDiff`, `OpenTerminal` |
| Service | Sustained typed capability | `WorkspaceService`, `SourceControlService`, `ModelProvider`, `ToolProvider` |
| Event | Fact that has occurred | `ResourceChanged`, `EditorOpened`, `PluginStarted` |

Actions, services, and events retain these distinct semantics even if they
eventually share generated transport infrastructure.

## One-to-many provider resolution

Several plugins may implement one action or service:

```text
EditResource
|-- ADELE in-app editor plugin
`-- External editor launcher plugin
```

A future caller must be able to:

- Check whether a compatible provider is available.
- Enumerate all compatible providers.
- Invoke ADELE's preferred provider.
- Explicitly select and invoke another provider.

Callers must handle zero, one, or many providers. ADELE owns preference
resolution and deterministic fallback; a provider cannot declare itself
globally primary. Future selection may consider explicit selection, user and
profile preferences, workspace overrides, request compatibility, resource
scheme, media type, availability, and dynamic suitability. The matching model
and precedence are intentionally deferred.

Phase 0 has no capability registry, provider discovery, ranking, routing,
preference persistence, message bus, or cross-plugin transport.

## Configured capability instances

One plugin runtime may expose multiple named configurations of the same
capability:

```text
OpenAI plugin runtime
|-- Model provider: Work
`-- Model provider: Personal
```

Accounts, providers, clusters, connections, endpoints, and devices are
configured capability instances. They do not require separate plugin
installations, backend copies, or runtime instances. A future ADELE profile may
make several instances available, prefer one, and apply optional configuration
overrides.

Provider-instance persistence, account and credential management, discovery,
selection, and profile-aware routing are not implemented in Phase 0.

## Runtime resources

Browser sessions, terminal sessions, open documents, processes, temporary
connections, and active tool executions are runtime resources. They are
normally represented by temporary handles or session objects. They are not
persistent configured capability instances, plugin runtime instances, or
plugin installations.
