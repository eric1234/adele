# Diff Viewer

Diff Viewer is a frontend-only stock plugin with a shared, pure-Dart public
contract. It contributes one read-only `Diff` Main Content pane for any canonical
Session, at order 200 between stock Chat and Source. It has no backend and does
not require Chat, a strategy frontend, or a Run.

## Ownership

`packages/contract/lib/diff_viewer_contract.dart` owns
`ChangeSetSourceService.snapshotUnstaged()` and the structured immutable snapshot
values. The service takes no arguments: Session and Environment authority is
captured by the host, not supplied in a request payload. The native library
exports `changeSetSourceCapability` (`adele.diff.change-set-source`, major 1);
the generator owns `changeSetSourceServiceId` and native/eval transport.

Snapshots contain changed files, explicit change/content status, numeric hunk
ranges, and context/addition/deletion lines with no-newline markers. They are not
opaque patches. All DTO list constructors copy into unmodifiable lists. Bounded
semantic strings keep the contract compatible with the pinned evaluator.
`ChangeSetFailure` has `code`, `message`, and the generator-required `details`
map, defaulting to empty. Native clients reconstruct declared failures; the
frontend's safe settlement path shows a local error state, not native diagnostics.

The [stock Git provider](../git_environment/README.md#unstaged-change-snapshots)
implements this deliberately public contract over its exact live Environment.
It owns Git/index semantics, filesystem safety, process execution and bounds.
The Diff frontend imports neither Git nor application/native-host implementation.
Other providers can implement the same contract without becoming dependencies
of the frontend.

## Presentation

`packages/frontend/lib/main.dart` supplies `initializeDiff()` and
`buildDiffPane()`. Initialization opens only local pane ID `diff`; reinitializing
does not duplicate it. The descriptor declares only `environmentReadCapabilities`
for the Diff capability. There is no context-free capability grant, own-backend
service, file mutation, process, terminal, editor, or execution grant.

The mounted pane requests a snapshot immediately. Each explicit Refresh or Retry
performs fresh contextual resolution, then invokes the typed generated client over
`EnvironmentCapabilityRequestChannel` through
`settleEnvironmentCapabilityOperation`. Each snapshot releases its provider
handle. Superseding refresh, departure preparation, and disposal invalidate the
local request revision and release pending access; a late resolution releases its
unused handle and an older result cannot replace a newer presentation. Departure
does not wait for independently owned backend work. If another pane refuses
navigation, Diff remains manually refreshable.

The pane distinguishes loading, unavailable, clean, and error states. Unified
rows are rendered lazily with file names, change kinds, hunk ranges, both line
numbers, addition/deletion prefixes and no-newline markers. Binary, conflicted,
oversized, and unsupported content remains explicit rather than an empty text
diff. An `unsupported` change kind can indicate uninspected change state, not a
confirmed modification: for example a provider may decline recursive submodule
inspection and supply that explanation in `detail`. Such a snapshot is not a
claim that the entire Environment was inspected or clean.
There is no automatic refresh, watcher, staging, apply/revert, editing,
side-by-side mode, or Source navigation.

## Preparation And Tests

`app/tool/diff_viewer_frontend_compiler.dart` compiles the actual frontend source
with a generated eval projection of the same authored contract. Its build harness
is `app/tool/compile_diff_viewer_frontend.dart`, selected by the maintained
frontend artifact builder using `ADELE_DIFF_VIEWER_FRONTEND_OUTPUT`. Stock
descriptors and frontend-only installation publication live in `tools/`.

Run the maintained targets from the repository root with the
[pinned toolchain](../../docs/development/toolchain.md):

```sh
dart tools/adele.dart test --target diff_viewer_contract
dart tools/adele.dart test --target diff_viewer_frontend
dart tools/adele.dart test --target adele_tools
```

The contract suite checks native nested transport, strict decoding, empty request
payloads, declared failures, and list immutability. The frontend suite compiles
and mounts real EVC with generated native/eval codecs through a test-only
contextual port, covering states, manual recovery, handle cleanup, held operation
races, and lazy display. It does not substitute for authority validation:
`app/test/prepared_diff_git_integration_test.dart` owns real stock Git AOT plus
Diff EVC through normal catalog/Main Content hosting and canonical nonprimary
Environment selection, including gated retirement/navigation.

Global boundaries belong to the [plugin architecture](../../docs/architecture/plugin-system.md),
[contracts and capabilities](../../docs/architecture/contracts-and-capabilities.md),
and [dependency rules](../../docs/architecture/dependency-rules.md).
