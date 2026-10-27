# AppFlowy 6.2.0 Compatibility Investigation

Role: Non-normative dependency and source investigation, dated 2026-10-27.

## Result and evidence boundary

The published `appflowy_editor 6.2.0` cannot resolve in the inspected ADELE
workspace without changing other dependency constraints or using an override or
fork. The first dependency gate failed, before native compilation or evaluated
frontend testing. The trial dependency was removed; no application, public API,
plugin, toolchain, or lockfile change is retained.

This is not evidence that AppFlowy cannot run under Flutter 3.38.10, nor that a
native widget cannot be hosted through EVC. It is a concrete incompatibility with
ADELE's existing dependency graph. No native adapter, EVC fixture, Markdown
round-trip guarantee, or editor retirement behavior was established by this
investigation. The existing Chat composer and its backend representation are
unchanged.

## Reproduction

The fetched `origin/main` and initial worktree HEAD were both
`ec4f2e5bbb96c1e7df6831e4bb451b8cefcfec9b`. Concurrent Diff PR #178 was inspected
but not incorporated. Before publication, main advanced to
`0c39a782732779b276ba52983846fe823d539ab3` by merging that PR; its root/app/OpenAI
dependency manifests, lockfile, SDK pin, and research index were unchanged.
The experiment ran on Linux with the maintained toolchain:

| Component | Verified identity |
| --- | --- |
| Flutter | `3.38.10`, framework `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80` |
| Engine | `cafcda5721a78a7884db92f13c5e89f7643d52dd` |
| Bundled Dart | `3.10.9` |
| Locked evaluators | `dart_eval 0.8.5`, `flutter_eval 0.8.2` |

On that revision, add only this entry to `app/pubspec.yaml`'s production
`dependencies`:

```yaml
appflowy_editor: 6.2.0
```

Select the pinned SDK explicitly, as required by the
[toolchain policy](../development/toolchain.md), and run from the repository root:

```sh
export FLUTTER_ROOT=/absolute/path/to/flutter-3.38.10
export PATH="$FLUTTER_ROOT/bin:$PATH"
flutter --version --machine
dart tools/adele.dart bootstrap
```

CodeForge source preparation succeeded. Workspace dependency resolution then
failed with exit code 1:

```text
Because openai_plugin depends on openai_model_provider_backend which depends on win32 ^6.4.0, win32 ^6.4.0 is required.
Because device_info_plus >=11.3.2 <13.0.0 depends on win32 ^5.11.0 and device_info_plus >=11.0.0 <11.3.2 depends on win32 ^5.5.3, device_info_plus >=11.0.0 <13.0.0 requires win32 ^5.5.3.
Thus, device_info_plus >=11.0.0 <13.0.0 is forbidden.
So, because adele_desktop depends on appflowy_editor 6.2.0 which depends on device_info_plus ^11.0.0, version solving failed.
```

The incompatible requirements are independently inspectable:

- ADELE's [OpenAI backend manifest](../../plugins/openai/packages/backend/pubspec.yaml)
  requires `win32 ^6.4.0`; the root lockfile resolves `6.4.0`. Its
  `lib/src/openai_chatgpt_auth.dart` imports that package.
