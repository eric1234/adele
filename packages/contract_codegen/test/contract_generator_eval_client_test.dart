import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';

import 'support/contract_generator_support.dart';

void main() {
  test(
    'eval client derives strict wire codecs without native dispatch',
    () async {
      final fixture = await createFixture('''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.entry')
final class Entry {
  const Entry({required this.id, required this.text});
  @AdeleField('entryId') final String id;
  final String? text;
}
@AdeleValue('fixture.snapshot')
final class Snapshot {
  const Snapshot({required this.entries, required this.budget});
  final List<Entry> entries;
  final int budget;
}
@AdeleService('fixture.session')
abstract interface class SessionService {
  @AdeleMethod('read') Future<Snapshot> snapshot(String session);
  @AdeleMethod('write') Future<void> configure(Snapshot snapshot);
  @AdeleMethod('json') Future<Map<String, Object?>> json(Map<String, Object?> value);
}
@AdeleFailure('fixture.failure')
final class SessionFailure implements Exception {
  const SessionFailure({required this.code, required this.message, required this.details});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''');
      final generator = const ContractGenerator();
      final output = await generator.generateEvalClient(fixture.source);
      expect(output, await generator.generateEvalClient(fixture.source));
      expect(parseString(content: output).errors, isEmpty);
      expect(output, contains('class SessionServiceClient'));
      expect(output, contains("'fixture.session.read'"));
      expect(output, contains("'entryId'"));
      expect(output, contains('Missing Entry field.'));
      expect(output, contains('Unknown Entry field.'));
      expect(output, contains('Expected String.'));
      expect(output, contains('Expected null.'));
      expect(output, contains('List<Entry>.unmodifiable'));
      expect(output, contains('.then((Object? _adeleResponse)'));
      expect(output, isNot(contains('catch (')));
      expect(output, contains('JSON exceeds maximum depth 64.'));
      expect(output, isNot(contains('switch')));
      expect(output, isNot(contains('.identity')));
      expect(output, isNot(contains('Dispatcher')));
      expect(output, isNot(contains('part of')));
      final emitted = File('${fixture.directory.path}/eval_client.dart');
      await emitted.writeAsString(output);
      final analysis = AnalysisContextCollection(includedPaths: [emitted.path]);
      final unit =
          await analysis
                  .contextFor(emitted.path)
                  .currentSession
                  .getResolvedUnit(emitted.path)
              as ResolvedUnitResult;
      expect(
        unit.diagnostics.where((error) => error.severity == Severity.error),
        isEmpty,
      );
      final native = await generator.generate(fixture.source);
      expect(native.contents, contains('SessionServiceDispatcher'));
      expect(native.contents, contains('switch'));
    },
    // Repeated native/eval generation and analysis use fresh analyzer contexts.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'eval client rejects unsupported shapes instead of weakening them',
    () async {
      final fixture = await createFixture(runtimeContract());
      await expectLater(
        const ContractGenerator().generateEvalClient(fixture.source),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'eval output uses the same contract validation as native output',
    () async {
      final fixture = await createFixture(
        minimalContract().replaceAll('final String value;', 'String value;'),
      );
      await expectLater(
        const ContractGenerator().generateEvalClient(fixture.source),
        throwsA(isA<ContractDiagnostic>()),
      );
    },
  );

  test(
    'real EVC round trips generated nested encoders and strict JSON',
    () async {
      final fixture = await createFixture('''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.entry')
final class Entry {
  const Entry({required this.text});
  final String text;
}
@AdeleValue('fixture.payload')
final class Payload {
  const Payload({required this.text, required this.enabled, required this.count,
    required this.ratio, required this.note, required this.values,
    required this.data, required this.entry});
  final String text;
  final bool enabled;
  final int count;
  final double ratio;
  final String? note;
  final List<String?> values;
  final Map<String, Object?> data;
  final Entry? entry;
}
@AdeleService('fixture.session')
abstract interface class SessionService {
  @AdeleMethod('echo') Future<Payload> echo(Payload value, String scope, int count);
  @AdeleMethod('json') Future<Map<String, Object?>> json(Map<String, Object?> value);
}
''');
      final output = await const ContractGenerator().generateEvalClient(
        fixture.source,
      );
      final compiler = Compiler()
        ..entrypoints.addAll([
          'package:adele_contract/adele_contract.dart',
          'package:fixture/fixture.dart',
          'package:runner/main.dart',
        ]);
      final program = compiler.compile({
        'adele_contract': {'adele_contract.dart': evalContractSupportSource},
        'fixture': {'fixture.dart': output},
        'runner': {
          'main.dart': r'''
import 'package:adele_contract/adele_contract.dart';
import 'package:fixture/fixture.dart';
class EchoChannel implements AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == 'fixture.session.echo' && (payload['scope'] != 'scope' || payload['count'] != 7)) throw StateError('Wrong payload');
    return payload['value'];
  }
}
Future<String> run() {
  final client = SessionServiceClient(EchoChannel());
  final value = Payload(text: 'sample', enabled: true, count: 4, ratio: 1.5,
    note: null, values: <String?>['a', null], entry: Entry(text: 'nested'),
    data: <String, Object?>{'items': <Object?>[1, true, null, 2.5, 'value']});
  return client.echo(value, 'scope', 7).then((Payload decoded) {
    if (decoded.note != null || decoded.values[1] != null) throw StateError('Nullable value lost');
    return '${decoded.text}|${decoded.enabled}|${decoded.count}|${decoded.ratio}|${decoded.values.length}|${decoded.entry!.text}|${decoded.data['items']}';
  });
}
String cycle() {
  final map = <String, Object?>{};
  map['self'] = map;
  try { SessionServiceClient(EchoChannel()).json(map); }
  catch (error) { return error.toString(); }
  return 'accepted';
}
String nonFinite() {
  try { SessionServiceClient(EchoChannel()).json(<String, Object?>{'bad': double.infinity}); }
  catch (error) { return error.toString(); }
  return 'accepted';
}
''',
        },
      });
      final runtime = Runtime(program.write().buffer.asByteData());
      final result = await runtime.executeLib(
        'package:runner/main.dart',
        'run',
      );
      expect(
        (result as $Value).$reified,
        'sample|true|4|1.5|2|nested|[1, true, null, 2.5, value]',
      );
      for (final entry in {
        'cycle': 'JSON exceeds maximum depth 64.',
        'nonFinite': 'Expected finite JSON number.',
      }.entries) {
        final runtime = Runtime(program.write().buffer.asByteData());
        final result =
            runtime.executeLib('package:runner/main.dart', entry.key) as $Value;
        expect(result.$reified, entry.value);
      }
    },
  );
}
