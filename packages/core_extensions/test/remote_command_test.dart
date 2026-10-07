import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/remote_command.dart';
import 'package:test/test.dart';

void main() {
  late _Service service;
  late RemoteCommandServiceDispatcher dispatcher;
  late _Channel channel;
  late RemoteCommandServiceClient client;

  setUp(() {
    service = _Service();
    dispatcher = RemoteCommandServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = RemoteCommandServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test('generated wire identifiers are stable', () {
    expect(remoteCommandServiceId, 'dev.adele.command.remote');
    expect(remoteCommandServiceInvokeId, 'dev.adele.command.remote.invoke');
  });

  test(
    'generated transport completes with only an opaque route payload',
    () async {
      for (final route in [
        'generation-7:command_3.route',
        'opaque/route?command=two\n',
      ]) {
        await expectLater(client.invoke(route), completes);
        expect(channel.method, remoteCommandServiceInvokeId);
        expect(channel.payload, {'routeId': route});
        expect(service.routes.last, route);
        expect(channel.response, {
          'kind': 'response',
          'requestId': 1,
          'ok': true,
          'payload': null,
        });
      }
      expect(service.routes, hasLength(2));
    },
  );

  test('client completion waits for asynchronous service completion', () async {
    final entered = Completer<void>();
    final completion = Completer<void>();
    service.onInvoke = () {
      entered.complete();
      return completion.future;
    };
    var completed = false;
    final invocation = client.invoke('pending-route').then((_) {
      completed = true;
    });
    addTearDown(() async {
      if (!completion.isCompleted) completion.complete();
      await invocation;
    });

    await entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(service.routes, ['pending-route']);
    expect(completed, isFalse);
    expect(channel.response, isNull);

    completion.complete();
    await invocation;
    expect(completed, isTrue);
    expect(channel.response!['ok'], isTrue);
  });

  test('service errors remain opaque failed client invocations', () async {
    for (final invoke in <Future<void> Function()>[
      () => throw StateError('private synchronous command state'),
      () async {
        await Future<void>.delayed(Duration.zero);
        throw const AdeleProtocolException(
          'private asynchronous command state',
        );
      },
    ]) {
      service.onInvoke = invoke;
      await expectLater(
        client.invoke('failing-route'),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((failure) => failure.code, 'code', 'internal_error')
              .having((failure) => failure.declaredFailureType, 'type', isNull),
        ),
      );
      expect(channel.response!['ok'], isFalse);
      expect(jsonEncode(channel.response), isNot(contains('private')));
    }
    expect(service.routes, ['failing-route', 'failing-route']);
  });

  test('dispatcher rejects malformed payloads before invocation', () async {
    for (final payload in <Object?>[
      null,
      'route',
      <String, Object?>{},
      {'routeId': null},
      {'routeId': 1},
      {'routeId': 'route', 'hostInvocationContext': 'forged'},
      {'routeId': 'route', 'services': <String>[]},
      {'routeId': 'route', 'availability': 'enabled'},
      {'routeId': 'route', 'arguments': <String, Object?>{}},
    ]) {
      final response = await dispatcher.dispatch(
        _request(remoteCommandServiceInvokeId, payload),
      );
      expect(response['ok'], isFalse);
      expect((response['error']! as Map)['code'], 'invalid_request');
      expect(service.routes, isEmpty);
    }
  });

  test('client rejects non-null completion payloads', () async {
    for (final payload in <Object?>[true, 'completed', <String, Object?>{}]) {
      await expectLater(
        RemoteCommandServiceClient(_ResponseChannel(payload)).invoke('route'),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });
}

final class _Service implements RemoteCommandService {
  final routes = <String>[];
  Future<void> Function()? onInvoke;

  @override
  Future<void> invoke(String routeId) {
    routes.add(routeId);
    return onInvoke?.call() ?? Future<void>.value();
  }
}

Map<String, Object?> _request(String method, Object? payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': method,
  'payload': payload,
};

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final RemoteCommandServiceDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch(
      _request(method, jsonDecode(jsonEncode(payload))),
    );
    this.response = response;
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return jsonDecode(jsonEncode(response['payload']));
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;

  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}
