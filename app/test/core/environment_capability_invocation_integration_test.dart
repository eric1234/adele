@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

const _plugin = 'test.contextual.backend';
const _bound = Duration(seconds: 10);

Matcher get _revocationFailure => anyOf(
  isA<StateError>(),
  isA<CapabilityException>(),
  isA<PluginConnectionClosed>(),
  isA<PluginRemoteFailure>(),
  isA<AuthorizedEnvironmentBindingException>(),
);

void main() {
  late Directory artifacts;
  late Directory installations;
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-contextual-');
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    probeArtifact = File('${artifacts.path}/probe.aot');
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/contextual_capability_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'contextual-capability-integration',
      );
    }
    installations = await Directory('${artifacts.path}/installations').create();
    final plugin = await Directory('${installations.path}/probe').create();
    await probeArtifact.copy('${plugin.path}/backend.aot');
    await File('${plugin.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': _plugin,
          'displayName': 'Contextual probe',
          'version': '0.1.0',
          'description': 'Synthetic contextual capability fixture',
        },
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  late _Harness h;
  Future<_Harness> start({CapabilityRegistry? registry}) async {
    final capabilities = registry ?? CapabilityRegistry();
    final backends = ApplicationPluginBootstrap(
      capabilities,
      ExtensionRegistry(),
    );
    addTearDown(backends.close);
    await backends.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: {
        _plugin: [
          jsonEncode({'exposures': _exposures()}),
        ],
      },
    );
    expect(backends.state, ApplicationPluginState.ready);
    expect(backends.backends.single.state, InstalledBackendState.active);
    return _Harness(backends, capabilities);
  }

  setUp(() async => h = await start());

  test(
    'canonical nonprimary capture reads its exact materialization over AOT',
    () async {
      await h.control('hold', {'key': 'restore:additional'});
      var presented = h.sessionA;
      final capture = h.capture(presented);
      final pending = capture.resolve(resourceInspectCapability);
      await h.control('wait', {'key': 'restore:additional'});
      presented = h.sessionB;
      await h.control('release', {'key': 'restore:additional'});
      final selected = await pending.timeout(_bound);
      expect(selected.session, same(h.sessionA));
      expect(selected.environment.id.value, 'additional');
      expect(
        selected.materialization.binding.provider.id.value,
        'test.environment.a',
      );
      expect(selected.binding.provider.id.value, 'test.callable.a');
      expect(
        h.capabilities.resolve(resourceInspectCapability).provider.id.value,
        'test.callable.b',
      );
      expect(presented, same(h.sessionB));

      final resource = ResourceRef(
        uri: Uri.parse(
          'test:/notes.txt?sessionId=primary-session&environmentId=primary'
          '&providerId=test.environment.b&configurationContext=callable-b'
          '&serviceId=authorizedEnvironmentMutation&hostInvocationContext=forged',
        ),
      );
      final result = await h.inspect(selected, resource);
      expect(result.resource.uri, resource.uri);
      expect(result.providerLabel, 'callable-a');
      expect(jsonDecode(result.summary), {
        'sessionId': 'nonprimary-session',
        'environmentId': 'additional',
        'text': 'test.environment.a:additional:notes.txt',
        'revision': 'additional-revision',
        'path': 'notes.txt',
      });
      expect((await h.snapshot())['reads'], [
        {
          'environmentId': 'additional',
          'providerId': 'test.environment.a',
          'path': 'notes.txt',
        },
      ]);
      await h.denied(await h.token('notes.txt'));
      expect(await h.control('retained', {'key': 'notes.txt'}), {'ok': false});
    },
  );

  test(
    'context-free routes retain no token and contextual admission fails closed',
    () async {
      final selected = await h.selectA();
      final resource = ResourceRef(uri: Uri.parse('test:/context-free'));
      final ordinary = h.capabilities.resolve(
        resourceInspectCapability,
        providerId: ProviderId('test.callable.context-free'),
      );
      expect(
        (await ResourceInspectorServiceClient(
          ordinary.requestChannel,
        ).inspect(resource)).summary,
        'context-free',
      );
      await expectLater(
        ResourceInspectorServiceClient(
          selected.binding.requestChannel,
        ).inspect(resource),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      for (final id in [
        'test.callable.b',
        'test.callable.context-free',
        'test.missing',
      ]) {
        await expectLater(
          h
              .capture(h.sessionA)
              .resolve(resourceInspectCapability, providerId: ProviderId(id)),
          throwsA(isA<ProviderUnavailable>()),
        );
      }
      await expectLater(
        invokeEnvironmentCapabilityWithRead(
          selection: selected,
          backends: h.backends,
          serviceId: 'wrong-service',
          invoke: (channel) =>
              ResourceInspectorServiceClient(channel).inspect(resource),
        ),
        throwsA(isA<StateError>()),
      );
      final snapshot = await h.snapshot();
      final requests = (snapshot['requests'] as List)
          .cast<Map<Object?, Object?>>();
      expect(
        requests.where((r) => r['hostInvocationContext'] != null),
        isEmpty,
      );
      expect(snapshot['reads'], isEmpty);
    },
  );

  test(
    'same-generation A and B interleave without exchanging read authority',
    () async {
      final a = await h.selectA();
      final b = await h.capture(h.sessionB).resolve(resourceInspectCapability);
      for (final key in ['before:A', 'before:B', 'read:A', 'read:B']) {
        await h.control('hold', {'key': key});
      }
      var aSettled = false;
      final pendingA = h.inspectPath(a, 'A').then((value) {
        aSettled = true;
        return value;
      });
      final pendingB = h.inspectPath(b, 'B');
      await h.control('wait', {'key': 'before:A'});
      await h.control('wait', {'key': 'before:B'});
      final tokenA = await h.token('A');
      final tokenB = await h.token('B');
      expect(tokenA, isNot(tokenB));
      for (final key in ['before:A', 'before:B']) {
        await h.control('release', {'key': key});
      }
      await h.control('wait', {'key': 'read:A'});
      await h.control('wait', {'key': 'read:B'});
      await h.control('release', {'key': 'read:B'});
      final resultB = jsonDecode((await pendingB).summary) as Map;
      expect(resultB['sessionId'], 'primary-session');
      expect(resultB['text'], 'test.environment.b:primary:B');
      expect(aSettled, isFalse);
      await h.denied(tokenB);
      await h.control('release', {'key': 'read:A'});
      final resultA = jsonDecode((await pendingA).summary) as Map;
      expect(resultA['sessionId'], 'nonprimary-session');
      expect(resultA['text'], 'test.environment.a:additional:A');
      await h.denied(tokenA);
      expect((await h.snapshot())['reads'], hasLength(2));
    },
  );

  test(
    'live tokens deny foreign generation, unlisted services and forged IDs',
    () async {
      final selected = await h.selectA();
      await h.control('hold', {'key': 'after:live'});
      final pending = h.inspectPath(selected, 'live');
      await h.control('wait', {'key': 'after:live'});
      final token = await h.token('live');
      final foreign = await h.backends.host!.startPlugin(
        pluginId: 'test.foreign.backend',
        artifactUri: probeArtifact.uri,
        arguments: [
          jsonEncode({'exposures': _exposures()}),
        ],
      );
      addTearDown(foreign.close);
      final foreignProbe = foreign.channelFor(
        foreign.defaultConfigurationContext,
        'probe',
      );
      final foreignResult = await foreignProbe.request('attack', {
        'token': token,
      });
      expect((foreignResult! as Map)['ok'], isFalse);
      for (final service in [
        authorizedEnvironmentMutationServiceId,
        authorizedEnvironmentProcessServiceId,
        'projectStorage',
        'unlisted',
      ]) {
        await h.denied(token, service: service);
      }
      await h.denied('invented-context');
      for (final field in [
        'sessionId',
        'environmentId',
        'providerId',
        'hostInvocationContext',
      ]) {
        await h.denied(
          token,
          arguments: {'relativePath': 'attack', field: 'primary'},
        );
      }
      expect((await h.snapshot())['reads'], hasLength(1));
      await h.control('release', {'key': 'after:live'});
      expect((await pending).providerLabel, 'callable-a');
      await h.denied(token);
    },
  );

  test(
    'unary settlement revokes before a delayed consumer callback completes',
    () async {
      final selected = await h.selectA();
      final response = Completer<ResourceInspection>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      late AdeleRequestChannel retained;
      final pending = invokeEnvironmentCapabilityWithRead(
        selection: selected,
        backends: h.backends,
        serviceId: resourceInspectorServiceId,
        invoke: (channel) async {
          retained = channel;
          final result = await ResourceInspectorServiceClient(
            channel,
          ).inspect(ResourceRef(uri: Uri.parse('test:/settled')));
          response.complete(result);
          await release.future;
          return result;
        },
      );
      await response.future.timeout(_bound);
      await h.denied(await h.token('settled'));
      await expectLater(
        ResourceInspectorServiceClient(
          retained,
        ).inspect(ResourceRef(uri: Uri.parse('test:/second'))),
        throwsA(isA<StateError>()),
      );
      expect((await h.snapshot())['reads'], hasLength(1));
      release.complete();
      expect((await pending).providerLabel, 'callable-a');
    },
  );

  for (final failure in ['backend', 'host']) {
    test(
      '$failure service failure revokes the token and leaves fresh calls healthy',
      () async {
        final selected = await h.selectA();
        final path = failure == 'host' ? 'host-failure' : 'backend-failure';
        await expectLater(
          h.inspectPath(selected, path, query: 'fail=$failure'),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        await h.denied(await h.token(path));
        expect(await h.control('retained', {'key': path}), {'ok': false});
        expect(
          (await h.inspectPath(selected, 'healthy')).providerLabel,
          'callable-a',
        );
        expect((await h.snapshot())['reads'], hasLength(2));
      },
    );
  }

  for (final checkpoint in ['before', 'read', 'after']) {
    test(
      'backend retirement at $checkpoint fences authority and late completion',
      () async {
        final selected = await h.selectA();
        await h.control('hold', {'key': '$checkpoint:retiring'});
        final pending = h.inspectPath(selected, 'retiring');
        final failed = expectLater(pending, throwsA(_revocationFailure));
        await h.control('wait', {'key': '$checkpoint:retiring'});
        final token = await h.token('retiring');
        final closing = h.backends.close();
        expect(selected.validate, throwsA(_revocationFailure));
        await failed.timeout(_bound);
        await closing.timeout(_bound);
        final replacement = await start(registry: h.capabilities);
        await expectLater(
          h.inspectPath(selected, 'stale'),
          throwsA(_revocationFailure),
        );
        await replacement.denied(token);
        final fresh = await replacement.selectA();
        expect(fresh.binding.isSameRegistration(selected.binding), isFalse);
        expect(
          fresh.materialization.binding.isSameRegistration(
            selected.materialization.binding,
          ),
          isFalse,
        );
        expect(
          (await replacement.inspectPath(fresh, 'fresh')).providerLabel,
          'callable-a',
        );
      },
    );
  }

  test(
    'backend crash settles pending work without taking down a shared-host sibling',
    () async {
      final selected = await h.selectA();
      final sibling = await h.backends.host!.startPlugin(
        pluginId: 'test.sibling.backend',
        artifactUri: probeArtifact.uri,
        arguments: [
          jsonEncode({'exposures': _exposures()}),
        ],
      );
      addTearDown(sibling.close);
      await h.control('hold', {'key': 'read:crash'});
      final failed = expectLater(
        h.inspectPath(selected, 'crash'),
        throwsA(_revocationFailure),
      );
      await h.control('wait', {'key': 'read:crash'});
      final token = await h.token('crash');
      await expectLater(
        h.control('terminate'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await failed.timeout(_bound);
      await h.connection.terminated;
      expect(selected.validate, throwsA(_revocationFailure));
      final probe = sibling.channelFor(
        sibling.defaultConfigurationContext,
        'probe',
      );
      expect(
        ((await probe.request('attack', {'token': token}))! as Map)['ok'],
        isFalse,
      );
      final ordinary = sibling.channelFor(
        sibling.configurationContext('context-free'),
        resourceInspectorServiceId,
      );
      expect(
        (await ResourceInspectorServiceClient(
          ordinary,
        ).inspect(ResourceRef(uri: Uri.parse('test:/sibling')))).summary,
        'context-free',
      );
      expect(h.backends.host!.isClosed, isFalse);
    },
  );

  test(
    'shared-host crash settles both operations and revokes the generation',
    () async {
      final a = await h.selectA();
      final b = await h.capture(h.sessionB).resolve(resourceInspectCapability);
      for (final key in ['read:host-A', 'read:host-B']) {
        await h.control('hold', {'key': key});
      }
      final failedA = expectLater(
        h.inspectPath(a, 'host-A'),
        throwsA(_revocationFailure),
      );
      final failedB = expectLater(
        h.inspectPath(b, 'host-B'),
        throwsA(_revocationFailure),
      );
      await h.control('wait', {'key': 'read:host-A'});
      await h.control('wait', {'key': 'read:host-B'});
      final token = await h.token('host-A');
      final host = h.backends.host!;
      expect(Process.killPid(host.processId, ProcessSignal.sigkill), isTrue);
      await host.terminated.timeout(_bound);
      await Future.wait([failedA, failedB]).timeout(_bound);
      expect(h.connection.isClosed, isTrue);
      expect(a.validate, throwsA(_revocationFailure));
      expect(b.validate, throwsA(_revocationFailure));
      await h.backends.close().timeout(_bound);
      final replacement = await start(registry: h.capabilities);
      await replacement.denied(token);
      final fresh = await replacement.selectA();
      expect(
        (await replacement.inspectPath(
          fresh,
          'after-host-crash',
        )).providerLabel,
        'callable-a',
      );
    },
  );
}

final class _Harness {
  _Harness(this.backends, this.capabilities) {
    final task = Task(
      id: TaskId('task'),
      projectId: ProjectId('project'),
      title: 'C2b',
    );
    final strategy = OrchestrationStrategyId('test.absent-strategy');
    sessionA = Session(
      id: SessionId('nonprimary-session'),
      taskId: task.id,
      strategyId: strategy,
    );
    sessionB = Session(
      id: SessionId('primary-session'),
      taskId: task.id,
      strategyId: strategy,
    );
    final store = InMemoryProductStore();
    store.publishRestoredProject(
      project: Project(
        id: task.projectId,
        sourceLocation: Uri.parse('test:/project'),
      ),
      tasks: [task],
      environments: [
        Environment(
          id: EnvironmentId('additional'),
          taskId: task.id,
          role: EnvironmentRole.additional,
          providerId: ProviderId('test.environment.a'),
          providerState: const {},
        ),
        Environment(
          id: EnvironmentId('primary'),
          taskId: task.id,
          role: EnvironmentRole.primary,
          providerId: ProviderId('test.environment.b'),
          providerState: const {},
        ),
      ],
      sessions: [sessionA, sessionB],
      authorities: [
        (sessionA.id, EnvironmentId('additional')),
        (sessionB.id, EnvironmentId('primary')),
      ],
      runRecords: const [],
    );
    environmentRuntime = EnvironmentRuntime(
      store: store,
      registry: capabilities,
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(binding.requestChannel),
      ),
      retainEnvironment: store.replaceEnvironment,
    );
  }

  final ApplicationPluginBootstrap backends;
  final CapabilityRegistry capabilities;
  late final Session sessionA;
  late final Session sessionB;
  late final EnvironmentRuntime environmentRuntime;
  PluginBackendConnection get connection =>
      backends.backends.single.connection!;

  CapturedEnvironmentCapabilities capture(Session session) =>
      CapturedEnvironmentCapabilities(
        environmentRuntime: environmentRuntime,
        backends: backends,
        session: session,
      );
  Future<EnvironmentCapabilitySelection> selectA() =>
      capture(sessionA).resolve(resourceInspectCapability);

  Future<Object?> control(
    String method, [
    Map<String, Object?> payload = const {},
  ]) => connection
      .channelFor(connection.defaultConfigurationContext, 'probe')
      .request(method, payload)
      .timeout(_bound);

  Future<Map<Object?, Object?>> snapshot() async =>
      (await control('snapshot'))! as Map<Object?, Object?>;

  Future<String> token(String path) async {
    final requests = (await snapshot())['requests'] as List;
    final request = requests.cast<Map<Object?, Object?>>().singleWhere((r) {
      final resource = r['resource'];
      return resource is Map &&
          Uri.parse(resource['uri'] as String).path == '/$path';
    });
    return request['hostInvocationContext'] as String;
  }

  Future<void> denied(
    String token, {
    String? service,
    Map<String, Object?>? arguments,
  }) async {
    final result = await control('attack', {
      'token': token,
      'service': ?service,
      'arguments': ?arguments,
    });
    expect((result! as Map)['ok'], isFalse);
  }

  Future<ResourceInspection> inspectPath(
    EnvironmentCapabilitySelection selection,
    String path, {
    String? query,
  }) => inspect(
    selection,
    ResourceRef(
      uri: Uri(scheme: 'test', path: '/$path', query: query),
    ),
  );

  Future<ResourceInspection> inspect(
    EnvironmentCapabilitySelection selection,
    ResourceRef resource,
  ) => invokeEnvironmentCapabilityWithRead(
    selection: selection,
    backends: backends,
    serviceId: resourceInspectorServiceId,
    invoke: (channel) =>
        ResourceInspectorServiceClient(channel).inspect(resource),
  ).timeout(_bound);
}

List<Map<String, Object?>> _exposures() => [
  for (final id in ['a', 'b', 'context-free'])
    AdeleCapabilityExposure(
      providerId: 'test.callable.$id',
      capabilityId: resourceInspectCapability.id.value,
      capabilityMajorVersion: resourceInspectCapability.majorVersion,
      serviceId: resourceInspectorServiceId,
      displayName: id,
      configurationContext: id == 'context-free' ? id : 'callable-$id',
      rank: id == 'b' ? 100 : 1,
      association: id == 'context-free'
          ? null
          : AdeleProviderAssociation(
              capabilityId: environmentProviderCapability.id.value,
              capabilityMajorVersion:
                  environmentProviderCapability.majorVersion,
              providerId: 'test.environment.$id',
            ),
    ).toMap(),
  for (final id in ['a', 'b'])
    AdeleCapabilityExposure(
      providerId: 'test.environment.$id',
      capabilityId: environmentProviderCapability.id.value,
      capabilityMajorVersion: environmentProviderCapability.majorVersion,
      serviceId: environmentProviderServiceId,
      displayName: id,
      configurationContext: 'shared',
    ).toMap(),
];
