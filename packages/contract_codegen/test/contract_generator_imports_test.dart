import 'support/contract_generator_support.dart';

void main() {
  test('supports String bool int and double primitives', () async {
    final output = await generateContract(allTypesContract());
    expect(
      output,
      allOf(
        contains('_contractString'),
        contains('_contractBool'),
        contains('_contractInt'),
        contains('_contractDouble'),
      ),
    );
  });

  test('supports nullable contract types', () async {
    final output = await generateContract(allTypesContract());
    expect(output, contains(RegExp(r'switch \(_adeleValue\d+\.note\)')));
  });

  test('supports immutable decoded lists', () async {
    final output = await generateContract(allTypesContract());
    expect(output, contains(RegExp(r'List<[^>]+>\.unmodifiable')));
  });

  test('supports enums', () async {
    final output = await generateContract(allTypesContract());
    expect(output, contains('_decodeMood'));
  });

  test('supports nested values', () async {
    final output = await generateContract(allTypesContract());
    expect(output, contains('_decodeChild'));
  });

  test('emits named value invocation in deterministic wire order', () async {
    final output = await generateContract(wireOrderingContract());
    expect(output, contains(RegExp(r"'a':\s*_adeleValue\d+\.second")));
    expect(output, contains(RegExp(r"'z':\s*_adeleValue\d+\.first")));
    expect(output.indexOf("'a':"), lessThan(output.indexOf("'z':")));
    final constructor = output.indexOf('() => OrderedValue(');
    expect(constructor, isNonNegative);
    expect(
      output.indexOf('second:', constructor),
      lessThan(output.indexOf('first:', constructor)),
    );
  });

  test(
    'generated ResourceRef codecs reject malformed URI paths',
    () async {
      await runGeneratedFixture(
        resourceRuntimeContract(),
        resourceRuntimeTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('supports ResourceRef', () async {
    final output = await generateContract(allTypesContract());
    expect(
      output,
      allOf(contains('_contractResourceRef'), contains('_decodeResourceRef')),
    );
  });

  for (final import in <String>[
    "import 'package:adele_contract/adele_contract.dart' as contract;",
    "import 'package:adele_contract/adele_contract.dart' show AdeleService, AdeleMethod, AdeleValue, AdeleFailure;",
    "import 'package:adele_contract/adele_contract.dart' hide AdeleProtocolException;",
  ]) {
    test('rejects non-canonical adele_contract import $import', () async {
      await expectDiagnostic(
        minimalContract(namedValue: true).replaceFirst(
          "import 'package:adele_contract/adele_contract.dart';",
          import,
        ),
        'exactly one canonical unprefixed import',
      );
    });
  }

  for (final declaration in <String>[
    'class AdeleRequestChannel {}',
    'class AdeleProtocolException {}',
    'class String {}',
    'class Future<T> {}',
    'class Exception {}',
  ]) {
    test('rejects unprefixed import before reserved-name analysis', () async {
      final fixture = await fixtureWithSupport(
        "import 'support.dart';\n${minimalContract(namedValue: true)}",
        declaration,
      );
      final diagnostic = await readDiagnostic(fixture.source);
      expect(diagnostic.message, contains('must be prefixed'));
      expect(diagnostic.path, fixture.source.absolute.path);
      expect(diagnostic.line, 2);
      expect(diagnostic.column, 1);
    });
  }

  for (final symbol in <String>['TypeError', 'StateError']) {
    test('rejects generated core collision $symbol', () async {
      await expectDiagnostic(
        minimalContract(namedValue: true).replaceFirst(
          "@AdeleValue('fixture.value')",
          'class $symbol {}\n@AdeleValue(\'fixture.value\')',
        ),
        'Generated symbol collision for $symbol',
      );
    });
  }

  test('allows canonical and additional prefixed contract imports', () async {
    expect(
      await generateContract(
        minimalContract(namedValue: true).replaceFirst(
          "import 'package:adele_contract/adele_contract.dart';",
          "import 'package:adele_contract/adele_contract.dart';\nimport 'package:adele_contract/adele_contract.dart' as contract;",
        ),
      ),
      isNotEmpty,
    );
  });

  for (final import in <String>[
    "import 'support.dart';",
    "import './support.dart';",
    "import 'package:path/path.dart';",
    "import 'package:adele_contract_lookalike/adele_contract.dart';",
    "import 'package:other/adele_contract.dart';",
  ]) {
    test('rejects unprefixed noncanonical import $import', () async {
      await expectDiagnostic(
        '$import\n${minimalContract(namedValue: true)}',
        'Every other contract library import must be prefixed',
      );
    });
  }

  for (final import in <String>[
    "import 'package:adele_contract/src/annotations.dart';",
    "import 'package:adele_contract/other.dart';",
    "import 'package:adele_plugin_api/src/resource_ref.dart';",
    "import 'package:adele_plugin_api/other.dart';",
  ]) {
    test('rejects unprefixed canonical-package import $import', () async {
      await expectDiagnostic(
        '$import\n${minimalContract(namedValue: true)}',
        'package must be prefixed',
      );
    });
  }

  for (final pluginImport in <String>[
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api show ResourceRef;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api hide ResourceRef;",
    "import 'package:adele_plugin_api/src/resource_ref.dart' as resource;",
    "import 'package:adele_plugin_api/other.dart' as api_other;",
  ]) {
    test(
      'allows prefixed plugin import without ResourceRef $pluginImport',
      () async {
        expect(
          await generateContract('''
import 'support.dart' as support;
import 'package:path/path.dart' as path;
import 'package:adele_contract/src/annotations.dart' as annotations;
$pluginImport
${minimalContract(namedValue: true)}'''),
          isNotEmpty,
        );
      },
    );
  }

  for (final import in <String>[
    "import 'support.dart' if (dart.library.io) 'package:adele_contract/adele_contract.dart' as support;",
    "import 'package:adele_contract/adele_contract.dart' if (dart.library.io) 'support.dart';",
    "import 'package:adele_contract/src/annotations.dart' if (dart.library.io) 'support.dart' as support;",
    "import 'support.dart' if (dart.library.io) 'package:adele_plugin_api/adele_plugin_api.dart' as support;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' if (dart.library.io) 'support.dart' as api;",
    "import 'package:adele_plugin_api/src/resource_ref.dart' if (dart.library.io) 'support.dart' as resource;",
  ]) {
    test('rejects conditional canonical import $import', () async {
      await expectDiagnostic(
        '$import\n${minimalContract(namedValue: true)}',
        'Conditional imports from the adele_',
      );
    });
  }

  test('allows no adele_plugin_api import without ResourceRef', () async {
    expect(
      await generateContract(minimalContract(namedValue: true)),
      isNotEmpty,
    );
  });

  for (final import in <String>[
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' show ResourceRef;",
  ]) {
    test('rejects non-canonical ResourceRef import $import', () async {
      await expectDiagnostic(
        allTypesContract().replaceFirst(
          "import 'package:adele_plugin_api/adele_plugin_api.dart';",
          import,
        ),
        import.contains(' as api;')
            ? 'Unsupported contract type InvalidType'
            : 'exactly one canonical unprefixed import',
      );
    });
  }

  test('rejects ResourceRef when the canonical plugin import hides it', () async {
    await expectDiagnostic(
      allTypesContract().replaceFirst(
        "import 'package:adele_plugin_api/adele_plugin_api.dart';",
        "import 'package:adele_plugin_api/adele_plugin_api.dart' hide ResourceRef;",
      ),
      'Unsupported contract type InvalidType',
    );
  });

  for (final additionalImport in <String>[
    "import 'package:adele_plugin_api/adele_plugin_api.dart' show ResourceRef;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' hide ResourceRef;",
  ]) {
    test(
      'rejects additional unprefixed canonical plugin import $additionalImport',
      () async {
        await expectDiagnostic(
          allTypesContract().replaceFirst(
            "import 'package:adele_plugin_api/adele_plugin_api.dart';",
            "import 'package:adele_plugin_api/adele_plugin_api.dart';\n$additionalImport",
          ),
          'exactly one canonical unprefixed import',
        );
      },
    );
  }

  for (final entry in <String, String>{
    'contract show':
        "import 'package:adele_contract/adele_contract.dart' show AdeleService;",
    'contract hide':
        "import 'package:adele_contract/adele_contract.dart' hide AdeleProtocolException;",
  }.entries) {
    test('${entry.key} diagnostic targets additional import', () async {
      final source = minimalContract(namedValue: true).replaceFirst(
        "import 'package:adele_contract/adele_contract.dart';",
        "import 'package:adele_contract/adele_contract.dart';\n\n${entry.value}",
      );
      final fixture = await createFixture(source);
      final diagnostic = await readDiagnostic(fixture.source);
      final lines = await fixture.source.readAsLines();
      expect(diagnostic, isA<ContractDiagnostic>());
      expect(diagnostic.path, fixture.source.absolute.path);
      expect(diagnostic.line, lines.indexOf(entry.value) + 1);
      expect(diagnostic.column, 1);
    });
  }

  for (final entry in <String, String>{
    'plugin show':
        "import 'package:adele_plugin_api/adele_plugin_api.dart' show ResourceRef;",
    'plugin hide':
        "import 'package:adele_plugin_api/adele_plugin_api.dart' hide ResourceRef;",
  }.entries) {
    test('${entry.key} diagnostic targets additional import', () async {
      final source = allTypesContract().replaceFirst(
        "import 'package:adele_plugin_api/adele_plugin_api.dart';",
        "import 'package:adele_plugin_api/adele_plugin_api.dart';\n\n${entry.value}",
      );
      final fixture = await createFixture(source);
      final diagnostic = await readDiagnostic(fixture.source);
      final lines = await fixture.source.readAsLines();
      expect(diagnostic, isA<ContractDiagnostic>());
      expect(diagnostic.path, fixture.source.absolute.path);
      expect(diagnostic.line, lines.indexOf(entry.value) + 1);
      expect(diagnostic.column, 1);
    });
  }

  for (final additionalImport in <String>[
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api show ResourceRef;",
    "import 'package:adele_plugin_api/adele_plugin_api.dart' as api hide ResourceRef;",
  ]) {
    test(
      'allows additional prefixed canonical plugin import $additionalImport',
      () async {
        expect(
          await generateContract(
            allTypesContract().replaceFirst(
              "import 'package:adele_plugin_api/adele_plugin_api.dart';",
              "import 'package:adele_plugin_api/adele_plugin_api.dart';\n$additionalImport",
            ),
          ),
          isNotEmpty,
        );
      },
    );
  }

  for (final additionalImport in <String>[
    "import 'package:adele_contract/adele_contract.dart' show AdeleService;",
    "import 'package:adele_contract/adele_contract.dart' hide AdeleProtocolException;",
  ]) {
    test(
      'rejects additional unprefixed canonical contract import $additionalImport',
      () async {
        await expectDiagnostic(
          minimalContract(namedValue: true).replaceFirst(
            "import 'package:adele_contract/adele_contract.dart';",
            "import 'package:adele_contract/adele_contract.dart';\n$additionalImport",
          ),
          'exactly one canonical unprefixed import',
        );
      },
    );
  }

  for (final additionalImport in <String>[
    "import 'package:adele_contract/adele_contract.dart' as contract show AdeleService;",
    "import 'package:adele_contract/adele_contract.dart' as contract hide AdeleProtocolException;",
  ]) {
    test(
      'allows additional prefixed canonical contract import $additionalImport',
      () async {
        expect(
          await generateContract(
            minimalContract(namedValue: true).replaceFirst(
              "import 'package:adele_contract/adele_contract.dart';",
              "import 'package:adele_contract/adele_contract.dart';\n$additionalImport",
            ),
          ),
          isNotEmpty,
        );
      },
    );
  }

  test('rejects ResourceRef without canonical plugin API import', () async {
    await expectDiagnostic(
      allTypesContract().replaceFirst(
        "import 'package:adele_plugin_api/adele_plugin_api.dart';\n",
        "import 'package:adele_plugin_api/src/resource_ref.dart' as resource;\n",
      ),
      'Unsupported contract type InvalidType',
    );
  });

  test('rejects ResourceRef lookalikes', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst(
            "part 'fixture.g.dart';",
            "part 'fixture.g.dart';\nclass ResourceRef {}",
          )
          .replaceFirst(
            'Future<String> ping(String value);',
            'Future<ResourceRef> ping(ResourceRef value);',
          ),
      'Unsupported contract type ResourceRef',
    );
  });
}
