import 'dart:async';

import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generated client uses the argument-free infrastructure route',
    () async {
      final service = _LocalState();
      final dispatcher = BackendLocalStateServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final sent = <Map<String, Object?>>[];
      late final AdeleHostRequestMultiplexer host;
      host = AdeleHostRequestMultiplexer(
        send: (message) {
          sent.add(message);
          unawaited(
            dispatcher
                .dispatch({
                  'kind': 'request',
                  'requestId': message['requestId'],
                  'method': message['method'],
                  'payload': message['payload'],
                })
                .then((response) {
                  host.handleResponse({...response, 'kind': 'hostResponse'});
                }),
          );
        },
      );
      addTearDown(host.close);
      final client = BackendLocalStateServiceClient(
        host.bindInfrastructure(
          hostInfrastructureContext: 'exact-generation',
          serviceId: backendLocalStateServiceId,
        ),
      );

      expect(service.calls, 0);
      expect(await client.getLocalStateRoot(), '/fixture/state');
      expect(service.calls, 1);
      expect(backendLocalStateServiceId, 'adele.backendLocalState');
      expect(sent.single, {
        'kind': 'hostRequest',
        'requestId': 0,
        'hostContextKind': 'infrastructure',
        'hostContext': 'exact-generation',
        'serviceId': backendLocalStateServiceId,
        'method': backendLocalStateServiceGetLocalStateRootId,
        'payload': <String, Object?>{},
      });
    },
  );

  test('generated service rejects selectors and mutation methods', () async {
    final service = _LocalState();
    final dispatcher = BackendLocalStateServiceDispatcher(service);
    addTearDown(dispatcher.close);
    for (final selector in ['path', 'owner', 'sessionId', 'environment']) {
      final response = await dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': backendLocalStateServiceGetLocalStateRootId,
        'payload': {selector: '/private/selector'},
      });
      expect(response['ok'], isFalse);
      expect((response['error']! as Map)['code'], 'invalid_request');
      expect(response.toString(), isNot(contains('/private/selector')));
    }
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 2,
      'method': 'adele.backendLocalState.createDirectory',
      'payload': <String, Object?>{},
    });
    expect(response['ok'], isFalse);
    expect((response['error']! as Map)['code'], 'unknown_method');
    expect(service.calls, 0);
  });
}

final class _LocalState implements BackendLocalStateService {
  int calls = 0;

  @override
  Future<String> getLocalStateRoot() async {
    calls++;
    return '/fixture/state';
  }
}
