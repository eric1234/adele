import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/capability_access_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _capabilityId = 'dev.adele.test.probe';
const _serviceId = 'test.probe';
const _alpha = 'dev.adele.test.alpha';
const _beta = 'dev.adele.test.beta';
const _zulu = 'dev.adele.test.zulu';
final _capability = CapabilityKey(
  id: CapabilityId(_capabilityId),
  majorVersion: 1,
);

void main() {
  late CapabilityRegistry registry;
  late CapabilityAccessBridge bridge;

  setUp(() {
    registry = CapabilityRegistry();
    bridge = _bridge(registry);
  });

  test(
    'discovery and default retain registry rank and provider-ID order',
    () async {
      final zulu = _RecordingChannel(_zulu);
      final beta = _RecordingChannel(_beta);
      final alpha = _RecordingChannel(_alpha);
      _register(registry, _zulu, zulu, rank: 10);
      _register(registry, _beta, beta, rank: 20);
      _register(registry, _alpha, alpha, rank: 20);

      final expected = [_alpha, _beta, _zulu];
      expect(
        registry.providersFor(_capability).map((provider) => provider.id.value),
        expected,
      );
      expect(bridge.discover(_capabilityId, 1), [
        for (final id in expected)
          {
            'providerId': id,
            'pluginId': 'dev.adele.test.provider',
            'displayName': id,
            'serviceId': _serviceId,
          },
      ]);
      expect(registry.resolve(_capability).provider.id.value, _alpha);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      expect(await bridge.request(handle, 'read', {}), {'provider': _alpha});
      expect(alpha.requests, hasLength(1));
      expect(beta.requests, isEmpty);
      expect(zulu.requests, isEmpty);
    },
  );

  test(
    'explicit resolution selects that provider and never falls back',
    () async {
      final alpha = _RecordingChannel(_alpha);
      final beta = _RecordingChannel(_beta);
      _register(registry, _alpha, alpha, rank: 20);
      _register(registry, _beta, beta);

      final handle = bridge.resolve(_capabilityId, 1, _serviceId, _beta)!;
      expect(await bridge.request(handle, 'read', {}), {'provider': _beta});
      expect(
        bridge.resolve(_capabilityId, 1, _serviceId, 'dev.adele.test.missing'),
        isNull,
      );
      beta.available = false;
      expect(bridge.resolve(_capabilityId, 1, _serviceId, _beta), isNull);
      await expectLater(
        bridge.request(handle, 'read', {}),
        throwsA(isA<ProviderEndpointUnavailable>()),
      );
      expect(alpha.requests, isEmpty);
      expect(beta.requests, hasLength(1));
    },
  );

  test('missing providers are empty, but missing registry and grants deny', () {
    expect(bridge.discover(_capabilityId, 1), isEmpty);
    expect(bridge.resolve(_capabilityId, 1, _serviceId, null), isNull);

    final channel = _RecordingChannel(_alpha);
    _register(registry, _alpha, channel);
    for (final denied in [
      _bridge(null),
      _bridge(registry, capabilities: []),
      _bridge(registry, isActive: () => false),
    ]) {
      expect(denied.discover(_capabilityId, 1), isNull);
      expect(denied.resolve(_capabilityId, 1, _serviceId, null), isNull);
      expect(denied.resolve(_capabilityId, 1, _serviceId, _alpha), isNull);
    }
    expect(channel.requests, isEmpty);
    expect(channel.streams, isEmpty);
  });

  test('grants are an immutable snapshot of exact capability-major pairs', () {
    final grants = [_capability];
    final scoped = _bridge(registry, capabilities: grants);
    grants.clear();
    final other = CapabilityKey(
      id: CapabilityId('dev.adele.test.other'),
      majorVersion: 1,
    );
    grants.add(other);
    _register(registry, _alpha, _RecordingChannel(_alpha));
    _register(registry, _beta, _RecordingChannel(_beta), capability: other);

    expect(scoped.discover(_capabilityId, 1), hasLength(1));
    expect(scoped.discover(_capabilityId, 2), isNull);
    expect(scoped.resolve(_capabilityId, 2, _serviceId, _alpha), isNull);
    expect(scoped.discover(other.id.value, 1), isNull);
    expect(scoped.resolve(other.id.value, 1, _serviceId, _beta), isNull);

    final wrongMajor = _bridge(
      registry,
      capabilities: [CapabilityKey(id: _capability.id, majorVersion: 2)],
    );
    expect(wrongMajor.discover(_capabilityId, 2), isEmpty);
    expect(wrongMajor.resolve(_capabilityId, 2, _serviceId, null), isNull);
    expect(wrongMajor.resolve(_capabilityId, 2, _serviceId, _alpha), isNull);
  });

  test(
    'service mismatch and private service never become selectable routes',
    () async {
      final channel = _RecordingChannel(_alpha);
      _register(registry, _alpha, channel);
      for (final service in ['', 'test.wrong', 'test.private']) {
        expect(bridge.resolve(_capabilityId, 1, service, null), isNull);
        expect(bridge.resolve(_capabilityId, 1, service, _alpha), isNull);
        await expectLater(
          bridge.request(service, 'read', {}),
          throwsStateError,
        );
      }
      expect(channel.requests, isEmpty);
      expect(channel.streams, isEmpty);
    },
  );

  test('malformed selectors deny without consuming handle capacity', () {
    _register(registry, _alpha, _RecordingChannel(_alpha));
    for (
      var attempt = 0;
      attempt <= CapabilityAccessBridge.maxHandles;
      attempt++
    ) {
      expect(bridge.discover('invalid_id', 1), isNull);
      expect(bridge.discover(_capabilityId, 0), isNull);
      expect(bridge.resolve('invalid_id', 1, _serviceId, null), isNull);
      expect(bridge.resolve(_capabilityId, 0, _serviceId, null), isNull);
      expect(
        bridge.resolve(_capabilityId, 1, _serviceId, 'invalid_id'),
        isNull,
      );
      expect(bridge.resolve(_capabilityId, 1, 'test.private', null), isNull);
    }
    expect(bridge.resolve(_capabilityId, 1, _serviceId, null), isNotNull);
  });

  test('opaque handles cannot cross two otherwise identical scopes', () async {
    final channel = _RecordingChannel(_alpha);
    _register(registry, _alpha, channel);
    final sibling = _bridge(registry);
    final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
    final otherHandle = sibling.resolve(_capabilityId, 1, _serviceId, null)!;
    expect(otherHandle, isNot(handle));

    for (final (scope, foreign) in [(bridge, otherHandle), (sibling, handle)]) {
      expect(scope.release(foreign), isFalse);
      await expectLater(scope.request(foreign, 'read', {}), throwsStateError);
      await expectLater(
        scope.stream(foreign, 'watch', {}),
        emitsInOrder([emitsError(isA<StateError>()), emitsDone]),
      );
    }
    expect(channel.requests, isEmpty);
    expect(channel.streams, isEmpty);
    expect(await bridge.request(handle, 'read', {}), {'provider': _alpha});
    expect(await sibling.request(otherHandle, 'read', {}), {
      'provider': _alpha,
    });
  });

  test(
    'payload route fields stay data and cannot switch captured provider',
    () async {
      final alpha = _RecordingChannel(_alpha);
      final beta = _RecordingChannel(_beta);
      _register(registry, _alpha, alpha);
      _register(registry, _beta, beta);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, _alpha)!;
      final otherHandle = bridge.resolve(_capabilityId, 1, _serviceId, _beta)!;
      final spoof = <String, Object?>{
        'providerId': _beta,
        'pluginId': 'dev.adele.test.foreign',
        'configurationContext': 'foreign-context',
        'serviceId': 'test.private',
        'handle': otherHandle,
        'hostInvocationContext': 'not-authority',
      };

      expect(await bridge.request(handle, 'read', spoof), {'provider': _alpha});
      final subscription = bridge.stream(handle, 'watch', spoof).listen((_) {});
      addTearDown(subscription.cancel);
      expect(alpha.requests.single.method, 'read');
      expect(alpha.requests.single.payload, spoof);
      expect(alpha.streams.single.method, 'watch');
      expect(alpha.streams.single.payload, spoof);
      expect(beta.requests, isEmpty);
      expect(beta.streams, isEmpty);
      await subscription.cancel();
    },
  );

  test(
    'retired handles stay stale after same-ID replacement; sibling works',
    () async {
      final alpha = _RecordingChannel('alpha-original');
      final beta = _RecordingChannel(_beta);
      final registration = _register(registry, _alpha, alpha, rank: 20);
      _register(registry, _beta, beta);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, _alpha)!;
      final sibling = bridge.resolve(_capabilityId, 1, _serviceId, _beta)!;
      expect(await bridge.request(handle, 'read', {}), {
        'provider': 'alpha-original',
      });
      await registration.close();
      expect(alpha.available, isTrue);
      expect(bridge.resolve(_capabilityId, 1, _serviceId, _alpha), isNull);

      final replacement = _RecordingChannel('alpha-replacement');
      _register(registry, _alpha, replacement, rank: 20);
      await expectLater(
        bridge.request(handle, 'read', {}),
        throwsA(
          isA<ProviderUnavailable>().having(
            (error) => error.stale,
            'stale',
            isTrue,
          ),
        ),
      );
      await expectLater(
        bridge.stream(handle, 'watch', {}),
        emitsInOrder([emitsError(isA<ProviderUnavailable>()), emitsDone]),
      );
      expect(await bridge.request(sibling, 'read', {}), {'provider': _beta});
      expect(alpha.requests, hasLength(1));
      expect(alpha.streams, isEmpty);
      expect(replacement.requests, isEmpty);
      expect(replacement.streams, isEmpty);
      final fresh = bridge.resolve(_capabilityId, 1, _serviceId, _alpha)!;
      expect(fresh, isNot(handle));
      expect(await bridge.request(fresh, 'read', {}), {
        'provider': 'alpha-replacement',
      });
      await registration.close();
      expect(await bridge.request(fresh, 'read', {}), {
        'provider': 'alpha-replacement',
      });
    },
  );

  test(
    'admitted unary survives registration-only retirement without migration',
    () async {
      final held = Completer<Object?>();
      final original = _RecordingChannel('original')..heldRead = held;
      final registration = _register(registry, _alpha, original);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, _alpha)!;
      final result = bridge.request(handle, 'read', {'input': 'held'});
      expect(original.requests, hasLength(1));
      await registration.close();
      final replacement = _RecordingChannel('replacement');
      _register(registry, _alpha, replacement);
      held.complete({'provider': 'original', 'result': 'admitted'});

      expect(await result, {'provider': 'original', 'result': 'admitted'});
      await expectLater(
        bridge.request(handle, 'read', {}),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(original.available, isTrue);
      expect(original.requests, hasLength(1));
      expect(replacement.requests, isEmpty);
    },
  );

  test(
    'endpoint termination fails admitted work and new calls, not sibling',
    () async {
      final held = Completer<Object?>();
      final alpha = _RecordingChannel(_alpha)..heldRead = held;
      final beta = _RecordingChannel(_beta);
      final registration = _register(registry, _alpha, alpha, rank: 20);
      _register(registry, _beta, beta);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, _alpha)!;
      final sibling = bridge.resolve(_capabilityId, 1, _serviceId, _beta)!;
      final failure = StateError('Synthetic endpoint terminated.');
      final unaryCheck = expectLater(
        bridge.request(handle, 'read', {}),
        throwsA(same(failure)),
      );
      final streamCheck = expectLater(
        bridge.stream(handle, 'watch', {}),
        emitsInOrder([
          emitsError(anyOf(same(failure), isA<ProviderEndpointUnavailable>())),
          emitsDone,
        ]),
      );
      alpha.terminate(failure);
      await unaryCheck;
      await streamCheck;

      expect(registration.isClosed, isFalse);
      expect(alpha.streams.single.cancels, 1);
      expect(bridge.discover(_capabilityId, 1)!.map((p) => p['providerId']), [
        _beta,
      ]);
      expect(bridge.resolve(_capabilityId, 1, _serviceId, _alpha), isNull);
      await expectLater(
        bridge.request(handle, 'read', {}),
        throwsA(isA<ProviderEndpointUnavailable>()),
      );
      expect(await bridge.request(sibling, 'read', {}), {'provider': _beta});
      expect(alpha.requests, hasLength(1));
    },
  );

  for (final observeAtSettlement in [false, true]) {
    test(
      'false scope permanently fences late unary and admission (settlement=$observeAtSettlement)',
      () async {
        var active = true;
        final scoped = _bridge(registry, isActive: () => active);
        final held = Completer<Object?>();
        final channel = _RecordingChannel(_alpha)..heldRead = held;
        _register(registry, _alpha, channel);
        final handle = scoped.resolve(_capabilityId, 1, _serviceId, null)!;
        final check = expectLater(
          scoped.request(handle, 'read', {}),
          throwsStateError,
        );
        active = false;
        if (!observeAtSettlement) {
          expect(scoped.discover(_capabilityId, 1), isNull);
          active = true;
        }
        held.complete({'provider': _alpha, 'secret': 'late'});
        await check;
        active = true;

        expect(scoped.isActive, isFalse);
        expect(scoped.discover(_capabilityId, 1), isNull);
        expect(scoped.resolve(_capabilityId, 1, _serviceId, _alpha), isNull);
        await expectLater(scoped.request(handle, 'read', {}), throwsStateError);
        await expectLater(
          scoped.stream(handle, 'watch', {}),
          emitsInOrder([emitsError(isA<StateError>()), emitsDone]),
        );
        expect(channel.requests, hasLength(1));
        expect(channel.streams, isEmpty);
      },
    );
  }

  test(
    'release retires only that handle, cancels streams and rejects late unary',
    () async {
      final held = Completer<Object?>();
      final channel = _RecordingChannel(_alpha)..heldRead = held;
      _register(registry, _alpha, channel);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      final sibling = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      final unaryCheck = expectLater(
        bridge.request(handle, 'read', {}),
        throwsStateError,
      );
      final values = <Object?>[];
      final done = Completer<void>();
      final subscription = bridge
          .stream(handle, 'watch', {})
          .listen(values.add, onDone: done.complete);
      addTearDown(subscription.cancel);

      expect(bridge.release(handle), isTrue);
      expect(channel.streams.single.cancels, 1);
      expect(bridge.release(handle), isFalse);
      channel.streams.single.events.add({'late': true});
      held.complete({'late': true});
      await unaryCheck;
      await done.future;
      expect(values, isEmpty);
      await expectLater(bridge.request(handle, 'read', {}), throwsStateError);
      channel.heldRead = null;
      expect(await bridge.request(sibling, 'read', {}), {'provider': _alpha});
      expect(bridge.discover(_capabilityId, 1), hasLength(1));
      expect(channel.available, isTrue);
    },
  );

  test(
    'handle table is bounded per scope and release recovers one slot',
    () async {
      final channel = _RecordingChannel(_alpha);
      _register(registry, _alpha, channel);
      expect(CapabilityAccessBridge.maxHandles, 64);
      final handles = [
        for (var i = 0; i < CapabilityAccessBridge.maxHandles; i++)
          bridge.resolve(_capabilityId, 1, _serviceId, null)!,
      ];
      expect(handles.toSet(), hasLength(CapabilityAccessBridge.maxHandles));
      expect(bridge.resolve(_capabilityId, 1, _serviceId, null), isNull);
      expect(bridge.discover(_capabilityId, 1), hasLength(1));
      final sibling = _bridge(registry);
      expect(sibling.resolve(_capabilityId, 1, _serviceId, null), isNotNull);
      expect(bridge.release('unknown'), isFalse);
      expect(bridge.resolve(_capabilityId, 1, _serviceId, null), isNull);

      expect(bridge.release(handles.first), isTrue);
      final fresh = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      expect(handles, isNot(contains(fresh)));
      expect(bridge.resolve(_capabilityId, 1, _serviceId, null), isNull);
      await expectLater(
        bridge.request(handles.first, 'read', {}),
        throwsStateError,
      );
      expect(await bridge.request(handles.last, 'read', {}), {
        'provider': _alpha,
      });
      expect(await bridge.request(fresh, 'read', {}), {'provider': _alpha});
    },
  );

  test(
    'stream opens on listen and forwards pause, resume and cancellation',
    () async {
      final channel = _RecordingChannel(_alpha);
      _register(registry, _alpha, channel);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      final stream = bridge.stream(handle, 'watch', {'input': 'stream'});
      expect(channel.streams, isEmpty);
      final values = <Object?>[];
      final subscription = stream.listen(values.add);
      addTearDown(subscription.cancel);
      final observation = channel.streams.single;
      expect(observation.method, 'watch');
      expect(observation.payload, {'input': 'stream'});
      observation.events.add({'sequence': 1});
      expect(values, [
        {'sequence': 1},
      ]);

      subscription.pause();
      expect(observation.events.isPaused, isTrue);
      expect(observation.pauses, 1);
      observation.events.add({'sequence': 2});
      await Future<void>.delayed(Duration.zero);
      expect(values, [
        {'sequence': 1},
      ]);
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(observation.resumes, 1);
      expect(values, [
        {'sequence': 1},
        {'sequence': 2},
      ]);
      await subscription.cancel();
      expect(observation.cancels, 1);
      expect(observation.events.hasListener, isFalse);
      observation.events.add({'sequence': 3});
      await Future<void>.delayed(Duration.zero);
      expect(values, [
        {'sequence': 1},
        {'sequence': 2},
      ]);
      expect(channel.requests, isEmpty);
    },
  );

  for (final retire in ['registration', 'handle', 'presentation']) {
    test('unlistened stream cannot admit after $retire retirement', () async {
      final channel = _RecordingChannel(_alpha);
      final registration = _register(registry, _alpha, channel);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      final stream = bridge.stream(handle, 'watch', {});
      expect(channel.streams, isEmpty);
      switch (retire) {
        case 'registration':
          await registration.close();
        case 'handle':
          bridge.release(handle);
        case 'presentation':
          bridge.invalidate();
      }
      await expectLater(
        stream,
        emitsInOrder([
          emitsError(
            retire == 'registration'
                ? isA<ProviderUnavailable>()
                : isA<StateError>(),
          ),
          emitsDone,
        ]),
      );
      expect(channel.streams, isEmpty);
    });
  }

  for (final paused in [false, true]) {
    test(
      'registration retirement immediately cancels ${paused ? 'paused' : 'idle'} stream without publication or migration',
      () async {
        final cleanup = Completer<void>();
        final channel = _RecordingChannel(
          _alpha,
          onCancel: () => cleanup.future,
        );
        final registration = _register(registry, _alpha, channel);
        final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
        final values = <Object?>[];
        final errors = <Object>[];
        final done = Completer<void>();
        final subscription = bridge
            .stream(handle, 'watch', {})
            .listen(values.add, onError: errors.add, onDone: done.complete);
        addTearDown(subscription.cancel);
        final observation = channel.streams.single;
        if (paused) {
          subscription.pause();
          observation.events.add({'queued': true});
        }
        final closing = registration.close();
        expect(observation.cancels, 1);
        expect(observation.events.hasListener, isFalse);
        await closing;
        expect(cleanup.isCompleted, isFalse);
        final replacement = _RecordingChannel('replacement');
        _register(registry, _alpha, replacement);
        observation.events.add({'late': true});
        if (paused) subscription.resume();
        cleanup.complete();
        await done.future;
        expect(values, isEmpty);
        expect(errors, isEmpty);
        expect(replacement.streams, isEmpty);
        expect(channel.streams, hasLength(1));
        expect(observation.cancels, 1);
        expect(channel.available, isTrue);
        // Registration retirement is not endpoint termination or presentation release.
        expect(bridge.isActive, isTrue);
        final fresh = bridge.resolve(_capabilityId, 1, _serviceId, _alpha)!;
        expect(await bridge.request(fresh, 'read', {}), {
          'provider': 'replacement',
        });
      },
    );
  }

  test(
    'registration retirement inside onData cancels before deferred done',
    () async {
      final channel = _RecordingChannel(_alpha);
      final registration = _register(registry, _alpha, channel);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      final values = <Object?>[];
      final done = Completer<void>();
      Future<void>? closing;
      final subscription = bridge.stream(handle, 'watch', {}).listen((value) {
        values.add(value);
        closing = registration.close();
        expect(channel.streams.single.cancels, 1);
      }, onDone: done.complete);
      addTearDown(subscription.cancel);
      channel.streams.single.events.add({'sequence': 1});
      channel.streams.single.events.add({'sequence': 2});
      await closing;
      await done.future;
      expect(values, [
        {'sequence': 1},
      ]);
      expect(channel.streams.single.cancels, 1);
    },
  );

  test(
    'scope callback revocation cancels paused stream and cannot revive',
    () async {
      var active = true;
      final scoped = _bridge(registry, isActive: () => active);
      final channel = _RecordingChannel(_alpha);
      _register(registry, _alpha, channel);
      final handle = scoped.resolve(_capabilityId, 1, _serviceId, null)!;
      final values = <Object?>[];
      final done = Completer<void>();
      final subscription = scoped
          .stream(handle, 'watch', {})
          .listen(values.add, onDone: done.complete);
      addTearDown(subscription.cancel);
      subscription.pause();
      channel.streams.single.events.add({'queued': true});
      active = false;
      expect(scoped.discover(_capabilityId, 1), isNull);
      expect(channel.streams.single.cancels, 1);
      active = true;
      subscription.resume();
      await done.future;
      expect(values, isEmpty);
      expect(scoped.isActive, isFalse);
      expect(scoped.resolve(_capabilityId, 1, _serviceId, null), isNull);
    },
  );

  test(
    'frontend invalidation cancels observations and fails late unary only in its scope',
    () async {
      final held = Completer<Object?>();
      final channel = _RecordingChannel(_alpha)..heldRead = held;
      final registration = _register(registry, _alpha, channel);
      final sibling = _bridge(registry);
      final handle = bridge.resolve(_capabilityId, 1, _serviceId, null)!;
      final otherHandle = sibling.resolve(_capabilityId, 1, _serviceId, null)!;
      final check = expectLater(
        bridge.request(handle, 'read', {}),
        throwsStateError,
      );
      final values = <Object?>[];
      final done = Completer<void>();
      final subscription = bridge
          .stream(handle, 'watch', {})
          .listen(values.add, onDone: done.complete);
      addTearDown(subscription.cancel);
      subscription.pause();
      channel.streams.single.events.add({'queued': true});

      bridge.invalidate();
      bridge.invalidate();
      expect(channel.streams.single.cancels, 1);
      channel.streams.single.events.add({'late': true});
      subscription.resume();
      held.complete({'late': true});
      await check;
      await done.future;
      expect(values, isEmpty);
      expect(bridge.release(handle), isFalse);
      expect(bridge.discover(_capabilityId, 1), isNull);
      expect(bridge.resolve(_capabilityId, 1, _serviceId, null), isNull);
      await expectLater(bridge.request(handle, 'read', {}), throwsStateError);
      expect(registration.isClosed, isFalse);
      expect(channel.available, isTrue);
      channel.heldRead = null;
      expect(await sibling.request(otherHandle, 'read', {}), {
        'provider': _alpha,
      });
    },
  );
}

