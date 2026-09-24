# Workspace Demo Contract

`workspace_demo_contract` is the plugin's shared pure-Dart contract package.
It is plugin-owned public contract source, not an ADELE public package or
internal host implementation package.

It may depend on `adele_contract`, `adele_plugin_api`, and
`adele_capabilities` as concrete declarations require. Flutter, the sibling
frontend and backend, ADELE internal packages, and `adele_desktop` are
prohibited dependencies.

The annotated [`workspace_demo_contract.dart`](lib/workspace_demo_contract.dart)
is the source of truth for directory entry/listing and text-content DTOs, the
typed asynchronous filesystem service, and structured semantic failure. It
declares `part 'workspace_demo_contract.g.dart';`. Repository generation uses
[`contract_codegen.yaml`](../../../../contract_codegen.yaml) to materialize that
native sibling, which is Git-ignored local output, not committed source. The
generated part supplies the typed native client, dispatcher, codecs, and service
ID; wire details are not hand-maintained semantic declarations.

The package remains pure Dart. Generator/compiler implementation belongs to
[`contract_codegen`](../../../../packages/contract_codegen/README.md), not this
package. See the [toolchain workflow](../../../../docs/development/toolchain.md#generated-contract-artifacts)
for bootstrap, generation, checking, and cleanup.

Port/connection lifecycle and eval wrappers remain outside this package. The
interpreted [frontend](../frontend/README.md) still uses the fixture-specific eval
bridge backed by a native generated client, not the generic generated eval-client
projection.
