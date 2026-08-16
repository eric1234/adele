import 'package:path/path.dart' as p;

import 'support/contract_generator_support.dart';

void main() {
  final Directory repository = repositoryRoot();
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

  test('models mixed unary and server-streaming methods explicitly', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true).replaceFirst(
        'Future<String> ping(String value);',
        '''Future<String> ping(String value);
  @AdeleMethod('events')
  Stream<FixtureValue> events(String value);''',
      ),
    );
    final generated = await const ContractGenerator().generate(fixture.source);
    expect(generated.contents, contains('Stream<FixtureValue> events'));
    expect(generated.contents, contains('AdeleStreamChannel'));
    expect(generated.contents, contains("'fixture.service.events'"));
  });

  for (final entry in <String, String>{
    'Stream<void>': 'Stream<void>',
    'Future<Stream<String>>': 'Stream contract types',
    'Stream<String>?': 'Future<T> or Stream<T>',
  }.entries) {
    test('rejects ${entry.key}', () async {
      await expectDiagnostic(
        minimalContract(
          namedValue: true,
        ).replaceFirst('Future<String>', entry.key),
        entry.value,
      );
    });
  }

  test('rejects raw Stream returns', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('Future<String>', 'Stream'),
      'Dynamic or unconstrained contract types',
    );
  });

  test('rejects outer Stream aliases', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst(
            "part 'fixture.g.dart';",
            "part 'fixture.g.dart';\ntypedef StreamAlias<T> = Stream<T>;",
          )
          .replaceFirst('Future<String>', 'StreamAlias<String>'),
      'Future<T> or Stream<T>',
    );
  });

  test('rejects Stream lookalike returns', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true)
          .replaceFirst(
            "part 'fixture.g.dart';",
            "part 'fixture.g.dart';\nclass Stream<T> {}",
          )
          .replaceFirst('Future<String>', 'Stream<String>'),
      'Future<T> or Stream<T>',
    );
  });

  test('rejects Stream service parameters', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('String value);', 'Stream<String> value);'),
      'Stream contract types are not supported',
    );
  });

  test('rejects multiple annotated services in one contract library', () async {
    await expectDiagnostic(
      minimalContract(namedValue: true).replaceFirst(
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
    expect(output.contents, contains(RegExp(r'_adeleError\d+\.code')));
    expect(output.contents, contains(RegExp(r'_adeleError\d+\.details')));
  });

  test('emits stable service method value and failure IDs', () async {
    final output = await const ContractGenerator().generate(demo);
    expect(output.contents, contains("'workspaceDemo.listDirectory'"));
    expect(output.contents, contains("'workspaceDemo.directoryListing'"));
    expect(output.contents, contains("'workspaceDemo.failure'"));
  });

  test('rejects duplicate stable IDs', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true).replaceFirst(
        "@AdeleFailure('fixture.failure')",
        "@AdeleFailure('fixture.service')",
      ),
    );
    expect(
      (await readDiagnostic(fixture.source)).message,
      contains('Duplicate stable ID'),
    );
  });

  test(
    'reports the analyzer diagnostic for a missing annotation argument',
    () async {
      final fixture = await createFixture(
        minimalContract(
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
    final fixture = await createFixture(
      minimalContract(
        namedValue: true,
      ).replaceFirst("@AdeleService('fixture.service')", "@AdeleService('')"),
    );
    expect(
      (await readDiagnostic(fixture.source)).message,
      contains('must declare a stable ID'),
    );
  });

  test('rejects stable IDs outside the conservative grammar', () async {
    await expectDiagnostic(
      minimalContract(
        namedValue: true,
      ).replaceFirst('fixture.service', 'fixture/service'),
      'using ASCII letters or digits',
    );
  });

  for (final annotation in <String>[
    'AdeleService',
    'AdeleValue',
    'AdeleFailure',
    'AdeleMethod',
    'AdeleField',
  ]) {
    test('rejects repeated @$annotation annotations', () async {
      final source = switch (annotation) {
        'AdeleService' => minimalContract(namedValue: true).replaceFirst(
          "@AdeleService('fixture.service')",
          "@AdeleService('fixture.duplicate')\n@AdeleService('fixture.service')",
        ),
        'AdeleValue' => minimalContract(namedValue: true).replaceFirst(
          "@AdeleValue('fixture.value')",
          "@AdeleValue('fixture.duplicate')\n@AdeleValue('fixture.value')",
        ),
        'AdeleFailure' => minimalContract(namedValue: true).replaceFirst(
          "@AdeleFailure('fixture.failure')",
          "@AdeleFailure('fixture.duplicate')\n@AdeleFailure('fixture.failure')",
        ),
        'AdeleMethod' => minimalContract(namedValue: true).replaceFirst(
          "@AdeleMethod('ping')",
          "@AdeleMethod('duplicate')\n  @AdeleMethod('ping')",
        ),
        _ => minimalContract(namedValue: true).replaceFirst(
          'final String value;',
          "@AdeleField('duplicate')\n  @AdeleField('value')\n  final String value;",
        ),
      };
      await expectDiagnostic(source, 'Repeated @$annotation');
    });
  }

  for (final roles in <String>[
    "@AdeleValue('fixture.value')\n@AdeleService('fixture.service')",
    "@AdeleService('fixture.service')\n@AdeleValue('fixture.value')",
  ]) {
    test('rejects mixed class roles independent of annotation order', () async {
      await expectDiagnostic(
        minimalContract(
          namedValue: true,
        ).replaceFirst("@AdeleValue('fixture.value')", roles),
        'mixed roles',
      );
    });
  }

  test('output is deterministic across repeated generation', () async {
    final generator = const ContractGenerator();
    expect(
      (await generator.generate(demo)).contents,
      (await generator.generate(demo)).contents,
    );
  });

  test('escapes every source-derived Dart string literal', () async {
    final fixture = await createFixture(
      minimalContract(namedValue: true),
      basename: r"fixture'$name.dart".replaceAll(r'$name', r'$'),
    );
    await fixture.source.writeAsString(
      minimalContract(namedValue: true).replaceFirst(
        'fixture.g.dart',
        r"fixture\'$name.g.dart".replaceAll(r'$name', r'\$'),
      ),
    );
    final output = await const ContractGenerator().generate(fixture.source);
    expect(output.contents, contains(r"part of 'fixture\'\$.dart';"));
  });

  test('output is independent of declaration discovery ordering', () async {
    final first = await createFixture(orderedContract(valuesFirst: true));
    final second = await createFixture(orderedContract(valuesFirst: false));
    final generator = const ContractGenerator();
    final a = (await generator.generate(first.source)).contents;
    final b = (await generator.generate(second.source)).contents;
    expect(
      a.replaceFirst("part of 'fixture.dart';", ''),
      b.replaceFirst("part of 'fixture.dart';", ''),
    );
  });

  test(
    'generated Uri client and dispatcher compile and execute',
    () async {
      await runGeneratedFixture(runtimeContract(), runtimeTests('uri'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
