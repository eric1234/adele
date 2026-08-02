import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final Directory repository = _repository();
  final File demo = File(
    p.join(
      repository.path,
      'plugins/workspace_demo/packages/contract/lib/workspace_demo_contract.dart',
    ),
  );

  test('parses an annotated service declaration', () async {
    final output = await const ContractGenerator().generate(demo);
    expect(output.contents, contains('WorkspaceDemoServiceClient'));
    expect(output.contents, contains('WorkspaceDemoServiceDispatcher'));
  });

  test('rejects multiple annotated services in one contract library', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        "@AdeleFailure('fixture.failure')",
        '''
@AdeleService('fixture.other')
abstract interface class OtherService {
  @AdeleMethod('pong')
  Future<String> pong(String value);
}
@AdeleFailure('fixture.failure')''',
      ),
      'exactly one @AdeleService',
    );
  });

  test('parses annotated value declarations', () async {
    final output = await const ContractGenerator().generate(demo);
    expect(output.contents, contains('_decodeDirectoryListing'));
    expect(output.contents, contains('_decodeDirectoryEntry'));
  });

  test('parses an annotated structured failure declaration', () async {
    final output = await const ContractGenerator().generate(demo);
    expect(output.contents, contains('case workspaceDemoFailureTypeId'));
    expect(output.contents, contains('error.code'));
    expect(output.contents, contains('error.details'));
  });

  test('emits stable service method value and failure IDs', () async {
    final output = await const ContractGenerator().generate(demo);
    expect(output.contents, contains("'workspaceDemo.listDirectory'"));
    expect(output.contents, contains("'workspaceDemo.directoryListing'"));
    expect(output.contents, contains("'workspaceDemo.failure'"));
  });

  test('rejects duplicate stable IDs', () async {
    final fixture = await _fixture(
      _minimalContract(namedValue: true).replaceFirst(
        "@AdeleFailure('fixture.failure')",
        "@AdeleFailure('fixture.service')",
      ),
    );
    expect(
      (await _diagnostic(fixture.source)).message,
      contains('Duplicate stable ID'),
    );
  });

  test(
    'reports the analyzer diagnostic for a missing annotation argument',
    () async {
      final fixture = await _fixture(
        _minimalContract(
          namedValue: true,
        ).replaceFirst("@AdeleService('fixture.service')", '@AdeleService()'),
      );
      final AnalysisContextCollection collection = AnalysisContextCollection(
        includedPaths: <String>[fixture.source.absolute.path],
      );
      final result = await collection
          .contextFor(fixture.source.absolute.path)
          .currentSession
          .getResolvedUnit(fixture.source.absolute.path);
      expect(result, isA<ResolvedUnitResult>());
      expect(
        (result as ResolvedUnitResult).diagnostics.map(
          (error) => error.message,
        ),
        anyElement(contains('positional argument')),
      );
    },
  );

  test('rejects an empty annotation identifier', () async {
    final fixture = await _fixture(
      _minimalContract(
        namedValue: true,
      ).replaceFirst("@AdeleService('fixture.service')", "@AdeleService('')"),
    );
    expect(
      (await _diagnostic(fixture.source)).message,
      contains('must declare a stable ID'),
    );
  });

  test('rejects stable IDs outside the conservative grammar', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('fixture.service', 'fixture/service'),
      'using ASCII letters or digits',
    );
  });

  test('output is deterministic across repeated generation', () async {
    final generator = const ContractGenerator();
    expect(
      (await generator.generate(demo)).contents,
      (await generator.generate(demo)).contents,
    );
  });

  test('output is independent of declaration discovery ordering', () async {
    final first = await _fixture(_orderedContract(valuesFirst: true));
    final second = await _fixture(_orderedContract(valuesFirst: false));
    final generator = const ContractGenerator();
    final a = (await generator.generate(first.source)).contents;
    final b = (await generator.generate(second.source)).contents;
    expect(
      a.replaceFirst("part of 'fixture.dart';", ''),
      b.replaceFirst("part of 'fixture.dart';", ''),
    );
  });

  test('supports String bool int and double primitives', () async {
    final output = await _generate(_allTypesContract());
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
    final output = await _generate(_allTypesContract());
    expect(output, contains('switch (value.note)'));
  });

  test('supports immutable decoded lists', () async {
    final output = await _generate(_allTypesContract());
    expect(output, contains(RegExp(r'List<[^>]+>\.unmodifiable')));
  });

  test('supports enums', () async {
    final output = await _generate(_allTypesContract());
    expect(output, contains('_decodeMood'));
  });

  test('supports nested values', () async {
    final output = await _generate(_allTypesContract());
    expect(output, contains('_decodeChild'));
  });

  test('emits named value invocation in deterministic wire order', () async {
    final output = await _generate(_wireOrderingContract());
    expect(output, contains(RegExp(r"'a':\s*value\.second")));
    expect(output, contains(RegExp(r"'z':\s*value\.first")));
    expect(output.indexOf("'a':"), lessThan(output.indexOf("'z':")));
    final constructor = output.indexOf('() => OrderedValue(');
    expect(constructor, isNonNegative);
    expect(
      output.indexOf('second:', constructor),
      lessThan(output.indexOf('first:', constructor)),
    );
  });

  test(
    'generated Uri client and dispatcher compile and execute',
    () async {
      await _runGeneratedFixture(_runtimeContract(), _runtimeTests('uri'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated ResourceRef codecs reject malformed URI paths',
    () async {
      await _runGeneratedFixture(
        _resourceRuntimeContract(),
        _resourceRuntimeTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('supports ResourceRef', () async {
    final output = await _generate(_allTypesContract());
    expect(
      output,
      allOf(contains('_contractResourceRef'), contains('_decodeResourceRef')),
    );
  });

  test(
    'generated Map<String, Object?> recursively validates JSON',
    () async {
      await _runGeneratedFixture(_runtimeContract(), _runtimeTests('json'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated double codecs reject non-finite values',
    () async {
      await _runGeneratedFixture(_runtimeContract(), _runtimeTests('double'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated dispatcher stages classification and containment',
    () async {
      await _runGeneratedFixture(
        _runtimeContract(),
        _runtimeTests('dispatcher'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated dispatcher contains invalid backend output',
    () async {
      await _runGeneratedFixture(
        _runtimeContract(),
        _runtimeTests('invalidResult'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated dispatcher contains invalid failure details',
    () async {
      await _runGeneratedFixture(
        _runtimeContract(),
        _runtimeTests('invalidDetails'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated dispatcher contains service protocol exceptions',
    () async {
      await _runGeneratedFixture(
        _runtimeContract(),
        _runtimeTests('serviceProtocol'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated value construction failures stay within protocol boundaries',
    () async {
      await _runGeneratedFixture(_valueRuntimeContract(), _valueRuntimeTests());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'declared failure construction failures stay opaque and recoverable',
    () async {
      await _runGeneratedFixture(
        _failureRuntimeContract(),
        _failureRuntimeTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'relative URI backend result shapes are contained and recoverable',
    () async {
      await _runGeneratedFixture(
        _relativeUriResultContract(),
        _relativeUriResultTests(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated enum dispatcher rejects unknown enum values',
    () async {
      await _runGeneratedFixture(_runtimeContract(), _runtimeTests('enum'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated Future<void> client requires a null response',
    () async {
      await _runGeneratedFixture(
        _runtimeContract(),
        _runtimeTests('voidClient'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'generated Future<void> dispatcher returns a null payload',
    () async {
      await _runGeneratedFixture(
        _runtimeContract(),
        _runtimeTests('voidDispatcher'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('rejects mutable value fields', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('final String value;', 'String value;'),
      'Value fields must be non-late and final.',
    );
  });

  test('rejects late final value fields', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('final String value;', 'late final String value;'),
      'non-late and final',
    );
  });

  test('rejects unsupported synchronous returns', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('Future<String> ping', 'String ping'),
      'Service methods must return Future<T>.',
    );
  });

  test('rejects Stream returns', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('Future<String> ping', 'Stream<String> ping'),
      'Service methods must return Future<T>.',
    );
  });

  test('rejects generic service methods', () async {
    await _expectDiagnostic(
      _minimalContract(
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
      await _expectDiagnostic(
        _minimalContract(namedValue: true).replaceFirst(original, entry.value),
        'Generic annotated ${entry.key} declarations are not supported.',
      );
    });
  }

  test('rejects dynamic contract types', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'dynamic value);'),
      'Dynamic or unconstrained contract types are not supported.',
    );
  });

  test('rejects raw List contract types', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'List value);'),
      'Dynamic or unconstrained contract types are not supported.',
    );
  });

  test('rejects raw Map contract types', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Map value);'),
      'Only Map<String, Object?> is supported',
    );
  });

  test('rejects maps with non-string keys', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Map<int, Object?> value);'),
      'Only Map<String, Object?> is supported',
    );
  });

  test('rejects unsupported map value shapes', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Map<String, String> value);'),
      'Only Map<String, Object?> is supported',
    );
  });

  test('rejects ambiguous multiple constructors', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        'const FixtureValue({required this.value});',
        'const FixtureValue({required this.value});\n  const FixtureValue.named({required this.value});',
      ),
      'exactly one unnamed constructor',
    );
  });

  test('rejects positional value constructor parameters', () async {
    await _expectDiagnostic(
      _minimalContract(),
      'Value constructor parameters must be required and named.',
    );
  });

  test('rejects value field and constructor parameter type mismatch', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
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
      await _expectDiagnostic(
        _minimalContract(
          namedValue: true,
        ).replaceFirst('required this.value', 'required ${entry.value}'),
        'must have exactly the same type',
      );
    });
  }

  test('rejects list element value parameter type mismatch', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true)
          .replaceAll('String value', 'List<String> value')
          .replaceFirst('required this.value', 'required List<Object> value'),
      'must have exactly the same type',
    );
  });

  test('rejects annotated value parameter type mismatch', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true)
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
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        'const FixtureValue({required this.value});',
        'const FixtureValue({required String value}) : value = value;',
      ),
      'required named field-formal parameters',
    );
  });

  test('rejects nullable recursive annotated value schemas', () async {
    await _expectDiagnostic(_recursiveValueContract('Node?'), 'schema cycles');
  });

  test('rejects list recursive annotated value schemas', () async {
    await _expectDiagnostic(
      _recursiveValueContract('List<Node>'),
      'schema cycles',
    );
  });

  test('rejects mutual recursive annotated value schemas', () async {
    await _expectDiagnostic(
      _recursiveValueContract('Other?').replaceFirst(
        "@AdeleFailure('fixture.failure')",
        "@AdeleValue('fixture.other')\nfinal class Other { const Other({required this.next}); final Node? next; }\n@AdeleFailure('fixture.failure')",
      ),
      'schema cycles',
    );
  });

  test('rejects imported annotated value types', () async {
    final fixture = await _fixtureWithSupport(
      _minimalContract(namedValue: true).replaceFirst(
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
      (await _diagnostic(fixture.source)).message,
      contains('source library, not imported'),
    );
  });

  test('rejects imported enum types', () async {
    final fixture = await _fixtureWithSupport(
      _minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<ImportedMood> ping(ImportedMood value);',
      ),
      'enum ImportedMood { calm }',
    );
    expect(
      (await _diagnostic(fixture.source)).message,
      contains('declared in the source library'),
    );
  });

  test('rejects value inheritance', () async {
    final source = _minimalContract(namedValue: true)
        .replaceFirst(
          'final class FixtureValue {',
          'class Base {}\n@AdeleValue(\'fixture.value\')\nfinal class Replacement extends Base {',
        )
        .replaceFirst("@AdeleValue('fixture.value')\n", '')
        .replaceAll('FixtureValue', 'Replacement');
    await _expectDiagnostic(source, 'final class without a superclass');
  });

  test('rejects optional service parameters', () async {
    await _expectDiagnostic(
      _minimalContract(
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
      await _expectDiagnostic(
        _minimalContract(namedValue: true).replaceFirst(
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
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
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
      await _expectDiagnostic(
        _minimalContract(namedValue: true).replaceFirst(
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
      await _expectDiagnostic(
        _minimalContract(namedValue: true).replaceFirst(
          "@AdeleValue('fixture.value')",
          "$declaration\n@AdeleValue('fixture.value')",
        ),
        'Generated symbol collision for $symbol',
      );
    });
  }

  test('rejects conditional ResourceRef helper collisions', () async {
    await _expectDiagnostic(
      _allTypesContract().replaceFirst(
        'enum Mood',
        'Object? _decodeResourceRef;\nenum Mood',
      ),
      'Generated symbol collision for _decodeResourceRef',
    );
  });

  test('rejects enum decoder collisions with value decoders', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        "@AdeleValue('fixture.value')",
        "enum FixtureValue { value }\n@AdeleValue('fixture.value')",
      ),
      'Generated symbol collision for _decodeFixtureValue',
    );
  });

  test('rejects method names that map to one generated symbol', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        "  @AdeleMethod('ping')",
        "  @AdeleMethod('upperPing')\n  Future<String> Ping(String value);\n  @AdeleMethod('ping')",
      ),
      'Generated symbol collision',
    );
  });

  test('rejects an empty service', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        "  @AdeleMethod('ping')\n  Future<String> ping(String value);",
        '',
      ),
      'must declare at least one method',
    );
  });

  test('rejects multiple services in the Phase II transport', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        "@AdeleFailure('fixture.failure')",
        "@AdeleService('fixture.second')\nabstract interface class SecondService {\n  @AdeleMethod('ping') Future<String> ping(String value);\n}\n@AdeleFailure('fixture.failure')",
      ),
      'exactly one @AdeleService',
    );
  });

  test('rejects optional code or message reconstruction state', () async {
    await _expectDiagnostic(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('required this.message', 'this.message = \'fallback\''),
      'required named code and message',
    );
  });

  test('accepts canonical failure with optional details', () async {
    final fixture = await _fixture(
      _minimalContract(namedValue: true).replaceFirst(
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
      await _expectDiagnostic(
        _minimalContract(
          namedValue: true,
        ).replaceFirst('required this.message', 'required String message'),
        'named details field-formal parameters',
      );
    },
  );

  test('rejects extra failure constructor state', () async {
    await _expectDiagnostic(
      _minimalContract(namedValue: true).replaceFirst(
        'required this.details});',
        'required this.details, int ignored = 0});',
      ),
      'only initialize declared instance fields',
    );
  });

  test('diagnostics report actionable exact source locations', () async {
    final fixture = await _fixture(
      _minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        'Future<DateTime> ping(String value);',
      ),
    );
    final diagnostic = await _diagnostic(fixture.source);
    expect(diagnostic.path, fixture.source.absolute.path);
    expect(diagnostic.line, 11);
    expect(diagnostic.column, 20);
    expect(
      diagnostic.toString(),
      '${fixture.source.absolute.path}:11:20: Unsupported contract type DateTime.',
    );
  });

  test('apply check is non-mutating and write creates final output', () async {
    final fixture = await _fixture(_minimalContract(namedValue: true));
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
      await _expectDiagnostic(
        _minimalContract(
          namedValue: true,
        ).replaceFirst("part 'fixture.g.dart';", "part '$part';"),
        'Generated part URI must be exactly fixture.g.dart',
      );
    });
  }

  test('derives a contained sibling generated destination', () async {
    final fixture = await _fixture(
      _minimalContract(namedValue: true),
      basename: 'some_contract.dart',
    );
    await fixture.source.writeAsString(
      _minimalContract(
        namedValue: true,
      ).replaceFirst('fixture.g.dart', 'some_contract.g.dart'),
    );
    final generated = await const ContractGenerator().generate(fixture.source);
    expect(p.basename(generated.path), 'some_contract.g.dart');
    expect(p.dirname(generated.path), fixture.directory.path);
  });
}

