# Conservative Tool Policy

`conservative_tool_policy_backend` is the pure-Dart backend package in
[`packages/backend/`](packages/backend/). It supplies an independent stock
authorization opinion using only the public
[`RemoteToolAuthorizationPolicyService`](../../packages/orchestration/lib/remote_tool_authorization.dart)
contract. It does not import the application, kernel, internal host, or Flutter.

## Identity and installation

| Identity | Value |
| --- | --- |
| Plugin | `dev.adele.plugin.conservative-tool-policy` |
| Extension | `dev.adele.plugin.conservative-tool-policy.authorization` |
| Extension point | `toolAuthorizationPolicies` (`dev.adele.extension.tool-authorization-policies`) |
| Service | `remoteToolAuthorizationPolicyServiceId` (`toolAuthorizationPolicy`) |
| Route | `conservative` |

[`bin/conservative_tool_policy_backend.dart`](packages/backend/bin/conservative_tool_policy_backend.dart)
is the ordinary shared-host AOT entrypoint. Normal preparation publishes
`installations/conservative-tool-policy/backend.aot` in the prepared snapshot as a
backend-only installation.
[`publishStockPluginInstallation`](../../tools/backend_artifacts.dart) publishes
the boolean setting schema and an installation-level `authorizationPolicies`
declaration binding this Extension ID to its `enabledSettingId`. Discovery reads
the declaration independently of backend availability. It is neither a live
registration nor execution authority.

When enabled, readiness advertises exactly one `AdeleExtensionExposure`, bound to
the supplied default configuration context, with only `{'routeId': 'conservative'}` metadata.
Plugin identity belongs to the installation and connection, not the exposure.
Generic activation and the remote policy adapter register and retire its exact
generation; there is no special activation table or fallback implementation.

There is no frontend, capability advertisement, startup argument, configuration
record, or requested host service. See [plugin layout](../../docs/architecture/plugin-layout.md#expected-authorization-participation)
for the installation boundary.

## Global setting

In **Global Settings / Agents / Tool Authorization**, **Enable Conservative Tool
Authorization** (`dev.adele.plugin.conservative-tool-policy.enabled`) defaults to
`true`. Save the change and restart ADELE to apply it. The running backend and
host use the same captured value for the lifetime of that startup.

With `false` the backend starts normally but does not advertise this evaluator or
serve its route. Its Ask and Deny decisions no longer apply. Other active policies
still participate. **If no policies remain, tool operations may execute without
approval.** This does not grant filesystem or process access, repair a stale
tool binding, or waive a tool's preconditions. Disabling the setting is distinct
from a failed backend: if the policy is enabled and unavailable, new requests
fail without executing. A missing or invalid startup value is not `false`.

## Decisions

[`ConservativeToolPolicyBackend`](packages/backend/lib/conservative_tool_policy_backend.dart)
uses `request.toLocal()` for shared semantic validation and effect conversion.
Its decision depends only on the complete effect set and uncertainty:

| Effect set | Uncertainty | Decision |
| --- | --- | --- |
| Exactly `sourceRead` | `none` | Allow |
| Exactly `resourceInspection` | `none` | Allow |
| Exactly `sourceMutation` | `none` | Ask |
| Exactly `processExecution` | `none` or `uncertain` | Ask |
| Any other combination, including empty or mixed sets | Either | Deny |

Uncertain reads, inspections, and mutations are denied. The policy never returns
Abstain. Tool names, canonical arguments, target URIs, effect summaries, and
Run/Session/Project/invocation IDs do not override the table. Unknown routes throw;
malformed requests and evaluator errors remain failures, not authorization
decisions. Shared generated dispatch rejects malformed payloads without inventing
defaults or coercing effect values.

## Authority

The backend receives immutable request data, not executable tools, approval
tokens, host invocation contexts, or Environment filesystem/process/shell access.
It makes no host-service requests and performs no proposed effects. IDs and
target URIs are data, not access grants. An Allow opinion is not execution
authority: the host still owns composition, approvals, binding validation, and
execution. This is an ADELE-mediated authority boundary, not an OS sandbox.

Omitting this optional installation contributes neither a policy nor an expectation;
the app does not recreate Conservative behavior. See the host's rules for
[authorization composition](../../docs/architecture/execution-model.md#authorization-composition).

## Validation

After repository bootstrap and current contract generation, run
`dart tools/adele.dart test --target conservative_tool_policy_backend` from the
repository root, or `dart test` within `packages/backend/` for focused iteration.
Package tests cover all 16 effect subsets with both uncertainty values, generated
dispatch and canonical conversion, malformed requests, route failures, and real
entrypoint readiness/routing without host-service authority. The application-owned
[`conservative_tool_policy_integration_test.dart`](../../app/test/core/conservative_tool_policy_integration_test.dart)
covers prepared AOT installation and generic activation, including stock approval,
the disabled setting on restart, optional absence, and unavailable expected policy.
Package tests alone do not establish those integration boundaries.
The stock publication and catalog-discovery checks in
[`backend_artifacts_test.dart`](../../test/tools/backend_artifacts_test.dart)
cover the exact installed declaration, unrelated/optional absence, and retained
expectations with missing or invalid backend components without activating code.
