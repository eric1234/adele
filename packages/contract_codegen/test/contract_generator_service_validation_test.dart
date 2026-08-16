import 'package:path/path.dart' as p;

import 'support/contract_generator_support.dart';

void main() {
  test(
    'generated dispatcher contains invalid backend output',
    () async {
      await runGeneratedFixture(
        runtimeContract(),
        runtimeTests('invalidResult'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'stream runtime type enforcement is a contract violation',
    () async {
      await runGeneratedFixture(
        '''
library fixture;
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('ping')
  Future<String> ping(String value);
  @AdeleMethod('events')
  Stream<String> events(String mode);
  @AdeleMethod('invalidNumbers')
  Stream<double> invalidNumbers();
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''',
        '''
import 'dart:async';

import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('classifies boundary TypeErrors narrowly', () async {
    final dispatcher = FixtureServiceDispatcher(_UnsoundService());
    Future<Map<String, Object?>> run(String mode) async {
      final events = <Map<String, Object?>>[];
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': mode.hashCode,
        'method': fixtureServiceEventsId,
        'payload': {'mode': mode},
      }, events.add);
      await dispatcher.handle({
        'kind': 'streamCredit',
        'requestId': mode.hashCode,
        'credit': 1,
      }, events.add);
      while (events.isEmpty) await Future<void>.delayed(Duration.zero);
      return events.single;
    }
    for (final mode in ['wrongReturn', 'wrongItem']) {
      final event = await run(mode);
      expect(event['kind'], 'streamFailure');
      expect((event['error'] as Map)['code'], 'backend_contract_violation');
    }
    final event = await run('ordinaryFailure');
    expect((event['error'] as Map)['code'], 'internal_error');
    final service = _UnsoundService();
    final barrierDispatcher = FixtureServiceDispatcher(service);
    final barrierEvents = <Map<String, Object?>>[];
    await barrierDispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 99,
      'method': fixtureServiceInvalidNumbersId,
      'payload': {},
    }, barrierEvents.add);
    await barrierDispatcher.handle({
      'kind': 'streamCredit',
      'requestId': 99,
      'credit': 1,
    }, barrierEvents.add);
    await service.cancelStarted.future;
    expect(barrierEvents, isEmpty);
    bool closed = false;
    final closing = barrierDispatcher.close().then((_) => closed = true);
    expect(closed, isFalse);
    service.releaseCancel.complete();
    await closing;
    expect(barrierEvents, hasLength(1));
    expect((barrierEvents.single['error'] as Map)['code'], 'backend_contract_violation');
    expect(service.cancelCalls, 1);
    await dispatcher.close();
  });
}

final class _UnsoundService implements FixtureService {
  final Completer<void> cancelStarted = Completer<void>();
  final Completer<void> releaseCancel = Completer<void>();
  int cancelCalls = 0;
  @override
  Future<String> ping(String value) async => value;

  @override
  Stream<String> events(String mode) {
    if (mode == 'wrongReturn') return _dynamicValue(7);
    if (mode == 'wrongItem') {
      return _dynamicValue(Stream<Object?>.value(7));
    }
    return (() async* { throw StateError('ordinary'); })();
  }

  @override
  Stream<double> invalidNumbers() {
    late final StreamController<double> controller;
    controller = StreamController<double>(
      onListen: () => controller.add(double.nan),
      onCancel: () async {
        cancelCalls++;
        cancelStarted.complete();
        await releaseCancel.future;
      },
    );
    return controller.stream;
  }
}

dynamic _dynamicValue(Object? value) => value;
''',
        analyze: false,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated dispatcher contains invalid failure details',
    () async {
      await runGeneratedFixture(
        runtimeContract(),
        runtimeTests('invalidDetails'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('rejects mutable value fields', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('final String value;', 'String value;'),
      'Value fields must be non-late and final.',
    );
  });

  test('rejects late final value fields', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('final String value;', 'late final String value;'),
      'non-late and final',
    );
  });

  test('rejects unsupported synchronous returns', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('Future<String> ping', 'String ping'),
      'Service methods must return Future<T> or Stream<T>.',
    );
  });

  test('accepts Stream returns', () async {
    expect(
      await generateContract(
        minimalContract(
          namedValue: true,
        ).replaceFirst('Future<String> ping', 'Stream<String> ping'),
      ),
      contains('Stream<String> ping'),
    );
  });

  test('rejects generic service methods', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('ping(String value)', 'ping<T>(String value)'),
      'Generic service methods are not supported.',
    );
  });

  for (final entry in <String, String>{
    'value': 'final class FixtureValue<T>',
    'service': 'abstract interface class FixtureService<T>',
    'failure': 'final class FixtureFailure<T>',
  }.entries) {
    test('rejects generic annotated ${entry.key} declarations', () async {
      final original = switch (entry.key) {
        'value' => 'final class FixtureValue',
        'service' => 'abstract interface class FixtureService',
        _ => 'final class FixtureFailure',
      };
      await expectDiagnostic(
        minimalContract(namedValue: true).replaceFirst(original, entry.value),
        'Generic annotated ${entry.key} declarations are not supported.',
      );
    });
  }

  test('rejects dynamic contract types', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'dynamic value);'),
      'Dynamic or unconstrained contract types are not supported.',
    );
  });

  test(
    'reports ContractDiagnostic for an implicitly dynamic parameter',
    () async {
      final fixture = await createFixture(
        minimalContract(namedValue: true).replaceFirst(
          'Future<String> ping(String value);',
          'Future<String> ping(value);',
        ),
      );
      final diagnostic = await readDiagnostic(fixture.source);
      expect(diagnostic, isA<ContractDiagnostic>());
      expect(
        diagnostic.message,
        contains('Dynamic or unconstrained contract types'),
      );
      expect(diagnostic.path, fixture.source.absolute.path);
      expect(diagnostic.line, 11);
      expect(diagnostic.column, 23);
    },
  );

  test('reports ContractDiagnostic for a function-typed parameter', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<String> ping(String value());',
      ),
    );
    final diagnostic = await readDiagnostic(fixture.source);
    expect(diagnostic, isA<ContractDiagnostic>());
    expect(diagnostic.message, contains('Unsupported contract type'));
    expect(diagnostic.path, fixture.source.absolute.path);
    expect(diagnostic.line, 11);
    expect(diagnostic.column, 23);
  });

  for (final entry in <String, String>{
    'wildcard': 'String _',
    'covariant': 'covariant String value',
  }.entries) {
    test('reports ContractDiagnostic for ${entry.key} parameter', () async {
      final fixture = await createFixture(
        minimalContract(
          namedValue: true,
        ).replaceFirst('String value);', '${entry.value});'),
      );
      final generated = File(p.join(fixture.directory.path, 'fixture.g.dart'));
      final diagnostic = await readDiagnostic(fixture.source);
      expect(diagnostic, isA<ContractDiagnostic>());
      expect(
        diagnostic.message,
        contains(
          entry.key == 'wildcard'
              ? 'must declare public ASCII names'
              : 'Covariant service parameters are not supported',
        ),
      );
      expect(diagnostic.path, fixture.source.absolute.path);
      expect(diagnostic.line, 11);
      expect(diagnostic.column, 23);
      expect(generated.existsSync(), isFalse);
    });
  }

  test('rejects raw List contract types', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'List value);'),
      'Dynamic or unconstrained contract types are not supported.',
    );
  });

  test('rejects raw Map contract types', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Map value);'),
      'Only Map<String, Object?> is supported',
    );
  });

  test('rejects maps with non-string keys', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Map<int, Object?> value);'),
      'Only Map<String, Object?> is supported',
    );
  });

  test('rejects unsupported map value shapes', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Map<String, String> value);'),
      'Only Map<String, Object?> is supported',
    );
  });

  test('rejects ambiguous multiple constructors', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        'const FixtureValue({required this.value});',
        'const FixtureValue({required this.value});\n  const FixtureValue.named({required this.value});',
      ),
      'exactly one unnamed constructor',
    );
  });

  test('rejects positional value constructor parameters', () async {
    await expectDiagnostic(
      minimalContract(),
      'Value constructor parameters must be required and named.',
    );
  });

  test('rejects value field and constructor parameter type mismatch', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        'const FixtureValue({required this.value});',
        'const FixtureValue({required Object value}) : value = value as String;',
      ),
      'must have exactly the same type',
    );
  });

  for (final entry in <String, String>{
    'scalar': 'Object value',
    'nullability': 'String? value',
  }.entries) {
    test('rejects ${entry.key} value parameter type mismatch', () async {
      await expectDiagnostic(
        minimalContract(
          namedValue: true,
        ).replaceFirst('required this.value', 'required ${entry.value}'),
        'must have exactly the same type',
      );
    });
  }

  test('rejects list element value parameter type mismatch', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceAll('String value', 'List<String> value')
          .replaceFirst('required this.value', 'required List<Object> value'),
      'must have exactly the same type',
    );
  });

  test('rejects annotated value parameter type mismatch', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst(
            "@AdeleValue('fixture.value')",
            "@AdeleValue('fixture.child')\nfinal class Child { const Child({required this.value}); final String value; }\n@AdeleValue('fixture.otherChild')\nfinal class OtherChild { const OtherChild({required this.value}); final String value; }\n@AdeleValue('fixture.value')",
          )
          .replaceAll('String value', 'Child value')
          .replaceFirst('required this.value', 'required OtherChild value'),
      'must have exactly the same type',
    );
  });

  test('rejects non-field-formal value reconstruction', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        'const FixtureValue({required this.value});',
        'const FixtureValue({required String value}) : value = value;',
      ),
      'required named field-formal parameters',
    );
  });
}
