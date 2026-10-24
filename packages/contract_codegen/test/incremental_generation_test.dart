@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';

import 'package:contract_codegen/src/contract_inputs.dart';
import 'package:contract_codegen/src/incremental_generation.dart';
import 'package:path/path.dart' as p;

import 'support/contract_generator_support.dart';

void main() {
  test('cold, warm, selective edit, and content restoration', () async {
    final fixture = await _Fixture.create(['first', 'second']);
    expect(await fixture.run(), (current: 0, regenerated: 2));
    final before = fixture.outputs.map((f) => f.readAsStringSync()).toList();
    for (final file in fixture.outputs) {
      file.setLastModifiedSync(DateTime.utc(2000));
    }
    expect(await fixture.run(forbidGeneration: true), (
      current: 2,
      regenerated: 0,
    ));
    for (final file in fixture.outputs) {
      expect(file.lastModifiedSync().toUtc(), DateTime.utc(2000));
    }
    final source = fixture.sources.first;
    final original = source.readAsStringSync();
    source.writeAsStringSync(
      original.replaceFirst("AdeleMethod('ping')", "AdeleMethod('pong')"),
    );
    expect(await fixture.run(), (current: 1, regenerated: 1));
    expect(fixture.generated, [source.path]);
    expect(
      fixture.outputs.first.readAsStringSync(),
      (await const ContractGenerator().generate(source)).contents,
    );
    expect(fixture.outputs.last.readAsStringSync(), before.last);
    expect(fixture.outputs.last.lastModifiedSync().toUtc(), DateTime.utc(2000));
    source.writeAsStringSync(original);
    expect(await fixture.run(), (current: 1, regenerated: 1));
    expect(fixture.outputs.first.readAsStringSync(), before.first);
    source.writeAsStringSync('$original\n// temporary edit\n');
    source.writeAsStringSync(original);
    expect(await fixture.run(forbidGeneration: true), (
      current: 2,
      regenerated: 0,
    ));
  });

  test('shared authored part invalidates only its consumers', () async {
    final fixture = await _Fixture.create(['first', 'second', 'unrelated']);
    final shared = fixture.file('shared.dart')
      ..writeAsStringSync("part 'shared_part.dart';\n");
    final part = fixture.file('shared_part.dart')
      ..writeAsStringSync("part of 'shared.dart';\nconst method = 'ping';\n");
    for (final source in fixture.sources.take(2)) {
      source.writeAsStringSync(
        "import '${p.basename(shared.path)}' as shared;\n${source.readAsStringSync()}"
            .replaceFirst("AdeleMethod('ping')", 'AdeleMethod(shared.method)'),
      );
    }
    expect(await fixture.run(), (current: 0, regenerated: 3));
    part.writeAsStringSync(
      part.readAsStringSync().replaceFirst("'ping'", "'pong'"),
    );
    expect(await fixture.run(), (current: 1, regenerated: 2));
    expect(fixture.generated, fixture.sources.take(2).map((f) => f.path));
    for (final source in fixture.sources.take(2)) {
      expect(
        File(p.setExtension(source.path, '.g.dart')).readAsStringSync(),
        (await const ContractGenerator().generate(source)).contents,
      );
    }
  });

  test(
    'missing and damaged outputs or records never authorize a hit',
    () async {
      final fixture = await _Fixture.create(['first']);
      await fixture.run();
      final expected = fixture.outputs.single.readAsStringSync();
      for (final damage in <void Function()>[
        () => fixture.outputs.single.deleteSync(),
        () => fixture.outputs.single.writeAsStringSync(''),
        () => fixture.outputs.single.writeAsStringSync('part of "wrong.dart";'),
        () => fixture.receipt.deleteSync(),
        () => fixture.receipt.writeAsStringSync('{'),
        () {
          final data =
              jsonDecode(fixture.receipt.readAsStringSync())
                  as Map<String, dynamic>;
          final records = data['contracts'] as Map<String, dynamic>;
          final record = records.values.single as Map<String, dynamic>;
          record['output'] = '0' * 64;
          fixture.receipt.writeAsStringSync(jsonEncode(data));
        },
        () {
          final data =
              jsonDecode(fixture.receipt.readAsStringSync())
                  as Map<String, dynamic>;
          final records = data['contracts'] as Map<String, dynamic>;
          final record = records.values.single as Map<String, dynamic>;
          record['inputs'] = <String, String>{};
          fixture.receipt.writeAsStringSync(jsonEncode(data));
        },
      ]) {
        damage();
        expect(await fixture.run(), (current: 0, regenerated: 1));
        expect(fixture.outputs.single.readAsStringSync(), expected);
        expect(await fixture.run(forbidGeneration: true), (
          current: 1,
          regenerated: 0,
        ));
      }
    },
  );

  test(
    'generator, resolution metadata, and analyzer settings invalidate',
    () async {
      final fixture = await _Fixture.create(['first']);
      await fixture.run();
      expect(await fixture.run(identity: 'different-generator'), (
        current: 0,
        regenerated: 1,
      ));
      expect(await fixture.run(identity: 'different-sdk'), (
        current: 0,
        regenerated: 1,
      ));
      // Overrides/lock/graph are inputs even before a pub resolution materializes
      // a different package mapping. Absence is itself a recorded observation.
      for (final path in [
        'pubspec_overrides.yaml',
        'pubspec.lock',
        '.dart_tool/package_graph.json',
      ]) {
        fixture.file(path).writeAsStringSync('# changed resolution input\n');
        expect(await fixture.run(identity: 'different-sdk'), (
          current: 0,
          regenerated: 1,
        ));
      }
      final options = fixture.file('analysis_options.yaml');
      options.writeAsStringSync(
        'analyzer:\n  errors:\n    unused_import: ignore\n',
      );
      expect(await fixture.run(identity: 'different-sdk'), (
        current: 0,
        regenerated: 1,
      ));
      options.writeAsStringSync(
        'analyzer:\n  errors:\n    unused_import: warning\n',
      );
      expect(await fixture.run(identity: 'different-sdk'), (
        current: 0,
        regenerated: 1,
      ));
    },
  );

  test(
    'inventory additions and removals preserve unrelated receipts',
    () async {
      final fixture = await _Fixture.create(['first']);
      await fixture.run();
      fixture.add('second');
      expect(await fixture.run(), (current: 1, regenerated: 1));
      final removed = fixture.sources.removeAt(0);
      expect(await fixture.run(forbidGeneration: true), (
        current: 1,
        regenerated: 0,
      ));
      final data =
          jsonDecode(fixture.receipt.readAsStringSync())
              as Map<String, dynamic>;
      expect(
        (data['contracts'] as Map<String, dynamic>).containsKey(removed.path),
        isFalse,
      );
      fixture.sources.add(removed);
      expect(await fixture.run(), (current: 1, regenerated: 1));
    },
  );

  test(
    'malformed sources fail without replacing outputs or success records',
    () async {
      final fixture = await _Fixture.create(['first']);
      await fixture.run();
      final original = fixture.sources.single.readAsStringSync();
      final output = fixture.outputs.single.readAsStringSync();
      final receipt = fixture.receipt.readAsStringSync();
      fixture.sources.single.writeAsStringSync(
        original.replaceFirst('Future<String>', 'Future<DateTime>'),
      );
      await expectLater(fixture.run(), throwsA(isA<ContractDiagnostic>()));
      expect(fixture.receipt.readAsStringSync(), receipt);
      expect(fixture.outputs.single.readAsStringSync(), output);
      fixture.sources.single.writeAsStringSync(
        original.replaceFirst(
          "AdeleMethod('ping')",
          "AdeleMethod('recovered')",
        ),
      );
      expect(await fixture.run(), (current: 0, regenerated: 1));
      expect(await fixture.run(forbidGeneration: true), (
        current: 1,
        regenerated: 0,
      ));
      fixture.sources.single.deleteSync();
      await expectLater(
        fixture.run(),
        throwsA(anyOf(isA<ContractDiagnostic>(), isA<ArgumentError>())),
      );
    },
  );

  test(
    'generation failure and source edit/restore do not publish receipts',
    () async {
      final fixture = await _Fixture.create(['first']);
      await expectLater(
        fixture.run(
          afterGenerate: () => throw StateError('injected generation failure'),
        ),
        throwsStateError,
      );
      expect(fixture.receipt.existsSync(), isFalse);
      expect(fixture.outputs.single.existsSync(), isFalse);
      final source = fixture.sources.single;
      final original = source.readAsStringSync();
      await expectLater(
        fixture.run(
          afterGenerate: () {
            final modified = source.lastModifiedSync();
            source.writeAsStringSync('$original\n// race\n');
            source.writeAsStringSync(original);
            source.setLastModifiedSync(modified);
          },
        ),
        throwsStateError,
      );
      expect(fixture.receipt.existsSync(), isFalse);
      expect(await fixture.run(), (current: 0, regenerated: 1));
      expect(await fixture.run(forbidGeneration: true), (
        current: 1,
        regenerated: 0,
      ));
    },
  );

  test(
    'warm inputs and inventory remain fenced during another regeneration',
    () async {
      final fixture = await _Fixture.create(['first', 'second']);
      await fixture.run();
      fixture.sources.last.writeAsStringSync(
        '${fixture.sources.last.readAsStringSync()}\n// dirty\n',
      );
      final receipt = fixture.receipt.readAsStringSync();
      await expectLater(
        fixture.run(
          afterGenerate: () {
            fixture.sources.first.writeAsStringSync(
              '${fixture.sources.first.readAsStringSync()}\n// raced\n',
            );
          },
        ),
        throwsA(anyOf(isA<StateError>(), isA<FileSystemException>())),
      );
      expect(fixture.receipt.readAsStringSync(), receipt);
      expect(await fixture.run(), (current: 0, regenerated: 2));
      fixture.sources.last.writeAsStringSync(
        '${fixture.sources.last.readAsStringSync()}\n// dirty again\n',
      );
      await expectLater(
        fixture.run(
          afterGenerate: () {
            fixture
                .file('contract_codegen.yaml')
                .writeAsStringSync('sources:\n');
          },
        ),
        throwsStateError,
      );
    },
  );

  test(
    'overlapping in-process generation cannot publish competing receipts',
    () async {
      final fixture = await _Fixture.create(['first']);
      await fixture.run(
        afterGenerate: () async {
          await expectLater(fixture.run(), throwsA(isA<FileSystemException>()));
        },
      );
      expect(await fixture.run(forbidGeneration: true), (
        current: 1,
        regenerated: 0,
      ));
    },
  );

  test(
    'other generated siblings are inputs and cold dependencies settle',
    () async {
      final fixture = await _Fixture.create(['first', 'second']);
      fixture.sources.first.writeAsStringSync(
        "import 'second.dart' as other;\n${fixture.sources.first.readAsStringSync()}",
      );
      expect(await fixture.run(), (current: 0, regenerated: 2));
      expect(await fixture.run(forbidGeneration: true), (
        current: 2,
        regenerated: 0,
      ));
      fixture.outputs.last.writeAsStringSync(
        'part of "second.dart";\nconst changed = 1;\n',
      );
      expect(await fixture.run(), (current: 0, regenerated: 2));
      expect(await fixture.run(forbidGeneration: true), (
        current: 2,
        regenerated: 0,
      ));
    },
  );

  for (final failLater in [false, true]) {
    test(
      'settling ${failLater ? 'failure' : 'cycle'} keeps prior receipts and recovers',
      () async {
        final fixture = await _Fixture.create(['first', 'second']);
        for (final source in fixture.sources) {
          final other = fixture.sources.singleWhere((f) => f != source);
          source.writeAsStringSync(
            "import '${p.basename(other.path)}' as other;\n${source.readAsStringSync()}",
          );
        }
        await fixture.run();
        final prior = fixture.receipt.readAsStringSync();
        for (final source in fixture.sources) {
          source.writeAsStringSync(
            '${source.readAsStringSync()}\n// force generation\n',
          );
        }
        await expectLater(
          fixture.run(
            transform: (source, output) {
              if (failLater && fixture.generated.length == 3) {
                throw StateError('injected later-pass failure');
              }
              final other = fixture.sources.singleWhere(
                (f) => f.path != source.path,
              );
              final otherOutput = File(
                p.setExtension(other.path, '.g.dart'),
              ).readAsStringSync();
              final phase = otherOutput.contains('// phase 1') ? 0 : 1;
              return ContractGeneratedFile(
                output.path,
                '${output.contents}\n// phase $phase\n',
              );
            },
          ),
          failLater
              ? throwsStateError
              : throwsA(
                  isA<FileSystemException>().having(
                    (error) => error.message,
                    'message',
                    contains('did not settle'),
                  ),
                ),
        );
        expect(fixture.generated, hasLength(failLater ? 3 : 6));
        expect(fixture.outputs.first.readAsStringSync(), contains('// phase'));
        expect(fixture.receipt.readAsStringSync(), prior);
        expect(await fixture.run(), (current: 0, regenerated: 2));
        expect(await fixture.run(forbidGeneration: true), (
          current: 2,
          regenerated: 0,
        ));
      },
    );
  }
}

