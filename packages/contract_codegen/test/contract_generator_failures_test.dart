import 'support/contract_generator_support.dart';

void main() {
  test(
    'ordinary collision-prone identifiers and shapes compile and execute',
    () async {
      await runGeneratedFixture(adversarialContract(), adversarialTests());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated enum dispatcher rejects unknown enum values',
    () async {
      await runGeneratedFixture(runtimeContract(), runtimeTests('enum'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('rejects an empty service', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        "  @AdeleMethod('ping')\n  Future<String> ping(String value);",
        '',
      ),
      'must declare at least one method',
    );
  });

  test('rejects multiple services in the Phase II transport', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        "@AdeleFailure('fixture.failure')",
        "@AdeleService('fixture.second')\nabstract interface class SecondService {\n  @AdeleMethod('ping') Future<String> ping(String value);\n}\n@AdeleFailure('fixture.failure')",
      ),
      'exactly one @AdeleService',
    );
  });

  test('rejects optional code or message reconstruction state', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('required this.message', 'this.message = \'fallback\''),
      'required named code and message',
    );
  });

  test('accepts canonical failure with optional details', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true).replaceFirst(
        'required this.details',
        'this.details = const <String, Object?>{}',
      ),
    );
    expect(
      (await const ContractGenerator().generate(fixture.source)).contents,
      contains('FixtureFailure('),
    );
  });

  test(
    'rejects a failure constructor that does not initialize its field',
    () async {
      await expectDiagnostic(
        minimalContract(
          namedValue: true,
        ).replaceFirst('required this.message', 'required String message'),
        'named details field-formal parameters',
      );
    },
  );

  test('rejects extra failure constructor state', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
        'required this.details});',
        'required this.details, int ignored = 0});',
      ),
      'only initialize declared instance fields',
    );
  });
}
