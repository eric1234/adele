import 'support/contract_generator_support.dart';

void main() {
  for (final entry in <String, String>{
    'String': 'class String {}',
    'bool': 'class bool {}',
    'int': 'class int {}',
    'double': 'class double {}',
    'List': 'class List<T> {}',
    'Map': 'class Map<K, V> {}',
    'Uri': 'class Uri {}',
    'Object': 'class Object {}',
  }.entries) {
    test('rejects ${entry.key} lookalike contract types', () async {
      final source = minimalContract(namedValue: true)
          .replaceFirst(
            "part 'fixture.g.dart';",
            "part 'fixture.g.dart';\n${entry.value}",
          )
          .replaceAll('String value', '${entry.key} value');
      await expectDiagnostic(source, 'Unsupported contract type');
    });
  }

  test('rejects Future lookalike outer returns', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        "part 'fixture.g.dart';",
        "part 'fixture.g.dart';\nclass Future<T> {}",
      ),
      'Service methods must return Future<T>',
    );
  });

  for (final prefix in <String>[
    'FixtureServiceClient',
    '_contractMap',
    'fixtureServiceId',
    'fixtureValueTypeId',
    'AdeleRequestChannel',
    'AdeleStreamChannel',
    'AdeleLazyStream',
    'adeleDecodedStream',
  ]) {
    test('reserves import prefix $prefix against generated symbols', () async {
      final fixture = await fixtureWithSupport(
        minimalContract(namedValue: true),
        'class Unused {}',
        prefix: prefix,
      );
      expect(
        (await readDiagnostic(fixture.source)).message,
        contains('Generated symbol collision for $prefix'),
      );
    });
  }

  test('conditionally reserves ResourceRef import prefixes', () async {
    final fixture = await fixtureWithSupport(
      allTypesContract(),
      'class Unused {}',
      prefix: '_decodeResourceRef',
    );
    expect(
      (await readDiagnostic(fixture.source)).message,
      contains('Generated symbol collision for _decodeResourceRef'),
    );
  });

  for (final entry in <String, String>{
    'outer Future': 'typedef Alias<T> = Future<T>;',
    'nullable': 'typedef Alias = String?;',
    'list': 'typedef Alias = List<String>;',
    'list element': 'typedef Alias = String;',
    'enum': 'typedef Alias = FixtureMood;',
    'value': 'typedef Alias = FixtureValue;',
    'ResourceRef': 'typedef Alias = ResourceRef;',
  }.entries) {
    test('rejects transported ${entry.key} aliases', () async {
      String source = identifierContract().replaceFirst(
        "part 'fixture.g.dart';",
        "part 'fixture.g.dart';\n${entry.value}",
      );
      if (entry.key == 'outer Future') {
        source = source.replaceFirst(
          'Future<FixtureMood> ping(String value)',
          'Alias<FixtureMood> ping(String value)',
        );
      } else if (entry.key == 'list element') {
        source = source.replaceFirst('String value)', 'List<Alias> value)');
      } else if (entry.key == 'ResourceRef') {
        source = source
            .replaceFirst(
              "import 'package:adele_contract/adele_contract.dart';",
              "import 'package:adele_contract/adele_contract.dart';\nimport 'package:adele_plugin_api/adele_plugin_api.dart';",
            )
            .replaceFirst('String value)', 'Alias value)');
      } else {
        source = source.replaceFirst('String value)', 'Alias value)');
      }
      await expectDiagnostic(
        source,
        entry.key == 'outer Future'
            ? 'Service methods must return Future<T>'
            : 'Type aliases are not supported',
      );
    });
  }

  test('rejects imported schema aliases', () async {
    final fixture = await fixtureWithSupport(
      minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<Alias> ping(Alias value);',
      ),
      'class Imported {}\ntypedef Alias = Imported;',
    );
    expect(
      (await readDiagnostic(fixture.source)).message,
      contains('Type aliases are not supported'),
    );
  });

  test('allows unused unrelated aliases', () async {
    expect(
      await generateContract(
        minimalContract(namedValue: true).replaceFirst(
          "part 'fixture.g.dart';",
          "part 'fixture.g.dart';\ntypedef Unused = DateTime;",
        ),
      ),
      isNotEmpty,
    );
  });

  test('rejects transported alias chains', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst(
            "part 'fixture.g.dart';",
            "part 'fixture.g.dart';\ntypedef First = String;\ntypedef Second = First;",
          )
          .replaceFirst('String value)', 'Second value)'),
      'Type aliases are not supported',
    );
  });

  test(
    'generated Map<String, Object?> recursively validates JSON',
    () async {
      await runGeneratedFixture(runtimeContract(), runtimeTests('json'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated double codecs reject non-finite values',
    () async {
      await runGeneratedFixture(runtimeContract(), runtimeTests('double'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated dispatcher stages classification and containment',
    () async {
      await runGeneratedFixture(runtimeContract(), runtimeTests('dispatcher'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
