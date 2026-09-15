// Include backslashes in the same pass so controls and their literal notation
// stay distinguishable without invoking unsupported String replacement methods.
final RegExp _displayControls = RegExp(
  r'[\\\u0000-\u001F\u007F-\u009F\u00AD\u061C\u180E'
  r'\u200B-\u200F\u2028-\u202E\u2060-\u206F\uD800-\uDFFF\uFEFF'
  r'\u{E0001}\u{E0020}-\u{E007F}]',
  unicode: true,
);

/// Makes controls, bidi/invisible formatting and literal backslashes visible.
/// This is display-only: ordinary Unicode and valid surrogate pairs are kept.
String inspectionDisplayText(String value) {
  final StringBuffer result = StringBuffer();
  int offset = 0;
  for (final Match match in _displayControls.allMatches(value)) {
    result.write(value.substring(offset, match.start));
    final String character = match[0]!;
    if (character == r'\') {
      result.write(r'\\');
    } else if (character == '\n') {
      result.write(r'\n');
    } else if (character == '\r') {
      result.write(r'\r');
    } else if (character == '\t') {
      result.write(r'\t');
    } else {
      for (final int unit in character.codeUnits) {
        result.write(
          '\\u${unit.toRadixString(16).padLeft(4, '0').toUpperCase()}',
        );
      }
    }
    offset = match.end;
  }
  result.write(value.substring(offset));
  return result.toString();
}

/// A bounded display prefix, including escapes, optional delimiters and `...`.
/// Scans only the prefix needed for the budget, preserving Unicode pairs and
/// whole escape tokens. Delimiters show value boundaries, not shell quoting.
String compactDisplayText(
  String value, {
  int maximumCharacters = 160,
  bool quoted = false,
}) {
  if (maximumCharacters < 8) {
    throw ArgumentError('Compact display requires at least eight characters.');
  }
  final int budget = maximumCharacters - (quoted ? 2 : 0);
  final String delimiter = quoted ? '"' : '';
  final StringBuffer result = StringBuffer();
  int characters = 0;
  int clippedEnd = 0;
  int offset = 0;
  while (offset < value.length) {
    int end = offset + 1;
    final int unit = value.codeUnitAt(offset);
    if (unit >= 0xD800 && unit <= 0xDBFF && end < value.length) {
      final int next = value.codeUnitAt(end);
      if (next >= 0xDC00 && next <= 0xDFFF) end++;
    }
    String token = inspectionDisplayText(value.substring(offset, end));
    if (quoted && token == '"') token = r'\"';
    final int count = end - offset == 2 && token.length == 2 ? 1 : token.length;
    if (characters + count > budget) {
      return '$delimiter${result.toString().substring(0, clippedEnd)}...$delimiter';
    }
    result.write(token);
    characters += count;
    if (characters <= budget - 3) clippedEnd = result.length;
    offset = end;
  }
  return '$delimiter$result$delimiter';
}