final class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final sources = <File>[];
  final generated = <String>[];
  List<File> get outputs =>
      sources.map((f) => File(p.setExtension(f.path, '.g.dart'))).toList();
  File get receipt => file('.dart_tool/adele/contracts/freshness.json');

  static Future<_Fixture> create(List<String> names) async {
    final base = await createFixture('');
    base.source.deleteSync();
    final fixture = _Fixture(base.directory);
    for (final name in names) {
      fixture.add(name);
    }
    return fixture;
  }

  File file(String path) {
    final result = File(p.join(root.path, path));
    result.parent.createSync(recursive: true);
    return result;
  }

  void add(String name) {
    sources.add(
      file('$name.dart')..writeAsStringSync(
        minimalContract(
          namedValue: true,
        ).replaceFirst('fixture.g.dart', '$name.g.dart'),
      ),
    );
  }

  Future<({int current, int regenerated})> run({
    String identity = 'test-generator',
    bool forbidGeneration = false,
    FutureOr<void> Function()? afterGenerate,
    ContractGeneratedFile Function(File, ContractGeneratedFile)? transform,
  }) async {
    final configuration =
        'sources:\n${sources.map((f) => '  - ${p.relative(f.path, from: root.path)}\n').join()}';
    final config = file('contract_codegen.yaml');
    if (!config.existsSync() || config.readAsStringSync() != configuration) {
      config.writeAsStringSync(configuration);
    }
    generated.clear();
    return generateIncrementally(
      root: root,
      sources: sources,
      configuration: configuration,
      generatorIdentity: identity,
      generate: (source, {ContractInputs? inputs}) async {
        if (forbidGeneration) {
          fail('Unexpected semantic regeneration: ${source.path}');
        }
        generated.add(source.path);
        final output = await const ContractGenerator().generate(
          source,
          inputs: inputs,
        );
        await afterGenerate?.call();
        return transform?.call(source, output) ?? output;
      },
    );
  }
}
