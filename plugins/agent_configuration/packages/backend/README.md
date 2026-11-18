# Agent Configuration backend

[`bin/agent_configuration_backend.dart`](bin/agent_configuration_backend.dart)
registers the generated `agentCatalog` dispatcher on the shared AOT host's default
configuration context. It exposes no Capability or Extension Point. The public
[contract](../contract/lib/agent_configuration_contract.dart) returns definitions,
not a selected Agent, an inference contribution, or authority to run anything.

The prepared backend opts in to exactly `dev.adele.plugin.agent-configuration.agent`
from its [installation's schema](../../records.schema.json), and to no credential
slots. Its `AdeleConfigurationClient` is bound to the infrastructure context of
the generation the host started. Each `readAgents()` calls `currentRecords()`;
there is no startup-value fallback, record store, or cache in the plugin. The host
owns validation and I/O. The backend projects the `agents` records to public
definitions without altering their strings.

A partial read returns the healthy definitions with `isComplete: false`, even if
none remain. This differs from a clean empty snapshot (`isComplete: true`) and
from failure. If live access fails or the response does not match the authorized
projection, the active service returns a bounded `AgentCatalogFailure` without
record contents or host diagnostics. If the backend itself is missing or retires,
the service is unavailable; Global Settings still owns editing, and Chat and
Project restoration do not depend on this service.
