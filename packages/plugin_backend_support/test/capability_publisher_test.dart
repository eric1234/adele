import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

const _handle = '0123456789abcdef0123456789abcdef-0000000000000000';
const _next = '0123456789abcdef0123456789abcdef-0000000000000001';
const _private = 'private-route-or-native-diagnostic';

void main() {
  late List<Map<String, Object?>> sent;
  late AdeleHostRequestMultiplexer transport;
  late AdeleCapabilityPublisher publisher;
  setUp(() {
    sent = [];
    transport = AdeleHostRequestMultiplexer(send: sent.add);
    publisher = AdeleCapabilityPublisher(
      hostRequests: transport,
      hostInfrastructureContext: 'exact-generation',
    );
  });
  tearDown(() => transport.close());

  void reply(Object? payload) => transport.handleResponse({
    'kind': 'hostResponse',
    'requestId': sent.last['requestId'],
    'ok': true,
    'payload': payload,
  });

  Future<AdelePublishedCapabilityGroup> publish() async {
    final pending = publisher.publish([_exposure()]);
    reply({'group': _handle});
    return pending;
  }

  test(
    'adoption and publication bind only the exact infrastructure service',
    () async {
      for (final adopt in [true, false]) {
        final exposures = [_exposure()];
        final pending = adopt
            ? publisher.adoptAdvertised(exposures)
            : publisher.publish(exposures);
        exposures.clear();
        expect(sent.last, {
          'kind': 'hostRequest',
          'requestId': adopt ? 0 : 1,
          'hostContextKind': 'infrastructure',
          'hostContext': 'exact-generation',
          'serviceId': backendCapabilityPublicationServiceId,
          'method': adopt ? 'adoptAdvertised' : 'publish',
          'payload': {
            'exposures': [_exposure().toMap()],
          },
        });
        reply({'group': _handle});
        expect((await pending).isRetired, isFalse);
      }
    },
  );

  test(
    'replacement returns a fresh incarnation; old cleanup cannot retire it',
    () async {
      final old = await publish();
      final replacing = old.replace([_exposure(context: 'new-route')]);
      expect((sent.last['payload'] as Map)['group'], _handle);
      reply({'group': _next});
      final current = await replacing;
      expect(old.isRetired, isTrue);
      expect(current.isRetired, isFalse);
      expect(identical(old, current), isFalse);
      await old.retire();
      expect(sent, hasLength(2));
      await expectLater(
        old.replace([_exposure()]),
        throwsA(_failure('staleGroup')),
      );
      final retiring = current.retire();
      expect(identical(current.retire(), retiring), isTrue);
      expect(sent.last['payload'], {'group': _next});
      await expectLater(
        current.replace([_exposure()]),
        throwsA(_failure('staleGroup')),
      );
      reply({'retired': true});
      await retiring;
      expect(current.isRetired, isTrue);
      await current.retire();
      expect(sent, hasLength(3));
    },
  );

  test(
    'rejected candidate preserves old handle; post-retirement failure does not',
    () async {
      final group = await publish();
      for (final kind in ['rejected', 'replacementUnavailable']) {
        final pending = group.replace([_exposure(context: 'candidate')]);
        final check = expectLater(pending, throwsA(_failure(kind)));
        reply({'failure': kind});
        await check;
        expect(group.isRetired, kind == 'replacementUnavailable');
      }
      await group.retire();
      expect(sent, hasLength(3));
    },
  );

  test(
    'unknown replacement outcome is not confirmation of old retirement',
    () async {
      final group = await publish();
      final pending = group.replace([_exposure()]);
      final check = expectLater(pending, throwsA(_failure('outcomeUnknown')));
      reply({'group': _private, 'extra': _private});
      await check;
      expect(group.isRetired, isFalse);
    },
  );

  test('stale exact incarnation retirement is safe repeated cleanup', () async {
    final group = await publish();
    final pending = group.retire();
    reply({'failure': 'staleGroup'});
    await pending;
    expect(group.isRetired, isTrue);
    await group.retire();
    expect(sent, hasLength(2));
  });

  test('retirement capacity refusal permits an explicit retry', () async {
    final group = await publish();
    final first = group.retire();
    final check = expectLater(first, throwsA(_failure('capacityExceeded')));
    reply({'failure': 'capacityExceeded'});
    await check;
    expect(group.isRetired, isFalse);
    expect(sent, hasLength(2));
    final retry = group.retire();
    expect(identical(first, retry), isFalse);
    expect(sent, hasLength(3));
    reply({'retired': true});
    await retry;
    expect(group.isRetired, isTrue);
  });

  test(
    'retirement cleanup failure records fencing without hiding failure',
    () async {
      final group = await publish();
      final pending = group.retire();
      final check = expectLater(
        pending,
        throwsA(_failure('replacementUnavailable')),
      );
      reply({'failure': 'replacementUnavailable'});
      await check;
      expect(group.isRetired, isTrue);
      expect(identical(group.retire(), pending), isTrue);
    },
  );

  test(
    'strict bounded grammar rejects selectors and malformed exposures locally',
    () async {
      for (final value in <Object?>[
        null,
        [],
        {},
        _private,
        [for (var i = 0; i < 65; i++) _exposure().toMap()],
        for (final key in ['pluginId', 'generation', 'credential', 'group'])
          [
            {..._exposure().toMap(), key: _private},
          ],
        [
          {..._exposure().toMap(), 'capabilityMajorVersion': 0},
        ],
        [
          {..._exposure().toMap(), 'serviceId': 'invalid service'},
        ],
        [
          {..._exposure().toMap(), 'displayName': 'x' * 1025},
        ],
        [
          {
            ..._exposure().toMap(),
            'rank': {'secret': _private},
          },
        ],
        [
          {
            ..._exposure().toMap(),
            'association': {'providerId': _private},
          },
        ],
        [
          {
            ..._exposure().toMap(),
            'environmentHostServices': ['read', 'read', 'read'],
          },
        ],
      ]) {
        expect(
          () => adeleDecodeCapabilityPublication(value),
          throwsA(_failure('invalidRequest')),
        );
      }
      await expectLater(
        publisher.publish([]),
        throwsA(_failure('invalidRequest')),
      );
      expect(sent, isEmpty);
      final values = [_exposure().toMap()];
      final decoded = adeleDecodeCapabilityPublication(values);
      values.single.clear();
      values.clear();
      expect(decoded.single.providerId, 'test.provider');
      expect(decoded.clear, throwsUnsupportedError);
    },
  );

  test(
    'failure results and malformed replies expose no untrusted values',
    () async {
      for (final kind in AdeleCapabilityPublicationFailureKind.values) {
        final pending = publisher.publish([_exposure()]);
        final check = expectLater(pending, throwsA(_failure(kind.name)));
        reply({'failure': kind.name});
        await check;
      }
      for (final value in <Object?>[
        null,
        [],
        {},
        _private,
        {'group': _private},
        {'group': _handle, 'extra': _private},
        {'failure': _private},
        {'failure': 'rejected', 'message': _private},
      ]) {
        final pending = publisher.publish([_exposure()]);
        final check = expectLater(pending, throwsA(_failure('outcomeUnknown')));
        reply(value);
        await check;
      }
    },
  );

  test(
    'transport retirement and exceptions are bounded without original cause',
    () async {
      for (final entry in {
        'host_infrastructure_unavailable': 'generationUnavailable',
        'service_unavailable': 'notAuthorized',
        _private: 'outcomeUnknown',
      }.entries) {
        final pending = publisher.publish([_exposure()]);
        final check = expectLater(pending, throwsA(_failure(entry.value)));
        transport.handleResponse({
          'kind': 'hostResponse',
          'requestId': sent.last['requestId'],
          'ok': false,
          'error': {
            'code': entry.key,
            'message': _private,
            'details': {'private': _private},
          },
        });
        await check;
      }
      final pending = publisher.publish([_exposure()]);
      final check = expectLater(pending, throwsA(_failure('outcomeUnknown')));
      transport.close();
      await check;
    },
  );
}

AdeleCapabilityExposure _exposure({String context = 'original-route'}) =>
    AdeleCapabilityExposure(
      providerId: 'test.provider',
      capabilityId: 'test.capability',
      capabilityMajorVersion: 1,
      serviceId: 'test.service',
      displayName: 'Provider',
      configurationContext: context,
    );

Matcher _failure(String name) => isA<AdeleCapabilityPublicationFailure>()
    .having((e) => e.kind.name, 'kind', name)
    .having(
      (e) => e.toString(),
      'bounded diagnostic',
      'Capability publication failed ($name).',
    );
