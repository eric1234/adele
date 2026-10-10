import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:test/test.dart';

TypeMatcher<TomlException> failure(TomlFailureKind kind) => isA<TomlException>()
    .having((error) => error.kind, 'kind', kind)
    .having((error) => error.message, 'message', isNotEmpty);

void main() {
  // These are ordinary Dart tests. Every operation invokes the bundled Rust
  // asset through @Native; there is no fake parser or Flutter initialization.
  test('standalone Dart loads real toml_edit and reads ordinary scalars', () {
    final document = TomlDocument.parse(
      'name = "ADELE"\ncount = 7\nok = true\n',
    );
    expect(document.readScalar(['name']), 'ADELE');
    expect(document.readScalar(['count']), 7);
    expect(document.readScalar(['ok']), true);
    expect(TomlDocument.parse('').source, '');
  });

  test('valid TOML outside the editing subset is accepted and retained', () {
    const source = '''
date = 2026-10-10T12:00:00Z
ratio = 1.5
array = [1, 2]
inline = { a = 1 }
[[records]]
name = "one"
''';
    expect(TomlDocument.parse(source).source, source);
  });

  test('parse failures contain useful native location diagnostics', () {
    expect(
      () => TomlDocument.parse('[tools]\nlimit =\n'),
      throwsA(
        failure(TomlFailureKind.parse).having(
          (error) => error.message,
          'location',
          allOf(contains('line 2'), contains('column')),
        ),
      ),
    );
    expect(
      () => TomlDocument.parse('a = 1\na = 2\n'),
      throwsA(failure(TomlFailureKind.parse)),
    );
  });

  test('updates preserve comments, spaces, ordering and unrelated values', () {
    const source = '''
# Output should be large enough for diagnostics.
[tools]
outputLimit = 5000  # Keep this configurable
timeout = 30

[other] # table comment
name  =  'unchanged'
''';
    final original = TomlDocument.parse(source);
    final edited = original.setScalar(['tools', 'outputLimit'], 8000);
    expect(edited.source, source.replaceFirst('5000', '8000'));
    expect(original.source, source);
    expect(edited.readScalar(['tools', 'outputLimit']), 8000);
  });

  test('inserts and removes scalars without removing the enclosing table', () {
    final original = TomlDocument.parse('[tools]\ntimeout = 30\n');
    final inserted = original.setScalar(['tools', 'enabled'], true);
    expect(inserted.source, '[tools]\ntimeout = 30\nenabled = true\n');
    final removed = inserted.removeScalar(['tools', 'timeout']);
    expect(removed.source, '[tools]\nenabled = true\n');
    expect(removed.removeScalar(['tools', 'enabled']).source, '[tools]\n');
    expect(
      TomlDocument.parse('').setScalar(['name'], 'ADELE').source,
      'name = "ADELE"\n',
    );
  });

  test('strings roundtrip special characters, NUL and Unicode', () {
    const value =
        'quotes " and \' backslash \\ newline\n tab\t nul\x00 '
        '\u00e9 \u4e16\u754c \u{1f680}';
    final document = TomlDocument.parse(
      'text = "old" # keep\n',
    ).setScalar(['text'], value);
    expect(document.readScalar(['text']), value);
    expect(document.source, contains('# keep'));
    expect(TomlDocument.parse(document.source).readScalar(['text']), value);
  });

  test('literal path segments support quoted, dotted and empty keys', () {
    final document = TomlDocument.parse('["a.b"]\n"c.d" = 1\n')
        .setScalar(['a.b', 'c.d'], 2)
        .setScalar(['a.b', ''], 'empty key')
        .setScalar(['a.b', 'new.key'], false);
    expect(document.readScalar(['a.b', 'c.d']), 2);
    expect(document.readScalar(['a.b', '']), 'empty key');
    expect(document.readScalar(['a.b', 'new.key']), false);
    expect(document.source, contains('"c.d" = 2'));
    expect(
      () => document.readScalar(['a', 'b', 'c', 'd']),
      throwsA(failure(TomlFailureKind.path)),
    );
  });

  test('existing dotted-key tables can be edited', () {
    const source = 'tools.limit = 5 # keep\ntools.enabled = true\n';
    final edited = TomlDocument.parse(source).setScalar(['tools', 'limit'], 8);
    expect(edited.source, source.replaceFirst('5', '8'));
    final added = edited.setScalar(['tools', 'name'], 'test');
    expect(added.readScalar(['tools', 'name']), 'test');
    expect(
      added.removeScalar(['tools', 'limit']).readScalar(['tools', 'enabled']),
      true,
    );
  });

  test(
    'removing the last dotted key follows upstream implicit-table removal',
    () {
      final document = TomlDocument.parse('tools.limit = 5\n');
      final removed = document.removeScalar(['tools', 'limit']);
      expect(removed.source, '');
      expect(
        () => removed.setScalar(['tools', 'limit'], 8),
        throwsA(failure(TomlFailureKind.path)),
      );
      expect(document.source, 'tools.limit = 5\n');
    },
  );

  test('equal values and absent-leaf removal preserve exact original text', () {
    const source =
        "# header\r\nvalue = 0x10 # hexadecimal\r\ntext = 'literal'\r\n";
    final document = TomlDocument.parse(source);
    expect(document.setScalar(['value'], 16), same(document));
    expect(document.setScalar(['text'], 'literal'), same(document));
    expect(document.removeScalar(['missing']), same(document));
    expect(document.source, source);
  });

  test('changed CRLF documents follow upstream newline normalization', () {
    final document = TomlDocument.parse('value = 1\r\nother = 2\r\n');
    expect(document.setScalar(['value'], 3).source, 'value = 3\nother = 2\n');
  });

  test('integers preserve full signed 64-bit range across the bridge', () {
    final document = TomlDocument.parse(
      'min = -9223372036854775808\nmax = 0\n',
    );
    expect(document.readScalar(['min']), -9223372036854775808);
    expect(
      document.setScalar(['max'], 9223372036854775807).readScalar(['max']),
      9223372036854775807,
    );
  });

  test('failed operations never modify or publish a partial document', () {
    const source =
        'number = 1\nfloat = 1.2\nlist = [1]\ninline = { key = 2 }\n[table]\n';
    final document = TomlDocument.parse(source);
    for (final action in <void Function()>[
      () => document.setScalar(['number'], 'wrong type'),
      () => document.setScalar(['number'], 1.5),
      () => document.setScalar(['float'], 2),
      () => document.removeScalar(['list']),
      () => document.removeScalar(['table']),
      () => document.readScalar(['inline']),
    ]) {
      expect(action, throwsA(failure(TomlFailureKind.type)));
      expect(document.source, source);
    }
    for (final action in <void Function()>[
      () => document.setScalar([], 1),
      () => document.removeScalar([]),
      () => document.readScalar([]),
      () => document.setScalar(['missing', 'value'], 1),
      () => document.setScalar(['number', 'value'], 1),
      () => document.setScalar(['inline', 'key'], 3),
      () => document.removeScalar(['missing', 'value']),
      () => document.readScalar(['missing']),
    ]) {
      expect(action, throwsA(failure(TomlFailureKind.path)));
      expect(document.source, source);
    }
    expect(document.setScalar(['number'], 2).readScalar(['number']), 2);
  });

  test('repeated native calls retain independent snapshots', () {
    final original = TomlDocument.parse('value = 0\n');
    for (var index = 0; index < 500; index++) {
      expect(original.setScalar(['value'], index).readScalar(['value']), index);
    }
    expect(original.readScalar(['value']), 0);
  });
}
