import 'dart:io';

import 'package:contract_codegen/contract_codegen.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

export 'dart:io';
export 'package:analyzer/dart/analysis/analysis_context_collection.dart';
export 'package:analyzer/dart/analysis/results.dart';
export 'package:contract_codegen/contract_codegen.dart';
export 'package:test/test.dart';

Future<String> generateContract(String source) async {
  final fixture = await createFixture(source);
  return (await const ContractGenerator().generate(fixture.source)).contents;
}

String collectionSnapshotContract({
  String listInitializer = 'List<String>.unmodifiable(values)',
  String mapInitializer = 'adeleSnapshotJsonMap(data)',
  String extraParameter = '',
  String helper = '',
}) =>
    '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
$helper
@AdeleValue('fixture.value')
final class FixtureValue {
  FixtureValue({required List<String> values, required Map<String, Object?> data$extraParameter})
      : values = $listInitializer,
        data = $mapInitializer;
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
''';

Future<void> expectDiagnostic(String source, String message) async {
  final fixture = await createFixture(source);
  expect((await readDiagnostic(fixture.source)).message, contains(message));
}

String minimalContract({bool namedValue = false}) =>
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

String orderedContract({required bool valuesFirst}) {
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

String allTypesContract() => '''
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

String runtimeContract() => '''
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

String runtimeTests(String name) =>
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

String resourceRuntimeContract() => '''
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

String valueRuntimeContract() => '''
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

String valueRuntimeTests() => '''
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

String failureRuntimeContract() => '''
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

String failureRuntimeTests() => '''
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

String relativeUriResultContract() => '''
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

String relativeUriResultTests() => '''
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

String nullableUriResultContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.inner')
final class Inner { const Inner({required this.uri}); final Uri? uri; }
@AdeleValue('fixture.outer')
final class Outer { const Outer({required this.inner}); final Inner? inner; }
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('nullable') Future<Uri?> nullable(String mode);
  @AdeleMethod('nested') Future<Outer?> nested(String mode);
  @AdeleMethod('ping') Future<String> ping(String value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

String nullableUriResultTests() => '''
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';
void main() {
  test('nullable nested URI results', () async {
    final dispatcher = FixtureServiceDispatcher(_Service());
    for (final method in ['nullable', 'nested']) {
      final invalid = await dispatcher.dispatch(_request('fixture.service.\$method', 'relative'));
      expect((invalid['error'] as Map<Object?, Object?>)['code'], 'backend_contract_violation');
      final validNull = await dispatcher.dispatch(_request('fixture.service.\$method', 'null'));
      expect(validNull['ok'], isTrue);
      expect(validNull['payload'], isNull);
      final continued = await dispatcher.dispatch(_request('fixture.service.ping', 'continued'));
      expect(continued['payload'], 'continued');
    }
  });
}
Map<Object?, Object?> _request(String method, String value) => {'kind': 'request', 'requestId': 1, 'method': method, 'payload': method.endsWith('ping') ? {'value': value} : {'mode': value}};
final class _Service implements FixtureService {
  @override Future<Uri?> nullable(String mode) async => mode == 'null' ? null : Uri.parse('relative/path');
  @override Future<Outer?> nested(String mode) async => mode == 'null' ? null : Outer(inner: Inner(uri: Uri.parse('relative/path')));
  @override Future<String> ping(String value) async => value;
}
''';

String adversarialContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
enum CollisionMood { value, error, result }
@AdeleValue('fixture.collision')
final class CollisionValue {
  const CollisionValue({required this.value, required this.map, required this.response, required this.result, required this.error, required this.payload, required this.method, required this.values, required this.element, required this.nonNullValue, required this.channel, required this.service});
  final String value;
  final String map;
  final String response;
  final String result;
  final String? error;
  final Map<String, Object?> payload;
  final String method;
  final List<String?> values;
  final CollisionMood element;
  final List<List<String?>> nonNullValue;
  final String channel;
  final String service;
}
@AdeleService('fixture.service')
abstract interface class CollisionService {
  @AdeleMethod('dispatch') Future<CollisionValue?> dispatch(CollisionValue? value);
  @AdeleMethod('channel') Future<String> channel(String payload, String method, String values, String nonNullValue);
  @AdeleMethod('service') Future<String> service(String response, String error);
  @AdeleMethod('void') Future<void> error(String response);
  @AdeleMethod('enum') Future<CollisionMood> value(CollisionMood error);
}
@AdeleFailure('fixture.failure')
final class CollisionFailure implements Exception {
  const CollisionFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

String adversarialTests() => '''
import 'package:adele_contract/adele_contract.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';
void main() {
  test('client dispatcher and backend coexist', () async {
    final value = CollisionValue(value: 'v', map: 'm', response: 'r', result: 'result', error: null, payload: const {'ok': true}, method: 'method', values: const ['x', null], element: CollisionMood.result, nonNullValue: const [[null]], channel: 'channel', service: 'service');
    final dispatcher = CollisionServiceDispatcher(_Service());
    final response = await dispatcher.dispatch({'kind': 'request', 'requestId': 1, 'method': 'fixture.service.dispatch', 'payload': {'value': {'value': 'v', 'map': 'm', 'response': 'r', 'result': 'result', 'error': null, 'payload': {'ok': true}, 'method': 'method', 'values': ['x', null], 'element': 'result', 'nonNullValue': [[null]], 'channel': 'channel', 'service': 'service'}}});
    expect(response['ok'], isTrue);
    expect(await CollisionServiceClient(_Channel(response['payload'])).dispatch(value), isA<CollisionValue>());
    final sequence = _SequenceChannel(['channel', 'service']);
    expect(await CollisionServiceClient(sequence).channel('a', 'b', 'c', 'd'), 'channel');
    expect(await CollisionServiceClient(sequence).service('response', 'error'), 'service');
    await CollisionServiceClient(const _Channel(null)).error('response');
  });
}
final class _Service implements CollisionService {
  @override Future<CollisionValue?> dispatch(CollisionValue? value) async => value;
  @override Future<String> channel(String payload, String method, String values, String nonNullValue) async => 'channel';
  @override Future<String> service(String response, String error) async => response;
  @override Future<void> error(String response) async {}
  @override Future<CollisionMood> value(CollisionMood error) async => error;
}
final class _Channel implements AdeleRequestChannel {
  const _Channel(this.response); final Object? response;
  @override Future<Object?> request(String method, Map<String, Object?> payload) async => response;
}
final class _SequenceChannel implements AdeleRequestChannel {
  _SequenceChannel(this.responses); final List<Object?> responses; int index = 0;
  @override Future<Object?> request(String method, Map<String, Object?> payload) async => responses[index++];
}
''';

String identifierContract() => '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
enum FixtureMood { ready }
@AdeleValue('fixture.value')
final class FixtureValue {
  const FixtureValue({required this.value});
  final String value;
}
@AdeleService('fixture.service')
abstract interface class FixtureService {
  @AdeleMethod('ping') Future<FixtureMood> ping(String value);
}
@AdeleFailure('fixture.failure')
final class FixtureFailure implements Exception {
  const FixtureFailure({required this.code, required this.message, required this.details});
  final String code; final String message; final Map<String, Object?> details;
}
''';

String resourceRuntimeTests() => '''
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

String wireOrderingContract() => '''
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

String recursiveValueContract(String fieldType) =>
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

Future<ContractDiagnostic> readDiagnostic(File source) async {
  try {
    await const ContractGenerator().generate(source);
  } on ContractDiagnostic catch (error) {
    return error;
  }
  throw StateError('Expected contract generation to fail.');
}

Future<ContractFixture> createFixture(
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
  return ContractFixture(directory, file);
}

Future<ContractFixture> fixtureWithSupport(
  String source,
  String support, {
  String? prefix,
}) async {
  final String importPrefix = prefix ?? 'support';
  final String qualifiedSource = source.replaceAllMapped(
    RegExp(
      r'(?<![A-Za-z0-9_.])(?:Alias|ImportedValue|ImportedMood)(?![A-Za-z0-9_])',
    ),
    (Match match) => '$importPrefix.${match[0]}',
  );
  final fixture = await createFixture(
    "import 'support.dart' as $importPrefix;\n$qualifiedSource",
  );
  await File(
    p.join(fixture.directory.path, 'support.dart'),
  ).writeAsString(support);
  return fixture;
}

Future<void> runGeneratedFixture(
  String source,
  String tests, {
  bool analyze = true,
}) async {
  final fixture = await createFixture(source);
  final repository = repositoryRoot();
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
  if (analyze) await _runDart(fixture.directory, const ['analyze']);
  await _runDart(fixture.directory, const ['test']);
}

Directory repositoryRoot() {
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

final class ContractFixture {
  const ContractFixture(this.directory, this.source);
  final Directory directory;
  final File source;
}