- The [published editor metadata](https://pub.dev/api/packages/appflowy_editor/versions/6.2.0)
  requires `device_info_plus ^11.0.0`. The editor's declared minimums, Dart
  `>=3.6.0 <4.0.0` and Flutter `>=3.32.0`, do include ADELE's SDK.
- The editor archive SHA-256 is
  `c2367acdd93c7eeefaf6c58e5fed1a1c62cf02b8368102b786b5c6a0d1c583cf`.
  [Published source archive](https://pub.dev/api/archives/appflowy_editor-6.2.0.tar.gz)
  supplies the version-specific source paths used below.

The `win32` major-version ranges do not intersect. Running on Linux does not
remove a package's Windows dependencies from workspace resolution. An SDK upgrade
alone would not reconcile these declared ranges. No dependency override,
unrelated downgrade, package substitution, or evaluator upgrade was attempted.

After removing the trial entry, the maintained `bootstrap` command passed
dependency resolution, workspace listing, and contract generation. Both manifests
and the root lockfile remained identical to the base. `generate --check` and
`format --check` also passed. Application analysis, native/editor tests, UI tests,
and EVC compilation were not run: there is no retained executable change and the
candidate did not pass admission to those experiments.

## Markdown and Code Block source findings

These are source observations, not executed compatibility results. **None of the
requested Markdown cases is classified as passed or safely normalized.** Paragraphs
and blank lines, headings, emphasis, inline code, nested lists, blockquotes, links,
fenced code/language annotations, indentation/trailing newlines, Unicode, and line
break variants all still require tests after dependency resolution is possible.
Unchanged-document preservation and export after actual edits are separate,
unexecuted requirements.

The old plugin package is not a usable shortcut:

- [Published `appflowy_editor_plugins 0.0.6` metadata](https://pub.dev/api/packages/appflowy_editor_plugins/versions/0.0.6)
  actually declares editor `^2.3.4`, not `^3.3.0`.
- [GitHub source at `9fe683f1efd1ee0ff69417d44d37bea5fd813225`](https://github.com/AppFlowy-IO/AppFlowy-Plugins/tree/9fe683f1efd1ee0ff69417d44d37bea5fd813225/packages/appflowy_editor_plugins)
  still labels itself `0.0.6` but declares `^3.3.0`. Neither range includes 6.x.
- The complete package also introduces link-preview/chat and native video
  dependencies. Its Code Block implementation needs editor, Flutter, `provider`,
  and `highlight`; the inspected GitHub version also imports `universal_platform`.
  None of the video dependencies is necessary for Code Block.

In editor 6.2.0, `lib/src/plugins/markdown/document_markdown.dart` has no default
fenced-code decoder; the default component builders have no code-block renderer.
There is a code-node encoder at
`lib/src/plugins/markdown/encoder/parser/code_block_node_parser.dart` and an example
custom parser at `example/lib/pages/markdown/markdown_code_block_parser.dart`.
The example uses `trimRight()`, losing trailing code whitespace. The encoder uses
triple backticks and `DeltaMarkdownEncoder`; embedded fences and accidental prose
formatting inside code need explicit handling. Do not treat these facilities as
a demonstrated safe import/export pipeline for existing Draft Requests.

A small extension through the current public API looks practical, but was not
compiled. A `'code'` node can carry a Delta and language attribute; a configured
`ParagraphBlockComponentBuilder` can provide an initial monospace renderer. It
would also need code-specific Enter and literal-paste behavior, an exit action,
and suppression of prose shortcuts/formatting inside code. Merely changing the
font does not provide correct multiline code editing. Use a custom Markdown parser
and evaluate a safe code encoder rather than copying the whitespace-trimming
example. This plain-code route need not add a highlighting dependency.

If adapting the old renderer instead, at least these 6.2.0 API differences apply:

| Older usage | Current API |
| --- | --- |
| `bool validate(Node node)` override | Function-valued `BlockComponentValidate get validate` |
| `BlockComponentConfigurable.textStyle` | `textStyleWithTextSpan(...)`; corresponding placeholder method also changed |
| Text-style callback taking only a node | Callback taking `Node node, {TextSpan? textSpan}` |
| Publicly imported `PlatformExtension` | No longer exported; use appropriate Flutter APIs or an explicit platform dependency |

`AppFlowyRichText`, selectable mixins, node transactions, custom Markdown parsers,
and editor-local shortcut lists remain extension points. Porting all old selection,
paste, language-picker, and highlighting behavior is not necessary to investigate
a plain code block. The old implementation is reference material, not a verified
drop-in. Syntax highlighting could use a separately evaluated tokenizer later;
the complete old plugins package should not be added for this purpose.

## Licensing and distribution

Both inspected published archives' `LICENSE` files declare contributed code
dual-licensed under AGPLv3 and MPL 2.0 and contain both license texts. See the
version-specific [editor license](https://pub.dev/packages/appflowy_editor/versions/6.2.0/license)
and [plugins license](https://pub.dev/packages/appflowy_editor_plugins/versions/0.0.6/license).
Choosing MPL is a plausible route for a separately licensed larger application,
not a claim that inclusion or redistribution is obligation-free. The declaration
is prose rather than an explicit SPDX `OR` expression; confirm the intended
election and shipped contents before distribution.

Under an MPL election, preserve covered source notices and license terms, make
the corresponding covered source (including modifications) available to executable
recipients, and tell recipients how to obtain it. Copied/adapted covered code
remains covered; independently authored files using public APIs do not thereby
become covered. Consult [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/) and
[Mozilla's FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/), especially the larger-work,
modified-file, executable-distribution, and static-linking guidance. This is an
engineering compliance assessment, not legal clearance or an exhaustive audit.

Package-level notices alone need review:

- The old code-block renderer labels its `_convert` helper as copied from
  `flutter_highlight`; theme maps also match that package. Retaining such code
  requires its MIT attribution and permission notice (copyright 2019 Rongjian
  Zhang), not only AppFlowy's dual-license text.
- Editor archive `lib/src/flutter/overlay.dart` retains Flutter Authors BSD
  notices; `lib/src/flutter/scrollable_positioned_list/src/post_mount_callback.dart`
  retains Fuchsia Authors BSD notices. Preserve applicable embedded-source terms.
- Both archives contain `LICENSE` but no separately named third-party notice
  inventory. Flutter's normal license collection must not be assumed to discover
  all copied-source or asset obligations. No release-notice bundle was tested.

No AppFlowy source, font, adapted plugin code, or dependency is incorporated by
this investigation.

## Next experiment, not an accepted interface

Resolve the dependency choice explicitly before resuming native/EVC work.
Editor 6.2.0 was still the latest published version at inspection. Its only
`device_info_plus` usage in the archived Dart source is in
`lib/src/editor/toolbar/mobile/utils/keyboard_height_observer.dart`: an Android-only
`DeviceInfoPlugin().androidInfo` call stores `value.version.sdkInt` in static
`androidSDKVersion`. That value has no consumer beyond its own initialization
guard. Actual height reporting uses the separate `keyboard_height_plugin`.

Published device-info manifests narrow the alternatives:

| Version | Win32 constraint | Declared Dart / Flutter minimums |
| --- | --- | --- |
| [12.4.0](https://pub.dev/api/packages/device_info_plus/versions/12.4.0) | `^5.11.0` | `3.7.0` / `3.29.0` |
| [13.0.0](https://pub.dev/api/packages/device_info_plus/versions/13.0.0) | `^6.0.0` | `3.11.0` / `3.41.0` |
| [13.1.0](https://pub.dev/api/packages/device_info_plus/versions/13.1.0) | `^6.0.1` | `3.10.0` / `3.38.1` |
| [13.3.0](https://pub.dev/api/packages/device_info_plus/versions/13.3.0) | `^6.0.1` | `3.10.0` / `3.38.1` |

Moving to 12.x does not fix the conflict; 13.0.0 exceeds ADELE's SDK pin. The
[13.1.0 changelog](https://pub.dev/packages/device_info_plus/versions/13.3.0/changelog)
records the SDK-minimum reduction. Inspected 13.1.0 and 13.3.0 source retains
`androidInfo`, `version`, and `sdkInt`; no editor call-site change is indicated for
this usage. These versions also declare additional native build prerequisites,
including Java 17, Kotlin 2.2.0, AGP 8.12.1+, Gradle 8.13+, and Xcode 26.1.1+.
Manifest compatibility alone does not establish compilation, plugin registration,
or supported-platform runtime behavior.

The minimum next experiments, requiring an explicit changed dependency decision,
are:

1. Seek an upstream editor update, or review a manifest-only editor source patch
   selecting device-info 13.1.0 or 13.3.0, then rerun dependency resolution before
   native tests. Preserve the existing SDK, evaluators, and OpenAI/Win32 choices.
2. Alternatively, review a two-file editor patch removing the apparently unused
   probe, field, import, and device-info dependency. Retain keyboard-height
   reporting and Android duplicate-height suppression. Absence of archived
   consumers is not proof that this is behavior-preserving on all platforms.
3. If maintaining a patch is unacceptable, remain stopped pending upstream
   correction or evaluate another native Flutter editor against the same Markdown
   and EVC requirements.

Neither patch was applied or tested. Do not force Win32 6 underneath device-info
11, silently override the editor's declared dependency, or change OpenAI
authentication merely to admit the editor.

Once a candidate resolves, test Markdown conversion before claiming safe draft
import. Preserving the original Markdown until an actual content mutation is a
reasonable hypothesis for untouched content, not protection against loss after
editing: unsupported structures still need detection and explicit rejection.

The existing CodeForge and contribution-host paths suggest a small proof can
create a native owner from plugin-supplied Markdown, with exact presentation/runtime
access through a public stub and compile/runtime bridge. This accommodates future
asynchronous plugin-owned content without host knowledge of Chat. It does not
require a global current-document lookup, retained document registry, or production
prepared-plugin descriptor change. However, the native widget itself must lose
access on retirement, including during `PreparedFrontend` exit retention; clearing
an opaque handle alone is insufficient. The terminal bridge's captured-access
checks are a stronger precedent for that case than the code-editor bridge alone.
These are experiment design constraints, not newly established architecture or
tested AppFlowy lifecycle guarantees.
