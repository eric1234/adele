import 'dart:convert';

import 'package:adele_desktop/ui/execution/approval_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final List<int> controls = <int>[
    for (int code = 0; code <= 0x1F; code++) code,
    for (int code = 0x7F; code <= 0x9F; code++) code,
    0xAD,
    0x061C,
    0x180E,
    for (int code = 0x200B; code <= 0x200F; code++) code,
    for (int code = 0x2028; code <= 0x202E; code++) code,
    for (int code = 0x2060; code <= 0x206F; code++) code,
    0xFEFF,
    0xE0001,
    for (int code = 0xE0020; code <= 0xE007F; code++) code,
  ];

  test('all approval control classes are detected and visibly escaped', () {
    for (final int code in controls) {
      final String character = String.fromCharCode(code);
      final String input = 'before${character}after';
      final String reason = 'U+${code.toRadixString(16).toUpperCase()}';
      expect(hasUnsafeApprovalControls(input), isTrue, reason: reason);
      final String display = approvalDisplayText(input);
      expect(display, startsWith(r'before\'), reason: reason);
      expect(display, endsWith('after'), reason: reason);
      expect(display.runes.where(controls.contains), isEmpty, reason: reason);
    }
  });

  test('text escapes distinguish literal notation from active controls', () {
    expect(
      approvalDisplayText(
        '\n\r\t\u0000\u007F\u0085\u00AD\u061C\u180E'
        '\u200D\u202E\u2066\uFEFF\u{E0001}\u{E0020}\u{E007F}',
      ),
      r'\n\r\t\u0000\u007F\u0085\u00AD\u061C\u180E'
      r'\u200D\u202E\u2066\uFEFF\uDB40\uDC01\uDB40\uDC20\uDB40\uDC7F',
    );
    expect(approvalDisplayText(r'\n\r\t\u202E\'), r'\\n\\r\\t\\u202E\\');
    expect(
      approvalDisplayText(
        'line\n'
        r'\n',
      ),
      r'line\n\\n',
    );
    expect(
      approvalDisplayText(
        '\u202E'
        r'\u202E',
      ),
      r'\u202E\\u202E',
    );
  });

  test('unpaired surrogates are escaped without rejecting valid pairs', () {
    for (final int unit in <int>[0xD800, 0xDBFF, 0xDC00, 0xDFFF]) {
      final String text = 'a${String.fromCharCode(unit)}b';
      expect(hasUnsafeApprovalControls(text), isTrue);
      final String display = approvalDisplayText(text);
      expect(display, 'a\\u${unit.toRadixString(16).toUpperCase()}b');
      expect(hasUnsafeApprovalControls(display), isFalse);
      expect(jsonDecode(approvalDisplayJson(text)), text);
      expect(hasUnsafeApprovalControls(approvalDisplayJson(text)), isFalse);
    }
    expect(approvalDisplayText('\u{1F680}'), '\u{1F680}');
    expect(hasUnsafeApprovalControls('\u{1F680}'), isFalse);
  });

  test(
    'ordinary Unicode and adjacent non-control characters are preserved',
    () {
      for (final String text in <String>[
        '',
        'ordinary ASCII /path with spaces.dart',
        'caf\u00E9 e\u0301 \u03B1\u03B2 \u65E5\u672C\u8A9E',
        '\u{1F680} \u{1F44D}\u{1F3FD} \u2764\uFE0F',
        '\u007E\u00A0\u00AC\u00AE\u061B\u061D\u180D\u180F'
            '\u200A\u2010\u2027\u202F\u205F\u2070',
      ]) {
        expect(hasUnsafeApprovalControls(text), isFalse);
        expect(approvalDisplayText(text), text);
        expect(approvalDisplayJson(text), jsonEncode(text));
        expect(
          hasUnsafeApprovalTarget(Uri(scheme: 'file', path: '/$text')),
          isFalse,
        );
      }
      expect(hasUnsafeApprovalControls(r'\n\u202E'), isFalse);
    },
  );

  test('URI targets inspect every control after percent decoding', () {
    for (final int code in controls) {
      final Uri target = Uri(
        scheme: 'adele-environment',
        path: '/environment-1/lib/file${String.fromCharCode(code)}.dart',
      );
      final String reason = 'U+${code.toRadixString(16).toUpperCase()}';
      expect(target.toString().runes.where(controls.contains), isEmpty);
      expect(hasUnsafeApprovalTarget(target), isTrue, reason: reason);
    }
  });

  test('URI targets decode exactly one layer across URI components', () {
    for (final String target in <String>[
      'file:///lib/file%0A.dart',
      'file:///lib/file%E2%80%AE.dart',
      'https://example.test/?name=%09',
      'https://example.test/#%E2%80%8D',
      'https://user%0D@example.test/',
    ]) {
      expect(
        hasUnsafeApprovalTarget(Uri.parse(target)),
        isTrue,
        reason: target,
      );
    }
    for (final String target in <String>[
      'file:///lib/file%250A.dart',
      'file:///lib/file%25E2%2580%25AE.dart',
      'file:///lib/file%25FF.dart',
      'file:///lib/100%25+ordinary%20space.dart',
    ]) {
      expect(
        hasUnsafeApprovalTarget(Uri.parse(target)),
        isFalse,
        reason: target,
      );
    }
  });

  test('URI targets reject invalid UTF-8 at the first decoding layer', () {
    for (final String bytes in <String>[
      '%FF',
      '%C0%AF',
      '%E2%80',
      '%ED%A0%80',
      '%F4%90%80%80',
    ]) {
      expect(
        hasUnsafeApprovalTarget(Uri.parse('file:///lib/$bytes.dart')),
        isTrue,
        reason: bytes,
      );
    }
  });

  test(
    'JSON escapes all payload strings but retains trusted pretty newlines',
    () {
      final String allControls = String.fromCharCodes(controls);
      final Map<String, Object?> value = <String, Object?>{
        'key$allControls': <Object?>[
          allControls,
          <String, Object?>{
            'literal': r'\n\u202E',
            'unicode': 'e\u0301 \u{1F680}',
          },
          42,
          true,
          false,
          null,
        ],
      };
      final String display = approvalDisplayJson(value);
      expect(jsonDecode(display), value);
      expect(display, contains('\n  "key'));
      expect(display, contains(r'\\n\\u202E'));
      expect(display, contains('e\u0301 \u{1F680}'));
      expect(
        display.runes.where((code) => code != 0x0A && controls.contains(code)),
        isEmpty,
      );
      expect(
        approvalDisplayJson(<String, Object?>{
          'line': 'a\nb',
          'bidi': '\u202E',
        }),
        '{\n  "line": "a\\nb",\n  "bidi": "\\u202E"\n}',
      );
    },
  );
}
