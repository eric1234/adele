import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/backend_capability_publication_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_capability_publisher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _private = 'private-account-route-and-native-diagnostic';
final _capability = CapabilityKey(
  id: CapabilityId('test.capability'),
  majorVersion: 1,
);

void main() {
  late PluginBackendHost transport;
  late CapabilityRegistry registry;
  late ExtensionRegistry extensions;
  late List<PluginBackendActivation> activations;
  late List<BackendCapabilityPublicationHost> hosts;

  Future<
    ({
      PluginBackendConnection connection,
      BackendCapabilityPublicationHost host,
      PluginBackendActivation activation,
    })
  >
  start(
    String plugin, {
    List<AdeleCapabilityExposure> exposures = const [],
    bool attach = true,
  }) async {
    late BackendCapabilityPublicationHost host;
    final connection = await transport.startPlugin(
      pluginId: plugin,
      artifactUri: Uri.file('/unused/scripted.aot'),
      arguments: [
        jsonEncode({
          'capabilityExposures': [for (final e in exposures) e.toMap()],
        }),
      ],
      createInfrastructureServices: (connection) {
        host = BackendCapabilityPublicationHost(connection: connection);
        hosts.add(host);
        return {backendCapabilityPublicationServiceId: host};
      },
    );
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: registry,
      extensions: extensions,
      adapters: RemoteExtensionAdapterRegistry([]),
    );
    activations.add(activation);
    if (attach) host.attach(activation);
    return (connection: connection, host: host, activation: activation);
  }

  Future<Map<String, Object?>> request(
    BackendCapabilityPublicationHost host,
    String method,
    Map<String, Object?> payload,
  ) async =>
      (await host.dispatch({
            'kind': 'request',
            'requestId': 1,
            'method': method,
            'payload': payload,
          }))['payload']
          as Map<String, Object?>;

  Map<String, Object?> candidate(String id, {String context = 'route-1'}) => {
    'exposures': [_exposure(id, context: context).toMap()],
  };

  setUp(() async {
    registry = CapabilityRegistry();
    extensions = ExtensionRegistry();
    activations = [];
    hosts = [];
    transport = await PluginBackendHost.start(
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
      hostArtifactPath: File(
        'test/core/fixtures/backend_capability_scripted_host.dart',
      ).absolute.path,
    );
  });
  tearDown(() async {
    for (final activation in activations) {
      await activation.close();
    }
    for (final host in hosts) {
      await host.close();
    }
    await transport.close();
  });

  test(
    'before attachment fails notReady; attachment is exact and one-time',
    () async {
      final own = await start('test.owner', attach: false);
      final foreign = await start('test.foreign');
      expect(await request(own.host, 'publish', candidate('test.provider')), {
        'failure': 'notReady',
      });
      expect(
        () => own.host.attach(foreign.activation),
        throwsA(isA<AdeleCapabilityPublicationFailure>()),
      );
      own.host.attach(own.activation);
      expect(
        () => own.host.attach(own.activation),
        throwsA(isA<AdeleCapabilityPublicationFailure>()),
      );
      expect(
        (await request(
          own.host,
          'publish',
          candidate('test.provider'),
        ))['group'],
        isA<String>(),
      );
      expect(
        own.activation.ownsProvider(registry.resolve(_capability)),
        isTrue,
      );
    },
  );

  test(
    'initial adoption, replacement and retirement preserve sibling ownership',
    () async {
      final original = _exposure('test.a');
      final own = await start(
        'test.owner',
        exposures: [
          original,
          _exposure('test.b', context: 'b'),
        ],
      );
      final a = registry.resolve(_capability, providerId: ProviderId('test.a'));
      final b = registry.resolve(_capability, providerId: ProviderId('test.b'));
      final adopted = await request(own.host, 'adoptAdvertised', {
        'exposures': [original.toMap()],
      });
      expect(
        a.isSameRegistration(
          registry.resolve(_capability, providerId: a.provider.id),
        ),
        isTrue,
      );
      final replacement = await request(own.host, 'replace', {
        'group': adopted['group'],
        ...candidate('test.a', context: 'route-2'),
      });
      final fresh = registry.resolve(_capability, providerId: a.provider.id);
      expect(fresh.provider.id, a.provider.id);
      expect(fresh.isSameRegistration(a), isFalse);
      expect(
        () => a.endpointAs<CapabilityEndpoint>(),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        b.isSameRegistration(
          registry.resolve(_capability, providerId: b.provider.id),
        ),
        isTrue,
      );
      expect(await request(own.host, 'retire', {'group': adopted['group']}), {
        'failure': 'staleGroup',
      });
      expect(own.activation.ownsProvider(fresh), isTrue);
      expect(
        await request(own.host, 'retire', {'group': replacement['group']}),
        {'retired': true},
      );
      expect(registry.providersFor(_capability).map((p) => p.id), [
        b.provider.id,
      ]);
      own.connection.validateInfrastructureContext();
    },
  );

  test(
    'foreign and forged handles or ready identities never transfer ownership',
    () async {
      final a = await start('test.a', exposures: [_exposure('test.original')]);
      final b = await start('test.b');
      final published = await request(
        a.host,
        'publish',
        candidate('test.dynamic'),
      );
      for (final method in ['replace', 'retire']) {
        for (final handle in [published['group'], 'forged-$_private']) {
          expect(
            await request(b.host, method, {
              'group': handle,
              if (method == 'replace') ...candidate('test.dynamic'),
            }),
            {'failure': 'notAuthorized'},
          );
        }
      }
      expect(
        await request(b.host, 'adoptAdvertised', candidate('test.original')),
        {'failure': 'rejected'},
      );
      expect(await request(b.host, 'publish', candidate('test.dynamic')), {
        'failure': 'rejected',
      });
      expect(registry.providersFor(_capability), hasLength(2));
      expect(
        a.activation.ownsProvider(
          registry.resolve(_capability, providerId: ProviderId('test.dynamic')),
        ),
        isTrue,
      );
    },
  );

  test(
    'malformed selectors and exposures leave healthy registrations unchanged',
    () async {
      final own = await start('test.owner');
      final published = await request(own.host, 'publish', candidate('test.a'));
      final old = registry.resolve(_capability);
      final exposure = _exposure('test.a', context: 'candidate').toMap();
      for (final malformed in [
        {...exposure, 'capabilityMajorVersion': 0},
        {...exposure, 'serviceId': 'invalid service'},
        {...exposure, 'pluginId': 'test.foreign'},
        {...exposure, 'configurationContext': ''},
        {
          ...exposure,
          'association': {'providerId': 'test.absent'},
        },
      ]) {
        expect(
          await request(own.host, 'replace', {
            'group': published['group'],
            'exposures': [malformed],
          }),
          {'failure': 'invalidRequest'},
        );
        expect(old.isSameRegistration(registry.resolve(_capability)), isTrue);
      }
      for (final key in [
        'pluginId',
        'generation',
        'configurationContext',
        'credential',
      ]) {
        expect(
          await request(own.host, 'publish', {
            ...candidate('test.c'),
            key: _private,
          }),
          {'failure': 'invalidRequest'},
        );
      }
      final malformed = await own.host.dispatch({
        'kind': 'request',
        'requestId': _private,
        'method': _private,
        'payload': _private,
      });
      expect(malformed['requestId'], isNull);
      expect(jsonEncode(malformed), isNot(contains(_private)));
    },
  );

  test(
    'invalid associations and duplicate groups reject before replacing',
    () async {
      final own = await start('test.owner');
      final published = await request(own.host, 'publish', candidate('test.a'));
      final old = registry.resolve(_capability);
      for (final exposures in [
        [_exposure('test.a').toMap(), _exposure('test.a').toMap()],
        [_exposure('test.a', associated: 'test.missing').toMap()],
        [_exposure('test.a', associated: 'test.a').toMap()],
        [
          _exposure('test.a', associated: 'test.c').toMap(),
          _exposure('test.c', associated: 'test.a').toMap(),
        ],
      ]) {
        expect(
          await request(own.host, 'replace', {
            'group': published['group'],
            'exposures': exposures,
          }),
          {'failure': 'rejected'},
        );
        expect(old.isSameRegistration(registry.resolve(_capability)), isTrue);
      }
    },
  );

  test(
    'incomplete group replacement retires exact surviving members',
    () async {
      final own = await start('test.owner');
      final initial = await request(own.host, 'publish', {
        'exposures': [_exposure('test.a').toMap(), _exposure('test.b').toMap()],
      });
      final a = registry.resolve(_capability, providerId: ProviderId('test.a'));
      final b = registry.resolve(_capability, providerId: ProviderId('test.b'));
      await own.activation.retireProvider(a);
      expect(own.activation.ownsProvider(b), isTrue);
      expect(
        await request(own.host, 'replace', {
          'group': initial['group'],
          ...candidate('test.a', context: 'candidate'),
        }),
        {'failure': 'replacementUnavailable'},
      );
      expect(registry.providersFor(_capability), isEmpty);
      expect(await request(own.host, 'retire', {'group': initial['group']}), {
        'failure': 'staleGroup',
      });
    },
  );

  for (final method in ['retire', 'replace']) {
    test(
      '$method observer failure fences exact group and sanitizes diagnostics',
      () async {
        final own = await start(
          'test.owner',
          exposures: [_exposure('test.unrelated')],
        );
        final sibling = registry.resolve(_capability);
        final initial = await request(own.host, 'publish', {
          'exposures': [
            _exposure('test.a').toMap(),
            _exposure('test.b').toMap(),
          ],
        });
        registry
            .resolve(_capability, providerId: ProviderId('test.a'))
            .onRetire(() {
              throw StateError(_private);
            });
        final result = await request(own.host, method, {
          'group': initial['group'],
          if (method == 'replace') ...candidate('test.a', context: 'candidate'),
        });
        expect(result, {'failure': 'replacementUnavailable'});
        expect(jsonEncode(result), isNot(contains(_private)));
        expect(registry.providersFor(_capability).map((p) => p.id), [
          sibling.provider.id,
        ]);
        expect(
          sibling.isSameRegistration(registry.resolve(_capability)),
          isTrue,
        );
      },
    );
  }

  test(
    'pending and retained group bounds recover after exact cleanup',
    () async {
      final own = await start('test.owner');
      final pending = [
        for (
          var i = 0;
          i < BackendCapabilityPublicationHost.maxPendingMutations;
          i++
        )
          request(own.host, 'publish', candidate('test.provider.p$i')),
      ];
      expect(await request(own.host, 'publish', candidate('test.overflow')), {
        'failure': 'capacityExceeded',
      });
      final groups = await Future.wait(pending);
      expect(groups.every((value) => value['group'] is String), isTrue);
      expect(await request(own.host, 'publish', candidate('test.overflow')), {
        'failure': 'capacityExceeded',
      });
      await request(own.host, 'retire', {'group': groups.first['group']});
      expect(
        (await request(
          own.host,
          'publish',
          candidate('test.recovered'),
        ))['group'],
        isA<String>(),
      );
      await own.activation.retire();
      expect(registry.providersFor(_capability), isEmpty);
    },
  );

  test(
    'repeated replacement releases handle capacity; old handles stay stale',
    () async {
      final own = await start('test.owner');
      var current = await request(own.host, 'publish', candidate('test.a'));
      final original = current['group'];
      for (var i = 0; i < BackendCapabilityPublicationHost.maxGroups + 2; i++) {
        current = await request(own.host, 'replace', {
          'group': current['group'],
          ...candidate('test.a', context: 'route-$i'),
        });
        expect(current['group'], isA<String>());
      }
      expect(await request(own.host, 'retire', {'group': original}), {
        'failure': 'staleGroup',
      });
      expect(registry.providersFor(_capability), hasLength(1));
      expect(await request(own.host, 'retire', {'group': current['group']}), {
        'retired': true,
      });
      expect(registry.providersFor(_capability), isEmpty);
    },
  );

  test(
    'concurrent replacement and retirement serialize exact handle ownership',
    () async {
      final own = await start('test.owner');
      final initial = await request(own.host, 'publish', candidate('test.a'));
      final replacing = request(own.host, 'replace', {
        'group': initial['group'],
        ...candidate('test.a', context: 'new'),
      });
      final retiring = request(own.host, 'retire', {'group': initial['group']});
      final fresh = await replacing;
      expect(fresh['group'], isA<String>());
      expect(await retiring, {'failure': 'staleGroup'});
      expect(registry.providersFor(_capability), hasLength(1));
      await own.activation.retire();
      expect(registry.providersFor(_capability), isEmpty);
      expect(await request(own.host, 'publish', candidate('test.late')), {
        'failure': 'generationUnavailable',
      });
    },
  );

  test(
    'close and generation revocation fence queued publication and late replacement',
    () async {
      final own = await start('test.owner');
      final initial = await request(own.host, 'publish', candidate('test.a'));
      final old = registry.resolve(_capability);
      old.onRetire(own.connection.revokeInfrastructureContext);
      expect(
        await request(own.host, 'replace', {
          'group': initial['group'],
          ...candidate('test.a', context: 'late'),
        }),
        {'failure': 'generationUnavailable'},
      );
      expect(registry.providersFor(_capability), isEmpty);
      final other = await start('test.other');
      final pending = request(other.host, 'publish', candidate('test.queued'));
      final closed = other.host.close();
      expect(await pending, {'failure': 'generationUnavailable'});
      await closed;
      expect(registry.providersFor(_capability), isEmpty);
      await transport.close();
      expect(await request(other.host, 'publish', candidate('test.shutdown')), {
        'failure': 'generationUnavailable',
      });
    },
  );
}

AdeleCapabilityExposure _exposure(
  String id, {
  String context = 'route-1',
  String? associated,
}) => AdeleCapabilityExposure(
  providerId: id,
  capabilityId: _capability.id.value,
  capabilityMajorVersion: 1,
  serviceId: 'test.service',
  displayName: 'Provider',
  configurationContext: context,
  association: associated == null
      ? null
      : AdeleProviderAssociation(
          capabilityId: _capability.id.value,
          capabilityMajorVersion: 1,
          providerId: associated,
        ),
);
