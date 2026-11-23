@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

const _bound = Duration(seconds: 10);
const _controlService = 'test.controller';
const _consumerService = 'adele.capabilityConsumer';
final _declarations = [
  {'id': resourceInspectCapability.id.value, 'majorVersion': 1},
  {'id': resourceInspectCapability.id.value, 'majorVersion': 2},
  {'id': 'test.private', 'majorVersion': 1},
  {'id': 'test.missing', 'majorVersion': 1},
];
final _catalogDeclarations = [
  {
    'id': modelCatalogCapability.id.value,
    'majorVersion': modelCatalogCapability.majorVersion,
  },
];

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File consumerArtifact;
  late Map<String, File> providerArtifacts;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'adele-backend-consumer-',
    );
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    consumerArtifact = File('${artifacts.path}/consumer.aot');
    providerArtifacts = {
      for (final id in ['b', 'c', 'catalog'])
        id: File('${artifacts.path}/provider-$id.aot'),
    };
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/fixtures/backend_capability_consumer.dart',
        artifact: consumerArtifact,
      ),
      for (final entry in providerArtifacts.entries)
        (
          entrypoint: entry.key == 'catalog'
              ? 'app/test/fixtures/backend_capability_catalog_provider.dart'
              : 'app/test/fixtures/backend_capability_provider.dart',
          artifact: entry.value,
        ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'backend-capability-integration',
      );
    }
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  Future<_Installation> prepare({
    List<String> consumers = const ['a'],
    List<String> providers = const ['b', 'c'],
    List<Map<String, Object?>>? declarations,
    bool advertiseCatalogs = true,
    int? readyGatePort,
    int? discoveryGatePort,
    Map<String, AdeleBackendDispatcher> Function(PluginBackendConnection)?
    infrastructureServices,
  }) async {
    final root = await Directory(
      '${artifacts.path}/case-${sequence++}',
    ).create();
    for (final id in consumers) {
      final directory = await Directory('${root.path}/consumer-$id').create();
      await consumerArtifact.copy('${directory.path}/backend.aot');
      await _manifest(directory, 'test.consumer.$id', {
        'artifact': 'backend.aot',
        if ((declarations ?? _declarations).isNotEmpty)
          'consumesCapabilities': declarations ?? _declarations,
      });
    }
    for (final id in providers) {
      final directory = await Directory('${root.path}/provider-$id').create();
      await providerArtifacts[id]!.copy('${directory.path}/backend.aot');
      await _manifest(directory, 'test.backend.$id', {
        'artifact': 'backend.aot',
      });
    }
    final fixture = _Installation(
      infrastructureServices: infrastructureServices,
    );
    addTearDown(fixture.bootstrap.close);
    fixture.starting = fixture.bootstrap.start(
      installationRoot: root.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: {
        if (discoveryGatePort != null)
          for (final id in consumers)
            'test.consumer.$id': [
              jsonEncode({'discoveryGatePort': discoveryGatePort}),
            ],
        for (final id in providers)
          'test.backend.$id': [
            jsonEncode(
              id == 'catalog'
                  ? {'advertiseCatalogs': advertiseCatalogs}
                  : {
                      'identity': id.toUpperCase(),
                      'context': 'configured-$id',
                      'providerId': 'test.inspector.$id',
                      'rank': id == 'c' ? 20 : 10,
                      if (id == 'b' && readyGatePort != null)
                        'readyGatePort': readyGatePort,
                    },
            ),
          ],
      },
    );
    return fixture;
  }

  Future<_Installation> start({
    List<String> consumers = const ['a'],
    List<String> providers = const ['b', 'c'],
    List<Map<String, Object?>>? declarations,
    bool advertiseCatalogs = true,
    Map<String, AdeleBackendDispatcher> Function(PluginBackendConnection)?
    infrastructureServices,
  }) async {
    final fixture = await prepare(
      consumers: consumers,
      providers: providers,
      declarations: declarations,
      advertiseCatalogs: advertiseCatalogs,
      infrastructureServices: infrastructureServices,
    );
    await fixture.ready();
    return fixture;
  }

  test(
    'AOT fixtures share public contracts, never host or peer implementations',
    () async {
      final imports = RegExp(r"import '([^']+)';");
      Future<Set<String>> imported(String name) async => imports
          .allMatches(
            await File(
              'test/fixtures/backend_capability_$name.dart',
            ).readAsString(),
          )
          .map((match) => match[1]!)
          .toSet();
      expect(await imported('consumer'), {
        'dart:async',
        'dart:convert',
        'dart:io',
        'dart:isolate',
        'package:adele_contract/adele_contract.dart',
        'package:adele_model_provider/adele_model_catalog.dart',
        'package:adele_plugin_api/adele_plugin_api.dart',
        'package:adele_plugin_backend_support/adele_plugin_backend_support.dart',
        'package:adele_project_storage/adele_project_storage.dart',
        'package:resource_inspector_contract/resource_inspector_contract.dart',
      });
      expect(await imported('provider'), {
        'dart:async',
        'dart:convert',
        'dart:io',
        'dart:isolate',
        'package:adele_contract/adele_contract.dart',
        'package:adele_plugin_api/adele_plugin_api.dart',
        'package:resource_inspector_contract/resource_inspector_contract.dart',
      });
      expect(await imported('catalog_provider'), {
        'dart:async',
        'dart:convert',
        'dart:isolate',
        'package:adele_contract/adele_contract.dart',
        'package:adele_model_provider/adele_model_catalog.dart',
        'package:adele_model_provider/adele_model_provider.dart',
        // Only this provider fixture links the existing scripted implementation.
        'package:scripted_model_backend/scripted_model_provider_backend.dart',
      });
    },
  );

  test(
    'catalog AOT selects exact configured siblings and refreshes without restart or cross-routing',
    () async {
      final fixture = await start(
        providers: ['catalog'],
        declarations: _catalogDeclarations,
      );
      final consumer = fixture.consumer();
      final provider = fixture.provider('catalog');
      expect(fixture.bootstrap.catalog!.installations, hasLength(2));
      expect(consumer.capabilityExposures, isEmpty);
      expect(provider.capabilityExposures, hasLength(5));
      expect(
        fixture.capabilities.providersFor(modelProviderCapability),
        hasLength(3),
      );
      for (final account in ['work', 'personal']) {
        final catalog = fixture.capabilities.resolve(
          modelCatalogCapability,
          providerId: ProviderId('test.catalog.$account'),
        );
        final inference = fixture.capabilities.resolve(
          modelProviderCapability,
          providerId: ProviderId('test.inference.$account'),
        );
        final owner = fixture.bootstrap.backendForProvider(catalog)!;
        expect(owner.connection, same(provider));
        expect(fixture.bootstrap.backendForProvider(inference), same(owner));
        expect(
          owner.associationFor(catalog)!.isSameRegistration(inference),
          isTrue,
        );
        expect(owner.associationFor(inference), isNull);
        expect(
          provider.capabilityExposures
              .singleWhere(
                (value) => value.providerId == catalog.provider.id.value,
              )
              .configurationContext,
          'catalog-$account',
        );
        expect(
          provider.capabilityExposures
              .singleWhere(
                (value) => value.providerId == inference.provider.id.value,
              )
              .configurationContext,
          'inference-$account',
        );
      }
      expect(await _requests(provider), isEmpty);
      expect(await _call(consumer, 'discover', _catalogQuery), {
        'ok': true,
        'providers': [_catalogProvider('personal'), _catalogProvider('work')],
      });
      // Inference identity, even in the same generation, never implies a catalog.
      for (final id in [
        'test.inference.inference-only',
        'test.catalog.absent',
      ]) {
        expect(
          await _call(consumer, 'resolve', {
            ..._catalogQuery,
            'providerId': id,
          }),
          {'ok': true, 'provider': null},
        );
      }
      for (final account in ['work', 'personal']) {
        expect(await _selectCatalog(consumer, account), {
          'ok': true,
          'provider': _catalogProvider(account),
          'requestOnly': true,
        });
        expect(
          await _call(consumer, 'listModels', {'slot': account}),
          _catalogSnapshot(account),
        );
      }
      await _control(provider, 'setCatalog', {
        'account': 'work',
        'revision': 1,
      });
      // The same resolved generated client route observes a new snapshot.
      expect(
        await _call(consumer, 'listModels', {'slot': 'work'}),
        _catalogSnapshot('work', revision: 1),
      );
      expect(
        await _call(consumer, 'listModels', {'slot': 'personal'}),
        _catalogSnapshot('personal'),
      );
      await _control(provider, 'setCatalog', {
        'account': 'work',
        'mode': 'empty',
      });
      expect(await _call(consumer, 'listModels', {'slot': 'work'}), {
        'ok': true,
        'models': <Object?>[],
      });
      expect(
        await _call(consumer, 'listModels', {'slot': 'personal'}),
        _catalogSnapshot('personal'),
      );
      expect(fixture.consumer(), same(consumer));
      expect(fixture.provider('catalog'), same(provider));
      for (final account in ['work', 'personal']) {
        expect(await _call(consumer, 'release', {'slot': account}), {
          'ok': true,
        });
        expect(
          (await _call(consumer, 'listModels', {'slot': account}))['ok'],
          isFalse,
        );
        expect(await _call(consumer, 'release', {'slot': account}), {
          'ok': true,
        });
      }
      expect(await _requests(provider), [
        _catalogRequest('work'),
        _catalogRequest('personal'),
        _catalogRequest('work'),
        _catalogRequest('personal'),
        _catalogRequest('work'),
        _catalogRequest('personal'),
      ]);
    },
  );

  test(
    'inference-only AOT activation leaves declared catalog discovery unavailable',
    () async {
      final fixture = await start(
        providers: ['catalog'],
        declarations: _catalogDeclarations,
        advertiseCatalogs: false,
      );
      expect(
        fixture.capabilities.providersFor(modelProviderCapability),
        hasLength(3),
      );
      expect(
        fixture.capabilities.providersFor(modelCatalogCapability),
        isEmpty,
      );
      expect(await _call(fixture.consumer(), 'discover', _catalogQuery), {
        'ok': true,
        'providers': <Object?>[],
      });
      expect(await _call(fixture.consumer(), 'resolve', _catalogQuery), {
        'ok': true,
        'provider': null,
      });
      expect(await _selectCatalog(fixture.consumer(), 'work'), {
        'ok': true,
        'provider': null,
      });
      expect(await _requests(fixture.provider('catalog')), isEmpty);
    },
  );

  test('catalog AOT access requires its own consumption declaration', () async {
    final fixture = await start(
      providers: ['catalog'],
      declarations: [
        {
          'id': modelProviderCapability.id.value,
          'majorVersion': modelProviderCapability.majorVersion,
        },
      ],
    );
    expect(
      fixture.capabilities.providersFor(modelCatalogCapability),
      hasLength(2),
    );
    for (final method in ['discover', 'resolve']) {
      expect(
        (await _call(fixture.consumer(), method, _catalogQuery))['ok'],
        isFalse,
      );
    }
    expect(await _requests(fixture.provider('catalog')), isEmpty);
  });

  test(
    'catalog-only AOT access denies inference, credentials, service substitution and route authority',
    () async {
      final fixture = await start(
        providers: ['catalog'],
        declarations: _catalogDeclarations,
      );
      final consumer = fixture.consumer();
      final provider = fixture.provider('catalog');
      await _selectCatalog(consumer, 'work');
      for (final query in [
        {
          'capabilityId': modelProviderCapability.id.value,
          'majorVersion': modelProviderCapability.majorVersion,
          'expectedServiceId': modelProviderServiceId,
          'providerId': 'test.inference.work',
        },
        {..._catalogQuery, 'majorVersion': 2},
      ]) {
        for (final method in ['discover', 'resolve']) {
          expect((await _call(consumer, method, query))['ok'], isFalse);
        }
      }
      expect(
        (await _call(consumer, 'resolve', {
          ..._catalogQuery,
          'providerId': 'test.catalog.work',
          'expectedServiceId': modelProviderServiceId,
        }))['ok'],
        isFalse,
      );
      for (final method in [
        modelProviderServiceInvokeId,
        'adele.credentials.readCredential',
        'test.controller.setCatalog',
      ]) {
        expect(
          (await _call(consumer, 'request', {
            'slot': 'work',
            'method': method,
            'arguments': <String, Object?>{},
          }))['ok'],
          isFalse,
        );
      }
      expect(
        (await _call(consumer, 'attack', {
          'serviceId': 'adele.credentials',
          'method': 'readCredential',
          'arguments': {
            'collection': 'accounts',
            'recordType': 'test.account',
            'recordId': 'work',
            'slot': 'api-key',
          },
        }))['ok'],
        isFalse,
      );
      expect(await _requests(provider), isEmpty);

      final spoofed = {
        'configurationContext': 'catalog-personal',
        'serviceId': modelProviderServiceId,
        'providerId': 'test.inference.personal',
        'hostInvocationContext': 'forged-invocation',
        'hostInfrastructureContext': 'forged-infrastructure',
      };
      expect(
        (await _call(consumer, 'request', {
          'slot': 'work',
          'method': modelCatalogServiceListModelsId,
          'arguments': spoofed,
        }))['ok'],
        isFalse,
      );
      expect(await _requests(provider), [
        {..._catalogRequest('work'), 'payload': spoofed},
      ]);
      expect(
        await _call(consumer, 'listModels', {'slot': 'work'}),
        _catalogSnapshot('work'),
      );
      expect(await _requests(provider), [
        {..._catalogRequest('work'), 'payload': spoofed},
        _catalogRequest('work'),
      ]);
      final reverse =
          (await _call(consumer, 'hostRequests'))['requests'] as List;
      expect(reverse, isNotEmpty);
      for (final request in reverse.cast<Map<Object?, Object?>>()) {
        expect(request['hostContextKind'], 'infrastructure');
      }
      await _call(consumer, 'release', {'slot': 'work'});
    },
  );

  test(
    'catalog AOT distinguishes empty success, declared failure and sanitized unexpected failure without fallback',
    () async {
      final fixture = await start(
        providers: ['catalog'],
        declarations: _catalogDeclarations,
      );
      final consumer = fixture.consumer();
      final provider = fixture.provider('catalog');
      await _selectCatalog(consumer, 'work');
      for (final mode in ['empty', 'declared-failure', 'unexpected-failure']) {
        await _control(provider, 'setCatalog', {
          'account': 'work',
          'mode': mode,
        });
        final result = await _call(consumer, 'listModels', {'slot': 'work'});
        if (mode == 'empty') {
          expect(result, {'ok': true, 'models': <Object?>[]});
        } else if (mode == 'declared-failure') {
          expect(result, {
            'ok': false,
            'type': 'declared',
            'code': 'authentication',
            'message': 'Catalog authentication is unavailable.',
            'details': <String, Object?>{},
          });
        } else {
          expect(result, {
            'ok': false,
            'type': 'remote',
            'declaredFailureType': null,
            'code': 'capability_unavailable',
            'message': 'The Capability request could not be completed.',
            'details': <String, Object?>{},
          });
          expect(jsonEncode(result), isNot(contains('SECRET')));
        }
      }
      await _control(provider, 'setCatalog', {'account': 'work'});
      expect(
        await _call(consumer, 'listModels', {'slot': 'work'}),
        _catalogSnapshot('work'),
      );
      expect(
        await _requests(provider),
        List.generate(4, (_) => _catalogRequest('work')),
      );
      expect(fixture.provider('catalog'), same(provider));
      expect(fixture.bootstrap.host!.isClosed, isFalse);
      await _call(consumer, 'release', {'slot': 'work'});
    },
  );

  test(
    'normal three-plugin bootstrap lets consumer AOT discover, select and inspect independent B/C providers',
    () async {
      final fixture = await start();
      expect(fixture.bootstrap.catalog!.installations, hasLength(3));
      final consumer = fixture.consumer();
      expect(consumer.capabilityExposures, isEmpty);
      for (final id in ['b', 'c']) {
        expect(fixture.provider(id).capabilityExposures, hasLength(1));
        expect(await _requests(fixture.provider(id)), isEmpty);
      }
      expect(await _call(consumer, 'discover'), {
        'ok': true,
        'providers': [_provider('c'), _provider('b')],
      });
      expect(await _call(consumer, 'resolve'), {
        'ok': true,
        'provider': _provider('c'),
        'requestOnly': true,
      });
      expect(
        await _call(consumer, 'inspect', {
          'uri': 'test:/first',
          'mediaType': 'application/test',
        }),
        _inspection('c', 'test:/first', mediaType: 'application/test'),
      );
      expect(await _select(consumer, 'b'), {
        'ok': true,
        'provider': _provider('b'),
        'requestOnly': true,
      });
      expect(
        await _call(consumer, 'inspect', {'slot': 'b'}),
        _inspection('b', 'test:/ordinary'),
      );
      expect(await _call(consumer, 'resolve', {'providerId': 'test.absent'}), {
        'ok': true,
        'provider': null,
      });
      expect(await _requests(fixture.provider('b')), [
        _request('b', 'test:/ordinary'),
      ]);
      expect(await _requests(fixture.provider('c')), [
        _request('c', 'test:/first', mediaType: 'application/test'),
      ]);
    },
  );

  test(
    'consumer starts with no providers and observes independent late ready activation without restarting',
    () async {
      final gate = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(gate.close);
      final discoveryGate = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(discoveryGate.close);
      final discoveryConnected = discoveryGate.first.timeout(_bound);
      final connected = gate.first.timeout(_bound);
      final fixture = await prepare(
        readyGatePort: gate.port,
        discoveryGatePort: discoveryGate.port,
      );
      final socket = await connected;
      addTearDown(socket.destroy);
      final discoverySocket = await discoveryConnected;
      addTearDown(discoverySocket.destroy);
      try {
        final consumer = fixture.consumer();
        expect(fixture.bootstrap.state, ApplicationPluginState.starting);
        expect(
          fixture.bootstrap.backends
              .singleWhere(
                (entry) =>
                    entry.installation.metadata.id.value == 'test.backend.b',
              )
              .state,
          InstalledBackendState.starting,
        );
        final observed = discoverySocket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(_bound);
        discoverySocket.add([1]);
        await discoverySocket.flush();
        final before = jsonDecode(await observed) as Map;
        expect(before['discovery'], {'ok': true, 'providers': <Object?>[]});
        expect(before['selected'], {'ok': true, 'provider': null});
        expect(before['default'], {'ok': true, 'provider': null});
        socket.add([1]);
        await socket.flush();
        await fixture.ready();
        expect(fixture.consumer(), same(consumer));
        expect(await _call(consumer, 'discover'), {
          'ok': true,
          'providers': [_provider('c'), _provider('b')],
        });
        await _select(consumer, 'c');
        expect(
          await _call(consumer, 'inspect', {'slot': 'c'}),
          _inspection('c', 'test:/ordinary'),
        );
      } finally {
        socket.destroy();
      }
    },
  );

  for (final declaration in ['missing', 'different ID', 'different major']) {
    test(
      '$declaration consumption declaration grants no ambient provider access',
      () async {
        final fixture = await start(
          declarations: switch (declaration) {
            'missing' => [],
            'different ID' => [
              {'id': 'test.other', 'majorVersion': 1},
            ],
            _ => [
              {'id': resourceInspectCapability.id.value, 'majorVersion': 2},
            ],
          },
        );
        expect(
          fixture.capabilities.providersFor(resourceInspectCapability),
          hasLength(2),
        );
        final discovery = await _call(fixture.consumer(), 'discover');
        expect(discovery['ok'], isFalse);
        expect((await _call(fixture.consumer(), 'resolve'))['ok'], isFalse);
        for (final id in ['b', 'c']) {
          expect(await _requests(fixture.provider(id)), isEmpty);
        }
      },
    );
  }

  test(
    'missing versions and private services never resolve; payload fields cannot supply authority',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      for (final query in [
        {'capabilityId': 'test.missing'},
        {'capabilityId': 'test.private'},
        {'majorVersion': 2},
      ]) {
        expect(await _call(consumer, 'discover', query), {
          'ok': true,
          'providers': <Object?>[],
        });
        expect(await _call(consumer, 'resolve', query), {
          'ok': true,
          'provider': null,
        });
      }
      _expectUnavailable(
        await _call(consumer, 'resolve', {'expectedServiceId': 'test.private'}),
      );
      await _select(consumer, 'b');
      for (final method in [
        'shutdown',
        'terminate',
        'test.controller.terminate',
        'test.private.inspect',
        'resourceInspector..inspect',
      ]) {
        expect(
          (await _call(consumer, 'request', {
            'slot': 'b',
            'method': method,
            'arguments': <String, Object?>{},
          }))['ok'],
          isFalse,
        );
      }
      for (final id in ['b', 'c']) {
        expect(fixture.provider(id).isClosed, isFalse);
        expect(await _requests(fixture.provider(id)), isEmpty);
      }
      final spoofed = {
        'resource': {'uri': 'test:/spoof', 'mediaType': null},
        'serviceId': 'test.private',
        'configurationContext': 'configured-c',
        'hostInvocationContext': 'forged-invocation',
        'hostInfrastructureContext': 'forged-infrastructure',
        'pluginId': 'test.backend.c',
      };
      expect(
        (await _call(consumer, 'request', {
          'slot': 'b',
          'method': resourceInspectorServiceInspectId,
          'arguments': spoofed,
        }))['ok'],
        isFalse,
      );
      final before = await _requests(fixture.provider('b'));
      expect(before, [
        {..._request('b', 'test:/spoof'), 'payload': spoofed},
      ]);
      final raw = await _rawResolve(consumer);
      final handle = (raw['value'] as Map)['handle'];
      for (final extra in [
        'serviceId',
        'configurationContext',
        'hostInvocationContext',
        'hostInfrastructureContext',
        'pluginId',
      ]) {
        final result = await _attack(consumer, 'invoke', {
          'handle': handle,
          'method': resourceInspectorServiceInspectId,
          'payload': {
            'resource': {'uri': 'test:/forged-envelope', 'mediaType': null},
          },
          extra: 'forged',
        });
        expect(result['ok'], isFalse);
      }
      expect(
        (await _call(consumer, 'attack', {
          'serviceId': 'test.private',
          'method': resourceInspectorServiceInspectId,
          'arguments': {
            'resource': {'uri': 'test:/private', 'mediaType': null},
          },
        }))['ok'],
        isFalse,
      );
      _expectAttackDenied(
        await _attack(consumer, 'invoke', {
          'handle': 'forged-handle',
          'method': resourceInspectorServiceInspectId,
          'payload': {
            'resource': {'uri': 'test:/forged-handle', 'mediaType': null},
          },
        }),
      );
      expect(await _requests(fixture.provider('b')), before);
      expect(await _requests(fixture.provider('c')), isEmpty);
      expect(
        await _call(consumer, 'inspect', {
          'slot': 'b',
          'uri': 'test:/ordinary?hostInvocationContext=forged',
        }),
        _inspection('b', 'test:/ordinary?hostInvocationContext=forged'),
      );
      await _attack(consumer, 'release', {'handle': handle});
    },
  );

  test(
    'generated declared failures retain their DTO while unknown provider diagnostics are sanitized',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      await _select(consumer, 'b');
      expect(
        await _call(consumer, 'inspect', {
          'slot': 'b',
          'uri': 'test:/declared-failure',
        }),
        {
          'ok': false,
          'type': 'declared',
          'code': 'inspection_denied',
          'message': 'Inspection denied by B.',
          'details': {
            'provider': 'B',
            'resource': 'test:/declared-failure',
            'nested': {
              'retryable': false,
              'values': [1, null, 'public'],
            },
          },
        },
      );
      for (final path in ['unknown-failure', 'diagnostic-failure']) {
        final result = await _call(consumer, 'inspect', {
          'slot': 'b',
          'uri': 'test:/$path',
        });
        expect(result['ok'], isFalse);
        expect(result['type'], 'remote');
        expect(result['declaredFailureType'], isNull);
        expect(result['details'], isEmpty);
        expect(jsonEncode(result), isNot(contains('SECRET')));
      }
      expect(
        await _call(consumer, 'inspect', {'slot': 'b'}),
        _inspection('b', 'test:/ordinary'),
      );
      expect(fixture.bootstrap.host!.isClosed, isFalse);
    },
  );

  test(
    'release fences retained access and late publication without cancelling admitted provider work',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      final provider = fixture.provider('b');
      await _select(consumer, 'b');
      await _control(provider, 'hold', {'key': '/held-release'});
      final pending = _call(consumer, 'inspect', {
        'slot': 'b',
        'uri': 'test:/held-release',
      });
      await _control(provider, 'wait', {'key': '/held-release'});
      expect(await _call(consumer, 'release', {'slot': 'b'}), {'ok': true});
      expect((await _call(consumer, 'inspect', {'slot': 'b'}))['ok'], isFalse);
      await _control(provider, 'release', {'key': '/held-release'});
      expect((await pending)['ok'], isFalse);
      expect(await _call(consumer, 'release', {'slot': 'b'}), {'ok': true});
      expect(await _requests(provider), [_request('b', 'test:/held-release')]);
      await _select(consumer, 'b', slot: 'fresh');
      expect(
        await _call(consumer, 'inspect', {'slot': 'fresh'}),
        _inspection('b', 'test:/ordinary'),
      );
    },
  );

  test(
    'provider retirement fences retained access but permits admitted settlement without substituting the sibling',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      final provider = fixture.provider('b');
      await _select(consumer, 'b');
      await _select(consumer, 'c');
      await _control(provider, 'hold', {'key': '/held-retirement'});
      final pending = _call(consumer, 'inspect', {
        'slot': 'b',
        'uri': 'test:/held-retirement',
      });
      await _control(provider, 'wait', {'key': '/held-retirement'});
      final binding = fixture.capabilities.resolve(
        resourceInspectCapability,
        providerId: ProviderId('test.inspector.b'),
      );
      await fixture.bootstrap
          .backendForProvider(binding)!
          .retireProvider(binding);
      expect((await _call(consumer, 'inspect', {'slot': 'b'}))['ok'], isFalse);
      await _control(provider, 'release', {'key': '/held-retirement'});
      expect(await pending, _inspection('b', 'test:/held-retirement'));
      expect(await _call(consumer, 'discover'), {
        'ok': true,
        'providers': [_provider('c')],
      });
      expect(
        await _call(consumer, 'resolve', {'providerId': 'test.inspector.b'}),
        {'ok': true, 'provider': null},
      );
      expect(await _requests(fixture.provider('c')), isEmpty);
      expect(
        await _call(consumer, 'inspect', {'slot': 'c'}),
        _inspection('c', 'test:/ordinary'),
      );
      expect(await _requests(provider), [
        _request('b', 'test:/held-retirement'),
      ]);
    },
  );

  test(
    'AOT provider termination fails a held consumer call locally and leaves the other provider callable',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      final provider = fixture.provider('b');
      await _select(consumer, 'b');
      await _select(consumer, 'c');
      await _control(provider, 'hold', {'key': '/provider-terminated'});
      final pending = _call(consumer, 'inspect', {
        'slot': 'b',
        'uri': 'test:/provider-terminated',
      });
      await _control(provider, 'wait', {'key': '/provider-terminated'});
      final retired = fixture.bootstrap.changes.firstWhere(
        (_) =>
            fixture.bootstrap.backends
                .singleWhere((entry) => entry.connection == provider)
                .state ==
            InstalledBackendState.terminated,
      );
      await expectLater(
        _control(provider, 'terminate'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await provider.terminated.timeout(_bound);
      await retired.timeout(_bound);
      final failure = await pending;
      expect(failure['ok'], isFalse);
      expect(failure['type'], 'remote');
      expect(failure['declaredFailureType'], isNull);
      expect(failure['details'], isEmpty);
      expect((await _call(consumer, 'inspect', {'slot': 'b'}))['ok'], isFalse);
      expect(await _call(consumer, 'discover'), {
        'ok': true,
        'providers': [_provider('c')],
      });
      expect(await _requests(fixture.provider('c')), isEmpty);
      expect(
        await _call(consumer, 'inspect', {'slot': 'c'}),
        _inspection('c', 'test:/ordinary'),
      );
      expect(fixture.bootstrap.state, ApplicationPluginState.ready);
      expect(fixture.bootstrap.host!.isClosed, isFalse);
    },
  );

  test(
    'shared AOT host termination settles held nested requests and fences all captured connections',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      final provider = fixture.provider('b');
      final host = fixture.bootstrap.host!;
      await _select(consumer, 'b');
      await _control(provider, 'hold', {'key': '/host-terminated'});
      final pending = _call(consumer, 'inspect', {
        'slot': 'b',
        'uri': 'test:/host-terminated',
      });
      final failed = expectLater(
        pending,
        throwsA(isA<PluginConnectionClosed>()),
      );
      await _control(provider, 'wait', {'key': '/host-terminated'});
      final failedBootstrap = fixture.bootstrap.changes.firstWhere(
        (state) => state == ApplicationPluginState.failed,
      );
      expect(Process.killPid(host.processId), isTrue);
      await host.terminated.timeout(_bound);
      await failedBootstrap.timeout(_bound);
      await failed;
      expect(fixture.bootstrap.failure, isA<PluginConnectionClosed>());
      for (final backend in fixture.bootstrap.backends) {
        expect(backend.connection!.isClosed, isTrue);
      }
      await expectLater(
        _call(consumer, 'discover'),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await fixture.bootstrap.close();
      expect(
        fixture.capabilities.providersFor(resourceInspectCapability),
        isEmpty,
      );
    },
  );

  test(
    'normal bootstrap preserves generated Project Storage access alongside consumer mediation',
    () async {
      final store = InMemoryProductStore();
      final lifecycle = ProductLifecycleCoordinator.generated(
        store: store,
        registry: CapabilityRegistry(),
        extensions: ExtensionRegistry(),
      );
      addTearDown(lifecycle.close);
      final project = Project(
        id: ProjectId('volatile-project'),
        sourceLocation: Uri.parse('test:/volatile'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Storage',
      );
      final environment = Environment(
        id: EnvironmentId('environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('test.uninstalled-environment'),
        providerState: const {},
      );
      final session = Session(
        id: SessionId('session'),
        taskId: task.id,
        strategyId: OrchestrationStrategyId('test.uninstalled-strategy'),
      );
      store.publishRestoredProject(
        project: project,
        tasks: [task],
        environments: [environment],
        sessions: [session],
        authorities: [(session.id, environment.id)],
        runRecords: const [],
      );
      final external = <Map<String, AdeleBackendDispatcher>>[];
      final fixture = await start(
        infrastructureServices: (connection) {
          final services = Map<String, AdeleBackendDispatcher>.unmodifiable(
            projectStorageServices(lifecycle, connection),
          );
          external.add(services);
          return services;
        },
      );
      for (final services in external) {
        expect(services.keys, [projectStorageServiceId]);
      }
      final consumer = fixture.consumer();
      expect(
        await _call(consumer, 'storage', {'sessionId': session.id.value}),
        {'ok': true, 'durable': false},
      );
      await _select(consumer, 'b');
      expect(
        await _call(consumer, 'inspect', {'slot': 'b'}),
        _inspection('b', 'test:/ordinary'),
      );
      await _call(consumer, 'release', {'slot': 'b'});
      expect(
        await _call(consumer, 'storage', {'sessionId': session.id.value}),
        {'ok': true, 'durable': false},
      );
    },
  );

  test(
    'AOT Environment storage enrolls before Sessions with canonical backing and exact-generation infrastructure',
    () async {
      final store = InMemoryProductStore();
      final lifecycle = ProductLifecycleCoordinator.generated(
        store: store,
        registry: CapabilityRegistry(),
        extensions: ExtensionRegistry(),
      );
      addTearDown(lifecycle.close);
      for (final id in ['a', 'b']) {
        final project = Project(
          id: ProjectId('project-$id'),
          sourceLocation: Uri.parse('test:/volatile-$id'),
        );
        final task = Task(
          id: TaskId('task-$id'),
          projectId: project.id,
          title: 'Pre-Session storage $id',
        );
        store.publishRestoredProject(
          project: project,
          tasks: [task],
          environments: [
            Environment(
              id: EnvironmentId('primary-$id'),
              taskId: task.id,
              role: EnvironmentRole.primary,
              providerId: ProviderId('test.uninstalled-environment'),
              providerState: const {},
            ),
            Environment(
              id: EnvironmentId('environment-$id'),
              taskId: task.id,
              role: EnvironmentRole.additional,
              providerId: ProviderId('test.uninstalled-environment'),
              providerState: const {},
            ),
          ],
          sessions: const [],
          authorities: const [],
          runRecords: const [],
        );
        expect(store.sessionsForTask(task.id), isEmpty);
      }
      Map<String, AdeleBackendDispatcher> storageServices(
        PluginBackendConnection connection,
      ) {
        final services = projectStorageServices(lifecycle, connection);
        expect(services.keys, [projectStorageServiceId]);
        for (final dispatcher in services.values) {
          addTearDown(dispatcher.close);
        }
        return services;
      }

      final fixture = await start(
        consumers: ['a', 'd'],
        providers: [],
        infrastructureServices: storageServices,
      );
      final consumer = fixture.consumer();
      final peer = fixture.consumer('d');
      final context = (await _call(
        consumer,
        'identity',
      ))['infrastructureContext'];
      Map<String, Object?> retained(String id) => {
        'ok': true,
        'rows': [
          {
            'environment_id': 'environment-$id',
            'project_id': 'project-$id',
            'value': 'before-session-$id',
          },
        ],
      };
      for (final id in ['a', 'b']) {
        expect(
          await _call(consumer, 'enrollEnvironment', {
            'environmentId': 'environment-$id',
            'value': 'before-session-$id',
          }),
          retained(id),
        );
        expect(
          await _call(consumer, 'queryEnvironment', {
            'environmentId': 'environment-$id',
            'sql': 'SELECT COUNT(*) AS count FROM adele_product_sessions',
          }),
          {
            'ok': true,
            'rows': [
              {'count': 0},
            ],
          },
        );
        expect(
          await _call(consumer, 'queryEnvironment', {
            'environmentId': 'environment-$id',
            'sql':
                'SELECT owner_id, version FROM adele_schema_versions '
                "WHERE owner_id LIKE 'test.%' ORDER BY owner_id",
          }),
          {
            'ok': true,
            'rows': [
              {'owner_id': 'test.consumer.a', 'version': 1},
            ],
          },
        );
      }
      // A sibling Environment selects the same Project, not a per-ID database.
      expect(
        await _call(consumer, 'queryEnvironment', {
          'environmentId': 'primary-a',
        }),
        retained('a'),
      );
      const query = {
        'environmentId': 'environment-a',
        'sql': 'SELECT value FROM fixture_environment_records',
        'parameters': <String, Object?>{},
        'accessMode': 'durableOrTemporary',
      };
      Future<Map<String, Object?>> rawStorage(
        PluginBackendConnection connection,
        String method,
        Map<String, Object?> arguments, {
        Object? token,
      }) => _call(connection, 'attack', {
        'serviceId': projectStorageServiceId,
        'method': method,
        'arguments': arguments,
        'context': ?token,
      });
      void failure(Map<String, Object?> result, String code) {
        expect(result['ok'], isFalse, reason: '$result');
        expect(result['type'], 'remote', reason: '$result');
        expect(result['code'], code, reason: '$result');
      }

      for (final override in [
        {'ownerId': 'test.forged-owner'},
        {'projectId': 'project-b'},
        {'databasePath': '${artifacts.path}/caller-selected.db'},
      ]) {
        failure(
          await rawStorage(
            consumer,
            projectStorageServiceEnsureSchemaForEnvironmentId,
            {
              'environmentId': 'environment-a',
              'migrations': ['CREATE TABLE fixture_override (value TEXT)'],
              'accessMode': 'durableOrTemporary',
              ...override,
            },
          ),
          'invalid_request',
        );
      }
      for (final request in [
        (
          method: projectStorageServiceEnsureSchemaForEnvironmentId,
          arguments: <String, Object?>{
            'migrations': ['CREATE TABLE fixture_unknown (value TEXT)'],
          },
        ),
        (
          method: projectStorageServiceQueryForEnvironmentId,
          arguments: <String, Object?>{
            'sql': query['sql'],
            'parameters': query['parameters'],
          },
        ),
        (
          method: projectStorageServiceTransactionForEnvironmentId,
          arguments: <String, Object?>{
            'statements': [
              {
                'sql': 'DELETE FROM fixture_environment_records',
                'parameters': <String, Object?>{},
                'expectedRows': 1,
              },
            ],
          },
        ),
      ]) {
        failure(
          await rawStorage(consumer, request.method, {
            ...request.arguments,
            'environmentId': 'unknown-environment',
            'accessMode': 'durableOrTemporary',
          }),
          'internal_error',
        );
      }
      for (final attempt in [
        (connection: consumer, token: 'forged-infrastructure'),
        (connection: peer, token: context),
      ]) {
        failure(
          await rawStorage(
            attempt.connection,
            projectStorageServiceQueryForEnvironmentId,
            query,
            token: attempt.token,
          ),
          'host_infrastructure_unavailable',
        );
      }
      consumer.revokeInfrastructureContext();
      failure(
        await _call(consumer, 'queryEnvironment', {
          'environmentId': 'environment-a',
        }),
        'host_infrastructure_unavailable',
      );
      final oldRequests = await _call(consumer, 'hostRequests');
      await consumer.close();
      final replacement = await fixture.bootstrap.host!.startPlugin(
        pluginId: consumer.pluginId,
        artifactUri: consumerArtifact.uri,
        createInfrastructureServices: storageServices,
      );
      addTearDown(replacement.close);
      final fresh = (await _call(
        replacement,
        'identity',
      ))['infrastructureContext'];
      expect(fresh, isNot(context));
      failure(
        await rawStorage(
          replacement,
          projectStorageServiceQueryForEnvironmentId,
          query,
          token: context,
        ),
        'host_infrastructure_unavailable',
      );
      for (final id in ['a', 'b']) {
        expect(
          await _call(replacement, 'queryEnvironment', {
            'environmentId': 'environment-$id',
          }),
          retained(id),
        );
        expect(store.sessionsForTask(TaskId('task-$id')), isEmpty);
      }
      // No Environment provider or read/process invocation grant participates.
      for (final snapshot in [
        oldRequests,
        await _call(peer, 'hostRequests'),
        await _call(replacement, 'hostRequests'),
      ]) {
        final requests = snapshot['requests'] as List;
        expect(requests, isNotEmpty);
        for (final request in requests.cast<Map<Object?, Object?>>()) {
          expect(request['hostContextKind'], 'infrastructure');
          expect(request['serviceId'], projectStorageServiceId);
        }
      }
    },
  );

  for (final declared in [true, false]) {
    test(
      'reserved infrastructure collision fails closed with declaration=$declared',
      () async {
        final lifecycle = ProductLifecycleCoordinator.generated(
          store: InMemoryProductStore(),
          registry: CapabilityRegistry(),
          extensions: ExtensionRegistry(),
        );
        addTearDown(lifecycle.close);
        final fixture = await prepare(
          providers: [],
          declarations: declared ? _declarations : [],
          infrastructureServices: (connection) => {
            _consumerService: projectStorageServices(
              lifecycle,
              connection,
            ).values.single,
          },
        );
        await fixture.starting.timeout(_bound);
        expect(fixture.bootstrap.state, ApplicationPluginState.ready);
        expect(fixture.bootstrap.catalog!.issues, isEmpty);
        final backend = fixture.bootstrap.backends.single;
        expect(backend.state, InstalledBackendState.failed);
        expect(backend.failure, isA<StateError>());
        expect(
          fixture.capabilities.providersFor(resourceInspectCapability),
          isEmpty,
        );
      },
    );
  }

  test(
    'shared-host nested requests overlap and a held provider does not deadlock discovery or another call',
    () async {
      final fixture = await start();
      final consumer = fixture.consumer();
      await _select(consumer, 'b');
      await _select(consumer, 'c');
      for (final id in ['b', 'c']) {
        await _control(fixture.provider(id), 'hold', {'key': '/held-$id'});
      }
      final b = _call(consumer, 'inspect', {
        'slot': 'b',
        'uri': 'test:/held-b',
      });
      final c = _call(consumer, 'inspect', {
        'slot': 'c',
        'uri': 'test:/held-c',
      });
      for (final id in ['b', 'c']) {
        await _control(fixture.provider(id), 'wait', {'key': '/held-$id'});
      }
      expect((await _call(consumer, 'discover'))['providers'], [
        _provider('c'),
        _provider('b'),
      ]);
      // This reaches the same B dispatcher while B's earlier nested call is held.
      expect(
        await _call(consumer, 'inspect', {
          'slot': 'b',
          'uri': 'test:/concurrent',
        }),
        _inspection('b', 'test:/concurrent'),
      );
      await _control(fixture.provider('c'), 'release', {'key': '/held-c'});
      expect(await c, _inspection('c', 'test:/held-c'));
      await _control(fixture.provider('b'), 'release', {'key': '/held-b'});
      expect(await b, _inspection('b', 'test:/held-b'));
      expect(await _requests(fixture.provider('b')), [
        _request('b', 'test:/held-b'),
        _request('b', 'test:/concurrent'),
      ]);
      expect(fixture.bootstrap.host!.isClosed, isFalse);
    },
  );

  test(
    'independent consumers cannot steal handles or infrastructure grants, and termination leaves siblings alive',
    () async {
      final fixture = await start(consumers: ['a', 'd'], providers: ['b']);
      final a = fixture.consumer('a');
      final d = fixture.consumer('d');
      final provider = fixture.provider('b');
      await _select(a, 'b');
      await _select(d, 'b');
      final raw = await _rawResolve(a);
      final handle = (raw['value'] as Map)['handle'];
      final context = (await _call(a, 'identity'))['infrastructureContext'];
      final invoke = {
        'handle': handle,
        'method': resourceInspectorServiceInspectId,
        'payload': {
          'resource': {'uri': 'test:/stolen', 'mediaType': null},
        },
      };
      _expectAttackDenied(await _attack(d, 'invoke', invoke));
      _expectAttackDenied(await _attack(d, 'release', {'handle': handle}));
      expect(
        (await _call(d, 'attack', {
          'context': context,
          'method': '$_consumerService.invoke',
          'arguments': invoke,
        }))['ok'],
        isFalse,
      );
      expect(await _requests(provider), isEmpty);
      expect(
        await _call(a, 'inspect', {'slot': 'b'}),
        _inspection('b', 'test:/ordinary'),
      );
      await _control(provider, 'hold', {'key': '/consumer-terminated'});
      final pending = _call(a, 'inspect', {
        'slot': 'b',
        'uri': 'test:/consumer-terminated',
      });
      final failed = expectLater(pending, throwsA(isA<PluginRemoteFailure>()));
      await _control(provider, 'wait', {'key': '/consumer-terminated'});
      await expectLater(
        _control(a, 'terminate'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await a.terminated.timeout(_bound);
      await failed;
      await _control(provider, 'release', {'key': '/consumer-terminated'});
      expect(
        await _call(d, 'inspect', {'slot': 'b', 'uri': 'test:/survivor'}),
        _inspection('b', 'test:/survivor'),
      );
      _expectAttackDenied(await _attack(d, 'invoke', invoke));
      expect(fixture.bootstrap.host!.isClosed, isFalse);
      expect(
        fixture.capabilities.providersFor(resourceInspectCapability),
        hasLength(1),
      );
      expect(await _requests(provider), [
        _request('b', 'test:/ordinary'),
        _request('b', 'test:/consumer-terminated'),
        _request('b', 'test:/survivor'),
      ]);
    },
  );
}

final class _Installation {
  _Installation({
    Map<String, AdeleBackendDispatcher> Function(PluginBackendConnection)?
    infrastructureServices,
  }) {
    bootstrap = ApplicationPluginBootstrap(
      capabilities,
      ExtensionRegistry(),
      createInfrastructureServices: infrastructureServices,
    );
  }

  final capabilities = CapabilityRegistry();
  late final ApplicationPluginBootstrap bootstrap;
  late final Future<void> starting;

  Future<void> ready() async {
    await starting.timeout(_bound);
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(bootstrap.failure, isNull);
    expect(bootstrap.catalog!.issues, isEmpty);
    for (final backend in bootstrap.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
  }

  PluginBackendConnection consumer([String id = 'a']) =>
      _connection('test.consumer.$id');
  PluginBackendConnection provider(String id) =>
      _connection('test.backend.$id');
  PluginBackendConnection _connection(String pluginId) => bootstrap.backends
      .singleWhere((entry) => entry.installation.metadata.id.value == pluginId)
      .connection!;
}

Future<void> _manifest(
  Directory directory,
  String id,
  Map<String, Object?> backend,
) => File('${directory.path}/adele_plugin.installation.json').writeAsString(
  jsonEncode({
    'manifestVersion': 1,
    'metadata': {'id': id, 'version': '1', 'displayName': id},
    'components': {'backend': backend},
  }),
);

Map<String, Object?> _provider(String id) => {
  'capabilityId': resourceInspectCapability.id.value,
  'majorVersion': 1,
  'providerId': 'test.inspector.$id',
  'pluginId': 'test.backend.$id',
  'displayName': 'Inspector ${id.toUpperCase()}',
  'serviceId': resourceInspectorServiceId,
};

final _catalogQuery = {
  'capabilityId': modelCatalogCapability.id.value,
  'majorVersion': modelCatalogCapability.majorVersion,
  'expectedServiceId': modelCatalogServiceId,
};

Map<String, Object?> _catalogProvider(String account) => {
  'capabilityId': modelCatalogCapability.id.value,
  'majorVersion': modelCatalogCapability.majorVersion,
  'providerId': 'test.catalog.$account',
  'pluginId': 'test.backend.catalog',
  'displayName': 'Catalog $account',
  'serviceId': modelCatalogServiceId,
};

Map<String, Object?> _catalogSnapshot(String account, {int revision = 0}) => {
  'ok': true,
  'models': [
    {
      'modelId': 'scripted-v1',
      'displayName': 'Scripted $account v$revision',
      'description': null,
    },
  ],
};

Map<String, Object?> _catalogRequest(String account) => {
  'configurationContext': 'catalog-$account',
  'serviceId': modelCatalogServiceId,
  'method': modelCatalogServiceListModelsId,
  'payload': <String, Object?>{},
  'hostInvocationContext': null,
  'hostInfrastructureContext': null,
};

Future<Map<String, Object?>> _selectCatalog(
  PluginBackendConnection consumer,
  String account,
) => _call(consumer, 'resolve', {
  ..._catalogQuery,
  'slot': account,
  'providerId': 'test.catalog.$account',
});

Map<String, Object?> _inspection(String id, String uri, {String? mediaType}) =>
    {
      'ok': true,
      'providerLabel': id.toUpperCase(),
      'resource': {'uri': uri, 'mediaType': mediaType},
      'summary': '${id.toUpperCase()} inspected $uri',
    };

Map<String, Object?> _request(String id, String uri, {String? mediaType}) => {
  'configurationContext': 'configured-$id',
  'serviceId': resourceInspectorServiceId,
  'method': resourceInspectorServiceInspectId,
  'payload': {
    'resource': {'uri': uri, 'mediaType': mediaType},
  },
  'hostInvocationContext': null,
  'hostInfrastructureContext': null,
};

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, _controlService)
    .request(method, payload)
    .timeout(_bound);

Future<Map<String, Object?>> _call(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) async => Map<String, Object?>.from(
  await _control(connection, method, payload) as Map,
);

Future<List<Object?>> _requests(PluginBackendConnection connection) async =>
    List<Object?>.from(
      (await _control(connection, 'snapshot') as Map)['requests'] as List,
    );

Future<Map<String, Object?>> _select(
  PluginBackendConnection consumer,
  String id, {
  String? slot,
}) => _call(consumer, 'resolve', {
  'slot': slot ?? id,
  'providerId': 'test.inspector.$id',
});

Future<Map<String, Object?>> _attack(
  PluginBackendConnection consumer,
  String method,
  Map<String, Object?> arguments,
) => _call(consumer, 'attack', {
  'method': '$_consumerService.$method',
  'arguments': arguments,
});

Future<Map<String, Object?>> _rawResolve(PluginBackendConnection consumer) =>
    _attack(consumer, 'resolve', {
      'capabilityId': resourceInspectCapability.id.value,
      'majorVersion': 1,
      'expectedServiceId': resourceInspectorServiceId,
      'providerId': 'test.inspector.b',
    });

void _expectUnavailable(Map<String, Object?> result) {
  expect(
    result['ok'] == false || result['provider'] == null,
    isTrue,
    reason: '$result',
  );
}

void _expectAttackDenied(Map<String, Object?> result) {
  expect(
    result['ok'] == false ||
        (result['value'] is Map && (result['value'] as Map)['ok'] == false),
    isTrue,
    reason: '$result',
  );
}
