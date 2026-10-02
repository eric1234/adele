# CodeForge Correctness Findings

Role: Non-normative experimental evidence from 2026-10-01, not an editor
specification or a current acceptance result.

## Why the small patch set remains

ADELE continues to use published CodeForge 10.14.0 as a locally prepared source
dependency with `01-compatibility-build.patch` and the tiny controller-only
`02-correctness.patch`. The first adapts SDK syntax and pins native build inputs
for ADELE's integrated SDK; the second fixes demonstrated editing defects without
replacing the component's rope, widget, or ordinary editing model. These local
patches remain unpublished upstream. The
[preparation manifest](../../third_party/code_forge/preparation.json) owns exact
source/build identities; [toolchain policy](../development/toolchain.md#native-editor-preparation)
owns preparation procedures.

The retained correctness changes use current buffered text for deletion history,
scalar rope slices for text reconstruction, scalar undo/redo spans, complete CRLF
Backspace recording, and a post-await read-only/disposal paste guard. They do not
introduce a custom focus or composition-cancellation policy. ADELE keeps read-only
configuration fixed per editor owner.

## Key conclusion

The investigated defects reproduced both with unmodified CodeForge 10.14.0 on
official supported Flutter 3.47.5 / Dart 3.13.4 and with compatibility-only source
on ADELE's Flutter 3.38.10 / Dart 3.10.9 pin. Both used FRB 2.13.0 and Rust 1.93.0
on Linux x64. These are component defects, not merely consequences of adapting to
ADELE's older SDK. Dependency resolution also differed, so this was not a
one-variable SDK benchmark; targeted patch/reversal evidence supported the
identified mechanisms.

| Finding | Evidence and qualification |
| --- | --- |
| Buffered Delete history | Rapid successive Delete operations recorded stale removal payloads, so undo restored the wrong characters; normal grouping was accounted for. |
| Supplementary undo spans | Insertion/replacement replay used UTF-16 lengths against scalar rope indices and could remove adjacent text. |
| Buffered text getter/cache | Scalar offsets were used in Dart substring reconstruction, producing a wrong cached snapshot. The rope retained the correct text: this was not demonstrated rope destruction. |
| CRLF Backspace join | Joining `a\r\nb` left `a\rb`; undo restored CRLF. Forward Delete and general newline policy were not repaired. |
| Dynamic read-only propagation | An upstream widget rebuild could leave the controller's input guard stale. ADELE's fixed owner configuration does not depend on dynamic toggling. |

Already-admitted clipboard completion after a policy transition was observed, but
is not by itself a proven violation of an upstream cancellation contract. Calling
disposed controllers or assuming independent views share one controller likewise
does not establish corruption during supported single-view use.

## Remaining limitations

Selected-range composition remains deferred: replacing `a` in `ab` with composing
`x` should finish as `xb`. Normal completion preserves that result; blur/refocus
and full unmount/remount instead leave `b`, with undo restoring `ab`. Finish
composition before leaving or closing the editor. The
[explicit reproduction](../development/testing.md#deferred-selected-composition-reproduction)
retains correct assertions and is not normal acceptance or human OS/IME proof.

Supplementary-character Tab/Shift-Tab and double-click word selection retain
upstream offset edge cases. Use spaces or explicit selection instead during early
development. These paths, grouped Unicode edits, and broader clipboard/IME behavior
need resolution before file saving; a text snapshot and the small fixes do not
certify lossless saves or general IME support. No composition repair is included.

Eric's earlier manual report concerned an unpatched setup with an unverified SDK
identity, not the current integration. It corroborated the supplementary undo
symptom; the visual CRLF result did not distinguish residual CR from unchanged
CRLF, and restoring grouped ASCII deletions was normal undo behavior. It provides
no new integrated acceptance evidence.

## Current regression links

- [Native owner tests](../../app/test/native_code_editor_test.dart): ordinary editing, snapshots, undo, fixed read-only behavior, and owner lifetime.
- [Prepared-EVC bridge tests](../../app/test/code_editor_bridge_test.dart): scoped access, observation, snapshots, and independent ownership.
- [Focused checks](../development/testing.md#focused-editor-checks) and the single [Linux profile/manual target](../development/testing.md#integrated-editor-smoke): current workflows, not recorded pass results.
- [Application owner and limits](../../app/README.md#native-code-editor): local integration scope, without file/save, diff, or LSP authority.

Note: Full investigation chronology, comparison procedures, hashes, and intermediate
results belong to [PR #107](https://github.com/eric1234/adele/pull/107), not a second
maintained CLI or archive. This summary makes no broader SDK/platform, production
readiness, or redistribution-clearance claim.