Future<String> _generate(String source) async {
  final fixture = await _fixture(source);
  return (await const ContractGenerator().generate(fixture.source)).contents;
}

Future<void> _expectDiagnostic(String source, String message) async {
  final fixture = await _fixture(source);
  expect((await _diagnostic(fixture.source)).message, contains(message));
}

String _minimalContract({bool namedValue = false}) =>
    '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.value')
final class FixtureValue {
  const FixtureValue(${namedValue ? '{required this.value}' : 'this.value'});
  final String value;
}
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('ping')
  Future<String> ping(String value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''';

String _orderedContract({required bool valuesFirst}) {
  const value = '''
@AdeleValue('fixture.a')
final class AValue { const AValue({required this.text}); final String text; }
@AdeleValue('fixture.z')
final class ZValue { const ZValue({required this.text}); final String text; }
''';
  const service = '''
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('z') Future<ZValue> z(ZValue value);
  @AdeleMethod('a') Future<AValue> a(AValue value);
}
''';
  return '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
${valuesFirst ? value : service}
${valuesFirst ? service : value}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
 const FixtureFailure({required this.code, required this.message, required this.details});
 final String code; final String message; final Map<String, Object?> details;
}
''';
}

String _allTypesContract() => '''
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
part 'fixture.g.dart';
enum Mood { calm, busy }
@AdeleValue('fixture.child')
final class Child { const Child({required this.name}); final String name; }
@AdeleValue('fixture.value')
final class FixtureValue {
 const FixtureValue({required this.text, required this.flag, required this.count, required this.ratio, required this.note, required this.items, required this.mood, required this.child, required this.uri, required this.resource, required this.json});
 final String text; final bool flag; final int count; final double ratio;
 final String? note; final List<String?> items; final Mood mood; final Child child;
 final Uri uri; final ResourceRef resource; final Map<String, Object?> json;
}
@AdeleService('fixture.service')
abstract interface class FixtureService {
 @AdeleMethod('roundTrip') Future<FixtureValue> roundTrip(FixtureValue value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
 const FixtureFailure({required this.code, required this.message, required this.details});
 final String code; final String message; final Map<String, Object?> details;
}
''';

