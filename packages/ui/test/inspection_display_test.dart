import 'package:adele_ui/inspection_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compact text is bounded after escaping and preserves exact limits', () {
    for (final length in [159, 160, 161, 100000]) {
      final result = compactDisplayText('x' * length);
      expect(result.runes.length, lessThanOrEqualTo(160));
      expect(result, length <= 160 ? 'x' * length : '${'x' * 157}...');
    }
    expect(compactDisplayText('x' * 158, quoted: true), '"${'x' * 158}"');
    expect(compactDisplayText('x' * 159, quoted: true), '"${'x' * 155}..."');
    expect(
      () => compactDisplayText('x', maximumCharacters: 7),
      throwsArgumentError,
    );
  });

  test('compact tokens preserve whitespace, quotes and complete escapes', () {
    expect(compactDisplayText('', quoted: true), '""');
    expect(compactDisplayText('  ', quoted: true), '"  "');
    expect(compactDisplayText(' a"\\\n ', quoted: true), r'" a\"\\\n "');
    expect(
      compactDisplayText('\u202E' * 100000, maximumCharacters: 16),
      r'\u202E\u202E...',
    );
    expect(compactDisplayText('x && y', quoted: true), '"x && y"');
  });

  test(
    'compact Unicode boundaries never split pairs or invisible-tag escapes',
    () {
      final text = '\u{1F600}' * 160;
      expect(compactDisplayText(text), text);
      expect(compactDisplayText('$text!'), '${'\u{1F600}' * 157}...');
      expect(
        compactDisplayText('\u{E007F}' * 10, maximumCharacters: 16),
        r'\uDB40\uDC7F...',
      );
      expect(compactDisplayText('\uD800'), r'\uD800');
      expect(compactDisplayText('e\u0301'), 'e\u0301');
    },
  );

  test('ordinary Unicode and valid surrogate pairs survive unchanged', () {
    const String value = 'plain text / \u00E9 \u00E6 \u00F8 \u00E5';
    expect(inspectionDisplayText(value), value);
    expect(inspectionDisplayText('\u{1F600} e\u0301'), '\u{1F600} e\u0301');
  });

  test('controls and literal escape notation remain distinguishable', () {
    expect(
      inspectionDisplayText('line\nreturn\rtab\t\\n\x00\x1B\x7F\u0085'),
      r'line\nreturn\rtab\t\\n\u0000\u001B\u007F\u0085',
    );
  });

  test('every C0 and C1 control is escaped', () {
    for (final int unit in [
      for (int unit = 0; unit < 0x20; unit++) unit,
      for (int unit = 0x7F; unit <= 0x9F; unit++) unit,
    ]) {
      final String expected = switch (unit) {
        0x09 => r'\t',
        0x0A => r'\n',
        0x0D => r'\r',
        _ => '\\u${unit.toRadixString(16).padLeft(4, '0').toUpperCase()}',
      };
      expect(inspectionDisplayText(String.fromCharCode(unit)), expected);
    }
  });

  test(
    'bidi, invisible formatting, tags and unpaired surrogates are visible',
    () {
      for (final int unit in [
        0x00AD,
        0x061C,
        0x180E,
        0x200B,
        0x200C,
        0x200D,
        0x200E,
        0x200F,
        0x2028,
        0x2029,
        0x202A,
        0x202B,
        0x202C,
        0x202D,
        0x202E,
        0x2060,
        0x2066,
        0x2067,
        0x2068,
        0x2069,
        0x206F,
        0xFEFF,
        0xD800,
        0xDFFF,
      ]) {
        expect(
          inspectionDisplayText(String.fromCharCode(unit)),
          '\\u${unit.toRadixString(16).padLeft(4, '0').toUpperCase()}',
        );
      }
      expect(
        inspectionDisplayText('\u{E0001}\u{E0020}\u{E007F}'),
        r'\uDB40\uDC01\uDB40\uDC20\uDB40\uDC7F',
      );
    },
  );
}
