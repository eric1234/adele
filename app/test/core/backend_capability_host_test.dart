import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/backend_capability_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/capability_consumer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

final _capability = CapabilityKey(
  id: CapabilityId('test.callable'),
  majorVersion: 1,
);
const _service = 'test.provider';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = _Fixture();
    await fixture.start();
  });
  tearDown(() => fixture.close());

  for (final declaration in ['none', 'different ID', 'different major']) {
    test('consumption is denied for $declaration declaration', () async {
      final allowed = switch (declaration) {
        'different ID' => [
          CapabilityKey(id: CapabilityId('test.other'), majorVersion: 1),
        ],
        'different major' => [
          CapabilityKey(id: _capability.id, majorVersion: 2),
        ],
        _ => <CapabilityKey>[],
      };
      final consumer = await fixture.consumer(allowed: allowed);
      await fixture.provider();
      await expectLater(
        consumer.host.discover('test.callable', 1),
        throwsStateError,
      );
      await expectLater(fixture.resolve(consumer.host), throwsStateError);
      expect(consumer.host.retainedHandleCount, 0);
      expect(await fixture.calls(), isEmpty);
    });
  }

  test(
    'discovery and resolution preserve registry rank and ID ordering',
    () async {
      final consumer = await fixture.consumer();
      await fixture.provider(
        exposures: [
          _exposure('test.z', rank: 10),
          _exposure('test.low', rank: -1),
          _exposure('test.a', rank: 10, context: 'configured-a'),
        ],
      );
      final discovered = await consumer.host.discover('test.callable', 1);
      expect(discovered.map((provider) => provider.providerId), [
        'test.a',
        'test.z',
        'test.low',
      ]);
      expect(discovered.first.capabilityId, 'test.callable');
      expect(discovered.first.majorVersion, 1);
      expect(discovered.first.pluginId, 'test.provider-plugin');
      expect(discovered.first.displayName, 'Provider test.a');
      expect(discovered.first.serviceId, _service);
      final selected = (await fixture.resolve(consumer.host))!;
      expect(selected.provider.providerId, 'test.a');
      final explicit = (await fixture.resolve(
        consumer.host,
        providerId: 'test.low',
      ))!;
      expect(explicit.provider.providerId, 'test.low');
      final result = await consumer.host.invoke(
        selected.handle,
        '$_service.echo',
        {
          'value': [1, true, null],
          'pluginId': 'forged',
          'configurationContext': 'forged',
          'serviceId': 'private.route',
          'hostInvocationContext': 'forged',
        },
      );
      expect(result['ok'], isTrue);
      final value = result['value'] as Map;
      expect(value['pluginId'], 'test.provider-plugin');
      expect(value['configurationContext'], 'configured-a');
      expect(value['serviceId'], _service);
      expect(value['hasHostInvocationContext'], isFalse);
      expect((value['payload'] as Map)['hostInvocationContext'], 'forged');
      expect(await fixture.calls(), hasLength(1));
    },
  );

  test(
    'only valid methods in the selected service namespace reach the target',
    () async {
      final consumer = await fixture.consumer();
      final provider = await fixture.provider();
      final access = (await fixture.resolve(consumer.host))!;
      for (final method in [
        'shutdown',
        'terminate',
        'test.foreign.echo',
        '${_service}Extra.echo',
        _service,
      ]) {
        await expectLater(
          consumer.host.invoke(access.handle, method, {}),
          throwsStateError,
          reason: 'Must reject method ${jsonEncode(method)} before forwarding.',
        );
        expect(await fixture.calls(), isEmpty);
      }
      for (final method in ['', '$_service.', '$_service..echo']) {
        await expectLater(
          consumer.host.invoke(access.handle, method, {}),
          throwsFormatException,
          reason: 'Must reject malformed method ${jsonEncode(method)}.',
        );
        expect(await fixture.calls(), isEmpty);
      }
      expect(provider.connection.isClosed, isFalse);
      expect(consumer.host.retainedHandleCount, 1);
      final response = await consumer.host.invoke(
        access.handle,
        '$_service.echo',
        {'value': 'still live'},
      );
      expect(response['ok'], isTrue);
      expect((response['value'] as Map)['payload'], {'value': 'still live'});
      final calls = await fixture.calls();
      expect(calls, hasLength(1));
      expect((calls.single as Map)['method'], '$_service.echo');
    },
  );

  test(
    'missing providers do not activate dependencies or restart consumer',
    () async {
      final consumer = await fixture.consumer();
      expect(await consumer.host.discover('test.callable', 1), isEmpty);
      expect(await fixture.resolve(consumer.host), isNull);
      await fixture.provider(exposures: [_exposure('test.v2', major: 2)]);
      expect(await fixture.resolve(consumer.host), isNull);
      await fixture.provider(
        pluginId: 'test.later',
        exposures: [_exposure('test.late')],
      );
      final access = (await fixture.resolve(consumer.host))!;
      expect(access.provider.providerId, 'test.late');
      expect(consumer.connection.isClosed, isFalse);
      expect(
        await fixture.resolve(consumer.host, providerId: 'test.absent'),
        isNull,
      );
      expect(await fixture.calls(), isEmpty);
      expect(
        (await consumer.host.invoke(access.handle, '$_service.echo', {}))['ok'],
        isTrue,
      );
    },
  );

  test(
    'selected incompatible service fails without trying compatible runner-up',
    () async {
      final consumer = await fixture.consumer();
      await fixture.provider(
        exposures: [
          _exposure(
            'test.incompatible',
            rank: 10,
            service: 'test.other-service',
          ),
          _exposure('test.compatible'),
        ],
      );
      await expectLater(fixture.resolve(consumer.host), throwsStateError);
      await expectLater(
        fixture.resolve(
          consumer.host,
          providerId: 'test.compatible',
          service: 'test.other-service',
        ),
        throwsStateError,
      );
      expect(consumer.host.retainedHandleCount, 0);
      expect(await fixture.calls(), isEmpty);
      expect(
        (await fixture.resolve(
          consumer.host,
          providerId: 'test.compatible',
        ))!.provider.providerId,
        'test.compatible',
      );
    },
  );

  test(
    'self is not a peer and cannot silently select another provider',
    () async {
      final consumer = await fixture.consumer(
        exposures: [_exposure('test.self', rank: 10)],
      );
      await fixture.provider();
      expect(
        (await consumer.host.discover(
          'test.callable',
          1,
        )).map((p) => p.providerId),
        ['test.provider'],
      );
      await expectLater(fixture.resolve(consumer.host), throwsStateError);
      await expectLater(
        fixture.resolve(consumer.host, providerId: 'test.self'),
        throwsStateError,
      );
      expect(await fixture.calls(), isEmpty);
    },
  );

  test(
    'selected native provider is not substituted with an advertised backend',
    () async {
      final consumer = await fixture.consumer();
      await fixture.provider();
      fixture.registry.register(
        provider: _descriptor('test.native', rank: 100),
        endpoint: const _NativeEndpoint(),
      );
      await expectLater(fixture.resolve(consumer.host), throwsStateError);
      expect(
        (await consumer.host.discover(
          'test.callable',
          1,
        )).map((p) => p.providerId),
        ['test.provider'],
      );
      expect(consumer.host.retainedHandleCount, 0);
      expect(await fixture.calls(), isEmpty);
    },
  );

  for (final spoof in ['copied endpoint', 'private route', 'fake context']) {
    test(
      '$spoof and matching PluginId cannot prove registration ownership',
      () async {
        final consumer = await fixture.consumer();
        final provider = await fixture.provider(
          exposures: [
            _exposure('test.original', rank: 100),
            _exposure('test.fallback'),
          ],
        );
        final original = fixture.binding('test.original');
        final endpoint = original.endpointAs<AdeleRequestChannelEndpoint>();
        await provider.retireProvider(original);
        final channel = switch (spoof) {
          'private route' => provider.connection.channelFor(
            provider.connection.configurationContext('configured'),
            'private.route',
          ),
          'fake context' => provider.connection.channelFor(
            provider.connection.configurationContext('invented'),
            _service,
          ),
          _ => endpoint.channel,
        };
        final descriptor = spoof == 'private route'
            ? _descriptor('test.original', rank: 100, service: 'private.route')
            : original.provider;
        fixture.registry.register(
          provider: descriptor,
          endpoint: AdeleRequestChannelEndpoint(
            channel: channel,
            serviceId: descriptor.serviceId,
            isAvailable: () => true,
          ),
        );
        // Even an incorrect same-PluginId owner lookup must not grant access.
        fixture.ownerOverride = (_) => provider;
        expect(
          provider.ownsProvider(fixture.binding('test.original')),
          isFalse,
        );
        expect(
          (await consumer.host.discover(
            'test.callable',
            1,
          )).map((p) => p.providerId),
          ['test.fallback'],
        );
        await expectLater(
          fixture.resolve(consumer.host, service: descriptor.serviceId),
          throwsStateError,
        );
        expect(consumer.host.retainedHandleCount, 0);
        expect(await fixture.calls(), isEmpty);
      },
    );
  }

  test(
    'same-ID provider replacement never retargets a captured handle',
    () async {
      final consumer = await fixture.consumer();
      final oldProvider = await fixture.provider();
      final old = (await fixture.resolve(consumer.host))!;
      fixture.activations.remove(oldProvider);
      await oldProvider.close();
      await fixture.provider(
        exposures: [_exposure('test.provider', context: 'replacement')],
      );
      await expectLater(
        consumer.host.invoke(old.handle, '$_service.echo', {}),
        throwsA(isA<PluginConnectionClosed>()),
      );
      final replacement = (await fixture.resolve(consumer.host))!;
      expect(replacement.handle, isNot(old.handle));
      final result = await consumer.host.invoke(
        replacement.handle,
        '$_service.echo',
        {},
      );
      expect((result['value'] as Map)['configurationContext'], 'replacement');
      expect(await fixture.calls(), hasLength(1));
      await consumer.host.release(old.handle);
      expect(consumer.host.retainedHandleCount, 1);
    },
  );

  test(
    'foreign consumer and same-ID consumer replacement reject old handles',
    () async {
      final consumer = await fixture.consumer();
      final foreign = await fixture.consumer(pluginId: 'test.foreign');
      await fixture.provider();
      final old = (await fixture.resolve(consumer.host))!;
      await expectLater(
        foreign.host.invoke(old.handle, '$_service.echo', {}),
        throwsStateError,
      );
      await expectLater(foreign.host.release(old.handle), throwsStateError);
      await consumer.connection.close();
      expect(consumer.host.retainedHandleCount, 0);
      final replacement = await fixture.consumer();
      await expectLater(
        replacement.host.invoke(old.handle, '$_service.echo', {}),
        throwsStateError,
      );
      await expectLater(
        consumer.host.discover('test.callable', 1),
        throwsStateError,
      );
      final fresh = (await fixture.resolve(replacement.host))!;
      expect(fresh.handle, isNot(old.handle));
      expect(
        (await replacement.host.invoke(
          fresh.handle,
          '$_service.echo',
          {},
        ))['ok'],
        isTrue,
      );
      expect(await fixture.calls(), hasLength(1));
    },
  );

  test(
    'same-connection registration replacement cannot revive an old handle',
    () async {
      final consumer = await fixture.consumer();
      final provider = await fixture.provider();
      final original = fixture.binding('test.provider');
      final old = (await fixture.resolve(consumer.host))!;
      final pending = consumer.host.invoke(old.handle, '$_service.hold', {
        'gate': 'replace-registration',
      });
      await fixture.command('fixture.waitHeld', {
        'gate': 'replace-registration',
      });
      await provider.retireProvider(original);
      await fixture.activate(provider.connection);
      expect(
        original.isSameRegistration(fixture.binding('test.provider')),
        isFalse,
      );
      await expectLater(
        consumer.host.invoke(old.handle, '$_service.echo', {}),
        throwsA(isA<ProviderUnavailable>()),
      );
      final replacement = (await fixture.resolve(consumer.host))!;
      expect(replacement.handle, isNot(old.handle));
      // The old call was admitted, but release must still fence its publication
      // after retirement and replacement of the exact provider registration.
      final rejected = expectLater(pending, throwsStateError);
      await consumer.host.release(old.handle);
      await fixture.command('fixture.finishHeld', {
        'gate': 'replace-registration',
        'failure': true,
      });
      await rejected;
      expect(
        (await consumer.host.invoke(
          replacement.handle,
          '$_service.echo',
          {},
        ))['ok'],
        isTrue,
      );
      expect(await fixture.calls(), hasLength(2));
    },
  );

  test(
    'handle capacity, repeated resolve/release and close bound retention',
    () async {
      final consumer = await fixture.consumer();
      await fixture.provider();
      expect(BackendCapabilityHost.maxHandles, 64);
      final handles = <String>{};
      for (var index = 0; index < BackendCapabilityHost.maxHandles; index++) {
        handles.add((await fixture.resolve(consumer.host))!.handle);
      }
      expect(handles, hasLength(BackendCapabilityHost.maxHandles));
      await expectLater(fixture.resolve(consumer.host), throwsStateError);
      expect(
        consumer.host.retainedHandleCount,
        BackendCapabilityHost.maxHandles,
      );
      for (final handle in handles) {
        await consumer.host.release(handle);
      }
      expect(consumer.host.retainedHandleCount, 0);
      await expectLater(consumer.host.release(handles.first), throwsStateError);
      for (
        var index = 0;
        index < 2 * BackendCapabilityHost.maxHandles;
        index++
      ) {
        final handle = (await fixture.resolve(consumer.host))!.handle;
        expect(handles.add(handle), isTrue);
        await consumer.host.release(handle);
        expect(consumer.host.retainedHandleCount, 0);
      }
      await fixture.resolve(consumer.host);
      consumer.host.close();
      consumer.host.close();
      expect(consumer.host.retainedHandleCount, 0);
      await expectLater(fixture.resolve(consumer.host), throwsStateError);
      expect(await fixture.calls(), isEmpty);
    },
  );

  for (final failure in [false, true]) {
    test(
      'registration retirement fences admission but held ${failure ? 'failure' : 'success'} settles',
      () async {
        final consumer = await fixture.consumer();
        final provider = await fixture.provider();
        final access = (await fixture.resolve(consumer.host))!;
        final pending = consumer.host.invoke(access.handle, '$_service.hold', {
          'gate': 'retire',
        });
        await fixture.command('fixture.waitHeld', {'gate': 'retire'});
        await provider.retireProvider(fixture.binding('test.provider'));
        await expectLater(
          consumer.host.invoke(access.handle, '$_service.echo', {}),
          throwsA(isA<ProviderUnavailable>()),
        );
        expect(await fixture.resolve(consumer.host), isNull);
        expect(consumer.host.retainedHandleCount, 1);
        await fixture.command('fixture.finishHeld', {
          'gate': 'retire',
          'failure': failure,
        });
        final result = await pending;
        expect(result['ok'], !failure);
        if (failure) {
          expect(
            (result['error'] as Map)['declaredFailureType'],
            'test.ProviderFailure',
          );
        } else {
          expect(result['value'], {'settled': 'retire'});
        }
        await consumer.host.release(access.handle);
        expect(consumer.host.retainedHandleCount, 0);
        expect(await fixture.calls(), hasLength(1));
      },
    );
  }

  for (final fence in ['release', 'revoke', 'close']) {
    test(
      '$fence fences held completion without cancelling provider work',
      () async {
        final consumer = await fixture.consumer();
        await fixture.provider();
        final access = (await fixture.resolve(consumer.host))!;
        final pending = consumer.host.invoke(access.handle, '$_service.hold', {
          'gate': 'fence',
        });
        final rejected = expectLater(pending, throwsStateError);
        await fixture.command('fixture.waitHeld', {'gate': 'fence'});
        switch (fence) {
          case 'release':
            await consumer.host.release(access.handle);
          case 'revoke':
            consumer.connection.revokeInfrastructureContext();
          case 'close':
            consumer.host.close();
        }
        expect(consumer.host.retainedHandleCount, 0);
        await fixture.command('fixture.finishHeld', {'gate': 'fence'});
        await rejected;
        expect(await fixture.calls(), hasLength(1));
      },
    );
  }

  test(
    'target termination settles held call and leaves consumer usable',
    () async {
      final consumer = await fixture.consumer();
      final provider = await fixture.provider();
      final access = (await fixture.resolve(consumer.host))!;
      final pending = consumer.host.invoke(access.handle, '$_service.hold', {
        'gate': 'terminate',
      });
      final rejected = expectLater(pending, throwsStateError);
      await fixture.command('fixture.waitHeld', {'gate': 'terminate'});
      await fixture.command('fixture.terminate', {
        'pluginId': provider.connection.pluginId,
      });
      await rejected;
      expect(provider.connection.isClosed, isTrue);
      consumer.connection.validateInfrastructureContext();
      await consumer.host.release(access.handle);
      expect(consumer.host.retainedHandleCount, 0);
    },
  );

  test(
    'target transport loss settles held call without closing consumer transport',
    () async {
      final consumer = await fixture.consumer();
      final targetHost = await fixture.newTransport();
      final provider = await fixture.provider(transport: targetHost);
      final access = (await fixture.resolve(consumer.host))!;
      final pending = consumer.host.invoke(access.handle, '$_service.hold', {
        'gate': 'exit',
      });
      final rejected = expectLater(pending, throwsStateError);
      await provider.connection.request('fixture.waitHeld', {'gate': 'exit'});
      final exited = expectLater(
        provider.connection.request('fixture.exit', {}),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await exited;
      await rejected;
      consumer.connection.validateInfrastructureContext();
      await consumer.host.release(access.handle);
      expect(consumer.host.retainedHandleCount, 0);
    },
  );

  test(
    'declared remote failure survives inside outcome; unexpected diagnostics do not',
    () async {
      final consumer = await fixture.consumer();
      await fixture.provider();
      final access = (await fixture.resolve(consumer.host))!;
      final declared = await fixture.dispatch(
        consumer.dispatcher,
        backendCapabilityConsumerServiceInvokeId,
        {
          'handle': access.handle,
          'method': '$_service.declaredFailure',
          'payload': <String, Object?>{},
        },
      );
      expect(declared['ok'], isTrue);
      expect(declared['payload'], {
        'ok': false,
        'error': {
          'declaredFailureType': 'test.ProviderFailure',
          'code': 'denied',
          'message': 'A declared refusal.',
          'details': {'resource': 'sample', 'retryable': false},
        },
      });
      final unexpected = await consumer.host.invoke(
        access.handle,
        '$_service.unexpectedFailure',
        {},
      );
      expect(unexpected, {
        'ok': false,
        'error': {
          'declaredFailureType': null,
          'code': 'capability_unavailable',
          'message': 'The Capability request could not be completed.',
          'details': <String, Object?>{},
        },
      });
      expect(jsonEncode(unexpected), isNot(contains('SECRET')));
      fixture.ownerOverride = (_) => throw StateError('SECRET owner exception');
      final outer = await fixture.dispatch(
        consumer.dispatcher,
        backendCapabilityConsumerServiceResolveId,
        {
          'capabilityId': 'test.callable',
          'majorVersion': 1,
          'expectedServiceId': _service,
          'providerId': null,
        },
      );
      expect(outer['ok'], isFalse);
      expect((outer['error'] as Map)['code'], 'internal_error');
      expect(jsonEncode(outer), isNot(contains('SECRET')));
    },
  );

  test(
    'generated dispatcher rejects route overrides and forged handles before transport',
    () async {
      final consumer = await fixture.consumer();
      await fixture.provider();
      for (final field in [
        'pluginId',
        'configurationContext',
        'serviceId',
        'hostInvocationContext',
      ]) {
        final response = await fixture.dispatch(
          consumer.dispatcher,
          backendCapabilityConsumerServiceResolveId,
          {
            'capabilityId': 'test.callable',
            'majorVersion': 1,
            'expectedServiceId': _service,
            'providerId': null,
            field: 'forged',
          },
        );
        expect(response['ok'], isFalse);
        expect((response['error'] as Map)['code'], 'invalid_request');
      }
      final response = await fixture.dispatch(
        consumer.dispatcher,
        backendCapabilityConsumerServiceInvokeId,
        {
          'handle': 'invented',
          'method': '$_service.echo',
          'payload': <String, Object?>{},
        },
      );
      expect(response['ok'], isFalse);
      expect(consumer.host.retainedHandleCount, 0);
      expect(await fixture.calls(), isEmpty);
    },
  );

  test(
    'mediator close preserves unrelated infrastructure and other consumer grants',
    () async {
      final consumer = await fixture.consumer();
      final other = await fixture.consumer(pluginId: 'test.other-consumer');
      await fixture.provider();
      final access = (await fixture.resolve(other.host))!;
      await fixture.resolve(consumer.host);
      consumer.host.close();
      consumer.connection.validateInfrastructureContext();
      final unrelated =
          await consumer.connection.request('fixture.reverse', {
                'serviceId': 'test.unrelated',
              })
              as Map;
      expect(unrelated['ok'], isTrue);
      expect(unrelated['payload'], 'unrelated');
      consumer.connection.revokeInfrastructureContext();
      expect(consumer.host.retainedHandleCount, 0);
      other.connection.validateInfrastructureContext();
      expect(
        (await other.host.invoke(access.handle, '$_service.echo', {}))['ok'],
        isTrue,
      );
      expect(other.host.retainedHandleCount, 1);
    },
  );
}