String _runtimeContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';

enum Mood { calm, busy }

@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('uri')
  Future<Uri> uri(Uri value);

  @AdeleMethod('json')
  Future<Map<String, Object?>> json(Map<String, Object?> value);

  @AdeleMethod('ratio')
  Future<double> ratio(double value);

  @AdeleMethod('mood')
  Future<Mood> mood(Mood value);

  @AdeleMethod('notify')
  Future<void> notify(String value);
}

@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''';

String _runtimeTests(String name) =>
    '''
// ignore_for_file: inference_failure_on_collection_literal

import 'package:adele_contract/adele_contract.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('$name', () async {
    switch ('$name') {
      case 'uri':
        final channel = _Channel('https://example.test/a?b=c');
        final result = await FixtureServiceClient(channel).uri(Uri.parse('https://input.test/path'));
        expect(result, Uri.parse('https://example.test/a?b=c'));
        expect(channel.payload, <String, Object?>{'value': 'https://input.test/path'});
        final response = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.uri', <String, Object?>{'value': 'https://dispatch.test/path'}));
        expect(response['payload'], 'https://dispatch.test/path');
        await expectLater(FixtureServiceClient(_Channel('relative/path')).uri(Uri.parse('https://input.test/path')), throwsA(isA<AdeleProtocolException>()));
        final relative = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.uri', {'value': 'relative/path'}));
        expect((relative['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
        final malformed = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.uri', {'value': 'http://[::1'}));
        expect((malformed['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
        final channelFailure = _ThrowingChannel();
        expect(() => FixtureServiceClient(channelFailure).uri(Uri.parse('relative/path')), throwsA(isA<AdeleProtocolException>()));
        expect(channelFailure.called, isFalse);
      case 'json':
        final input = <String, Object?>{'nested': <Object?>[true, null, <String, Object?>{'count': 2}]};
        final channel = _Channel(input);
        expect(await FixtureServiceClient(channel).json(input), input);
        final response = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.json', {'value': input}));
        expect(response['payload'], input);
        await expectLater(FixtureServiceClient(_Channel(<String, Object?>{'bad': DateTime(2020)})).json(const {}), throwsA(isA<AdeleProtocolException>()));
        await expectLater(FixtureServiceClient(_Channel(<String, Object?>{'bad': <Object?, Object?>{1: 'value'}})).json(const {}), throwsA(isA<AdeleProtocolException>()));
        final invalidObject = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.json', {'value': <String, Object?>{'bad': DateTime(2020)}}));
        expect((invalidObject['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
        final invalidKey = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.json', {'value': <String, Object?>{'bad': <Object?, Object?>{1: 'value'}}}));
        expect((invalidKey['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
        await expectLater(FixtureServiceClient(_Channel(<String, Object?>{'bad': double.nan})).json(const {}), throwsA(isA<AdeleProtocolException>()));
        expect(() => FixtureServiceClient(_Channel(const <String, Object?>{})).json(<String, Object?>{'bad': double.infinity}), throwsA(isA<AdeleProtocolException>()));
        final cyclicMap = <String, Object?>{};
        cyclicMap['self'] = cyclicMap;
        expect(() => FixtureServiceClient(_Channel(const <String, Object?>{})).json(cyclicMap), throwsA(isA<AdeleProtocolException>().having((error) => error.message, 'message', contains('Cyclic JSON'))));
        final cyclicList = <Object?>[];
        cyclicList.add(cyclicList);
        expect(() => FixtureServiceClient(_Channel(const <String, Object?>{})).json({'list': cyclicList}), throwsA(isA<AdeleProtocolException>()));
        final mutualMap = <String, Object?>{};
        final mutualList = <Object?>[mutualMap];
        mutualMap['list'] = mutualList;
        final shared = <String, Object?>{'value': true};
        final acyclic = <String, Object?>{'first': shared, 'second': shared};
        final acyclicChannel = _Channel(acyclic);
        expect(await FixtureServiceClient(acyclicChannel).json(acyclic), acyclic);
        Object? depth64 = 'leaf';
        for (var index = 0; index < 63; index++) depth64 = <Object?>[depth64];
        await FixtureServiceClient(_Channel({'value': depth64})).json({'value': depth64});
        Object? depth65 = depth64;
        depth65 = <Object?>[depth65];
        expect(() => FixtureServiceClient(_Channel(const <String, Object?>{})).json({'value': depth65}), throwsA(isA<AdeleProtocolException>().having((error) => error.message, 'message', contains('maximum depth 64'))));
        final dispatcher = FixtureServiceDispatcher(_Service());
        for (final invalidValue in <Map<String, Object?>>[
          cyclicMap,
          {'list': cyclicList},
          mutualMap,
          {'value': depth65},
        ]) {
          final invalid = await dispatcher.dispatch(_request('fixture.service.json', {'value': invalidValue}));
          _expectOpaqueFailure(invalid, 'invalid_request');
        }
        final continued = await dispatcher.dispatch(_request('fixture.service.json', {'value': const {'continued': true}}));
        expect(continued['ok'], isTrue);
      case 'double':
        expect(await FixtureServiceClient(_Channel(1.5)).ratio(2.5), 1.5);
        await expectLater(FixtureServiceClient(_Channel(double.nan)).ratio(1), throwsA(isA<AdeleProtocolException>()));
        expect(() => FixtureServiceClient(_Channel(1.0)).ratio(double.infinity), throwsA(isA<AdeleProtocolException>()));
        final invalid = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.ratio', {'value': double.negativeInfinity}));
        expect((invalid['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
      case 'dispatcher':
        final missingId = await FixtureServiceDispatcher(_Service()).dispatch(<String, Object?>{'kind': 'request', 'method': 'fixture.service.uri', 'payload': const <String, Object?>{}});
        expect(missingId.containsKey('requestId'), isFalse);
        expect((missingId['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
        final unknownBadPayload = await FixtureServiceDispatcher(_Service()).dispatch(_request('missing', DateTime(2020)));
        expect((unknownBadPayload['error'] as Map<Object?, Object?>)['code'], 'unknown_method');
        final thrown = await FixtureServiceDispatcher(_ThrowingService()).dispatch(_request('fixture.service.uri', {'value': 'https://example.test'}));
        expect((thrown['error'] as Map<Object?, Object?>)['code'], 'internal_error');
        expect((thrown['error'] as Map<Object?, Object?>)['message'], isNot(contains('secret')));
      case 'invalidResult':
        final dispatcher = FixtureServiceDispatcher(_InvalidResultService());
        for (final mode in ['object', 'cycleMap', 'cycleList', 'mutual', 'deep']) {
          final invalid = await dispatcher.dispatch(_request('fixture.service.json', {'value': {'mode': mode}}));
          _expectOpaqueFailure(invalid, 'backend_contract_violation');
        }
        final continued = await dispatcher.dispatch(_request('fixture.service.uri', {'value': 'https://continued.test/path'}));
        expect(continued['ok'], isTrue);
        expect(continued['payload'], 'https://continued.test/path');
      case 'invalidDetails':
        final dispatcher = FixtureServiceDispatcher(_InvalidDetailsService());
        for (final mode in ['object', 'cycleMap', 'cycleList', 'mutual', 'deep']) {
          final invalid = await dispatcher.dispatch(_request('fixture.service.uri', {'value': 'https://example.test/\$mode'}));
          _expectOpaqueFailure(invalid, 'backend_contract_violation');
        }
        final continued = await dispatcher.dispatch(_request('fixture.service.json', {'value': const {'continued': true}}));
        expect(continued['ok'], isTrue);
        expect(continued['payload'], {'continued': true});
      case 'serviceProtocol':
        final dispatcher = FixtureServiceDispatcher(_ProtocolService());
        final invalid = await dispatcher.dispatch(_request('fixture.service.uri', {'value': 'https://example.test'}));
        _expectOpaqueFailure(invalid, 'internal_error');
        expect((invalid['error'] as Map<Object?, Object?>)['message'], 'The backend request failed unexpectedly.');
        final continued = await dispatcher.dispatch(_request('fixture.service.json', {'value': const {'continued': true}}));
        expect(continued['ok'], isTrue);
      case 'enum':
        final response = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.mood', {'value': 'missing'}));
        expect(response['ok'], isFalse);
        expect((response['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
      case 'voidClient':
        await FixtureServiceClient(_Channel(null)).notify('ok');
        expect(() => FixtureServiceClient(_Channel('not null')).notify('bad'), throwsA(isA<AdeleProtocolException>()));
      case 'voidDispatcher':
        final response = await FixtureServiceDispatcher(_Service()).dispatch(_request('fixture.service.notify', {'value': 'ok'}));
        expect(response['ok'], isTrue);
        expect(response.containsKey('payload'), isTrue);
        expect(response['payload'], isNull);
    }
  });
}

void _expectOpaqueFailure(Map<String, Object?> response, String code) {
  expect(response['ok'], isFalse);
  final error = response['error'] as Map<Object?, Object?>;
  expect(error['code'], code);
  expect(error.containsKey('declaredFailureType'), isFalse);
  expect(error['details'], isEmpty);
}

Map<Object?, Object?> _request(String method, Object? payload) => Map<Object?, Object?>.from({
  'kind': 'request',
  'requestId': 1,
  'method': method,
  'payload': payload,
});

final class _Channel implements AdeleRequestChannel {
  _Channel(this.response);
  final Object? response;
  Map<String, Object?>? payload;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.payload = payload;
    return response;
  }
}

final class _ThrowingChannel implements AdeleRequestChannel {
  bool called = false;
  @override Future<Object?> request(String method, Map<String, Object?> payload) async {
    called = true;
    throw StateError('channel must not be called');
  }
}

final class _Service implements FixtureService {
  @override
  Future<Map<String, Object?>> json(Map<String, Object?> value) async => value;
  @override
  Future<Mood> mood(Mood value) async => value;
  @override
  Future<void> notify(String value) async {}
  @override
  Future<double> ratio(double value) async => value;
  @override
  Future<Uri> uri(Uri value) async => value;
}

final class _ThrowingService implements FixtureService {
  @override
  Future<Map<String, Object?>> json(Map<String, Object?> value) => throw StateError('secret');
  @override
  Future<Mood> mood(Mood value) => throw StateError('secret');
  @override
  Future<void> notify(String value) => throw StateError('secret');
  @override
  Future<double> ratio(double value) => throw StateError('secret');
  @override
  Future<Uri> uri(Uri value) => throw StateError('secret');
}

final class _InvalidResultService extends _Service {
  @override
  Future<Map<String, Object?>> json(Map<String, Object?> value) async {
    switch (value['mode']) {
      case 'cycleMap':
        final result = <String, Object?>{};
        result['self'] = result;
        return result;
      case 'cycleList':
        final list = <Object?>[];
        list.add(list);
        return <String, Object?>{'list': list};
      case 'mutual':
        final result = <String, Object?>{};
        final list = <Object?>[result];
        result['list'] = list;
        return result;
      case 'deep':
        Object? result = 'leaf';
        for (var index = 0; index < 65; index++) result = <Object?>[result];
        return <String, Object?>{'deep': result};
      default:
        return <String, Object?>{'bad': DateTime(2020)};
    }
  }
}

final class _InvalidDetailsService extends _Service {
  @override
  Future<Uri> uri(Uri value) {
    final mode = value.pathSegments.last;
    final Map<String, Object?> details;
    switch (mode) {
      case 'cycleMap':
        details = <String, Object?>{};
        details['self'] = details;
      case 'cycleList':
        final list = <Object?>[];
        list.add(list);
        details = <String, Object?>{'list': list};
      case 'mutual':
        details = <String, Object?>{};
        final list = <Object?>[details];
        details['list'] = list;
      case 'deep':
        Object? value = 'leaf';
        for (var index = 0; index < 65; index++) value = <Object?>[value];
        details = <String, Object?>{'deep': value};
      default:
        details = <String, Object?>{'bad': DateTime(2020)};
    }
    throw FixtureFailure(code: 'secret', message: 'secret', details: details);
  }
}

final class _ProtocolService extends _Service {
  @override
  Future<Uri> uri(Uri value) => throw const AdeleProtocolException('secret protocol detail');
}
''';

String _resourceRuntimeContract() => '''
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
part 'fixture.g.dart';
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('resource') Future<ResourceRef> resource(ResourceRef value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

String _valueRuntimeContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';

@AdeleValue('fixture.guarded')
final class GuardedValue {
  GuardedValue({required this.name}) {
    if (name == 'throw') throw ArgumentError.value(name);
    if (name == 'protocol') throw const AdeleProtocolException('constructor detail');
  }
  final String name;
}

@AdeleValue('fixture.values')
final class GuardedValues {
  const GuardedValues({required this.direct, required this.items, required this.optional});
  final GuardedValue direct;
  final List<GuardedValue> items;
  final GuardedValue? optional;
}

@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('roundTrip')
  Future<GuardedValues> roundTrip(GuardedValues value);
}

@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

String _valueRuntimeTests() => '''
// ignore_for_file: inference_failure_on_collection_literal

import 'package:adele_contract/adele_contract.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('request and response construction are contained', () async {
    final dispatcher = FixtureServiceDispatcher(_Service());
    for (final value in [
      {'direct': {'name': 'throw'}, 'items': const [], 'optional': null},
      {'direct': {'name': 'ok'}, 'items': [{'name': 'throw'}], 'optional': null},
      {'direct': {'name': 'ok'}, 'items': const [], 'optional': {'name': 'throw'}},
    ]) {
      final response = await dispatcher.dispatch(_request(value));
      expect((response['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
    }
    final continued = await dispatcher.dispatch(_request({'direct': {'name': 'ok'}, 'items': const [], 'optional': null}));
    expect(continued['ok'], isTrue);

    await expectLater(
      FixtureServiceClient(_Channel({'direct': {'name': 'ok'}, 'items': [{'name': 'throw'}], 'optional': null}))
          .roundTrip(GuardedValues(direct: GuardedValue(name: 'ok'), items: const [], optional: null)),
      throwsA(isA<AdeleProtocolException>()),
    );
    await expectLater(
      FixtureServiceClient(_Channel({'direct': {'name': 'protocol'}, 'items': const [], 'optional': null}))
          .roundTrip(GuardedValues(direct: GuardedValue(name: 'ok'), items: const [], optional: null)),
      throwsA(isA<AdeleProtocolException>().having((error) => error.message, 'message', 'Invalid value for GuardedValue.')),
    );
  });
}

Map<Object?, Object?> _request(Object? value) => {'kind': 'request', 'requestId': 1, 'method': 'fixture.service.roundTrip', 'payload': {'value': value}};
final class _Service implements FixtureService {
  @override Future<GuardedValues> roundTrip(GuardedValues value) async => value;
}
final class _Channel implements AdeleRequestChannel {
  const _Channel(this.response); final Object? response;
  @override Future<Object?> request(String method, Map<String, Object?> payload) async => response;
}
''';

String _failureRuntimeContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';

@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('ping') Future<String> ping(String value);
}

@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  FixtureFailure({required this.code, required this.message, required this.details}) {
    if (code == 'state') throw StateError('state constructor secret');
    if (code == 'protocol') throw const AdeleProtocolException('protocol constructor secret');
  }
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''';

String _failureRuntimeTests() => '''
import 'package:adele_contract/adele_contract.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('failure constructors are opaque protocol failures', () async {
    final channel = _FailureChannel();
    final client = FixtureServiceClient(channel);
    for (final code in ['state', 'protocol']) {
      channel.code = code;
      await expectLater(
        client.ping('fail'),
        throwsA(isA<AdeleProtocolException>().having(
          (error) => error.message,
          'message',
          'Invalid value for FixtureFailure.',
        )),
      );
      channel.code = null;
      expect(await client.ping('continued'), 'continued');
    }
  });
}

final class _FailureChannel implements AdeleRequestChannel {
  String? code;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final failureCode = code;
    if (failureCode != null) {
      throw _RemoteFailure(
        code: failureCode,
        declaredFailureType: fixtureFailureTypeId,
      );
    }
    return payload['value'];
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure({required this.code, required this.declaredFailureType});
  @override final String code;
  @override final String? declaredFailureType;
  @override Map<String, Object?> get details => const <String, Object?>{};
  @override String get message => 'remote secret';
}
''';

String _relativeUriResultContract() => '''
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
part 'fixture.g.dart';

@AdeleValue('fixture.uriValue')
final class UriValue {
  const UriValue({required this.uri, required this.resource, required this.items});
  final Uri uri;
  final ResourceRef resource;
  final List<List<Uri>> items;
}

@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('uri') Future<Uri> uri(String mode);
  @AdeleMethod('resource') Future<ResourceRef> resource(String mode);
  @AdeleMethod('value') Future<UriValue> value(String mode);
  @AdeleMethod('uris') Future<List<List<Uri>>> uris(String mode);
  @AdeleMethod('ping') Future<String> ping(String value);
}

@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''';

String _relativeUriResultTests() => '''
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('relative URI result shapes are opaque backend violations', () async {
    final dispatcher = FixtureServiceDispatcher(_Service());
    for (final method in ['uri', 'resource', 'value', 'uris']) {
      final invalid = await dispatcher.dispatch(
        _request('fixture.service.\$method', argument: 'mode'),
      );
      expect(invalid['ok'], isFalse);
      final error = invalid['error'] as Map<Object?, Object?>;
      expect(error['code'], 'backend_contract_violation');
      expect(error.containsKey('declaredFailureType'), isFalse);
      expect(error['details'], isEmpty);
      expect(error['message'], 'The backend violated its generated contract.');
      final continued = await dispatcher.dispatch(
        _request('fixture.service.ping', argument: 'value', value: 'continued'),
      );
      expect(continued['ok'], isTrue);
      expect(continued['payload'], 'continued');
    }
    for (final mode in ['uri', 'resource', 'items']) {
      final invalid = await dispatcher.dispatch(
        _request('fixture.service.value', argument: 'mode', value: mode),
      );
      final error = invalid['error'] as Map<Object?, Object?>;
      expect(error['code'], 'backend_contract_violation');
      expect(error.containsKey('declaredFailureType'), isFalse);
      expect(error['details'], isEmpty);
      final continued = await dispatcher.dispatch(
        _request('fixture.service.ping', argument: 'value', value: 'continued'),
      );
      expect(continued['payload'], 'continued');
    }
  });
}

Map<Object?, Object?> _request(String method, {required String argument, String value = 'relative'}) => {
  'kind': 'request', 'requestId': 1, 'method': method, 'payload': {argument: value},
};

final class _Service implements FixtureService {
  static final relative = Uri.parse('relative/path');
  @override Future<String> ping(String value) async => value;
  @override Future<ResourceRef> resource(String mode) async => ResourceRef(uri: relative);
  @override Future<Uri> uri(String mode) async => relative;
  @override Future<List<List<Uri>>> uris(String mode) async => [[relative]];
  @override Future<UriValue> value(String mode) async {
    final absolute = Uri.parse('https://example.test/path');
    return UriValue(
      uri: mode == 'uri' || mode == 'relative' ? relative : absolute,
      resource: ResourceRef(uri: mode == 'resource' ? relative : absolute),
      items: [[mode == 'items' ? relative : absolute]],
    );
  }
}
''';

String _resourceRuntimeTests() => '''
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('resource URI paths', () async {
    final dispatcher = FixtureServiceDispatcher(_Service());
    final valid = await dispatcher.dispatch(_request({'uri': 'file:///demo/path', 'mediaType': null}));
    expect((valid['payload'] as Map<Object?, Object?>)['uri'], 'file:///demo/path');
    for (final uri in ['relative/path', 'http://[::1']) {
      final response = await dispatcher.dispatch(_request({'uri': uri, 'mediaType': null}));
      expect((response['error'] as Map<Object?, Object?>)['code'], 'invalid_request');
    }
    await expectLater(FixtureServiceClient(_Channel({'uri': 'relative/path', 'mediaType': null})).resource(ResourceRef(uri: Uri.parse('file:///input'))), throwsA(isA<AdeleProtocolException>()));
  });
}

Map<Object?, Object?> _request(Object? value) => {'kind': 'request', 'requestId': 1, 'method': 'fixture.service.resource', 'payload': {'value': value}};
final class _Service implements FixtureService {
  @override Future<ResourceRef> resource(ResourceRef value) async => value;
}
final class _Channel implements AdeleRequestChannel {
  const _Channel(this.response);
  final Object? response;
  @override Future<Object?> request(String method, Map<String, Object?> payload) async => response;
}
''';

String _wireOrderingContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.ordered')
final class OrderedValue {
  const OrderedValue({required this.first, required this.second});
  @AdeleField('z')
  final String first;
  @AdeleField('a')
  final String second;
}
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('roundTrip') Future<OrderedValue> roundTrip(OrderedValue value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

String _recursiveValueContract(String fieldType) =>
    '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.node')
final class Node {
  const Node({required this.child});
  final $fieldType child;
}
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('ping') Future<Node> ping(Node value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

Future<ContractDiagnostic> _diagnostic(File source) async {
  try {
    await const ContractGenerator().generate(source);
  } on ContractDiagnostic catch (error) {
    return error;
  }
  throw StateError('Expected contract generation to fail.');
}

Future<_Fixture> _fixture(
  String source, {
  String basename = 'fixture.dart',
}) async {
  final parent = Directory(
    p.join(Directory.current.path, '.dart_tool', 'contract_fixtures'),
  )..createSync(recursive: true);
  final directory = await parent.createTemp('fixture.');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final file = File(p.join(directory.path, basename));
  await file.writeAsString(source);
  return _Fixture(directory, file);
}

Future<_Fixture> _fixtureWithSupport(String source, String support) async {
  final fixture = await _fixture("import 'support.dart';\n$source");
  await File(
    p.join(fixture.directory.path, 'support.dart'),
  ).writeAsString(support);
  return fixture;
}

Future<void> _runGeneratedFixture(String source, String tests) async {
  final fixture = await _fixture(source);
  final repository = _repository();
  final lib = Directory(p.join(fixture.directory.path, 'lib'))..createSync();
  final sourceFile = File(p.join(lib.path, 'fixture.dart'));
  await fixture.source.rename(sourceFile.path);
  await File(p.join(fixture.directory.path, 'pubspec.yaml')).writeAsString('''
name: generated_contract_fixture
publish_to: none
environment:
  sdk: ">=3.10.9 <4.0.0"
dependencies:
  adele_contract:
    path: ${p.join(repository.path, 'packages/contract')}
  adele_plugin_api:
    path: ${p.join(repository.path, 'packages/plugin_api')}
dev_dependencies:
  test: ^1.26.3
''');
  await Directory(p.join(fixture.directory.path, 'test')).create();
  await File(
    p.join(fixture.directory.path, 'test', 'fixture_test.dart'),
  ).writeAsString(tests);
  final output = await const ContractGenerator().generate(sourceFile);
  await const ContractGenerator().write(output);
  await _runDart(fixture.directory, const ['pub', 'get']);
  await _runDart(fixture.directory, const ['analyze']);
  await _runDart(fixture.directory, const ['test']);
}

Directory _repository() {
  Directory directory = Directory.current.absolute;
  while (!File(
    p.join(directory.path, 'packages', 'contract', 'pubspec.yaml'),
  ).existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate the repository root.');
    }
    directory = parent;
  }
  return directory;
}

Future<void> _runDart(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    arguments,
    workingDirectory: directory.path,
  );
  expect(
    result.exitCode,
    0,
    reason:
        'dart ${arguments.join(' ')} failed in ${directory.path}\n${result.stdout}\n${result.stderr}',
  );
}

final class _Fixture {
  const _Fixture(this.directory, this.source);
  final Directory directory;
  final File source;
}
