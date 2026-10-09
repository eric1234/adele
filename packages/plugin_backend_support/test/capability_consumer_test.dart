import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generated control roundtrips DTOs and fixed infrastructure route',
    () async {
      final wire = _Wire();
      final providers = await wire.consumer.discover('test.capability', 1);
      expect(providers.single.providerId, 'test.provider');
      expect(providers.single.pluginId, 'test.plugin');
      expect(providers.single.displayName, 'Test provider');
      expect(providers.single.serviceId, 'test.service');
      expect(() => providers.clear(), throwsUnsupportedError);
      expect(wire.sent.single, {
        'kind': 'hostRequest',
        'requestId': 0,
        'hostContextKind': 'infrastructure',
        'hostContext': 'consumer-generation',
        'serviceId': backendCapabilityConsumerServiceId,
        'method': backendCapabilityConsumerServiceDiscoverId,
        'payload': {'capabilityId': 'test.capability', 'majorVersion': 1},
      });

      final access = (await wire.resolve(providerId: 'test.provider'))!;
      expect(access.provider.providerId, 'test.provider');
      expect(access.requestChannel, isNot(isA<AdeleStreamChannel>()));
      expect(wire.sent.last['payload'], {
        'capabilityId': 'test.capability',
        'majorVersion': 1,
        'expectedServiceId': 'test.service',
        'providerId': 'test.provider',
      });
      await access.requestChannel.request('test.service.read', {'argument': 7});
      expect(wire.sent.last['payload'], {
        'handle': 'opaque-access',
        'method': 'test.service.read',
        'payload': {'argument': 7},
      });
      expect(wire.sent.last['serviceId'], backendCapabilityConsumerServiceId);
      await access.release();
      expect(
        wire.sent.last['method'],
        backendCapabilityConsumerServiceReleaseId,
      );
      expect(wire.sent.last['payload'], {'handle': 'opaque-access'});
    },
  );

  test(
    'empty discovery and null resolution remain absence, not fallback',
    () async {
      final wire = _Wire();
      wire.broker.providers = [];
      wire.broker.access = null;
      expect(await wire.consumer.discover('test.capability', 1), isEmpty);
      expect(await wire.resolve(), isNull);
      expect(await wire.resolve(providerId: 'test.missing'), isNull);
      expect(wire.sent, hasLength(3));
    },
  );

  test(
    'all native structured response shapes survive the invoke envelope',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      for (final value in <Object?>[
        null,
        false,
        true,
        42,
        9007199254740993,
        -9223372036854775808,
        1.25,
        'scalar',
        <Object?>[],
        <String, Object?>{},
        <Object?>[
          null,
          'enumValue',
          {'uri': 'file:///example', 'mediaType': null},
        ],
        <String, Object?>{
          'dto': {'field': 'value'},
          'list': [1, 2.5, true, null],
        },
        <String, Object?>{'ok': false, 'error': 'ordinary semantic data'},
      ]) {
        wire.broker.result = {'ok': true, 'value': value};
        expect(
          await access.requestChannel.request('test.service.read', {}),
          value,
        );
      }
    },
  );

  test(
    'declared failures reconstruct in the semantic generated-style client',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      wire.broker.result = _failure('test.declaredFailure');
      final client = _SemanticClient(access.requestChannel);
      await expectLater(
        client.read(),
        throwsA(
          isA<_DeclaredFailure>()
              .having((error) => error.code, 'code', 'not_found')
              .having((error) => error.message, 'message', 'Not found')
              .having((error) => error.details, 'details', {
                'path': 'example',
                'nested': [null, 1, true],
              }),
        ),
      );
      for (final type in <String?>[null, 'test.unrecognizedFailure']) {
        wire.broker.result = _failure(type);
        await expectLater(
          client.read(),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((error) => error.declaredFailureType, 'type', type)
                .having((error) => error.code, 'code', 'not_found')
                .having((error) => error.message, 'message', 'Not found')
                .having((error) => error.details['path'], 'path', 'example'),
          ),
        );
      }
    },
  );

  test(
    'release fences immediately, is idempotent, and rejects late success',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      final invocation = wire.broker.invocation =
          Completer<Map<String, Object?>>();
      final release = wire.broker.releasing = Completer<void>();
      final pending = access.requestChannel.request('test.service.read', {});
      final pendingCheck = expectLater(pending, throwsStateError);
      await wire.broker.invoked.future;
      final releasing = access.release();
      expect(access.release(), same(releasing));
      final sentBefore = wire.sent.length;
      await expectLater(
        access.requestChannel.request('test.service.read', {}),
        throwsStateError,
      );
      expect(wire.sent, hasLength(sentBefore));
      var released = false;
      unawaited(releasing.then((_) => released = true));
      invocation.complete({'ok': true, 'value': 'late'});
      await pendingCheck;
      expect(released, isFalse);
      release.complete();
      await releasing;
      expect(wire.broker.releaseCalls, 1);
    },
  );

  test(
    'failed host release never reopens local access or retries release',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      wire.broker.releasing = Completer<void>();
      final releasing = access.release();
      final check = expectLater(
        releasing,
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private host diagnostic')),
              ),
        ),
      );
      wire.broker.releasing!.completeError(
        StateError('private host diagnostic'),
      );
      await check;
      expect(access.release(), same(releasing));
      await expectLater(
        access.requestChannel.request('read', {}),
        throwsStateError,
      );
      expect(wire.broker.releaseCalls, 1);
    },
  );

  test(
    'multiplexer closure rejects retained facade calls without new sends',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      final sentBefore = wire.sent.length;
      wire.host.close();
      await expectLater(
        access.requestChannel.request('read', {}),
        throwsStateError,
      );
      await expectLater(
        wire.consumer.discover('test.capability', 1),
        throwsStateError,
      );
      await expectLater(wire.resolve(), throwsStateError);
      expect(wire.sent, hasLength(sentBefore));
    },
  );

  test(
    'generated control rejects malformed arguments and route overrides',
    () async {
      final wire = _Wire();
      final resolve = <String, Object?>{
        'capabilityId': 'test.capability',
        'majorVersion': 1,
        'expectedServiceId': 'test.service',
        'providerId': null,
      };
      for (final (method, payload) in <(String, Map<String, Object?>)>[
        (
          backendCapabilityConsumerServiceDiscoverId,
          {'capabilityId': 'test.capability'},
        ),
        (
          backendCapabilityConsumerServiceDiscoverId,
          {'capabilityId': 'test.capability', 'majorVersion': '1'},
        ),
        (
          backendCapabilityConsumerServiceResolveId,
          {...resolve}..remove('providerId'),
        ),
        (
          backendCapabilityConsumerServiceResolveId,
          {...resolve, 'providerId': 42},
        ),
        (
          backendCapabilityConsumerServiceResolveId,
          {...resolve, 'configurationContext': 'forged'},
        ),
        (
          backendCapabilityConsumerServiceInvokeId,
          {'handle': 'opaque-access', 'method': 'read', 'payload': []},
        ),
        (
          backendCapabilityConsumerServiceInvokeId,
          {
            'handle': 'opaque-access',
            'method': 'read',
            'payload': {},
            'serviceId': 'private',
          },
        ),
        (backendCapabilityConsumerServiceReleaseId, {'handle': null}),
        (
          backendCapabilityConsumerServiceReleaseId,
          {'handle': 'opaque-access', 'hostInvocationContext': 'forged'},
        ),
      ]) {
        final response = await wire.dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': method,
          'payload': payload,
        });
        expect(response['ok'], isFalse);
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(wire.broker.calls, 0);
    },
  );

  test(
    'generated DTO decoding rejects missing, extra, and malformed fields',
    () async {
      final wire = _Wire();
      for (final malformed in <Object?>[
        _providerMap()..remove('displayName'),
        {..._providerMap(), 'configurationContext': 'private'},
        {..._providerMap(), 'majorVersion': '1'},
        {..._providerMap(), 'majorVersion': 0},
        {..._providerMap(), 'serviceId': 'bad/service'},
        {..._providerMap(), 'providerId': ''},
      ]) {
        wire.reply = (_) => [malformed];
        await expectLater(
          wire.consumer.discover('test.capability', 1),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
      for (final malformed in <Object?>[
        {'provider': _providerMap()},
        {'handle': 'opaque-access'},
        {'handle': '', 'provider': _providerMap()},
        {
          'handle': 'opaque-access',
          'provider': _providerMap(),
          'serviceId': 'private',
        },
      ]) {
        wire.reply = (_) => malformed;
        await expectLater(
          wire.resolve(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test('facade rejects mismatched discovery and resolved metadata', () async {
    final wire = _Wire();
    for (final mismatch in <Map<String, Object?>>[
      {'capabilityId': 'test.other'},
      {'majorVersion': 2},
    ]) {
      wire.reply = (_) => [
        {..._providerMap(), ...mismatch},
      ];
      await expectLater(
        wire.consumer.discover('test.capability', 1),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
    for (final mismatch in <Map<String, Object?>>[
      {'capabilityId': 'test.other'},
      {'majorVersion': 2},
      {'serviceId': 'test.other'},
      {'providerId': 'test.other'},
    ]) {
      wire.reply = (_) => {
        'handle': 'opaque-access',
        'provider': {..._providerMap(), ...mismatch},
      };
      await expectLater(
        wire.resolve(providerId: 'test.provider'),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });

  test(
    'invoke strictly validates success and failure envelope shapes',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      final failure = _failure(null)['error']! as Map<String, Object?>;
      for (final malformed in <Object?>[
        null,
        [],
        {'ok': true},
        {'ok': true, 'value': null, 'extra': 1},
        {'ok': 'true', 'value': null},
        {'ok': false, 'value': null},
        {'ok': false, 'error': 'private'},
        {
          'ok': false,
          'error': {...failure}..remove('declaredFailureType'),
        },
        {
          'ok': false,
          'error': {...failure}..remove('details'),
        },
        {
          'ok': false,
          'error': {...failure, 'details': null},
        },
        {
          'ok': false,
          'error': {...failure, 'declaredFailureType': 1},
        },
        {
          'ok': false,
          'error': {...failure, 'code': 1},
        },
        {
          'ok': false,
          'error': {...failure, 'message': null},
        },
        {
          'ok': false,
          'error': {...failure, 'stack': 'private'},
        },
      ]) {
        wire.reply = (_) => malformed;
        await expectLater(
          access.requestChannel.request('read', {}),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'structured responses and preflight reject unsafe or unbounded data',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      Object? deep;
      for (var i = 0; i < 65; i++) {
        deep = [deep];
      }
      Object? expanded = [null];
      for (var i = 0; i < 17; i++) {
        expanded = [expanded, expanded];
      }
      for (final malformed in <Object?>[
        Object(),
        double.nan,
        double.infinity,
        {1: 'not a string key'},
        cyclic,
        deep,
        expanded,
      ]) {
        wire.reply = (_) => {'ok': true, 'value': malformed};
        await expectLater(
          access.requestChannel.request('read', {}),
          throwsA(isA<AdeleProtocolException>()),
        );
        final sentBefore = wire.sent.length;
        await expectLater(
          access.requestChannel.request('read', {'value': malformed}),
          throwsA(isA<AdeleProtocolException>()),
        );
        expect(wire.sent, hasLength(sentBefore));
      }
      wire.reply = (_) =>
          List<Object?>.filled(adelePluginBackendJsonMaxNodes, null);
      await expectLater(
        wire.consumer.discover('test.capability', 1),
        throwsA(isA<AdeleProtocolException>()),
      );
    },
  );

  test(
    'shared acyclic values are accepted and request data is snapshotted',
    () async {
      final wire = _Wire();
      final access = (await wire.resolve())!;
      final shared = <Object?>['before'];
      final payload = <String, Object?>{'first': shared, 'second': shared};
      final pending = access.requestChannel.request('read', payload);
      shared[0] = 'after';
      await pending;
      expect((wire.sent.last['payload']! as Map)['payload'], {
        'first': ['before'],
        'second': ['before'],
      });
      wire.broker.result = {'ok': true, 'value': payload};
      expect(await access.requestChannel.request('read', {}), payload);
    },
  );
}

Map<String, Object?> _providerMap() => {
  'capabilityId': 'test.capability',
  'majorVersion': 1,
  'providerId': 'test.provider',
  'pluginId': 'test.plugin',
  'displayName': 'Test provider',
  'serviceId': 'test.service',
};

Map<String, Object?> _failure(String? type) => {
  'ok': false,
  'error': {
    'declaredFailureType': type,
    'code': 'not_found',
    'message': 'Not found',
    'details': {
      'path': 'example',
      'nested': [null, 1, true],
    },
  },
};

final class _Wire {
  _Wire() {
    dispatcher = BackendCapabilityConsumerServiceDispatcher(
      broker,
      concurrent: true,
    );
    host = AdeleHostRequestMultiplexer(
      send: (message) {
        sent.add(message);
        if (reply != null) {
          host.handleResponse({
            'kind': 'hostResponse',
            'requestId': message['requestId'],
            'ok': true,
            'payload': reply!(message),
          });
          return;
        }
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
    consumer = AdeleCapabilityConsumer(
      hostRequests: host,
      hostInfrastructureContext: 'consumer-generation',
    );
    addTearDown(() async {
      host.close();
      await dispatcher.close();
    });
  }

  final broker = _Broker();
  final sent = <Map<String, Object?>>[];
  late final BackendCapabilityConsumerServiceDispatcher dispatcher;
  late final AdeleHostRequestMultiplexer host;
  late final AdeleCapabilityConsumer consumer;
  Object? Function(Map<String, Object?>)? reply;

  Future<AdeleResolvedCapability?> resolve({String? providerId}) =>
      consumer.resolve(
        'test.capability',
        1,
        expectedServiceId: 'test.service',
        providerId: providerId,
      );
}

final class _Broker implements BackendCapabilityConsumerService {
  List<BackendCapabilityProvider> providers = [
    BackendCapabilityProvider(
      capabilityId: 'test.capability',
      majorVersion: 1,
      providerId: 'test.provider',
      pluginId: 'test.plugin',
      displayName: 'Test provider',
      serviceId: 'test.service',
    ),
  ];
  late BackendCapabilityAccess? access = BackendCapabilityAccess(
    handle: 'opaque-access',
    provider: providers.single,
  );
  Map<String, Object?> result = {'ok': true, 'value': null};
  Completer<Map<String, Object?>>? invocation;
  Completer<void>? releasing;
  final invoked = Completer<void>();
  int releaseCalls = 0;
  int calls = 0;

  @override
  Future<List<BackendCapabilityProvider>> discover(
    String capabilityId,
    int majorVersion,
  ) async {
    calls++;
    return providers;
  }

  @override
  Future<BackendCapabilityAccess?> resolve(
    String capabilityId,
    int majorVersion,
    String expectedServiceId,
    String? providerId,
  ) async {
    calls++;
    return access;
  }

  @override
  Future<Map<String, Object?>> invoke(
    String handle,
    String method,
    Map<String, Object?> payload,
  ) async {
    calls++;
    if (!invoked.isCompleted) invoked.complete();
    return invocation == null ? result : await invocation!.future;
  }

  @override
  Future<void> release(String handle) async {
    calls++;
    releaseCalls++;
    await releasing?.future;
  }
}

/// Local mock of the generated native client's declared-failure catch boundary.
/// No semantic contract dependency belongs in this generic public package.
final class _SemanticClient {
  const _SemanticClient(this.channel);
  final AdeleRequestChannel channel;

  Future<Object?> read() async {
    try {
      return await channel.request('test.service.read', {});
    } on AdeleRemoteFailure catch (error) {
      switch (error.declaredFailureType) {
        case 'test.declaredFailure':
          throw _DeclaredFailure(error.code, error.message, error.details);
        default:
          rethrow;
      }
    }
  }
}

final class _DeclaredFailure implements Exception {
  const _DeclaredFailure(this.code, this.message, this.details);
  final String code;
  final String message;
  final Map<String, Object?> details;
}