CapabilityAccessBridge _bridge(
  CapabilityRegistry? registry, {
  Iterable<CapabilityKey>? capabilities,
  bool Function()? isActive,
}) {
  final bridge = CapabilityAccessBridge(
    registry: registry,
    capabilities: capabilities ?? [_capability],
    isActive: isActive ?? () => true,
  );
  addTearDown(bridge.invalidate);
  return bridge;
}

CapabilityRegistration _register(
  CapabilityRegistry registry,
  String providerId,
  _RecordingChannel channel, {
  CapabilityKey? capability,
  int rank = 0,
}) {
  final registration = registry.register(
    provider: ProviderDescriptor(
      id: ProviderId(providerId),
      capability: capability ?? _capability,
      pluginId: 'dev.adele.test.provider',
      displayName: providerId,
      serviceId: _serviceId,
      rank: rank,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: _serviceId,
      isAvailable: () => channel.available,
    ),
  );
  addTearDown(registration.close);
  return registration;
}

final class _RecordingChannel implements AdeleStreamChannel {
  _RecordingChannel(this.provider, {this.onCancel});

  final String provider;
  final Future<void> Function()? onCancel;
  final requests = <({String method, Map<String, Object?> payload})>[];
  final streams = <_Observation>[];
  bool available = true;
  Completer<Object?>? heldRead;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (!available) throw StateError('Synthetic endpoint is unavailable.');
    requests.add((method: method, payload: payload));
    if (heldRead case final held?) return held.future;
    return {'provider': provider};
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    if (!available) throw StateError('Synthetic endpoint is unavailable.');
    final observation = _Observation(method, payload, onCancel: onCancel);
    streams.add(observation);
    return observation.events.stream;
  }

  void terminate(Object failure) {
    available = false;
    final held = heldRead;
    if (held != null && !held.isCompleted) held.completeError(failure);
    for (final observation in streams) {
      observation.events.addError(failure);
    }
  }
}

final class _Observation {
  _Observation(this.method, this.payload, {Future<void> Function()? onCancel}) {
    events = StreamController<Object?>(
      sync: true,
      onPause: () => pauses++,
      onResume: () => resumes++,
      onCancel: () {
        cancels++;
        return onCancel?.call();
      },
    );
    addTearDown(() => unawaited(events.close()));
  }

  final String method;
  final Map<String, Object?> payload;
  late final StreamController<Object?> events;
  int pauses = 0;
  int resumes = 0;
  int cancels = 0;
}
