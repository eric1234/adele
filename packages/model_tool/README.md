# ADELE Model Tools

Public, Flutter-free model-tool contribution and execution contracts. The package
owns tool definitions, materialized registrations, canonical arguments, effect
descriptions, outcomes and their generated remote transport. Concrete tool behavior
belongs to plugins; execution admission, policy, approvals and live authority belong
to the host. See the [execution model](../../docs/architecture/execution-model.md)
and [dependency rules](../../docs/architecture/dependency-rules.md).

## Entrypoints

- `adele_model_tool.dart`: native contributions, Session host context, executable
  registrations and provider-neutral tool semantics.
- `remote_model_tool.dart`: annotated transport DTOs and `RemoteModelToolService`,
  with generated clients and dispatchers in its ignored sibling part.

## Remote materialization

`RemoteModelToolService.materialize` receives a
`RemoteModelToolMaterialization`, not a Session ID string. Its required fields are
`sessionId`, nullable `environmentId` and nullable `shellProfile`. The identities
use canonical product validation, and a non-null profile requires an Environment
ID. This is immutable data scoped to the exact host-captured Session, Environment
and tool materialization, not durable state, an authority token, or permission to
resolve a different binding.

The generic host requests shell discovery only for an exposure declaring
`authorizedEnvironmentShellServiceId`. A null profile means that the exposure
requested no shell description or the captured Environment explicitly reported
`shell_unavailable`. Unexpected discovery failures must remain failures, not a
silent null profile or fallback interpreter.

`RemoteEnvironmentShellProfile` is a local wire projection of
`adele_environment.EnvironmentShellProfile`, because generated schemas do not
import another schema's value declarations. Its `profileId`, `interpreter` and
open `dialect` token retain the Environment contract's exact values and bounds;
construction delegates validation to that canonical type. `fromLocal` and
`toLocal` convert without choosing or normalizing an interpreter. The
`adele_environment` dependency serves this public semantic boundary, not a host
implementation dependency.

Materialization, argument validation and effect description receive no invocation
authority. Only execution receives the host-issued operation context. Consumers
that do not need shell metadata may ignore it; existing stock tools preserve their
descriptors, routes, schemas and descriptions.

## Validation

After repository bootstrap, `dart tools/adele.dart test --target adele_model_tool`
regenerates contracts and runs the maintained package target. Focused transport
coverage lives in `test/remote_model_tool_test.dart`, including strict generated
materialization decoding, semantic validation and authority-free snapshots. See
[testing and validation](../../docs/development/testing.md) for direct local
iteration and [generation policy](../../docs/development/toolchain.md#generated-contract-artifacts)
for ignored generated parts.
