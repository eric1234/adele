import 'support/contract_generator_support.dart';

void main() {
  test(
    'generated dispatcher contains service protocol exceptions',
    () async {
      await runGeneratedFixture(
        runtimeContract(),
        runtimeTests('serviceProtocol'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated value construction failures stay within protocol boundaries',
    () async {
      await runGeneratedFixture(valueRuntimeContract(), valueRuntimeTests());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'declared failure construction failures stay opaque and recoverable',
    () async {
      await runGeneratedFixture(
        failureRuntimeContract(),
        failureRuntimeTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('accepts exact collection snapshot constructor parameters', () async {
    final String generated = await generateContract('''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.value')
final class FixtureValue {
  FixtureValue({required List<String> values, required Map<String, Object?> data})
      : values = List<String>.unmodifiable(values),
        data = adeleSnapshotJsonMap(data);
  final List<String> values;
  final Map<String, Object?> data;
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
@AdeleService('fixture')
abstract interface class FixtureService {
  @AdeleMethod('ping') Future<FixtureValue> ping(FixtureValue value);
}
''');
    expect(generated, contains('FixtureValue(data:'));
  });

  test('rejects scalar snapshot constructor parameters', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        'const FixtureValue({required this.value});',
        'const FixtureValue({required String value}) : value = value;',
      ),
      'except exact-type List and Map<String, Object?> snapshot parameters',
    );
  });

  test('rejects collection snapshot parameter type mismatch', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst('String value', 'List<String> value')
          .replaceFirst(
            'const FixtureValue({required this.value});',
            'FixtureValue({required List<Object> value}) : value = value.cast<String>();',
          ),
      'must have exactly the same type',
    );
  });

  for (final ({String name, String initializer}) fixture
      in <({String name, String initializer})>[
        (name: 'list reversal', initializer: 'values.reversed.toList()'),
        (
          name: 'list wrong parameter',
          initializer: 'List<String>.unmodifiable(other)',
        ),
        (name: 'arbitrary list helper', initializer: 'snapshot(values)'),
      ]) {
    test('rejects ${fixture.name} snapshot initializer', () async {
      await expectDiagnostic(
        collectionSnapshotContract(
          listInitializer: fixture.initializer,
          extraParameter: fixture.name == 'list wrong parameter'
              ? ', required List<String> other'
              : '',
          helper: fixture.name == 'arbitrary list helper'
              ? 'List<String> snapshot(List<String> value) => List.unmodifiable(value);'
              : '',
        ),
        'snapshot parameters',
      );
    });
  }

  for (final ({String name, String initializer, String helper}) fixture
      in <({String name, String initializer, String helper})>[
        (name: 'constant map', initializer: 'const {}', helper: ''),
        (
          name: 'local map helper',
          initializer: 'localSnapshot(data)',
          helper:
              'Map<String, Object?> localSnapshot(Map<String, Object?> value) => Map.unmodifiable(value);',
        ),
        (
          name: 'canonical map wrong parameter',
          initializer: 'adeleSnapshotJsonMap(other)',
          helper: '',
        ),
      ]) {
    test('rejects ${fixture.name} snapshot initializer', () async {
      await expectDiagnostic(
        collectionSnapshotContract(
          mapInitializer: fixture.initializer,
          extraParameter: fixture.name == 'canonical map wrong parameter'
              ? ', required Map<String, Object?> other'
              : '',
          helper: fixture.helper,
        ),
        'snapshot parameters',
      );
    });
  }

  test('rejects nullable recursive annotated value schemas', () async {
    await expectDiagnostic(recursiveValueContract('Node?'), 'schema cycles');
  });

  test('rejects list recursive annotated value schemas', () async {
    await expectDiagnostic(
      recursiveValueContract('List<Node>'),
      'schema cycles',
    );
  });

  test('rejects mutual recursive annotated value schemas', () async {
    await expectDiagnostic(
      recursiveValueContract('Other?').replaceFirst(
        "@AdeleFailure('fixture.failure')",
        "@AdeleValue('fixture.other')\nfinal class Other { const Other({required this.next}); final Node? next; }\n@AdeleFailure('fixture.failure')",
      ),
      'schema cycles',
    );
  });

  test('rejects imported annotated value types', () async {
    final fixture = await fixtureWithSupport(
      minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<ImportedValue> ping(ImportedValue value);',
      ),
      '''
import 'package:adele_contract/adele_contract.dart';
@AdeleValue('support.value')
final class ImportedValue {
  const ImportedValue({required this.value});
  final String value;
}
''',
    );
    expect(
      (await readDiagnostic(fixture.source)).message,
      contains('source library, not imported'),
    );
  });

  test('rejects imported enum types', () async {
    final fixture = await fixtureWithSupport(
      minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<ImportedMood> ping(ImportedMood value);',
      ),
      'enum ImportedMood { calm }',
    );
    expect(
      (await readDiagnostic(fixture.source)).message,
      contains('declared in the source library'),
    );
  });
}
