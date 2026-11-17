import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_core_extensions/remote_command.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_backend_support/adele_capability_publisher.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart'
    show AdeleHostRequestMultiplexer;

const _bound = Duration(seconds: 10);

/// Independent provider: only public contracts and plugin-side support are linked.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final hostRequests = AdeleHostRequestMultiplexer(send: responses.send);
  final fixture = _Fixture(
    AdeleCapabilityPublisher(
      hostRequests: hostRequests,
      hostInfrastructureContext:
          bootstrap['hostInfrastructureContext'] as String,
    ),
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': [
      for (final account in fixture.active.values)
        for (final exposure in account.exposures) exposure.toMap(),
    ],
    'extensionExposures': [
      AdeleExtensionExposure(
        extensionPointId: commandContributions.value,
        extensionId: 'test.publication.command-registration',
        serviceId: remoteCommandServiceId,
        configurationContext: 'command',
        metadata: {
          'commandId': 'test.publication.command',
          'label': 'Publication fixture command',
          'routeId': 'unchanged',
        },
      ).toMap(),
    ],
  });
  try {
    await for (final Object? message in commands) {
      if (hostRequests.handleResponse(message)) continue;
      if (message is! Map) continue;
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        fixture.releaseAll();
        await fixture.router.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': null,
        });
        break;
      }
      if (message['kind'] == 'request' &&
          message['serviceId'] == 'test.controller') {
        // Reverse replies, stream controls and old-route releases must remain
        // receivable while a publication or a drain is waiting.
        unawaited(fixture.control(message, responses));
        continue;
      }
      fixture.frames.add({
        'kind': message['kind'],
        'configurationContext': message['configurationContext'],
        'serviceId': message['serviceId'],
        'method': message['method'],
        'requestId': message['requestId'],
      });
      unawaited(fixture.router.handle(message, responses.send));
    }
  } finally {
    fixture.releaseAll();
    hostRequests.close();
    commands.close();
    await fixture.router.close();
  }
}

final class _Fixture implements RemoteCommandService {
  _Fixture(this.publisher) {
    router = AdeleConfigurationContextRouter(
      contexts: {
        'command': {
          remoteCommandServiceId: RemoteCommandServiceDispatcher(this),
        },
      },
    );
    // The ready advertisement captures retireable routes, not static contexts
    // which would need mutation to support replacement later in this generation.
    for (final id in ['a', 'b']) {
      active[id] = create(id, 0);
    }
  }

  final AdeleCapabilityPublisher publisher;
  late final AdeleConfigurationContextRouter router;
  final active = <String, _Account>{};
  final draining = <String, _Account>{};
  final frames = <Map<String, Object?>>[];
  int allocatedRoutes = 0;
  int closedRoutes = 0;
  int commandCalls = 0;

  _Account create(String id, int revision) {
    final account = _Account(id, revision);
    account.inferenceRoute = router.registerContext(
      services: {
        modelProviderServiceId: ModelProviderServiceDispatcher(account),
      },
    );
    account.catalogRoute = router.registerContext(
      services: {
        modelCatalogServiceId: ModelCatalogServiceDispatcher(
          account,
          concurrent: true,
        ),
      },
    );
    allocatedRoutes += 2;
    return account;
  }

  void retireRoutes(_Account account) {
    draining[account.label] = account;
    account.drain =
        Future.wait([
          account.inferenceRoute.retire(),
          account.catalogRoute.retire(),
        ]).then((_) {
          closedRoutes += 2;
          draining.remove(account.label);
        });
  }

  _Account account(Map<Object?, Object?> payload) {
    final id = payload['account'] as String? ?? 'a';
    final revision = payload['revision'] as int?;
    final current = active[id];
    if (current != null && (revision == null || current.revision == revision)) {
      return current;
    }
    return draining['$id:$revision']!;
  }

  Map<String, Object?> snapshot() => {
    'accounts': {
      for (final entry in active.entries) entry.key: entry.value.snapshot(),
    },
    'draining': draining.keys.toList(),
    'allocatedRoutes': allocatedRoutes,
    'closedRoutes': closedRoutes,
    'commandCalls': commandCalls,
    'frames': frames,
  };

