# Contracts and Capabilities

## Separate questions

Contracts and capabilities solve different problems:

| Concern | Question |
| --- | --- |
| Contract | How do typed values and asynchronous operations cross a runtime boundary? |
| Capability | Which compatible provider handles a request? |

One manual typed reference transport is implemented for `workspace_demo`.
General transport generation and capability resolution remain unimplemented.

## Contracts

Plugin contract source is shared by frontend and backend packages and should
normally describe immutable snapshot values. A value received across a runtime
boundary is reconstructed; its object identity is not shared with the sender.

Future internal generation is intended to provide typed proxies, dispatchers,
serializers, request handling, streams, cancellation, and structured errors.
Generated code should hide ports, wire formats, request IDs, subscriptions, and
transport details from plugin code. Contract declarations remain lightweight
and independent of compiler or generation tooling.

The process-hosted communication path is proven. Its manual proxy, dispatcher,
and codecs remain reference evidence for future generation; no stable generator
API or compatibility policy is accepted yet.

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
