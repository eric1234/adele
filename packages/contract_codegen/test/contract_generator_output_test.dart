import 'package:path/path.dart' as p;

import 'support/contract_generator_support.dart';

void main() {
  test(
    'generated Future<void> dispatcher returns a null payload',
    () async {
      await runGeneratedFixture(
        runtimeContract(),
        runtimeTests('voidDispatcher'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('diagnostics report actionable exact source locations', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<DateTime> ping(String value);',
      ),
    );
    final diagnostic = await readDiagnostic(fixture.source);
    expect(diagnostic.path, fixture.source.absolute.path);
    expect(diagnostic.line, 11);
    expect(diagnostic.column, 10);
    expect(
      diagnostic.toString(),
      '${fixture.source.absolute.path}:11:10: Unsupported contract type DateTime.',
    );
  });

  for (final entry
      in <
            String,
            ({String original, String replacement, int line, int column})
          >{
            'method': (
              original: 'Future<FixtureMood> ping(String value)',
              replacement: r'Future<FixtureMood> $ping(String value)',
              line: 11,
              column: 3,
            ),
            'parameter': (
              original: 'ping(String value)',
              replacement: r'ping(String $value)',
              line: 11,
              column: 49,
            ),
            'field': (
              original: 'final String value;',
              replacement: r'final String $value;',
              line: 7,
              column: 16,
            ),
            'enum value': (
              original: 'enum FixtureMood { ready }',
              replacement: r'enum FixtureMood { $ready }',
              line: 3,
              column: 20,
            ),
          }
          .entries) {
    test('reports precise ${entry.key} identifier location', () async {
      final fixture = await createFixture(
        identifierContract().replaceFirst(
          entry.value.original,
          entry.value.replacement,
        ),
      );
      final diagnostic = await readDiagnostic(fixture.source);
      expect(diagnostic.line, entry.value.line);
      expect(diagnostic.column, entry.value.column);
    });
  }

  test('apply check is non-mutating and write creates final output', () async {
    final fixture = await createFixture(minimalContract(namedValue: true));
    final generator = const ContractGenerator();
    final generated = await generator.generate(fixture.source);
    expect(await generator.apply(fixture.source, check: true), isFalse);
    expect(File(generated.path).existsSync(), isFalse);
    expect(await generator.apply(fixture.source, check: false), isFalse);
    expect(await File(generated.path).readAsString(), generated.contents);
    expect(await generator.apply(fixture.source, check: true), isTrue);
  });

  for (final part in <String>[
    'other.g.dart',
    'generated/fixture.g.dart',
    '../fixture.g.dart',
    './fixture.g.dart',
    '/fixture.g.dart',
    r'generated\fixture.g.dart',
    'file:fixture.g.dart',
    'package:fixture/fixture.g.dart',
    '//example.test/fixture.g.dart',
    'fixture.g.dart?query',
    'fixture.g.dart#fragment',
    'fixture%2Eg.dart',
  ]) {
    test('rejects non-canonical generated part URI $part', () async {
      await expectDiagnostic(
        minimalContract(
          namedValue: true,
        ).replaceFirst("part 'fixture.g.dart';", "part '$part';"),
        'Generated part URI must be exactly fixture.g.dart',
      );
    });
  }

  test('derives a contained sibling generated destination', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true),
      basename: 'some_contract.dart',
    );
    await fixture.source.writeAsString(
      minimalContract(
        namedValue: true,
      ).replaceFirst('fixture.g.dart', 'some_contract.g.dart'),
    );
    final generated = await const ContractGenerator().generate(fixture.source);
    expect(p.basename(generated.path), 'some_contract.g.dart');
    expect(p.dirname(generated.path), fixture.directory.path);
  });
}
