@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/model_provider_host.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _bound = Duration(seconds: 10);
const _providerId = 'test.publication.provider';
const _consumerId = 'test.publication.consumer';
final _catalogQuery = {
  'capabilityId': modelCatalogCapability.id.value,
  'majorVersion': modelCatalogCapability.majorVersion,
  'expectedServiceId': modelCatalogServiceId,
};

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File providerArtifact;
  late File consumerArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'adele-capability-publication-',
    );
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    providerArtifact = File('${artifacts.path}/provider.aot');
    consumerArtifact = File('${artifacts.path}/consumer.aot');
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'app/test/fixtures/backend_capability_publication_provider.dart',
        artifact: providerArtifact,
      ),
      (
        entrypoint: 'app/test/fixtures/backend_capability_consumer.dart',
        artifact: consumerArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'capability-publication-integration',
      );
    }
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  Future<_Installation> start() async {
    final root = await Directory(
      '${artifacts.path}/case-${sequence++}',
    ).create();
    for (final plugin in [
      (id: _consumerId, artifact: consumerArtifact),
      (id: _providerId, artifact: providerArtifact),
    ]) {
      final directory = await Directory('${root.path}/${plugin.id}').create();
      await plugin.artifact.copy('${directory.path}/backend.aot');
      await File(
        '${directory.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': plugin.id,
            'version': '1',
            'displayName': plugin.id,
          },
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              if (plugin.id == _consumerId)
                'consumesCapabilities': [
                  {
                    'id': modelCatalogCapability.id.value,
                    'majorVersion': modelCatalogCapability.majorVersion,
                  },
                ],
              // Publication reuses advertisement authority. There is deliberately
              // no special provider permission, settings or startup argument.
            },
          },
        }),
      );
    }
    final installation = _Installation();
    addTearDown(installation.bootstrap.close);
    await installation.bootstrap
        .start(
          installationRoot: root.path,
          dartaotruntimeExecutable: aotRuntime,
          hostArtifactPath: hostArtifact.path,
        )
        .timeout(_bound);
    expect(installation.bootstrap.state, ApplicationPluginState.ready);
    expect(installation.bootstrap.failure, isNull);
    expect(installation.bootstrap.catalog!.issues, isEmpty);
    expect(installation.bootstrap.backends, hasLength(2));
    for (final backend in installation.bootstrap.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
    return installation;
  }

  test(
    'publication AOT fixture links only public contracts and support',
    () async {
      final source = await File(
        'test/fixtures/backend_capability_publication_provider.dart',
      ).readAsString();
      expect(
        RegExp(
          r"import '([^']+)'",
        ).allMatches(source).map((match) => match[1]!).toSet(),
        {
          'dart:async',
          'dart:convert',
          'dart:isolate',
          'package:adele_contract/adele_contract.dart',
          'package:adele_core_extensions/adele_core_extensions.dart',
          'package:adele_core_extensions/remote_command.dart',
          'package:adele_model_provider/adele_model_catalog.dart',
          'package:adele_model_provider/adele_model_provider.dart',
          'package:adele_plugin_backend_support/adele_capability_publisher.dart',
          'package:adele_plugin_backend_support/adele_plugin_backend_support.dart',
        },
      );
    },
  );

  test(
    'normal AOT publication replaces exact A routes while admitted work, B and extensions survive',
    () async {
      final fixture = await start();
      final provider = fixture.provider;
      final consumer = fixture.consumer;
      final host = fixture.bootstrap.host!;
      final processId = host.processId;
      final generation = provider.defaultConfigurationContext;
      final a = fixture.bindings('a');
      final b = fixture.bindings('b');
      final capturedAdapter = ModelProviderCapabilityAdapter(
        a.inference,
        selectedModel: 'captured-adapter',
      );
      final owner = fixture.bootstrap.backendForProvider(a.inference)!;
      final commandResolver = CommandResolver(fixture.extensions);
      final commandId = CommandId('test.publication.command');
      final command = commandResolver.resolve(commandId);
      final original = await _ok(provider, 'snapshot');
      final originalA = _account(original, 'a');
      final originalB = _account(original, 'b');
      final oldCatalogClient = ModelCatalogServiceClient(
        a.catalog.requestChannel,
      );
      final oldInferenceClient = ModelProviderServiceClient(
        a.inference.streamChannel,
      );
      expect(provider.capabilityExposures, hasLength(4));
      expect(consumer.capabilityExposures, isEmpty);
      for (final id in ['a', 'b']) {
        final routes = _account(original, id);
        for (final kind in ['inference', 'catalog']) {
          expect(
            provider.capabilityExposures
                .singleWhere(
                  (e) => e.providerId == 'test.publication.$kind.$id',
                )
                .configurationContext,
            routes['${kind}Context'],
          );
        }
      }
      fixture.expectAssociation(a);
      fixture.expectAssociation(b);
      await command.invoke().timeout(_bound);
      await _ok(provider, 'adopt');
      _sameBindings(fixture.bindings('a'), a);
      _sameBindings(fixture.bindings('b'), b);
      expect(await _discovered(consumer), [_catalogId('a'), _catalogId('b')]);
      await _select(consumer, 'a');
      await _select(consumer, 'b');

      await _ok(provider, 'holdCatalog');
      final heldCatalog = _call(consumer, 'listModels', {'slot': 'a'});
      await _ok(provider, 'waitCatalog');
      final oldStream = StreamIterator(
        oldInferenceClient.invoke(_request('old-a')),
      );
      final bStream = StreamIterator(
        ModelProviderServiceClient(
          b.inference.streamChannel,
        ).invoke(_request('b')),
      );
      addTearDown(oldStream.cancel);
      addTearDown(bStream.cancel);
      await _next(provider, oldStream, 'a', 'old-a', 'before');
      await _next(provider, bStream, 'b', 'b', 'before');
      final before = await _ok(provider, 'snapshot');
      final oldStreamId = _frames(before).singleWhere(
        (f) =>
            f['kind'] == 'streamOpen' &&
            f['configurationContext'] == originalA['inferenceContext'],
      )['requestId'];
      final oldCredits = _frames(before)
          .where(
            (f) => f['kind'] == 'streamCredit' && f['requestId'] == oldStreamId,
          )
          .length;

      await _ok(provider, 'publish', {'account': 'c'});
      final c = fixture.bindings('c');
      fixture.expectAssociation(c);
      expect(await _discovered(consumer), [
        _catalogId('a'),
        _catalogId('b'),
        _catalogId('c'),
      ]);
      await _select(consumer, 'c');
      expect(
        await _call(consumer, 'listModels', {'slot': 'c'}),
        _catalog('c', 0),
      );
      await _ok(provider, 'retire', {'account': 'c'});
      await _ok(provider, 'waitDrained', {'label': 'c:0'});
      _stale(c);
      expect(
        (await _call(consumer, 'listModels', {'slot': 'c'}))['ok'],
        isFalse,
      );
      expect(
        await _call(consumer, 'resolve', {
          ..._catalogQuery,
          'providerId': _catalogId('c'),
        }),
        {'ok': true, 'provider': null},
      );
      expect(await _discovered(consumer), [_catalogId('a'), _catalogId('b')]);

      final replaced = await _ok(provider, 'replace');
      expect(replaced['draining'], ['a:0']);
      final freshA = fixture.bindings('a');
      expect(freshA.inference.isSameRegistration(a.inference), isFalse);
      expect(freshA.catalog.isSameRegistration(a.catalog), isFalse);
      _stale(a);
      expect(
        () => owner.associationFor(a.catalog),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        () => owner.resolveAssociatedProvider(
          modelCatalogCapability,
          associatedWith: a.inference,
        ),
        throwsA(isA<ProviderUnavailable>()),
      );
      final adapterEvents = await capturedAdapter
          .invoke(
            SemanticModelRequest(
              invocationId: ModelInvocationId('stale-adapter'),
              context: InferenceContextSnapshot.fromStrategy(
                StrategyInferenceMaterial(input: const []),
              ),
              tools: MaterializedToolSet(const []),
            ),
          )
          .toList()
          .timeout(_bound);
      expect(
        adapterEvents.single,
        isA<ModelInvocationFailedEvent>().having(
          (event) => event.error,
          'error',
          isA<ProviderUnavailable>().having((e) => e.stale, 'stale', isTrue),
        ),
      );
      expect(capturedAdapter.invocationCount, 0);
      fixture.expectAssociation(freshA);
      fixture.expectAssociation(b);
      _sameBindings(fixture.bindings('b'), b);
      final freshRoutes = _account(replaced, 'a');
      expect(
        freshRoutes['inferenceContext'],
        isNot(originalA['inferenceContext']),
      );
      expect(freshRoutes['catalogContext'], isNot(originalA['catalogContext']));
      expect(_account(replaced, 'b'), _account(before, 'b'));
      expect(
        fixture.bootstrap.backendForProvider(freshA.inference),
        same(owner),
      );
      expect(fixture.bootstrap.backendForProvider(freshA.catalog), same(owner));

      // Neither an old peer handle nor a previously extracted raw client can
      // silently resolve the new same-ID registration or select B as fallback.
      expect(
        (await _call(consumer, 'listModels', {'slot': 'a'}))['ok'],
        isFalse,
      );
      await expectLater(
        oldCatalogClient.listModels(),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      await expectLater(
        oldInferenceClient.invoke(_request('stale-a')).toList(),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      await _select(consumer, 'a', slot: 'fresh-a');
      expect(
        await _call(consumer, 'listModels', {'slot': 'fresh-a'}),
        _catalog('a', 1),
      );
      expect(
        await _call(consumer, 'listModels', {'slot': 'b'}),
        _catalog('b', 0),
      );
      final freshStream = StreamIterator(
        ModelProviderServiceClient(
          freshA.inference.streamChannel,
        ).invoke(_request('fresh-a')),
      );
      addTearDown(freshStream.cancel);
      await _next(
        provider,
        freshStream,
        'a',
        'fresh-a',
        'new-route',
        revision: 1,
      );
      await freshStream.cancel().timeout(_bound);
      await _ok(provider, 'releaseCatalog', {'revision': 0});
      expect(await heldCatalog, _catalog('a', 0));

      // StreamIterator pauses after every item. Resuming after replacement must
      // send credit to the old owner, never to A's fresh immutable context.
      await _next(provider, oldStream, 'a', 'old-a', 'after', revision: 0);
      await _next(provider, bStream, 'b', 'b', 'after');
      final resumed = await _ok(provider, 'snapshot');
      expect(
        _frames(resumed)
            .where(
              (f) =>
                  f['kind'] == 'streamCredit' && f['requestId'] == oldStreamId,
            )
            .length,
        greaterThan(oldCredits),
      );
      expect(_account(resumed, 'a')['streams'], isEmpty);
      expect(_account(resumed, 'b')['streams'], ['b']);
      await _ok(provider, 'holdCancel', {'revision': 0, 'key': 'old-a'});
      var cancelled = false;
      final cancellation = oldStream.cancel().then((_) => cancelled = true);
      await _ok(provider, 'waitCancel', {'revision': 0, 'key': 'old-a'});
      expect(cancelled, isFalse);
      expect((await _ok(provider, 'snapshot'))['draining'], ['a:0']);
      await _next(provider, bStream, 'b', 'b', 'during-a-cancel');
      await _ok(provider, 'releaseCancel', {'revision': 0, 'key': 'old-a'});
      await cancellation.timeout(_bound);
      await _ok(provider, 'waitDrained', {'label': 'a:0'});
      await bStream.cancel().timeout(_bound);
      await command.invoke().timeout(_bound);

      final settled = await _ok(provider, 'snapshot');
      expect(settled['draining'], isEmpty);
      expect(settled['allocatedRoutes'], 8);
      expect(settled['closedRoutes'], 4);
      expect(settled['commandCalls'], 2);
      expect(_account(settled, 'b'), originalB);
      expect(
        _frames(settled).where(
          (f) => f['kind'] == 'streamCancel' && f['requestId'] == oldStreamId,
        ),
        hasLength(1),
      );
      expect(
        commandResolver
            .resolve(commandId)
            .binding
            .isSameRegistration(command.binding),
        isTrue,
      );
      _sameBindings(fixture.bindings('b'), b);
      expect(fixture.provider, same(provider));
      expect(fixture.consumer, same(consumer));
      expect(provider.defaultConfigurationContext, same(generation));
      expect(provider.validateInfrastructureContext, returnsNormally);
      expect(
        fixture.bootstrap.backendForProvider(freshA.inference),
        same(owner),
      );
      expect(owner.validate, returnsNormally);
      expect(fixture.bootstrap.host, same(host));
      expect(host.processId, processId);
      expect(host.isClosed, isFalse);
      expect(fixture.bootstrap.state, ApplicationPluginState.ready);
    },
  );

  test(
    'bad publication preserves A and repeated replacement drains without accumulation',
    () async {
      final fixture = await start();
      final provider = fixture.provider;
      final consumer = fixture.consumer;
      await _ok(provider, 'adopt');
      final a = fixture.bindings('a');
      final b = fixture.bindings('b');
      final initial = await _ok(provider, 'snapshot');
      for (final method in ['invalidPublish', 'invalidReplace']) {
        final failed = await _call(provider, method);
        expect(failed['ok'], isFalse);
        expect(failed['failure'], 'rejected');
        _sameBindings(fixture.bindings('a'), a);
        _sameBindings(fixture.bindings('b'), b);
        fixture.expectAssociation(a);
        expect(
          _account(await _ok(provider, 'snapshot'), 'a'),
          _account(initial, 'a'),
        );
        await _select(consumer, 'a', slot: method);
        expect(
          await _call(consumer, 'listModels', {'slot': method}),
          _catalog('a', 0),
        );
      }
      final contexts = <Object?>{
        _account(initial, 'a')['inferenceContext'],
        _account(initial, 'a')['catalogContext'],
        _account(initial, 'b')['inferenceContext'],
        _account(initial, 'b')['catalogContext'],
      };
      for (var revision = 1; revision <= 12; revision++) {
        final previous = fixture.bindings('a');
        await _ok(provider, 'replace');
        final snapshot = await _ok(provider, 'waitDrained', {
          'label': 'a:${revision - 1}',
        });
        _stale(previous);
        final current = fixture.bindings('a');
        fixture.expectAssociation(current);
        expect(
          current.inference.isSameRegistration(previous.inference),
          isFalse,
        );
        expect(current.catalog.isSameRegistration(previous.catalog), isFalse);
        final routes = _account(snapshot, 'a');
        expect(contexts.add(routes['inferenceContext']), isTrue);
        expect(contexts.add(routes['catalogContext']), isTrue);
        expect(snapshot['draining'], isEmpty);
        expect(snapshot['closedRoutes'], revision * 2);
        expect(snapshot['allocatedRoutes'], revision * 2 + 4);
        expect(
          fixture.capabilities.providersFor(modelProviderCapability),
          hasLength(2),
        );
        expect(
          fixture.capabilities.providersFor(modelCatalogCapability),
          hasLength(2),
        );
        expect(await _discovered(consumer), [_catalogId('a'), _catalogId('b')]);
        final slot = 'revision-$revision';
        await _select(consumer, 'a', slot: slot);
        expect(
          await _call(consumer, 'listModels', {'slot': slot}),
          _catalog('a', revision),
        );
        await _ok(consumer, 'release', {'slot': slot});
        _sameBindings(fixture.bindings('b'), b);
        expect(_account(snapshot, 'b'), _account(initial, 'b'));
      }
      expect(fixture.provider, same(provider));
      expect(fixture.consumer, same(consumer));
      expect(fixture.bootstrap.host!.isClosed, isFalse);
    },
  );
}

typedef _Bindings = ({ProviderBinding inference, ProviderBinding catalog});

final class _Installation {
  _Installation() {
    bootstrap = ApplicationPluginBootstrap(capabilities, extensions);
  }

  final capabilities = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  late final ApplicationPluginBootstrap bootstrap;

  PluginBackendConnection get provider => _connection(_providerId);
  PluginBackendConnection get consumer => _connection(_consumerId);
  PluginBackendConnection _connection(String id) => bootstrap.backends
      .singleWhere((backend) => backend.installation.metadata.id.value == id)
      .connection!;

  _Bindings bindings(String id) => (
    inference: capabilities.resolve(
      modelProviderCapability,
      providerId: ProviderId('test.publication.inference.$id'),
    ),
    catalog: capabilities.resolve(
      modelCatalogCapability,
      providerId: ProviderId(_catalogId(id)),
    ),
  );

  void expectAssociation(_Bindings binding) {
    final owner = bootstrap.backendForProvider(binding.catalog)!;
    expect(bootstrap.backendForProvider(binding.inference), same(owner));
    expect(
      owner
          .associationFor(binding.catalog)!
          .isSameRegistration(binding.inference),
      isTrue,
    );
    expect(owner.associationFor(binding.inference), isNull);
    expect(
      owner
          .resolveAssociatedProvider(
            modelCatalogCapability,
            associatedWith: binding.inference,
          )
          .isSameRegistration(binding.catalog),
      isTrue,
    );
  }
}

void _sameBindings(_Bindings actual, _Bindings expected) {
  expect(actual.inference.isSameRegistration(expected.inference), isTrue);
  expect(actual.catalog.isSameRegistration(expected.catalog), isTrue);
  expect(actual.inference.endpointAs<CapabilityEndpoint>, returnsNormally);
  expect(actual.catalog.endpointAs<CapabilityEndpoint>, returnsNormally);
}

void _stale(_Bindings bindings) {
  for (final binding in [bindings.inference, bindings.catalog]) {
    expect(
      () => binding.requestChannel,
      throwsA(
        isA<ProviderUnavailable>().having((e) => e.stale, 'stale', isTrue),
      ),
    );
  }
}

Future<Map<String, Object?>> _call(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) async => Map<String, Object?>.from(
  await connection
          .channelFor(connection.defaultConfigurationContext, 'test.controller')
          .request(method, payload)
          .timeout(_bound)
      as Map,
);

Future<Map<String, Object?>> _ok(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) async {
  final result = await _call(connection, method, payload);
  expect(result['ok'], isTrue, reason: '$method: $result');
  return result;
}

String _catalogId(String id) => 'test.publication.catalog.$id';

Future<void> _select(
  PluginBackendConnection consumer,
  String id, {
  String? slot,
}) async {
  final result = await _ok(consumer, 'resolve', {
    ..._catalogQuery,
    'providerId': _catalogId(id),
    'slot': slot ?? id,
  });
  expect(result['provider'], {
    'capabilityId': modelCatalogCapability.id.value,
    'majorVersion': modelCatalogCapability.majorVersion,
    'providerId': _catalogId(id),
    'pluginId': _providerId,
    'displayName': 'Catalog $id',
    'serviceId': modelCatalogServiceId,
  });
  expect(result['requestOnly'], isTrue);
}

Future<List<Object?>> _discovered(PluginBackendConnection consumer) async => [
  for (final provider
      in (await _ok(consumer, 'discover', _catalogQuery))['providers'] as List)
    (provider as Map)['providerId'],
];

Map<String, Object?> _catalog(String id, int revision) => {
  'ok': true,
  'models': [
    {
      'modelId': 'fixture-model',
      'displayName': 'Catalog $id:$revision',
      'description': null,
    },
  ],
};

Map<Object?, Object?> _account(Map<Object?, Object?> snapshot, String id) =>
    (snapshot['accounts'] as Map)[id] as Map;

Iterable<Map<Object?, Object?>> _frames(Map<Object?, Object?> snapshot) =>
    (snapshot['frames'] as List).cast<Map<Object?, Object?>>();

ModelProviderRequest _request(String key) => ModelProviderRequest(
  model: key,
  instructions: '',
  input: [],
  tools: [],
  toolChoice: ModelProviderToolChoice.none,
  maxOutputTokens: null,
  reasoningEffort: null,
  providerOptions: {},
  nativeState: null,
  affinity: null,
);

Future<void> _next(
  PluginBackendConnection provider,
  StreamIterator<ModelProviderEvent> stream,
  String account,
  String key,
  String text, {
  int revision = 0,
}) async {
  final next = stream.moveNext().timeout(_bound);
  final payload = {'account': account, 'revision': revision, 'key': key};
  await _ok(provider, 'waitStream', payload);
  await _ok(provider, 'emit', {...payload, 'text': text});
  expect(await next, isTrue);
  expect(stream.current.kind, ModelProviderEventKind.observation);
  expect(stream.current.observation!.textDelta, '$account:$revision:$text');
}