AdeleCapabilityExposure _exposure(
  String id, {
  int rank = 0,
  int major = 1,
  String service = _service,
  String context = 'configured',
}) => AdeleCapabilityExposure(
  providerId: id,
  capabilityId: 'test.callable',
  capabilityMajorVersion: major,
  serviceId: service,
  displayName: 'Provider $id',
  configurationContext: context,
  rank: rank,
);

ProviderDescriptor _descriptor(
  String id, {
  int rank = 0,
  String service = _service,
}) => ProviderDescriptor(
  id: ProviderId(id),
  capability: _capability,
  pluginId: 'test.provider-plugin',
  displayName: 'Provider $id',
  serviceId: service,
  rank: rank,
);

final class _Fixture {
  final registry = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final activations = <PluginBackendActivation>[];
  final transports = <PluginBackendHost>[];
  final consumers = <_Consumer>[];
  PluginBackendActivation? Function(ProviderBinding)? ownerOverride;
  late PluginBackendHost transport;
  late PluginBackendConnection controller;
  var requestId = 0;

  Future<void> start() async {
    transport = await newTransport();
    controller = await connect('test.controller');
  }

  Future<PluginBackendHost> newTransport() async {
    final host = await PluginBackendHost.start(
      dartaotruntimeExecutable: _dartExecutable(),
      hostArtifactPath: File(
        'test/core/fixtures/backend_capability_scripted_host.dart',
      ).absolute.path,
    );
    transports.add(host);
    return host;
  }

