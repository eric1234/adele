import 'dart:io';

import 'package:contract_codegen/contract_codegen.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final Directory repository = Directory.current.parent.parent;
  final File demo = File(
    p.join(
      repository.path,
      'plugins/workspace_demo/packages/contract/lib/workspace_demo_contract.dart',
    ),
  );

  test(
    'generation is deterministic and matches the checked-in golden',
    () async {
      final ContractGenerator generator = const ContractGenerator();
      final ContractGeneratedFile first = await generator.generate(demo);
      final ContractGeneratedFile second = await generator.generate(demo);

      expect(first.contents, second.contents);
      expect(first.contents, await File(first.path).readAsString());
      expect(await generator.apply(demo, check: true), isTrue);
      expect(first.contents, contains('WorkspaceDemoServiceClient'));
      expect(first.contents, contains('WorkspaceDemoServiceDispatcher'));
      expect(first.contents, isNot(contains('.cast<')));
    },
  );

  test('supports package-agnostic names and all wire types', () async {
    final _Fixture fixture = await _fixture('''
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
part 'nested/generated/other_name.g.dart';
enum Mood { calm, busy }
@AdeleValue('odd.record')
final class OddRecord {
  const OddRecord(this.text, {required this.enabled, required this.count, required this.ratio, required this.note, required this.tags, required this.mood, required this.resource});
  final String text;
  final bool enabled;
  final int count;
  final double ratio;
  final String? note;
  final List<String?> tags;
  final Mood mood;
  final ResourceRef resource;
}
@AdeleService('odd.service')
abstract interface class OddGateway {
  @AdeleMethod('roundTrip')
  Future<OddRecord?> send(@AdeleField('input') OddRecord? value);
}
@AdeleFailure('odd.failure')
final class OddFailure implements Exception {
  const OddFailure({required this.code, required this.message, this.details = const {}});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''');
    final ContractGeneratedFile output = await const ContractGenerator()
        .generate(fixture.source);

    expect(output.path, endsWith('nested/generated/other_name.g.dart'));
    expect(output.contents, contains('OddGatewayClient'));
    expect(output.contents, contains('_contractBool'));
    expect(output.contents, contains('_contractInt'));
    expect(output.contents, contains('_contractDouble'));
    expect(output.contents, contains('_decodeMood'));
    expect(output.contents, contains('_decodeOddRecord'));
    expect(output.contents, contains('_decodeResourceRef'));
    expect(output.contents, contains('List.unmodifiable'));
    expect(output.contents, contains("'input': value == null ? null"));
  });

  test(
    'apply check is non-mutating and write creates only final output',
    () async {
      final _Fixture fixture = await _fixture(_minimalContract());
      final ContractGenerator generator = const ContractGenerator();
      final ContractGeneratedFile generated = await generator.generate(
        fixture.source,
      );

      expect(await generator.apply(fixture.source, check: true), isFalse);
      expect(File(generated.path).existsSync(), isFalse);
      expect(await generator.apply(fixture.source, check: false), isFalse);
      expect(await File(generated.path).readAsString(), generated.contents);
      expect(fixture.directory.listSync().whereType<File>(), hasLength(2));
      expect(await generator.apply(fixture.source, check: true), isTrue);
    },
  );

  final Map<String, String Function(String)> invalid = {
    'unsupported type': (String source) => source.replaceFirst(
      'Future<String> ping(String value);',
      'Future<DateTime> ping(String value);',
    ),
    'duplicate stable ID': (String source) => source.replaceFirst(
      "@AdeleFailure('fixture.failure')",
      "@AdeleFailure('fixture.service')",
    ),
    'method without annotation': (String source) =>
        source.replaceFirst("  @AdeleMethod('ping')\n", ''),
    'bad constructor': (String source) => source.replaceFirst(
      'const FixtureValue(this.value);',
      'const FixtureValue();',
    ),
    'bad part': (String source) => source.replaceFirst(
      "part 'fixture.g.dart';",
      "part '/absolute.g.dart';",
    ),
    'unsupported service shape': (String source) => source.replaceFirst(
      'abstract interface class FixtureService',
      'abstract class FixtureService',
    ),
    'unsupported value shape': (String source) =>
        source.replaceFirst('final class FixtureValue', 'class FixtureValue'),
    'unsupported failure shape': (String source) => source.replaceFirst(
      'final class FixtureFailure implements Exception',
      'class FixtureFailure',
    ),
  };
  for (final MapEntry<String, String Function(String)> entry
      in invalid.entries) {
    test('rejects ${entry.key} at an exact source location', () async {
      final _Fixture fixture = await _fixture(entry.value(_minimalContract()));
      final ContractDiagnostic diagnostic = await _diagnostic(fixture.source);
      expect(diagnostic.path, fixture.source.absolute.path);
      expect(diagnostic.line, greaterThan(1));
      expect(diagnostic.column, greaterThan(0));
      expect(
        diagnostic.toString(),
        startsWith('${fixture.source.absolute.path}:'),
      );
      if (entry.key == 'method without annotation') {
        expect(diagnostic.line, 10);
        expect(diagnostic.column, 18);
      }
    });
  }
}

String _minimalContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.value')
final class FixtureValue {
  const FixtureValue(this.value);
  final String value;
}
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('ping')
  Future<String> ping(String value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, this.details = const {}});
  final String code;
  final String message;
  final Map<String, Object?> details;
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

Future<_Fixture> _fixture(String source) async {
  final Directory parent = Directory(
    p.join(Directory.current.path, '.dart_tool', 'contract_fixtures'),
  )..createSync(recursive: true);
  final Directory directory = await parent.createTemp('fixture.');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final File file = File(p.join(directory.path, 'fixture.dart'));
  await file.writeAsString(source);
  return _Fixture(directory, file);
}

final class _Fixture {
  const _Fixture(this.directory, this.source);
  final Directory directory;
  final File source;
}