  Future<void> control(
    Map<Object?, Object?> command,
    SendPort responses,
  ) async {
    try {
      final payload = command['payload'] as Map;
      switch (command['method']) {
        case 'adopt':
          for (final account in active.values) {
            account.publication = await publisher.adoptAdvertised(
              account.exposures,
            );
          }
        case 'publish':
          final id = payload['account'] as String;
          if (active.containsKey(id)) throw StateError('Already published.');
          final next = create(id, 0);
          try {
            next.publication = await publisher.publish(next.exposures);
            active[id] = next;
          } on Object {
            retireRoutes(next);
            await next.drain;
            rethrow;
          }
        case 'replace':
          final old = account(payload);
          final next = create(old.id, old.revision + 1);
          try {
            next.publication = await old.publication.replace(next.exposures);
          } on Object {
            retireRoutes(next);
            await next.drain;
            rethrow;
          }
          active[old.id] = next;
          retireRoutes(old);
        case 'invalidReplace':
          // A live B collision must be rejected before A is retired, even though
          // this is otherwise a complete, valid association-closed group.
          await active['a']!.publication.replace(active['b']!.exposures);
        case 'invalidPublish':
          await publisher.publish(active['a']!.exposures);
        case 'retire':
          final old = account(payload);
          await old.publication.retire();
          active.remove(old.id);
          retireRoutes(old);
        case 'waitDrained':
          await draining[payload['label']]?.drain.timeout(_bound);
        case 'holdCatalog':
          account(payload).catalogGate = Completer<void>();
        case 'waitCatalog':
          await account(payload).catalogEntered.future.timeout(_bound);
        case 'releaseCatalog':
          account(payload).catalogGate!.complete();
        case 'waitStream':
          await account(
            payload,
          ).streamEntered(payload['key'] as String).future.timeout(_bound);
        case 'emit':
          final owner = account(payload);
          owner.streams[payload['key']]!.controller.add(
            ModelProviderEvent(
              kind: ModelProviderEventKind.observation,
              observation: ModelProviderObservation(
                kind: ModelProviderObservationKind.textDelta,
                textDelta: '${owner.label}:${payload['text']}',
                itemId: null,
              ),
              output: null,
              terminal: null,
            ),
          );
        case 'holdCancel':
          account(payload).streams[payload['key']]!.cancelGate =
              Completer<void>();
        case 'waitCancel':
          await account(
            payload,
          ).streams[payload['key']]!.cancelEntered.future.timeout(_bound);
        case 'releaseCancel':
          account(payload).streams[payload['key']]!.cancelGate!.complete();
        case 'snapshot':
          break;
        default:
          throw StateError('Unknown publication fixture control.');
      }
      responses.send({
        'kind': 'response',
        'requestId': command['requestId'],
        'ok': true,
        'payload': jsonDecode(jsonEncode({'ok': true, ...snapshot()})),
      });
    } on Object catch (error) {
      responses.send({
        'kind': 'response',
        'requestId': command['requestId'],
        'ok': true,
        'payload': {
          'ok': false,
          if (error is AdeleCapabilityPublicationFailure)
            'failure': error.kind.name,
          'message': '$error',
        },
      });
    }
  }

  @override
  Future<void> invoke(String routeId) async {
    if (routeId != 'unchanged') throw StateError('Unknown command route.');
    commandCalls++;
  }

  void releaseAll() {
    for (final account in [...active.values, ...draining.values]) {
      final gate = account.catalogGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      for (final stream in account.streams.values) {
        final cancel = stream.cancelGate;
        if (cancel != null && !cancel.isCompleted) cancel.complete();
      }
    }
  }
}

final class _Account implements ModelProviderService, ModelCatalogService {
  _Account(this.id, this.revision);

  final String id;
  final int revision;
  String get label => '$id:$revision';
  late final AdeleConfigurationContextRegistration inferenceRoute;
  late final AdeleConfigurationContextRegistration catalogRoute;
  late AdelePublishedCapabilityGroup publication;
  late Future<void> drain;
  Completer<void>? catalogGate;
  final catalogEntered = Completer<void>();
  final streams = <String, _Invocation>{};
  final _entered = <String, Completer<void>>{};

  List<AdeleCapabilityExposure> get exposures => [
    AdeleCapabilityExposure(
      providerId: 'test.publication.inference.$id',
      capabilityId: modelProviderCapability.id.value,
      capabilityMajorVersion: modelProviderCapability.majorVersion,
      serviceId: modelProviderServiceId,
      displayName: 'Inference $id',
      configurationContext: inferenceRoute.configurationContext,
    ),
    AdeleCapabilityExposure(
      providerId: 'test.publication.catalog.$id',
      capabilityId: modelCatalogCapability.id.value,
      capabilityMajorVersion: modelCatalogCapability.majorVersion,
      serviceId: modelCatalogServiceId,
      displayName: 'Catalog $id',
      configurationContext: catalogRoute.configurationContext,
      association: AdeleProviderAssociation(
        capabilityId: modelProviderCapability.id.value,
        capabilityMajorVersion: modelProviderCapability.majorVersion,
        providerId: 'test.publication.inference.$id',
      ),
    ),
  ];

  Map<String, Object?> snapshot() => {
    'revision': revision,
    'inferenceContext': inferenceRoute.configurationContext,
    'catalogContext': catalogRoute.configurationContext,
    'streams': streams.keys.toList(),
  };

  Completer<void> streamEntered(String key) =>
      _entered.putIfAbsent(key, Completer<void>.new);

  @override
  Future<ModelCatalogSnapshot> listModels() async {
    if (!catalogEntered.isCompleted) catalogEntered.complete();
    await catalogGate?.future;
    return ModelCatalogSnapshot(
      models: [
        ModelCatalogEntry(
          modelId: 'fixture-model',
          displayName: 'Catalog $label',
          description: null,
        ),
      ],
    );
  }

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) {
    final key = request.model;
    if (streams.containsKey(key)) throw StateError('Duplicate stream key.');
    final invocation = _Invocation();
    invocation.controller = StreamController<ModelProviderEvent>(
      onListen: () => streamEntered(key).complete(),
      onCancel: () async {
        invocation.cancelEntered.complete();
        await invocation.cancelGate?.future;
        streams.remove(key);
      },
    );
    streams[key] = invocation;
    return invocation.controller.stream;
  }
}

final class _Invocation {
  late final StreamController<ModelProviderEvent> controller;
  final cancelEntered = Completer<void>();
  Completer<void>? cancelGate;
}
