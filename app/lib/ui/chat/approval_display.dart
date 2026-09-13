import 'dart:convert';

// Approval display only: controls, bidi formatting, invisible joining/formatting
// characters, Unicode tags, and unpaired UTF-16 surrogates. Unicode-mode matching
// leaves ordinary letters/marks and valid surrogate pairs (such as emoji) intact.
final RegExp _displayControls = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u00AD\u061C\u180E'
  r'\u200B-\u200F\u2028-\u202E\u2060-\u206F\uD800-\uDFFF\uFEFF'
  r'\u{E0001}\u{E0020}-\u{E007F}]',
  unicode: true,
);

bool hasUnsafeApprovalControls(String text) => _displayControls.hasMatch(text);

/// Inspect one URI decoding layer, not just its percent-encoded serialization.
/// Invalid UTF-8 escapes also cannot receive ordinary approval presentation.
bool hasUnsafeApprovalTarget(Uri target) {
  try {
    return hasUnsafeApprovalControls(Uri.decodeComponent(target.toString()));
  } on FormatException {
    return true;
  }
}

String _escapeControl(String character) => switch (character) {
  '\n' => r'\n',
  '\r' => r'\r',
  '\t' => r'\t',
  // UTF-16 escapes keep the JSON projection valid even for supplementary tags.
  _ =>
    character.codeUnits
        .map(
          (unit) =>
              '\\u${unit.toRadixString(16).padLeft(4, '0').toUpperCase()}',
        )
        .join(),
};

/// Escape literal backslashes too, distinguishing a control from its notation.
String approvalDisplayText(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAllMapped(_displayControls, (match) => _escapeControl(match[0]!));

/// JSON already escapes string controls/backslashes. Only its trusted pretty-
/// printing newlines survive; remaining display controls become JSON escapes.
/// This is a display copy, never the canonical arguments used for execution.
String approvalDisplayJson(Object? value) => const JsonEncoder.withIndent('  ')
    .convert(value)
    .replaceAllMapped(
      _displayControls,
      (match) => match[0] == '\n' ? '\n' : _escapeControl(match[0]!),
    );
