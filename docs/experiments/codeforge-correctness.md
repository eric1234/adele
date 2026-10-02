# CodeForge Correctness Investigation

Role: Non-normative, versioned experimental evidence. Investigation date:
2026-10-01. This is neither a dependency-selection decision nor E1 completion.

## Question and scope

Distinguish component defects from older-SDK adaptation effects, harness mistakes,
unsupported controller use, and ADELE-specific lifetime requirements. The starting
evidence is PR #107 at `6d478fb4ada7e4df1c20a90370efcab45e28eb11`, based on
`6a55a1e14eaf296414113649ba42370e8421a574`. No public editor bridge, file association,
Environment grant, Main Content layout, or production patch is introduced here.

Procedures and prerequisites have one maintained home in
[testing](../development/testing.md#native-editor-candidate-probe) and
[toolchain policy](../development/toolchain.md#isolated-native-editor-probe).

### Current use

This investigation and its retained 37-case fixture are historical evidence, not
the current editor's specification or acceptance gate. The application uses
conventional CodeForge behind a thin EVC bridge, with a smaller preparation patch
set; its [owner and limitations](../../app/README.md#native-code-editor) and
[current checks](../development/testing.md#focused-editor-checks) have separate
maintained homes. Historical cancellation experiments do not impose a custom
composition or clipboard policy. Targeted getter/scalar undo fixes are not a
lossless file-saving certification. Eric's report below retains its original
qualifications and does not identify or validate the current integrated setup.

## Baseline identities

- Published `code_forge 10.14.0`, archive SHA-256
  `bddb3fe2001e4dd1653b32fc2752b9d4f60c7cb78f2a02165ea45ee60a867b61`.
- Previously inspected upstream main
  `0d75fa298b368bc6f47b0daa82aa6bee2b900815`; package constraint Dart `^3.13.2`.
- FRB runtime/generated Dart/generated Rust **2.13.0**, content hash **434014572**.
- Native crate `code_forge 0.1.0`; supplied Cargo lock resolves ropey **1.6.1**,
  zed-sum-tree **0.2.0**, unicode-bidi **0.3.18**. Sum-tree uses Rust edition 2024.
- ADELE comparison: Flutter **3.38.10**, framework
  `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`, engine
  `cafcda5721a78a7884db92f13c5e89f7643d52dd`, bundled Dart **3.10.9**.
- Rust/Cargo **1.93.0**, target `x86_64-unknown-linux-gnu`.

`compatibility.patch` lowers the isolated Dart constraint, expands twelve private
named constructor parameters into equivalent explicit initializers, and pins FRB
plus Cargokit compiler/lock behavior. It does not alter editing logic or generated
codecs. Causal correctness patches, when used, are separately selected and named.

An initial local rustc SIGSEGV in proc-macro2 1.0.106 was followed by successful
builds using the compiler-recommended `RUST_MIN_STACK=16777216`. That does not
establish the crash's root cause or an editor defect.

## Controlled comparison

The supported control is official stable **Flutter 3.47.5 / Dart 3.13.4**, not a
manifest-only override. The [official archive](https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz)
was checked against the [official release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json):
SHA-256 `2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb`,
framework `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`, engine
`af7e796e161ae0bb1ff0758c71a7105418bd9ded`, bundled Dart revision
`b530c21f7de367b94fb04787bfed9d8e989d75e8`.

The control resolves **hosted** CodeForge 10.14.0 with an exact direct FRB 2.13.0
constraint. The complete hosted source matches the verified archive before and
after execution. No SDK, constructor, Cargokit, or correctness patch is applied.
Upstream still invokes `rustup run stable`; an isolated `RUSTUP_HOME` maps that
name to exact 1.93.0. A PATH shim initially bypassed that isolation (the actual
compiler was still 1.93.0); the retained driver resolves a real rustup launcher,
checks its isolated home, and records the selected stable compiler before building.
`RUST_MIN_STACK` is a build-only setting, not a source alteration. Upstream's
Cargo command is not changed to `--locked`; its supplied Cargo lock is checked
unchanged afterward. The effective runner/application locks are retained in logs.

Each configuration has separate source, package cache where applicable, Flutter
build output, runtime working directory, and native library. Rust crate download
caches may be shared, not compiled Flutter/native artifacts. Tests load their own
configuration's verified bundle. The corrected profile smoke verifies the actual
mapping, performs one insertion using the current advertised text-input projection
and client ID, renders, fully unmounts, and uses retained undo/redo before disposal.
It is synthetic engine-to-framework input, not a manual OS test.

Relevant source SHA-256 identities:

| Input | Unmodified / ADELE compatibility-only |
| --- | --- |
| Controller | Both `5ebe49f32cd3cda930262a82a9ae1b33fc3544f1478f0be158510a02d8dc9d6b` |
| Undo controller | Both `e36e151122ea1f85cdd3dfd4662cba27b9898afbf07346f9c67bdb20c5bd2f42` |
| Widget/renderer | `2285b4e07c25dc4466b7ff392e51ce4e533ad9b3f95648a3f934b72d9f158ba0` / `b5b5689f15cb3b310402ba20dff14dc57b13057db65638415e230104d4d06035` (constructor adaptation only) |
| Generated Dart bridge | Both `136d7de228ceff1a14fed4f91617b5f9de0daaf5919e645b3266844105d05df5` |
| Generated Rust bridge | Both `9fd7ddfdc4656b48c0081ab471a08f74512d4e46ed033e58ab669cf8fddb8d6d` |
| Cargo lock | Both `45b16a91490101531165c67b0f988e95817de3c2e53b18732bef367948f08cd4` |

The ordinary supported-SDK resolver changes nine isolated dependency versions
versus the ADELE fixture lock: characters 1.4.0 -> 1.4.1, clock 1.1.2 -> 1.1.3,
matcher 0.12.17 -> 0.12.20, material_color_utilities 0.11.1 -> 0.13.0,
meta 1.17.0 -> 1.18.3, stack_trace 1.12.1 -> 1.12.2, test_api 0.7.7 -> 0.7.12,
url_launcher_android 6.3.30 -> 6.3.33, vector_math 2.2.0 -> 2.4.0. These are
recorded confounds: this is not a one-variable SDK-only benchmark. FRB and the
native Cargo graph are unchanged; the effective runner versions match. Identical
failures in unmodified supported upstream plus local red/green/reversed-patch
evidence isolate the demonstrated controller mechanisms, not every possible path.
ADELE's root lock and workspace graph are unchanged.

## Classified findings

The table is the single maintained outcome summary. "Control" means unmodified
10.14.0 on official 3.47.5; "pin" means 10.14.0 with SDK/build adaptation only on
3.38.10. All correctness assertions retain the desired result. The suite reports
JSON observations before assertions; compilation errors, skipped tests, crashes,
and unrelated assertion reasons are not accepted as reproductions.

| Case | Valid use / qualification | Control result | Pin result | Mounted / manual evidence | First inconsistency | Classification / confidence | Correction / uncertainty |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A: ASCII Delete and undo | Default grouping and ungrouped; two Delete keys at 0ms and 20ms; undo actual recorded history, not an assumed count | Restores `aac`, or `xxz` for `xyz`; 120ms and navigation-flush controls pass | Same | Mounted widget keyboard; backspace contrast passes. Eric reports both deleted letters restored in one undo: normal grouping, not a manual reproduction of corruption; timing unrecorded | Second Delete edits pending `bc` but records `a` from old rope `abc`; default merged payload is `aa` | Confirmed upstream defect under valid single-view use; high | Read removal payload from current buffered line. Zero fake time is not required; 20ms also fails. Waiting for flush only identifies trigger, not an acceptable editing policy |
| B: supplementary insertion/replacement undo | Offset zero avoids caller conversion; direct API and mounted Ctrl+V with synthetic clipboard; ASCII/BMP controls | Insertion undo loses adjacent `a`; supplementary replacement undo/redo loses suffixes | Same | Mounted paste and direct controls. Eric independently reports undo removing the pasted emoji and following `a`; manual configuration identity not supplied | Inverse deletion/replacement endpoint uses UTF-16 `.length` for a scalar-indexed rope; payload itself is correct | Confirmed upstream defect; high | Scalar replay spans fix these cases. Grouped supplementary merging remains a separate, unmodified path |
| C: buffered current-text snapshot | Ctrl+End validates scalar caret, then Backspace; immediate and first explicit read after flush | Getter returns `\u{1f600}ab`, while pending/render-line text and flushed rope contain `\u{1f600}\na` | Same; also reproduced with plain controller, without getter-count subclass | Mounted navigation; line accessor is renderer data, not pixel/OCR evidence | Getter passes scalar line boundaries to Dart substring; `_recordDeletion` implicitly calls it even without LSP, caching the wrong value before the explicit observer | Confirmed snapshot/cache defect, **not demonstrated rope data loss**; high | Scalar rope slices fix reconstruction without a forced flush, duplicate document, or cache polling |
| D: CRLF Backspace join | Initial CRLF is accepted and roundtrips; Ctrl+End then Home places caret at scalar 3; LF control | `a\r\nb` becomes `a\rb`; undo restores CRLF, redo repeats stray CR | Same | Mounted keys/direct vector agree with inspected code units. Eric reports `a` and `b` remaining on separate lines after Backspace; consistent with residual CR, but no manual snapshot distinguishes it from unchanged CRLF | LF-special-case removes only LF, not preceding CR | Confirmed upstream line-join behavior defect for admitted CRLF; high observation confidence; explicit upstream newline policy is undocumented | Remove and record the full CRLF pair. Forward Delete, generated newline policy and CRLF IME projection are not repaired |
| E1: widget read-only propagation | Supported rebuild of same mounted CodeForge; fresh operations distinguished from pending paste | Widget true/controller false; fresh public paste and valid current-client delta still edit | Same | Mounted keyboard, controller command, and bounded advertised ASCII delta; no human IME test | `didUpdateWidget` updates local flag but not controller input guard | Confirmed upstream propagation inconsistency; high. Programmatic owner updates alone would not establish a user-input bypass | Propagate flag to controller. General composition, read-only context menus and accessibility are not certified |
| E2: clipboard admitted before transition | Hold only synthetic `Clipboard.getData` using a Completer; change controller flag or rebuild widget before completion | Already-admitted paste completes | Same | Native paste shortcut with injected latency, not an OS clipboard timing test | Permission is checked before await, not after | Reproduced async semantics; cancellation policy is undocumented. Exact ADELE revocation is an additional requirement, not proof every editor must cancel admitted work | Experimental post-await read-only/disposal guard implements cancellation. No generation token, focus revocation, or replacement-owner authority is proven |
| Post-disposal calls | Deliberately call a retired controller | Not a supported-use control | Prior observation: still mutates | Not included in the correctness matrix | Caller used disposed owner | Unsupported use / future ADELE fail-closed requirement | Retract its use as evidence of valid editing corruption; no production lifetime repair here |
| Two widgets / one controller | Controller owns selection, input and callbacks; no independent-view contract found | Not a supported split-view control | Prior observation: coupled state | Not included in the correctness matrix | Sharing a view-oriented controller | Unsupported independent-view assumption / ADELE attachment requirement | Do not infer data corruption in conventional single-view use or implement a split architecture here |

## Causal patch and limits

`tools/code_editor_probe/fixtures/correctness.patch` is **experimental and opt-in**,
separate from the SDK/build patch. It changes 18 added / 15 removed lines across
`controller.dart` and `code_area.dart`: buffered Delete/Backspace payload source,
scalar snapshot slices, scalar undo/redo spans and dirty ranges, CRLF Backspace
pair recording, post-await paste guard, and widget read-only propagation.
It does not replace the rope, add parallel authoritative text, sleep between
edits, or force a flush everywhere. The patched controller SHA-256 is
`cfcd8999f8398d680410efe32a683920adf466041ea430eb3804462dc00dbd59`.

The initial identical 35-case suite produced 18 passes / 17 assertion failures in
both SDK configurations. Enabling ordinary optional widget defaults and adding a
plain-controller snapshot control plus advertised read-only input produced the
37-case fixture SHA-256
`180acadf01e4cb5e24863c993f10d97b404c6d603d3a048d38dd2d2c8b87b5b5`.
On the ADELE pin it produced **18 passes / 19 expected-behavior failures**, then
**37 passes with the patch**, then **18 passes / 19 failures after removing it**.
The final unmodified official-SDK control also produced **18 passes / 19 failures**
using the identical 37-case fixture; its corrected native smoke, negative-library
subprocess and interactive reset/F8 test passed before those assertions ran.
The removal restored the original source bytes. This is targeted causal evidence,
not production acceptance or a verdict inferred from failure count.

No useful neighboring upstream unit tests were present in the archive: no root
`test/`, no Rust `#[test]`/`#[cfg(test)]`; the example test is a stock counter-app
test and the integration driver delegates `integrationDriver`. They were not
misreported as editor regression coverage. Nearby ASCII/BMP insert/replacement,
undo/redo, backspace, flush/navigation and initially-read-only controls are included
in the retained suite instead.

Still unmodified/unproven: supplementary operation merging in `undo_redo.dart`,
other buffered length/line-offset arithmetic, forward CRLF Delete and newline
policy, CRLF projection, copy/cut, composition, folds, LSP, multicursor and native
resource lifetime. Full-value/composing IME input is not certified by the bounded
delta test. The mounted widget advertises `enableDeltaModel: true`; injecting
full-value engine messages into that client and calling them normal platform input
would itself need justification. A further full-value/fallback experiment must
first establish its supported delivery mode. The defensively added disposed-paste
guard is not an ADELE capability revocation design.

The supported control and small causal delta correct the earlier implication
that substantial repair or rejection was already established. A credible next
step is upstream clarification/fix with these runnable cases, or review of this
small patch plus a bounded audit of related offset/grouping/newline paths before
resuming E1. A larger repair or alternative comparison should depend on that
demonstrated reach, not the count of failing assertions. No technology switch or
production adoption is made here.

## Execution boundaries

- Automated: real Rust-backed widget keyboard/paste tests; deterministically held
  synthetic clipboard replies; fake-clock pending/post-flush controls; current
  client/projection delta; native profile rendering/unmount/undo and missing-library
  subprocesses; interactive sample-reset/undo/F8 widget test.
- Automated desktop launch: the unmodified supported-SDK `--interactive` profile
  binary reached its first rendered frame under Xvfb, stayed alive, and was stopped
  deliberately. This is not a human editing or real OS clipboard/IME result.
- Human manual execution by the agent: **none**. Eric's separately reported
  checklist observations are incorporated in the table with the qualifications
  below; they are not substituted for the identified automated configurations.
- No macOS/Windows execution, paid/live-model calls, upstream issues/comments/PRs,
  production editor integration, or EVC frontend acceptance was performed.

### Eric's manual report

On 2026-10-01, Eric reported following the three manual checklist cases. The
observations are recorded in rows A, B and D above. No displayed configuration
identity, launch command, F8 snapshot, or measured timing accompanied this report;
do not infer a specific SDK or patch mode from it.

Restoring both ASCII letters in one undo is expected default grouping. The
approximately 100ms line-buffer flush and 500ms undo-group window are distinct:
edits can flush between keystrokes and still form one undo operation. The manual
result therefore does not reproduce the narrow pending-buffer defect, but does
not invalidate its automated 20ms reproduction. It does not establish the actual
timing or flush cause in Eric's run.

The supplementary-character report independently corroborates the observed undo
symptom. For CRLF, the visual failure to join lines is consistent with the
automated residual-CR result, but the remaining text is not yet established by
manual evidence. An explicit F8 snapshot would distinguish `a\rb` (code units
`[97,13,98]`) from unchanged `a\r\nb` (`[97,13,10,98]`). No additional timing race
or broad IME testing is required to interpret the existing report.

## Harness corrections

The reviewed CI run [36886040891](https://github.com/eric1234/adele/actions/runs/36886040891)
failed before native editor execution: the SDK-only launcher fixture omitted the
new probe-driver import. These compilation failures are harness defects, not
expected component failures. Normal tooling must remain network/Rust independent.

The old profile fixture started asynchronous error flushing while a separate
success path could call `exit(0)`. Its original success result alone is therefore
not decisive evidence. The corrected fixture must record errors synchronously,
settle through one decision, and have the driver reject failure markers on either
output stream even alongside a completion marker and zero exit.

Local setup also exposed an inherited `FLUTTER_ROOT` selecting a newer SDK while
the executable was pinned Dart. A tooling invocation automatically re-resolved the
workspace against that environment; those investigation-induced lock changes were
restored, the pinned graph was materialized with `--enforce-lockfile`, and validation
was rerun with an explicit matching `FLUTTER_ROOT`. This was not a component failure
or an accepted dependency upgrade. The final root lock and SDK configuration match
the reviewed head. The maintained `adele_tools --ci` target then passed **182 tests**,
including the SDK-only launcher assertions; the focused driver/settlement run
passed **30 tests** without requiring Rust or network for those unit tests.

Direct post-disposal mutation and two widgets attached to one controller are
unsupported-use/embedding observations, not evidence that conventional one-view
editing corrupts data. The original synthetic text-input messages are not manual
OS input. Default grouping and advertised platform projection require separate
controls rather than assuming the original ungrouped/direct-offset tests generalize.

## Prior release comparison

This bounded comparison was source inspection only, not an executed supported-SDK
control. It does not establish that all releases are unsuitable:

| Release | Verified archive SHA-256 | Relevant difference |
| --- | --- | --- |
| 10.13.0 | `8b30559d2b7a15fda71bd01fb358bcd553a91c93bcfba1159a0da30b775ec1ab` | Same controller/rope/undo/Rust sources; lacks later scrolling/highlighting and Shift-click changes. |
| 10.12.0 | `930c8c1ddd873dc39beb575ca01e15ad12e32f4f63545bec9f8dff2c9d4bbee6` | Same relevant editing logic; FRB 2.12.0 and earlier drag-selection behavior. |
| 10.0.0 | `4eddf43e57f0eed2d379383c29b64403993b692647ef238854508fcf9f2c29cf` | First Rust release; different buffered-delete payload logic, but native inserted cursor arithmetic uses UTF-8 byte length. |

## Upstream issue review

Rechecked the package registry, current default branch and tag on 2026-10-01:
10.14.0 remains latest, and `main` and tag `10.14.0` both resolve to the baseline
commit above. Audited archive files (`controller.dart`, `undo_redo.dart`,
`code_area.dart`, Dart/Rust rope, README and example) match that commit's Git blobs.
No newer default-branch fix is silently substituted into these results.

- [Issue #1](https://github.com/heckmon/code_forge/issues/1) is a historical
  read-only keyboard issue. Tag 1.5.0 adds widget keyboard guards; the later
  [PR #5](https://github.com/heckmon/code_forge/pull/5) adds controller/menu guards.
  Both are present in 10.14.0. This is not an exact report of a pending paste
  completing after a dynamic policy change.
- [Issue #45](https://github.com/heckmon/code_forge/issues/45) concerns desktop
  input/composition. Its reporter confirmed the
  [PR #78](https://github.com/heckmon/code_forge/pull/78) fix.
  [PR #77](https://github.com/heckmon/code_forge/pull/77) and #78 are merged
  ancestors of 10.14.0. They fix CJK composition/grouping and native replacement
  cursor byte-counting; they do not change the supplementary Dart undo span or
  stale buffered Delete payload identified in this experiment.
- [Issue #74](https://github.com/heckmon/code_forge/issues/74) was resolved after
  removing the reporter's customized external focus node. It is not evidence
  of general single-view lifetime corruption. Likewise
  [issue #86](https://github.com/heckmon/code_forge/issues/86) did not reproduce
  in the upstream example, so its similar title is not confirmation.
- The `dev` branch has one divergent, older IME commit
  `0470ec3396dd78f5627c064680c8ba0864219793`, behind current main by 63 commits.
  There are no open upstream PRs at inspection time. No experimental branch
  change is adopted here.

GitHub searches included open/closed issues and PR bodies/comments for `undo`,
`buffer`, `buffered`, `CRLF`, `line ending`, `UTF-16`, `UTF16`, `supplementary`,
`scalar`, `emoji`, `snapshot`, `text snapshot`, `buffer line`, `readOnly`,
`read-only`, `readOnly transition`, `paste await`, controller ownership and
`dispose`. No exact report of the investigated buffered-delete payload,
supplementary undo, cached scalar snapshot, or delayed-paste transition was found
in those searches. That is not a claim that no report exists anywhere. Nothing
was published upstream by this investigation.

### Valid setup and input qualifications

The README's initialization section and example await `RustLib.init()` before
constructing controllers; its abbreviated Basic Usage snippet omits that step.
The example supplies persistent controller and undo objects. Default grouping is
enabled, merges eligible operations within 500ms, and is independent of the
100ms pending-line flush. Tests must undo the actual history, not assume two
operations when grouping is on.

Retraction of an overly broad earlier inference: inbound and outbound
UTF-16/scalar conversions **do exist** in `_localImeOffsetToGlobal`,
`_syncToConnection`, and `_buildCurrentImeEditingValue`. `_ensureImeProjection`
uses scalar-local intermediate state; that alone is not a broken platform value.
The platform receives a local projection (normally a two-line radius, bounded to
4,096 units), not necessarily the full document. Current input-client identity,
advertised old text, UTF-16 delta ranges/selection and composition must match it.
Ongoing IME composition may intentionally be an overlay, not committed text.
This investigation does not certify or reject general CJK/IME support.

Scalar indices, UTF-16 units, UTF-8 bytes, grapheme clusters and display columns
remain distinct. The targeted inverse-span and snapshot hypotheses concern
specific internal uses of Dart `.length`/`substring`, not absence of all conversion.

## Packaging and evidence limits

The Linux probe uses upstream CMake/Cargokit library bundling. A separate runtime
working directory and `/proc/self/maps` check distinguish bundled loading from a
development library. Removing the library tests load failure separately from
mapping failure, timeout, or test assertion failure. Native widget tests use that
configuration's actual library, never a Dart-only mock.

Windows DLL and macOS CocoaPods static-library/framework paths were inspected, not
executed. The macOS podspec says 10.12.0. The upstream MIT notice is truncated and
eight icon fonts lack separate provenance. Rust/stdlib transitive notices,
including Apache-2.0 zed-sum-tree, still need a distribution audit. Only source and
diagnostics are delivered, not binaries or fonts.

Initial text roundtrips include tabs, empty/final lines, combining marks, CJK,
supplementary characters, a 32 Ki-code-unit line, and a 2,048-line sample. They do
not prove corresponding editing, IME, or performance behavior. Rope and undo
payloads occupy content-proportional memory; a 1,000-operation history is not a
byte bound. No broad native lifetime, allocation, or production readiness claim
follows from this investigation.
