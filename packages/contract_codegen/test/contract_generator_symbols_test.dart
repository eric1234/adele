import 'support/contract_generator_support.dart';

void main() {
  test(
    'relative URI backend result shapes are contained and recoverable',
    () async {
      await runGeneratedFixture(
        relativeUriResultContract(),
        relativeUriResultTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'nullable and nested annotated URI backend results are contained',
    () async {
      await runGeneratedFixture(
        nullableUriResultContract(),
        nullableUriResultTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated Future<void> client requires a null response',
    () async {
      await runGeneratedFixture(runtimeContract(), runtimeTests('voidClient'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('rejects value inheritance', () async {
    final source = minimalContract(namedValue: true)
        .replaceFirst(
          'final class FixtureValue {',
          'class Base {}\n@AdeleValue(\'fixture.value\')\nfinal class Replacement extends Base {',
        )
        .replaceFirst("@AdeleValue('fixture.value')\n", '')
        .replaceAll('FixtureValue', 'Replacement');
    await expectDiagnostic(source, 'final class without a superclass');
  });

  test('rejects optional service parameters', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('ping(String value)', 'ping([String value = \'\'])'),
      'required positional parameters',
    );
  });

  for (final entry in <String, String>{
    'static methods':
        "@AdeleMethod('other') static Future<String> other(String value) async => value;",
    'concrete methods':
        "@AdeleMethod('other') Future<String> other(String value) async => value;",
    'operators':
        "@AdeleMethod('other') Future<String> operator +(String value);",
    'getters': 'String get value;',
    'setters': 'set value(String value);',
    'fields': "static final String value = 'value';",
    'constructors': 'factory FixtureService() => throw UnimplementedError();',
  }.entries) {
    test('rejects service ${entry.key}', () async {
      await expectDiagnostic(
        minimalContract(namedValue: true).replaceFirst(
          "  @AdeleMethod('ping')",
          "  ${entry.value}\n  @AdeleMethod('ping')",
        ),
        entry.key == 'constructors'
            ? 'may not declare constructors'
            : entry.key == 'getters' || entry.key == 'setters'
            ? 'may not declare getters or setters'
            : 'abstract instance methods',
      );
    });
  }

  test('rejects generated public symbol collisions', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        "@AdeleValue('fixture.value')",
        "class FixtureServiceClient {}\n@AdeleValue('fixture.value')",
      ),
      'Generated symbol collision for FixtureServiceClient',
    );
  });

  for (final entry in <String, String>{
    'enum': 'enum FixtureServiceClient { value }',
    'mixin': 'mixin FixtureServiceClient {}',
    'typedef': 'typedef FixtureServiceClient = String;',
    'extension': 'extension FixtureServiceClient on String {}',
    'extension type': 'extension type FixtureServiceClient(String value) {}',
    'function': 'void FixtureServiceClient() {}',
    'variable': 'final FixtureServiceClient = Object();',
    'getter': 'Object get FixtureServiceClient => Object();',
    'setter': 'set FixtureServiceClient(Object value) {}',
  }.entries) {
    test('rejects generated collisions with top-level ${entry.key}', () async {
      await expectDiagnostic(
        minimalContract(namedValue: true).replaceFirst(
          "@AdeleValue('fixture.value')",
          "${entry.value}\n@AdeleValue('fixture.value')",
        ),
        'Generated symbol collision for FixtureServiceClient',
      );
    });
  }

  for (final declaration in <String>[
    'Object? _contractMap;',
    'Object? _contractJsonMaxDepth;',
    'Object? _decodeContractEnvelope;',
    'class _ContractUnknownMethod {}',
    'Object? _contractFailure;',
  ]) {
    test('rejects fixed generated helper collision $declaration', () async {
      final symbol = RegExp(
        r'_[A-Za-z][A-Za-z0-9_]*',
      ).firstMatch(declaration)!.group(0)!;
      await expectDiagnostic(
        minimalContract(namedValue: true).replaceFirst(
          "@AdeleValue('fixture.value')",
          "$declaration\n@AdeleValue('fixture.value')",
        ),
        'Generated symbol collision for $symbol',
      );
    });
  }

  test('rejects conditional ResourceRef helper collisions', () async {
    await expectDiagnostic(
      allTypesContract().replaceFirst(
        'enum Mood',
        'Object? _decodeResourceRef;\nenum Mood',
      ),
      'Generated symbol collision for _decodeResourceRef',
    );
  });

  test('rejects enum decoder collisions with value decoders', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst(
            "@AdeleValue('fixture.value')",
            "enum FixtureValue { value }\n@AdeleValue('fixture.value')",
          )
          .replaceFirst(
            'Future<String> ping(String value);',
            'Future<FixtureValue> ping(FixtureValue value);',
          ),
      'Generated symbol collision for _decodeFixtureValue',
    );
  });

  test('rejects method names that map to one generated symbol', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        "  @AdeleMethod('ping')",
        "  @AdeleMethod('upperPing')\n  Future<String> Ping(String value);\n  @AdeleMethod('ping')",
      ),
      'Generated symbol collision',
    );
  });

  for (final entry in <String, String>{
    'service': 'FixtureService',
    'value': 'FixtureValue',
    'failure': 'FixtureFailure',
    'method': 'ping',
    'service parameter': 'ping(String value)',
    'value field': 'final String value;',
    'value constructor parameter': 'required this.value',
    'enum': 'FixtureMood',
    'enum value': 'ready',
  }.entries) {
    for (final invalid in const <String>['_private', r'$dollar', 'café']) {
      test('rejects ${entry.key} schema name $invalid', () async {
        String source = identifierContract();
        source = switch (entry.key) {
          'method' => source.replaceFirst(
            'Future<FixtureMood> ping(String value)',
            'Future<FixtureMood> $invalid(String value)',
          ),
          'service parameter' => source.replaceFirst(
            entry.value,
            'ping(String $invalid)',
          ),
          'value field' =>
            source
                .replaceFirst(entry.value, 'final String $invalid;')
                .replaceAll('this.value', 'this.$invalid'),
          'value constructor parameter' =>
            source
                .replaceFirst(entry.value, 'required this.$invalid')
                .replaceFirst('final String value;', 'final String $invalid;'),
          'enum' => source.replaceAll(entry.value, invalid),
          _ => source.replaceFirst(entry.value, invalid),
        };
        await expectDiagnostic(source, '[A-Za-z][A-Za-z0-9_]*');
      });
    }
  }

  test('allows unrelated unreachable private helpers and enums', () async {
    final output = await generateContract(
      identifierContract().replaceFirst(
        "@AdeleValue('fixture.value')",
        'class _PrivateHelper {}\nenum _PrivateMood { _ready }\n'
            "@AdeleValue('fixture.value')",
      ),
    );
    expect(output, isNot(contains('_decode_PrivateMood')));
  });
}
