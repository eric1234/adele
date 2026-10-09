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
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
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

  test(
    'already-retired external lifetime rejects admission and detaches',
    () async {
      final selected = await h.selectA();
      var detached = 0;
      var invoked = false;
      final before = (await h.snapshot())['requests'];
      await expectLater(
        invokeEnvironmentCapabilityWithRead<void>(
          selection: selected,
          backends: h.backends,
          serviceId: resourceInspectorServiceId,
          onRetire: (revoke) {
            revoke();
            revoke();
            return () => detached++;
          },
          invoke: (_) async => invoked = true,
        ),
        throwsA(isA<StateError>()),
      );
      expect(invoked, isFalse);
      expect(detached, 1);
      expect((await h.snapshot())['requests'], before);
      expect((await h.snapshot())['reads'], isEmpty);
      selected.validate();
      expect(
        (await h.inspectPath(selected, 'fresh')).providerLabel,
        'callable-a',
      );
      await h.denied(await h.token('fresh'));
    },
  );

  test(
    'external retirement revokes a reverse read before held cleanup completes',
    () async {
      final selected = await h.selectA();
      await h.control('hold', {'key': 'read:external-retirement'});
      late void Function() retire;
      var detached = 0;
      var published = false;
      final pending =
          invokeEnvironmentCapabilityWithRead(
            selection: selected,
            backends: h.backends,
            serviceId: resourceInspectorServiceId,
            onRetire: (revoke) {
              retire = revoke;
              return () => detached++;
            },
            invoke: (channel) => ResourceInspectorServiceClient(
              channel,
            ).inspect(ResourceRef(uri: Uri.parse('test:/external-retirement'))),
          ).then((value) {
            published = true;
            return value;
          });
      final failed = expectLater(pending, throwsA(isA<StateError>()));
      await h.control('wait', {'key': 'read:external-retirement'});
      final token = await h.token('external-retirement');

      retire();
      retire();
      // The provider read and dispatcher cleanup remain held behind the gate.
      // Revocation must settle the reverse call without either one finishing.
      await failed.timeout(_bound);
      expect(detached, 1);
      expect(published, isFalse);
      selected.validate();
      expect(h.connection.isClosed, isFalse);
      await h.denied(token);
      expect(await h.control('retained', {'key': 'external-retirement'}), {
        'ok': false,
      });
      expect((await h.snapshot())['reads'], hasLength(1));

      // A different operation on the same selection remains independently live.
      await h.control('hold', {'key': 'after:fresh'});
      final fresh = h.inspectPath(selected, 'fresh');
      await h.control('wait', {'key': 'after:fresh'});
      final freshToken = await h.token('fresh');
      expect(freshToken, isNot(token));
      retire();
      await h.denied(token);
      await h.control('release', {'key': 'read:external-retirement'});
      await h.control('release', {'key': 'after:fresh'});
      expect((await fresh).providerLabel, 'callable-a');
      expect(published, isFalse);
      expect(detached, 1);
      await h.denied(token);
      await h.denied(freshToken);
      expect((await h.snapshot())['reads'], hasLength(2));
    },
  );

  for (final outcome in ['success', 'failure']) {
    test('external retirement observer detaches on unary $outcome', () async {
      final selected = await h.selectA();
      final observers = <void Function()>{};
      var detached = 0;
      final pending = invokeEnvironmentCapabilityWithRead(
        selection: selected,
        backends: h.backends,
        serviceId: resourceInspectorServiceId,
        onRetire: (revoke) {
          observers.add(revoke);
          return () {
            detached++;
            observers.remove(revoke);
          };
        },
        invoke: (channel) => ResourceInspectorServiceClient(channel).inspect(
          ResourceRef(
            uri: Uri(
              scheme: 'test',
              path: '/observed',
              query: outcome == 'failure' ? 'fail=backend' : null,
            ),
          ),
        ),
      );
      if (outcome == 'failure') {
        await expectLater(pending, throwsA(isA<AdeleRemoteFailure>()));
      } else {
        expect((await pending).providerLabel, 'callable-a');
      }
      expect(detached, 1);
      expect(observers, isEmpty);
      await h.denied(await h.token('observed'));
    });
  }

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

  test(
    'provider retirement rejects foreign and stale same-ID registrations',
    () async {
      final selected = await h.selectA();
      final owner = h.backends.backends.single;
      final endpoint = selected.binding
          .endpointAs<AdeleRequestChannelEndpoint>();
      final foreignRegistration = h.capabilities.register(
        provider: ProviderDescriptor(
          id: ProviderId('test.external.callable'),
          capability: resourceInspectCapability,
          pluginId: _plugin,
          displayName: 'External registration on the same backend route',
          serviceId: resourceInspectorServiceId,
        ),
        endpoint: endpoint,
      );
      addTearDown(foreignRegistration.close);
      final foreign = h.capabilities.resolve(
        resourceInspectCapability,
        providerId: ProviderId('test.external.callable'),
      );
      expect(
        () => owner.retireProvider(foreign),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      expect(foreign.requestChannel, same(endpoint.channel));
      selected.validate();

      await owner.retireProvider(selected.binding);
      final replacementRegistration = h.capabilities.register(
        provider: selected.binding.provider,
        endpoint: endpoint,
      );
      addTearDown(replacementRegistration.close);
      final replacement = h.capabilities.resolve(
        resourceInspectCapability,
        providerId: selected.binding.provider.id,
      );
      expect(replacement.isSameRegistration(selected.binding), isFalse);
      expect(
        () => owner.retireProvider(selected.binding),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        () => owner.retireProvider(replacement),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      expect(replacement.requestChannel, same(endpoint.channel));
      expect(replacementRegistration.isClosed, isFalse);
      owner.validateProviderOwnership(selected.materialization.binding);
      owner.validate();
      expect(h.connection.isClosed, isFalse);
      expect(await _resolveBridge(_bridge(h)), isNull);
      expect((await h.snapshot())['reads'], isEmpty);
    },
  );

  for (final route in ['helper', 'bridge']) {
    for (final kind in ['callable', 'environment']) {
      test(
        '$route observes isolated $kind retirement before reverse-read cleanup',
        () async {
          final selected = await h.selectA();
          final owner = h.backends.backends.single;
          final target = kind == 'callable'
              ? selected.binding
              : selected.materialization.binding;
          final other = kind == 'callable'
              ? selected.materialization.binding
              : selected.binding;
          var ownerRetirements = 0;
          var otherRetirements = 0;
          addTearDown(owner.onRetire(() => ownerRetirements++));
          addTearDown(other.onRetire(() => otherRetirements++));
          final bridge = route == 'bridge' ? _bridge(h) : null;
          final handle = bridge == null
              ? null
              : (await _resolveBridge(bridge))!;
          Future<ResourceInspection> inspect(String path) => bridge == null
              ? h.inspectPath(selected, path)
              : _inspectBridge(bridge, handle!, path);
          await h.control('hold', {'key': 'read:individual-retirement'});
          var publications = 0;
          final failed = expectLater(
            inspect('individual-retirement').then((value) {
              publications++;
              return value;
            }),
            throwsA(_revocationFailure),
          );
          await h.control('wait', {'key': 'read:individual-retirement'});
          final token = await h.token('individual-retirement');

          final retiring = owner.retireProvider(target);
          expect(
            () => target.requestChannel,
            throwsA(isA<ProviderUnavailable>()),
          );
          owner.validateProviderOwnership(other);
          owner.validate();
          expect(ownerRetirements, 0);
          expect(otherRetirements, 0);
          expect(h.connection.isClosed, isFalse);
          expect(owner.state, InstalledBackendState.active);
          // Nothing retires the owner or the other binding. Only the production
          // helper's observer on this exact target can revoke the held reverse call.
          await h.denied(token);
          await failed.timeout(_bound);
          await retiring;
          expect(publications, 0);
          expect(
            () => owner.retireProvider(target),
            throwsA(isA<ProviderUnavailable>()),
          );
          await expectLater(inspect('stale'), throwsA(_revocationFailure));
          expect((await h.snapshot())['reads'], hasLength(1));

          final sibling = _bridge(h, session: h.sessionB);
          final siblingHandle = (await _resolveBridge(sibling))!;
          expect(
            (await _inspectBridge(
              sibling,
              siblingHandle,
              'sibling',
            )).providerLabel,
            'callable-b',
          );
          final ordinary = h.capabilities.resolve(
            resourceInspectCapability,
            providerId: ProviderId('test.callable.context-free'),
          );
          expect(
            (await ResourceInspectorServiceClient(
              ordinary.requestChannel,
            ).inspect(ResourceRef(uri: Uri.parse('test:/ordinary')))).summary,
            'context-free',
          );
          expect(ownerRetirements, 0);
          expect(otherRetirements, 0);
          await h.control('release', {'key': 'read:individual-retirement'});
          await h.denied(token);
          await h.denied(await h.token('sibling'));
          expect(publications, 0);
          expect((await h.snapshot())['reads'], hasLength(2));

          await h.backends.close();
          final replacement = await start(registry: h.capabilities);
          await replacement.denied(token);
          await expectLater(inspect('replaced'), throwsA(_revocationFailure));
          final fresh = _bridge(h, backends: replacement.backends);
          final freshHandle = (await _resolveBridge(fresh))!;
          expect(
            (await _inspectBridge(fresh, freshHandle, 'fresh')).providerLabel,
            'callable-a',
          );
          final newSelection = await CapturedEnvironmentCapabilities(
            environmentRuntime: h.environmentRuntime,
            backends: replacement.backends,
            session: h.sessionA,
          ).resolve(resourceInspectCapability);
          expect(
            newSelection.binding.isSameRegistration(selected.binding),
            isFalse,
          );
          expect(
            newSelection.materialization.binding.isSameRegistration(
              selected.materialization.binding,
            ),
            isFalse,
          );
          await expectLater(
            inspect('still-stale'),
            throwsA(_revocationFailure),
          );
          await replacement.denied(await replacement.token('fresh'));
          expect((await replacement.snapshot())['reads'], hasLength(1));
        },
      );
    }
  }

  group('native Environment Capability bridge', () {
    test('denies undeclared or unavailable canonical authority', () async {
      for (final unavailable in [
        'undeclared',
        'no-session',
        'no-runtime',
        'no-backend',
        'noncanonical-session',
        'inactive',
      ]) {
        final bridge = EnvironmentCapabilityAccessBridge(
          session: unavailable == 'no-session'
              ? null
              : unavailable == 'noncanonical-session'
              ? Session(
                  id: h.sessionA.id,
                  taskId: h.sessionA.taskId,
                  strategyId: h.sessionA.strategyId,
                )
              : h.sessionA,
          environmentRuntime: unavailable == 'no-runtime'
              ? null
              : h.environmentRuntime,
          backends: unavailable == 'no-backend' ? null : h.backends,
          capabilities: unavailable == 'undeclared'
              ? const []
              : [resourceInspectCapability],
          isActive: () => unavailable != 'inactive',
        );
        addTearDown(bridge.invalidate);
        expect(await _resolveBridge(bridge), isNull, reason: unavailable);
        expect(bridge.release('invented'), isFalse);
        await expectLater(
          _inspectBridge(bridge, 'invented', 'denied'),
          throwsA(isA<StateError>()),
          reason: unavailable,
        );
      }
      final snapshot = await h.snapshot();
      expect(snapshot['requests'], isEmpty);
      expect(snapshot['reads'], isEmpty);
    });

    test(
      'denies wrong keys, services and ineligible explicit providers',
      () async {
        final bridge = _bridge(h);
        for (final (id, major) in [
          ('test.unlisted', resourceInspectCapability.majorVersion),
          (resourceInspectCapability.id.value, 0),
          (
            resourceInspectCapability.id.value,
            resourceInspectCapability.majorVersion + 1,
          ),
        ]) {
          expect(
            await bridge.resolve(id, major, resourceInspectorServiceId, null),
            isNull,
          );
        }
        expect(
          await _resolveBridge(bridge, serviceId: 'wrong-service'),
          isNull,
        );
        for (final provider in [
          'test.callable.b',
          'test.callable.context-free',
          'test.missing',
        ]) {
          expect(await _resolveBridge(bridge, providerId: provider), isNull);
        }
        final handle = (await _resolveBridge(bridge))!;
        await expectLater(
          bridge.request(handle, '', const {}),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          bridge.request(handle, 'resourceInspector.inspect', const []),
          throwsA(isA<FormatException>()),
        );
        final snapshot = await h.snapshot();
        expect(snapshot['reads'], isEmpty);
        expect(
          (snapshot['requests'] as List).cast<Map<Object?, Object?>>().where(
            (request) => request['hostInvocationContext'] != null,
          ),
          isEmpty,
        );
        expect(
          (await _inspectBridge(bridge, handle, 'healthy')).providerLabel,
          'callable-a',
        );
        await h.denied(await h.token('healthy'));
      },
    );

    for (final failResolution in [false, true]) {
      test(
        'bounds pending and retained handles, failed resolution=$failResolution',
        () async {
          final bridge = _bridge(h);
          await h.control('hold', {'key': 'restore:additional'});
          final pending = [
            for (
              var i = 0;
              i < EnvironmentCapabilityAccessBridge.maxHandles;
              i++
            )
              _resolveBridge(
                bridge,
                serviceId: failResolution ? 'wrong-service' : null,
              ),
          ];
          await h.control('wait', {'key': 'restore:additional'});
          // An excess resolution must finish while every reservation is held.
          expect(await _resolveBridge(bridge).timeout(_bound), isNull);
          await h.control('release', {'key': 'restore:additional'});
          var handles = await Future.wait(pending).timeout(_bound);
          if (failResolution) {
            expect(handles, everyElement(isNull));
            // All failed reservations must be available to fresh resolutions.
            handles = await Future.wait([
              for (
                var i = 0;
                i < EnvironmentCapabilityAccessBridge.maxHandles;
                i++
              )
                _resolveBridge(bridge),
            ]).timeout(_bound);
          }
          expect(handles, everyElement(isA<String>()));
          expect(
            handles.toSet(),
            hasLength(EnvironmentCapabilityAccessBridge.maxHandles),
          );
          expect(await _resolveBridge(bridge), isNull);
          final released = handles.first!;
          expect(bridge.release(released), isTrue);
          expect(bridge.release(released), isFalse);
          final replacing = _resolveBridge(bridge);
          final excess = _resolveBridge(bridge);
          final replacement = await replacing;
          expect(await excess, isNull);
          expect(replacement, isA<String>());
          expect(handles, isNot(contains(replacement)));
          expect(await _resolveBridge(bridge), isNull);
          for (final handle in [...handles.skip(1), replacement]) {
            expect(bridge.release(handle!), isTrue);
          }
          expect((await h.snapshot())['reads'], isEmpty);
        },
      );
    }

    test('invalidation fences pending handle publication', () async {
      var invalidations = 0;
      final bridge = _bridge(h, onInvalidate: () => invalidations++);
      await h.control('hold', {'key': 'restore:additional'});
      final pending = _resolveBridge(bridge);
      await h.control('wait', {'key': 'restore:additional'});
      bridge.invalidate();
      bridge.invalidate();
      expect(invalidations, 1);
      await h.control('release', {'key': 'restore:additional'});
      expect(await pending.timeout(_bound), isNull);
      expect(await _resolveBridge(bridge), isNull);
      expect((await h.snapshot())['reads'], isEmpty);
      final fresh = _bridge(h);
      expect(await _resolveBridge(fresh), isA<String>());
    });

    test(
      'foreign, guessed and released handles cannot reach providers',
      () async {
        final a = _bridge(h);
        final b = _bridge(h, session: h.sessionB);
        final handleA = (await _resolveBridge(a))!;
        final handleB = (await _resolveBridge(b))!;
        expect(handleA, isNot(handleB));
        expect(b.release(handleA), isFalse);
        for (final handle in [handleA, 'invented']) {
          await expectLater(
            _inspectBridge(b, handle, 'foreign'),
            throwsA(isA<StateError>()),
          );
        }
        expect(a.release(handleA), isTrue);
        expect(a.release(handleA), isFalse);
        await expectLater(
          _inspectBridge(a, handleA, 'released'),
          throwsA(isA<StateError>()),
        );
        expect((await h.snapshot())['reads'], isEmpty);
        final result = await _inspectBridge(b, handleB, 'own');
        expect(result.providerLabel, 'callable-b');
        expect((jsonDecode(result.summary) as Map)['environmentId'], 'primary');
        await h.denied(await h.token('own'));
      },
    );

    test(
      'one handle admits repeated and concurrent calls with fresh grants',
      () async {
        final bridge = _bridge(h);
        final handle = (await _resolveBridge(bridge))!;
        for (final path in ['one', 'two']) {
          await h.control('hold', {'key': 'read:$path'});
        }
        var firstSettled = false;
        final first = _inspectBridge(bridge, handle, 'one').then((value) {
          firstSettled = true;
          return value;
        });
        final second = _inspectBridge(bridge, handle, 'two');
        for (final path in ['one', 'two']) {
          await h.control('wait', {'key': 'read:$path'});
        }
        final tokens = [await h.token('one'), await h.token('two')];
        expect(tokens.toSet(), hasLength(2));
        await h.control('release', {'key': 'read:two'});
        expect((await second).providerLabel, 'callable-a');
        expect(firstSettled, isFalse);
        await h.denied(tokens.last);
        await h.control('release', {'key': 'read:one'});
        expect((await first).providerLabel, 'callable-a');
        await expectLater(
          _inspectBridge(bridge, handle, 'failure', query: 'fail=backend'),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        expect(
          (await _inspectBridge(bridge, handle, 'again')).providerLabel,
          'callable-a',
        );
        tokens.addAll([await h.token('failure'), await h.token('again')]);
        expect(tokens.toSet(), hasLength(4));
        for (final token in tokens) {
          await h.denied(token);
        }
        expect((await h.snapshot())['reads'], hasLength(4));
      },
    );

    for (final retirement in ['release', 'invalidate', 'inactive']) {
      test(
        '$retirement revokes all handle calls before reverse-read cleanup',
        () async {
          var active = true;
          var invalidations = 0;
          final bridge = _bridge(
            h,
            isActive: () => active,
            onInvalidate: () => invalidations++,
          );
          final handle = (await _resolveBridge(bridge))!;
          final sibling = (await _resolveBridge(bridge))!;
          for (final path in ['retire-one', 'retire-two']) {
            await h.control('hold', {'key': 'read:$path'});
          }
          var publications = 0;
          final failed = [
            for (final path in ['retire-one', 'retire-two'])
              expectLater(
                _inspectBridge(bridge, handle, path).then((value) {
                  publications++;
                  return value;
                }),
                throwsA(isA<StateError>()),
              ),
          ];
          for (final path in ['retire-one', 'retire-two']) {
            await h.control('wait', {'key': 'read:$path'});
          }
          final tokens = [
            await h.token('retire-one'),
            await h.token('retire-two'),
          ];
          if (retirement == 'release') {
            expect(bridge.release(handle), isTrue);
            expect(bridge.release(handle), isFalse);
          } else if (retirement == 'invalidate') {
            bridge.invalidate();
            bridge.invalidate();
          } else {
            active = false;
            expect(bridge.isActive, isFalse);
            active = true;
            expect(bridge.isActive, isFalse);
          }
          await Future.wait(failed).timeout(_bound);
          expect(publications, 0);
          expect(invalidations, retirement == 'release' ? 0 : 1);
          for (final token in tokens) {
            await h.denied(token);
          }
          await expectLater(
            _inspectBridge(bridge, handle, 'late'),
            throwsA(isA<StateError>()),
          );
          expect((await h.snapshot())['reads'], hasLength(2));
          if (retirement == 'release') {
            expect(
              (await _inspectBridge(bridge, sibling, 'healthy')).providerLabel,
              'callable-a',
            );
          } else {
            expect(await _resolveBridge(bridge), isNull);
            await expectLater(
              _inspectBridge(bridge, sibling, 'late-sibling'),
              throwsA(isA<StateError>()),
            );
            final fresh = _bridge(h);
            final freshHandle = (await _resolveBridge(fresh))!;
            expect(
              (await _inspectBridge(
                fresh,
                freshHandle,
                'healthy',
              )).providerLabel,
              'callable-a',
            );
          }
          for (final path in ['retire-one', 'retire-two']) {
            await h.control('release', {'key': 'read:$path'});
          }
          for (final token in [...tokens, await h.token('healthy')]) {
            await h.denied(token);
          }
          expect(publications, 0);
          expect((await h.snapshot())['reads'], hasLength(3));
        },
      );
    }

    test(
      'retired exact bindings require fresh resolution after same-ID replacement',
      () async {
        final bridge = _bridge(h);
        final handle = (await _resolveBridge(bridge))!;
        final selected = await h.selectA();
        await h.control('hold', {'key': 'read:retiring-handle'});
        final failed = expectLater(
          _inspectBridge(bridge, handle, 'retiring-handle'),
          throwsA(_revocationFailure),
        );
        await h.control('wait', {'key': 'read:retiring-handle'});
        final token = await h.token('retiring-handle');
        final closing = h.backends.close();
        await failed.timeout(_bound);
        await closing.timeout(_bound);
        for (final binding in [
          selected.binding,
          selected.materialization.binding,
        ]) {
          expect(() => binding.requestChannel, throwsA(_revocationFailure));
        }
        final replacement = await start(registry: h.capabilities);
        await replacement.denied(token);
        await expectLater(
          _inspectBridge(bridge, handle, 'stale'),
          throwsA(_revocationFailure),
        );
        expect(await _resolveBridge(bridge), isNull);
        final fresh = _bridge(h, backends: replacement.backends);
        final freshHandle = (await _resolveBridge(fresh))!;
        expect(freshHandle, isNot(handle));
        final result = await _inspectBridge(fresh, freshHandle, 'replacement');
        expect(result.providerLabel, 'callable-a');
        expect(
          (jsonDecode(result.summary) as Map)['environmentId'],
          'additional',
        );
        final newSelection = await CapturedEnvironmentCapabilities(
          environmentRuntime: h.environmentRuntime,
          backends: replacement.backends,
          session: h.sessionA,
        ).resolve(resourceInspectCapability);
        expect(
          newSelection.binding.isSameRegistration(selected.binding),
          isFalse,
        );
        expect(
          newSelection.materialization.binding.isSameRegistration(
            selected.materialization.binding,
          ),
          isFalse,
        );
        await expectLater(
          _inspectBridge(bridge, handle, 'still-stale'),
          throwsA(_revocationFailure),
        );
        await replacement.denied(await replacement.token('replacement'));
        expect((await replacement.snapshot())['reads'], hasLength(1));
      },
    );
  });
}

EnvironmentCapabilityAccessBridge _bridge(
  _Harness harness, {
  Session? session,
  ApplicationPluginBootstrap? backends,
  bool Function()? isActive,
  void Function()? onInvalidate,
}) {
  final bridge = EnvironmentCapabilityAccessBridge(
    session: session ?? harness.sessionA,
    environmentRuntime: harness.environmentRuntime,
    backends: backends ?? harness.backends,
    capabilities: [resourceInspectCapability],
    isActive: isActive ?? () => true,
    onInvalidate: onInvalidate,
  );
  addTearDown(bridge.invalidate);
  return bridge;
}

Future<String?> _resolveBridge(
  EnvironmentCapabilityAccessBridge bridge, {
  String? serviceId,
  String? providerId,
}) => bridge.resolve(
  resourceInspectCapability.id.value,
  resourceInspectCapability.majorVersion,
  serviceId ?? resourceInspectorServiceId,
  providerId,
);

Future<ResourceInspection> _inspectBridge(
  EnvironmentCapabilityAccessBridge bridge,
  String handle,
  String path, {
  String? query,
}) => ResourceInspectorServiceClient(_BridgeChannel(bridge, handle))
    .inspect(
      ResourceRef(
        uri: Uri(scheme: 'test', path: '/$path', query: query),
      ),
    )
    .timeout(_bound);

final class _BridgeChannel implements AdeleRequestChannel {
  const _BridgeChannel(this.bridge, this.handle);

  final EnvironmentCapabilityAccessBridge bridge;
  final String handle;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      bridge.request(handle, method, payload);
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