  Future<PluginBackendConnection> connect(
    String pluginId, {
    List<AdeleCapabilityExposure> exposures = const [],
    PluginBackendHost? transport,
    Map<String, AdeleBackendDispatcher> Function(PluginBackendConnection)?
    services,
  }) => (transport ?? this.transport).startPlugin(
    pluginId: pluginId,
    artifactUri: Uri.file('/unused-scripted-provider.aot'),
    arguments: [
      jsonEncode({
        'capabilityExposures': exposures.map((e) => e.toMap()).toList(),
      }),
    ],
    createInfrastructureServices: services,
  );

  Future<PluginBackendActivation> activate(
    PluginBackendConnection connection,
  ) async {
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: registry,
      extensions: extensions,
      adapters: RemoteExtensionAdapterRegistry([]),
    );
    activations.add(activation);
    return activation;
  }

  Future<PluginBackendActivation> provider({
    String pluginId = 'test.provider-plugin',
    List<AdeleCapabilityExposure>? exposures,
    PluginBackendHost? transport,
  }) async => activate(
    await connect(
      pluginId,
      exposures: exposures ?? [_exposure('test.provider')],
      transport: transport,
    ),
  );

  Future<_Consumer> consumer({
    String pluginId = 'test.consumer',
    List<CapabilityKey>? allowed,
    List<AdeleCapabilityExposure> exposures = const [],
  }) async {
    late BackendCapabilityHost host;
    late BackendCapabilityConsumerServiceDispatcher dispatcher;
    final connection = await connect(
      pluginId,
      exposures: exposures,
      services: (connection) {
        host = BackendCapabilityHost(
          connection: connection,
          registry: registry,
          allowedCapabilities: allowed ?? [_capability],
          ownerForProvider: (binding) {
            if (ownerOverride != null) return ownerOverride!(binding);
            for (final activation in activations) {
              if (!activation.connection.isClosed &&
                  activation.ownsProvider(binding)) {
                return activation;
              }
            }
            return null;
          },
        );
        dispatcher = BackendCapabilityConsumerServiceDispatcher(
          host,
          concurrent: true,
        );
        return {
          backendCapabilityConsumerServiceId: dispatcher,
          'test.unrelated': _UnrelatedDispatcher(),
        };
      },
    );
    await activate(connection);
    final consumer = _Consumer(connection, host, dispatcher);
    consumers.add(consumer);
    return consumer;
  }

  ProviderBinding binding(String id) =>
      registry.resolve(_capability, providerId: ProviderId(id));

  Future<BackendCapabilityAccess?> resolve(
    BackendCapabilityHost host, {
    String? providerId,
    String service = _service,
  }) => host.resolve('test.callable', 1, service, providerId);

  Future<Object?> command(String method, Map<String, Object?> payload) =>
      controller.request(method, payload);
  Future<List<Object?>> calls() async =>
      (await command('fixture.calls', {}) as List).cast<Object?>();

  Future<Map<String, Object?>> dispatch(
    BackendCapabilityConsumerServiceDispatcher dispatcher,
    String method,
    Map<String, Object?> payload,
  ) => dispatcher.dispatch({
    'kind': 'request',
    'requestId': requestId++,
    'method': method,
    'payload': payload,
  });

  Future<void> close() async {
    for (final consumer in consumers) {
      consumer.host.close();
    }
    for (final transport in transports.reversed) {
      await transport.close();
    }
    for (final activation in activations.reversed) {
      await activation.retire();
    }
    for (final consumer in consumers) {
      await consumer.dispatcher.close();
    }
  }
}

final class _Consumer {
  _Consumer(this.connection, this.host, this.dispatcher);
  final PluginBackendConnection connection;
  final BackendCapabilityHost host;
  final BackendCapabilityConsumerServiceDispatcher dispatcher;
}

final class _NativeEndpoint implements CapabilityEndpoint {
  const _NativeEndpoint();
  @override
  bool get isAvailable => true;
  @override
  String get serviceId => _service;
}

final class _UnrelatedDispatcher implements AdeleBackendDispatcher {
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async =>
      {
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': 'unrelated',
      };
  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async => send(await dispatch(command));
  @override
  Future<void> close() async {}
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    return File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    ).path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError(
    'Set FLUTTER_ROOT to the pinned Flutter SDK for scripted-host tests.',
  );
}
