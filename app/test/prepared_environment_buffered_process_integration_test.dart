@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'support/prepared_buffered_process.dart';
import 'support/prepared_environment_capability_installation.dart';

void main() {
  final suite = PreparedBufferedProcess(Directory.current.parent);
  late File environmentArtifact;
  late File siblingArtifact;
  setUpAll(() async {
    await suite.prepare();
    await suite.copyFixture('prepared_environment_capability_environment');
    await suite.copyFixture('prepared_environment_capability_callable');
    final environment = await suite.copyFixture(
      'prepared_environment_buffered_process_environment',
    );
    final sibling = await suite.copyFixture(
      'prepared_environment_capability_backend',
    );
    environmentArtifact = await suite.compileBackend(
      environment.path,
      'environment',
    );
    siblingArtifact = await suite.compileBackend(sibling.path, 'sibling');
  });

  late PreparedEnvironmentCapabilityInstallation fixture;
  Future<void> mount(
    WidgetTester tester, {
    bool noBufferedFacet = false,
    bool readOnlySibling = false,
    bool processGrant = true,
    bool readGrant = false,
    bool concurrent = false,
    bool present = true,
    int providers = 1,
    List<AdeleEnvironmentHostService>? secondPermissions,
    List<AdeleEnvironmentHostService> permissions = const [
      AdeleEnvironmentHostService.bufferedProcess,
    ],
    CapabilityRegistry? registry,
  }) async {
    fixture = await suite.mount(
      tester,
      environmentPlugin: environmentPluginId,
      environmentArtifact: readOnlySibling
          ? siblingArtifact
          : environmentArtifact,
      environmentArguments: [
        jsonEncode({
          'noBufferedFacet': noBufferedFacet,
          'exposures': [
            ..._environmentExposures(noBufferedFacet: noBufferedFacet),
            if (readOnlySibling)
              AdeleCapabilityExposure(
                providerId: 'test.callable.sibling',
                capabilityId: bufferedCapability.id.value,
                capabilityMajorVersion: 1,
                serviceId: probeServiceId,
                displayName: 'Read-only associated sibling',
                configurationContext: 'callable-shared',
                environmentHostServices: const [
                  AdeleEnvironmentHostService.read,
                ],
                association: AdeleProviderAssociation(
                  capabilityId: environmentProviderCapability.id.value,
                  capabilityMajorVersion:
                      environmentProviderCapability.majorVersion,
                  providerId: 'test.environment.a',
                ),
              ).toMap(),
          ],
        }),
      ],
      processGrant: processGrant,
      readGrant: readGrant,
      concurrent: concurrent,
      present: present,
      providers: providers,
      secondPermissions: secondPermissions,
      permissions: permissions,
      registry: registry,
    );
  }

  test(
    'semantic B and EVC C depend only on public APIs and cannot start processes',
    () async {
      final backend = await suite
          .fixtureSource('prepared_environment_buffered_process_callable')
          .readAsString();
      final frontend = await suite
          .fixtureSource('prepared_environment_buffered_process_frontend')
          .readAsString();
      for (final source in [backend, frontend]) {
        expect(source, isNot(contains("import 'dart:io'")));
        expect(source, isNot(contains('Process.start')));
        expect(source, isNot(contains('package:git_backend')));
        expect(source, isNot(contains('package:adele_desktop')));
        expect(source, isNot(contains('package:plugin_runtime')));
      }
      expect(backend, contains('operation!.bind('));
      expect(
        frontend,
        contains('resolveEnvironmentBufferedProcessCapabilityProvider'),
      );
      expect(frontend, isNot(contains('EnvironmentBufferedProcessRequest')));
      expect(frontend, isNot(contains('hash-object')));
    },
  );

  for (final frontend in ['none', 'read-only']) {
    testWidgets(
      '$frontend frontend declaration cannot acquire buffered authority',
      (tester) async {
        await mount(
          tester,
          processGrant: false,
          readGrant: frontend == 'read-only',
        );
        press(tester, 'Default');
        await waitForText(tester, 'selection:unavailable');
        press(tester, 'Forged handle');
        await waitForText(tester, 'process:unavailable');
        expect(
          fixture.calls(
            (await tester.runAsync(() => callableSnapshot(fixture)))!,
          ),
          isEmpty,
        );
        if (frontend == 'read-only') {
          await select(tester, button: 'Read grant');
          press(tester, 'hash');
          await waitForText(tester, 'process:unavailable');
        }
        press(tester, 'Ordinary');
        await waitForText(tester, 'process:unavailable');
        final snapshot = (await tester.runAsync(fixture.snapshot))!;
        expect(snapshot['processes'], isEmpty);
        expect(snapshot['reads'], isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final permissions in <List<AdeleEnvironmentHostService>>[
    [],
    [AdeleEnvironmentHostService.read],
  ]) {
    testWidgets(
      'provider permissions $permissions do not authorize buffered execution',
      (tester) async {
        await mount(tester, permissions: permissions);
        press(tester, 'Default');
        await waitForText(tester, 'selection:unavailable');
        final binding = fixture.capabilities.resolve(
          bufferedCapability,
          providerId: ProviderId('test.callable.a'),
        );
        expect(
          fixture.callableOwner.allowsEnvironmentHostService(
            binding,
            AdeleEnvironmentHostService.bufferedProcess,
          ),
          isFalse,
        );
        final selection = await tester.runAsync(
          () => CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: fixture.backends,
            session: fixture.sessionA,
          ).resolve(bufferedCapability),
        );
        var called = false;
        await tester.runAsync(
          () => expectLater(
            invokeEnvironmentCapabilityWithBufferedProcess<void>(
              selection: selection!,
              backends: fixture.backends,
              serviceId: probeServiceId,
              invoke: (_) async {
                called = true;
              },
            ),
            throwsStateError,
          ),
        );
        expect(called, isFalse);
        expect(
          fixture.calls(
            (await tester.runAsync(() => callableSnapshot(fixture)))!,
          ),
          isEmpty,
        );
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'wrong selectors context-free handles and foreign payload IDs never widen authority',
    (tester) async {
      await mount(tester, readGrant: true);
      press(tester, 'Check denials');
      await waitForText(tester, 'denials:passed');
      expect(
        fixture.calls(
          (await tester.runAsync(() => callableSnapshot(fixture)))!,
        ),
        isEmpty,
      );
      await select(tester);
      press(tester, 'Forge payload');
      await waitForText(tester, 'forgery:rejected');
      for (final action in ['foreign-id', 'read-service']) {
        press(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'settled:$action'));
        await waitForText(tester, 'process:unavailable');
      }
      final snapshot = (await tester.runAsync(fixture.snapshot))!;
      expect(snapshot['processes'], isEmpty);
      expect(snapshot['reads'], isEmpty);
      expect(fixture.calls(snapshot), hasLength(3));
      press(tester, 'hash');
      await waitForText(tester, bufferedResult([0, 255, 195, 40]));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live operation grants reject foreign activations services methods and authority selectors, then expire',
    (tester) async {
      await mount(tester);
      await select(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'after:hash'}),
      );
      press(tester, 'hash');
      await tester.runAsync(() => fixture.wait(tester, 'after:hash'));
      final token = (await tester.runAsync(() => _token(fixture, 'hash')))!;
      await tester.runAsync(() async {
        expect(
          await fixture.controlOn(
            fixture.environmentConnection,
            'attackBuffered',
            {'token': token},
          ),
          {'ok': false},
        );
        await expectDenied(fixture, 'invented');
        for (final (service, method, arguments) in [
          (
            authorizedEnvironmentReadServiceId,
            authorizedEnvironmentReadServiceAuthorityId,
            <String, Object?>{},
          ),
          (
            authorizedEnvironmentReadServiceId,
            authorizedEnvironmentReadServiceReadFileId,
            <String, Object?>{'relativePath': 'A'},
          ),
          (
            authorizedEnvironmentMutationServiceId,
            'authorizedEnvironmentMutation.writeFile',
            <String, Object?>{},
          ),
          (
            authorizedEnvironmentProcessServiceId,
            'authorizedEnvironmentProcess.run',
            <String, Object?>{},
          ),
          ('projectStorage', 'projectStorage.query', <String, Object?>{}),
          ('unlisted', 'unlisted.call', <String, Object?>{}),
        ]) {
          await expectDenied(
            fixture,
            token,
            service: service,
            method: method,
            arguments: arguments,
          );
        }
        await expectDenied(fixture, token, method: 'wrong-method');
        for (final field in [
          'environmentId',
          'sessionId',
          'providerId',
          'hostInvocationContext',
        ]) {
          await expectDenied(
            fixture,
            token,
            arguments: {..._requestPayload(), field: 'primary'},
          );
        }
        for (final request in [
          {..._requestPayload()['request']! as Map, 'stdinBase64': 'AB=='},
          {
            ..._requestPayload()['request']! as Map,
            'stdinBase64': base64Encode(
              List<int>.filled(environmentBufferedProcessStdinLimit + 1, 0),
            ),
          },
          {..._requestPayload()['request']! as Map, 'timeoutSeconds': 0},
        ]) {
          await expectDenied(fixture, token, arguments: {'request': request});
        }
        final attack = fixture.control('attackBuffered', {'token': token});
        await fixture.wait(tester, 'process:attack');
        expect(await attack, {'ok': true});
        final retained = fixture.control('retainedBuffered', {'key': 'hash'});
        await fixture.wait(tester, 'process:retained');
        expect(await retained, {'ok': true});
        expect(
          await fixture.control('retainedBufferedIdentity', {'key': 'hash'}),
          {
            'ok': true,
            'sessionId': fixture.sessionA.id.value,
            'environmentId': 'additional',
          },
        );
        expect(
          await fixture.controlOn(
            fixture.environmentConnection,
            'attackBuffered',
            {
              'token': token,
              'method':
                  authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
              'arguments': <String, Object?>{},
            },
          ),
          {'ok': false},
        );
        await fixture.control('release', {'key': 'after:hash'});
      });
      await waitForText(tester, bufferedResult([0, 255, 195, 40]));
      await tester.runAsync(() async {
        await expectDenied(fixture, token);
        expect(await fixture.control('retainedBuffered', {'key': 'hash'}), {
          'ok': false,
        });
        expect(
          await fixture.control('retainedBufferedIdentity', {'key': 'hash'}),
          {'ok': false},
        );
      });
      final processes =
          (await tester.runAsync(fixture.snapshot))!['processes'] as List;
      expect(processes, hasLength(3));
      expect(
        processes.cast<Map<Object?, Object?>>().every(
          (p) =>
              p['environmentId'] == 'additional' &&
              p['providerId'] == 'test.environment.a',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty and nonzero binary results plus G2a bound timeout and unavailable failures cross the reverse boundary',
    (tester) async {
      await mount(tester);
      await select(tester);
      press(tester, 'empty');
      await waitForText(tester, bufferedResult([]));
      press(tester, 'nonzero');
      await waitForText(
        tester,
        bufferedResult([0, 255, 195, 40], exitCode: 17, stderr: [255, 0]),
      );
      for (final (action, code) in [
        ('stdout-overflow', 'process_output_overflow'),
        ('timeout', 'process_timed_out'),
        ('unavailable', environmentBufferedProcessUnavailableCode),
      ]) {
        press(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'settled:$action'));
        await waitForText(tester, 'process:unavailable');
        final snapshot = (await tester.runAsync(
          () => callableSnapshot(fixture),
        ))!;
        expect((snapshot['failures'] as List).last, code);
        await tester.runAsync(
          () async => expectDenied(fixture, await _token(fixture, action)),
        );
        expect(find.textContaining('SECRET'), findsNothing);
        press(tester, 'hash');
        await waitForText(tester, bufferedResult([0, 255, 195, 40]));
      }
      final snapshot = (await tester.runAsync(fixture.snapshot))!;
      expect(snapshot['processes'], hasLength(8));
      expect(
        (snapshot['processes'] as List).cast<Map<Object?, Object?>>().every(
          (p) => p['providerId'] == 'test.environment.a',
        ),
        isTrue,
      );
      expect(snapshot['reads'], isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final departure in [
    'release',
    'navigation',
    'frontend retirement',
    'raw registration',
  ]) {
    testWidgets(
      '$departure revokes process authority and suppresses a gated late result',
      (tester) async {
        await mount(tester);
        await select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        press(tester, 'held');
        await tester.runAsync(() => fixture.wait(tester, 'process:held'));
        final token = (await tester.runAsync(() => _token(fixture, 'held')))!;
        final staleCall = buttonCallback(tester, 'hash');
        final staleResolve = buttonCallback(tester, 'Default');
        if (departure == 'release') {
          press(tester, 'Release');
          await waitForText(tester, 'released');
          press(tester, 'Release');
          await waitForText(tester, 'already released');
        } else if (departure == 'navigation') {
          fixture.frontends.unbind(fixture.sessionA);
          await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
          await tester.pumpAndSettle();
        } else if (departure == 'raw registration') {
          fixture.frontends.generations.single.registrations.single.close();
        } else {
          await tester.runAsync(fixture.frontends.generations.single.close);
        }
        await tester.runAsync(() => expectDenied(fixture, token));
        staleCall();
        if (departure != 'release') staleResolve();
        await tester.runAsync(() async {
          await fixture.control('release', {'key': 'process:held'});
          await fixture.wait(tester, 'settled:held');
        });
        await tester.pumpAndSettle();
        expect(find.text(bufferedResult([0, 255, 195, 40])), findsNothing);
        expect(
          fixture.calls(
            (await tester.runAsync(() => callableSnapshot(fixture)))!,
          ),
          hasLength(1),
        );
        if (departure == 'release' || departure == 'navigation') {
          await select(tester);
          press(tester, 'hash');
          await waitForText(
            tester,
            bufferedResult(
              departure == 'navigation' ? [0, 128, 66] : [0, 255, 195, 40],
            ),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final count in [0, 2]) {
    testWidgets(
      'provider count $count does not fall back through rank or permissions',
      (tester) async {
        await mount(
          tester,
          providers: count,
          permissions: const [],
          secondPermissions: const [
            AdeleEnvironmentHostService.bufferedProcess,
          ],
        );
        press(tester, 'Default');
        await waitForText(tester, 'selection:unavailable');
        press(tester, 'Select A');
        await waitForText(tester, 'selection:unavailable');
        expect(
          fixture.calls(
            (await tester.runAsync(() => callableSnapshot(fixture)))!,
          ),
          isEmpty,
        );
        if (count == 2) {
          await select(tester, button: 'Select B');
          press(tester, 'hash');
          await waitForText(tester, bufferedResult([0, 255, 195, 40]));
        }
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          hasLength(count == 2 ? 1 : 0),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'independent presentations retain distinct grants and releasing one leaves the other live',
    (tester) async {
      await mount(tester, concurrent: true);
      await select(tester);
      await select(tester, pane: 'b');
      for (final action in ['one', 'two']) {
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:$action'}),
        );
      }
      press(tester, 'one');
      press(tester, 'two', pane: 'b');
      await tester.runAsync(() async {
        await fixture.wait(tester, 'process:one');
        await fixture.wait(tester, 'process:two');
      });
      final firstToken = (await tester.runAsync(() => _token(fixture, 'one')))!;
      final secondToken = (await tester.runAsync(
        () => _token(fixture, 'two'),
      ))!;
      expect(firstToken, isNot(secondToken));
      press(tester, 'Release');
      await waitForText(tester, 'process:unavailable');
      await tester.runAsync(() async {
        await expectDenied(fixture, firstToken);
        await fixture.control('release', {'key': 'process:two'});
      });
      await waitForText(tester, bufferedResult([0, 128, 66]), pane: 'b');
      await tester.runAsync(() async {
        await expectDenied(fixture, secondToken);
        await fixture.control('release', {'key': 'process:one'});
        await fixture.wait(tester, 'settled:one');
      });
      expect(find.text(bufferedResult([0, 255, 195, 40])), findsNothing);
      press(tester, 'fresh', pane: 'b');
      await waitForText(tester, bufferedResult([0, 128, 66]), pane: 'b');
      final freshToken = (await tester.runAsync(
        () => _token(fixture, 'fresh'),
      ))!;
      expect({firstToken, secondToken, freshToken}, hasLength(3));
      await tester.runAsync(() => expectDenied(fixture, freshToken));
      final processes =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .cast<Map<Object?, Object?>>();
      expect(processes.map((p) => p['environmentId']), [
        'additional',
        'primary',
        'primary',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final side in ['environment', 'callable']) {
    testWidgets(
      '$side registration retirement revokes buffered grants without retiring either activation',
      (tester) async {
        await mount(tester, concurrent: true);
        await select(tester);
        await select(tester, pane: 'b');
        final environment = fixture.capabilities.resolve(
          environmentProviderCapability,
          providerId: ProviderId('test.environment.a'),
        );
        final callable = fixture.capabilities.resolve(
          bufferedCapability,
          providerId: ProviderId('test.callable.a'),
        );
        final target = side == 'environment' ? environment : callable;
        final other = side == 'environment' ? callable : environment;
        final owner = side == 'environment'
            ? fixture.environmentOwner
            : fixture.callableOwner;
        var otherRetirements = 0;
        addTearDown(other.onRetire(() => otherRetirements++));
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        press(tester, 'held');
        await tester.runAsync(() => fixture.wait(tester, 'process:held'));
        final token = (await tester.runAsync(() => _token(fixture, 'held')))!;
        await tester.runAsync(() => owner.retireProvider(target));
        await waitForText(tester, 'process:unavailable');
        expect(
          () => target.requestChannel,
          throwsA(isA<ProviderUnavailable>()),
        );
        fixture.environmentOwner.validate();
        fixture.callableOwner.validate();
        expect(fixture.connection.isClosed, isFalse);
        expect(fixture.environmentConnection.isClosed, isFalse);
        await tester.runAsync(() => expectDenied(fixture, token));
        press(tester, 'Default');
        await waitForText(tester, 'selection:unavailable');
        press(tester, 'hash', pane: 'b');
        await waitForText(
          tester,
          side == 'environment'
              ? bufferedResult([0, 128, 66])
              : 'process:unavailable',
          pane: 'b',
        );
        await tester.runAsync(() async {
          await fixture.control('release', {'key': 'process:held'});
          await fixture.wait(tester, 'settled:held');
          await expectDenied(fixture, token);
        });
        expect(otherRetirements, 0);
        expect(find.text(bufferedResult([0, 255, 195, 40])), findsNothing);
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          hasLength(side == 'environment' ? 2 : 1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$side backend termination settles buffered calls while preserving the other activation',
      (tester) async {
        await mount(tester);
        await select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        press(tester, 'held');
        await tester.runAsync(() => fixture.wait(tester, 'process:held'));
        final token = (await tester.runAsync(() => _token(fixture, 'held')))!;
        final terminating = side == 'environment'
            ? fixture.environmentConnection
            : fixture.connection;
        final surviving = side == 'environment'
            ? fixture.connection
            : fixture.environmentConnection;
        await tester.runAsync(() async {
          await expectLater(
            fixture.controlOn(terminating, 'terminate'),
            throwsA(isA<PluginRemoteFailure>()),
          );
          await terminating.terminated.timeout(bufferedWait);
        });
        await waitForText(tester, 'process:unavailable');
        expect(terminating.isClosed, isTrue);
        expect(surviving.isClosed, isFalse);
        expect(fixture.backends.host!.isClosed, isFalse);
        press(tester, 'Default');
        await waitForText(tester, 'selection:unavailable');
        await tester.runAsync(() async {
          for (final (method, arguments) in [
            (
              authorizedEnvironmentBufferedProcessServiceRunBufferedProcessId,
              _requestPayload(),
            ),
            (
              authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
              <String, Object?>{},
            ),
          ]) {
            expect(
              await fixture.controlOn(surviving, 'attackBuffered', {
                'token': token,
                'method': method,
                'arguments': arguments,
              }),
              {'ok': false},
            );
          }
          if (side == 'callable') {
            fixture.environmentOwner.validate();
            await fixture.controlOn(surviving, 'release', {
              'key': 'process:held',
            });
          } else {
            fixture.callableOwner.validate();
          }
        });
        expect(find.text(bufferedResult([0, 255, 195, 40])), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'same-ID backend replacement never revives retained process clients or tokens',
    (tester) async {
      await mount(tester);
      await select(tester);
      final old = fixture;
      final oldBinding = old.capabilities.resolve(
        bufferedCapability,
        providerId: ProviderId('test.callable.a'),
      );
      final oldEnvironment = old.capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      final stale = buttonCallback(tester, 'hash');
      await tester.runAsync(() => old.control('hold', {'key': 'process:held'}));
      press(tester, 'held');
      await tester.runAsync(() => old.wait(tester, 'process:held'));
      final token = (await tester.runAsync(() => _token(old, 'held')))!;
      await tester.runAsync(old.backends.close);
      await waitForText(tester, 'process:unavailable');
      await mount(tester, present: false, registry: old.capabilities);
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.capabilities
            .resolve(
              bufferedCapability,
              providerId: ProviderId('test.callable.a'),
            )
            .isSameRegistration(oldBinding),
        isFalse,
      );
      expect(
        fixture.capabilities
            .resolve(
              environmentProviderCapability,
              providerId: ProviderId('test.environment.a'),
            )
            .isSameRegistration(oldEnvironment),
        isFalse,
      );
      stale();
      await waitForText(tester, 'process:unavailable');
      expect(
        fixture.calls(
          (await tester.runAsync(() => callableSnapshot(fixture)))!,
        ),
        isEmpty,
      );
      await tester.runAsync(() => expectDenied(fixture, token));
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await select(tester);
      press(tester, 'hash');
      await waitForText(tester, bufferedResult([0, 255, 195, 40]));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final identityOnly in [false, true]) {
    testWidgets(
      'queued reverse ${identityOnly ? 'identity' : 'process'} is revoked before service entry after held cleanup',
      (tester) async {
        await mount(tester);
        await select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        press(tester, 'held');
        await tester.runAsync(() => fixture.wait(tester, 'process:held'));
        final token = (await tester.runAsync(() => _token(fixture, 'held')))!;
        expect(
          await tester.runAsync(
            () => fixture.control('queueBuffered', {
              'token': token,
              'identity': identityOnly,
            }),
          ),
          {'queued': true},
        );
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          hasLength(1),
        );
        press(tester, 'Release');
        await waitForText(tester, 'process:unavailable');
        // Both reverse callers settle while the first provider process stays held.
        expect(await tester.runAsync(() => fixture.control('queuedResult')), {
          'ok': false,
        });
        await tester.runAsync(() async {
          await expectDenied(fixture, token);
          await fixture.control('release', {'key': 'process:held'});
          await fixture.wait(tester, 'settled:held');
        });
        await tester.pumpAndSettle();
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          hasLength(1),
        );
        expect(find.text(bufferedResult([0, 255, 195, 40])), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'read and process handles share capacity but retain fixed authority and reject foreign handles',
    (tester) async {
      await mount(tester, present: false, readGrant: true);
      await tester.runAsync(() async {
        EnvironmentCapabilityAccessBridge bridge() =>
            EnvironmentCapabilityAccessBridge(
              session: fixture.sessionA,
              environmentRuntime: fixture.environmentRuntime,
              backends: fixture.backends,
              capabilities: [bufferedCapability],
              bufferedProcessCapabilities: [bufferedCapability],
              isActive: () => true,
            );
        final access = bridge();
        final foreign = bridge();
        addTearDown(access.invalidate);
        addTearDown(foreign.invalidate);
        Future<String?> resolve(bool process) => process
            ? access.resolveBufferedProcess(
                bufferedCapability.id.value,
                1,
                probeServiceId,
                null,
              )
            : access.resolve(
                bufferedCapability.id.value,
                1,
                probeServiceId,
                null,
              );
        final handles = <String>[];
        for (
          var index = 0;
          index < EnvironmentCapabilityAccessBridge.maxHandles;
          index++
        ) {
          handles.add((await resolve(index.isOdd))!);
        }
        expect(
          handles.toSet(),
          hasLength(EnvironmentCapabilityAccessBridge.maxHandles),
        );
        expect(await resolve(false), isNull);
        expect(await resolve(true), isNull);
        expect(foreign.release(handles[1]), isFalse);
        await expectLater(
          foreign.request(handles[1], '$probeServiceId.read', {
            'scope': 'hash',
          }),
          throwsStateError,
        );
        await expectLater(
          access.request(handles[0], '$probeServiceId.read', {'scope': 'hash'}),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        await expectLater(
          access.request(handles[1], '$probeServiceId.read', {
            'scope': 'read-service',
          }),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        expect((await fixture.snapshot())['processes'], isEmpty);
        final result =
            (await access.request(handles[1], '$probeServiceId.read', {
                  'scope': 'hash',
                }))!
                as Map;
        expect(result['configuration'], base64Encode([0, 255, 195, 40]));
        expect(access.release(handles[0]), isTrue);
        expect(access.release(handles[0]), isFalse);
        final replacement = await resolve(true);
        expect(replacement, isNotNull);
        expect(handles, isNot(contains(replacement)));
        expect(await resolve(false), isNull);
        await expectLater(
          access.request(handles[0], '$probeServiceId.read', {'scope': 'hash'}),
          throwsStateError,
        );
        // Reuse of the one live process handle opens independent unary grants.
        await access.request(handles[1], '$probeServiceId.read', {
          'scope': 'fresh',
        });
        expect((await fixture.snapshot())['processes'], hasLength(2));
        final calls = fixture.calls(await callableSnapshot(fixture));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(4),
        );
        for (final call in calls) {
          await expectDenied(fixture, call['hostInvocationContext'] as String);
        }
      });
    },
  );

  testWidgets(
    'process-only captured identity reports exact Sessions without reads or buffered provider support',
    (tester) async {
      await mount(tester, present: false, noBufferedFacet: true);
      await tester.runAsync(() async {
        final tokens = <String>{};
        for (final (session, environmentId) in [
          (fixture.sessionA, 'additional'),
          (fixture.sessionB, 'primary'),
        ]) {
          final selection = await CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: fixture.backends,
            session: session,
          ).resolve(bufferedCapability);
          expect(
            fixture.callableOwner.allowsEnvironmentHostService(
              selection.binding,
              AdeleEnvironmentHostService.read,
            ),
            isFalse,
          );
          final result = await invokeEnvironmentCapabilityWithBufferedProcess(
            selection: selection,
            backends: fixture.backends,
            serviceId: probeServiceId,
            invoke: (channel) =>
                channel.request('$probeServiceId.read', {'scope': 'identity'}),
          );
          expect(result, {
            'provider': 'identity',
            'configuration': session.id.value,
            'sequence': 0,
            'text': environmentId,
          });
          final token = await _token(fixture, 'identity');
          tokens.add(token);
          await expectDenied(fixture, token);
          expect(
            await fixture.control('retainedBufferedIdentity', {
              'key': 'identity',
            }),
            {'ok': false},
          );
        }
        expect(tokens, hasLength(2));
        final snapshot = await fixture.snapshot();
        expect(snapshot['reads'], isEmpty);
        expect(snapshot['processes'], isEmpty);
        expect(fixture.calls(snapshot), hasLength(2));
      });
    },
  );

  for (final checkpoint in ['before', 'after']) {
    testWidgets(
      'retired identity fails $checkpoint query without reselecting or publishing cached IDs',
      (tester) async {
        await mount(tester, present: false);
        await tester.runAsync(() async {
          final selection = await CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: fixture.backends,
            session: fixture.sessionA,
          ).resolve(bufferedCapability);
          await fixture.control('hold', {'key': '$checkpoint:identity'});
          late void Function() retire;
          final pending = invokeEnvironmentCapabilityWithBufferedProcess(
            selection: selection,
            backends: fixture.backends,
            serviceId: probeServiceId,
            onRetire: (revoke) {
              retire = revoke;
              return () {};
            },
            invoke: (channel) =>
                channel.request('$probeServiceId.read', {'scope': 'identity'}),
          );
          final failed = expectLater(pending, throwsStateError);
          await fixture.wait(tester, '$checkpoint:identity');
          final token = await _token(fixture, 'identity');
          expect(
            await fixture.control('retainedBufferedIdentity', {
              'key': 'identity',
            }),
            {
              'ok': true,
              'sessionId': fixture.sessionA.id.value,
              'environmentId': 'additional',
            },
          );
          retire();
          // Both registrations remain live; only this invocation has retired.
          selection.validate();
          await expectDenied(fixture, token);
          expect(
            await fixture.control('retainedBufferedIdentity', {
              'key': 'identity',
            }),
            {'ok': false},
          );
          await fixture.control('release', {'key': '$checkpoint:identity'});
          await failed.timeout(bufferedWait);
          final snapshot = await fixture.snapshot();
          expect(snapshot['reads'], isEmpty);
          expect(snapshot['processes'], isEmpty);
          expect(fixture.calls(snapshot), hasLength(1));
        });
      },
    );
  }

  testWidgets(
    'native buffered invocation revokes at unary receipt before a delayed consumer and consumes the channel',
    (tester) async {
      await mount(tester, present: false);
      await tester.runAsync(() async {
        final selection = await CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(bufferedCapability);
        final received = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        late AdeleRequestChannel retained;
        final pending = invokeEnvironmentCapabilityWithBufferedProcess(
          selection: selection,
          backends: fixture.backends,
          serviceId: probeServiceId,
          invoke: (channel) async {
            retained = channel;
            final result = await channel.request('$probeServiceId.read', {
              'scope': 'hash',
            });
            received.complete();
            await release.future;
            return result;
          },
        );
        await received.future.timeout(bufferedWait);
        await expectDenied(fixture, await _token(fixture, 'hash'));
        expect(await fixture.control('retainedBuffered', {'key': 'hash'}), {
          'ok': false,
        });
        await expectLater(
          retained.request('$probeServiceId.read', {'scope': 'fresh'}),
          throwsStateError,
        );
        release.complete();
        expect(((await pending)! as Map)['sequence'], 0);
        expect((await fixture.snapshot())['processes'], hasLength(1));
      });
    },
  );
  for (final readGrant in [false, true]) {
    for (final permissions in <List<AdeleEnvironmentHostService>>[
      [],
      [AdeleEnvironmentHostService.read],
    ]) {
      testWidgets(
        'neither side opts in: frontend read=$readGrant provider=$permissions',
        (tester) async {
          await mount(
            tester,
            processGrant: false,
            readGrant: readGrant,
            permissions: permissions,
          );
          press(tester, 'Default');
          await waitForText(tester, 'selection:unavailable');
          if (readGrant) {
            await select(tester, button: 'Read grant');
            press(tester, 'hash');
            await waitForText(tester, 'process:unavailable');
          }
          final snapshot = (await tester.runAsync(fixture.snapshot))!;
          expect(snapshot['processes'], isEmpty);
          expect(snapshot['reads'], isEmpty);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'selected read-only associated sibling is not replaced by opted-in independent B',
    (tester) async {
      await mount(tester, readOnlySibling: true);
      final selected = await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(bufferedCapability),
      );
      expect(selected!.binding.provider.id.value, 'test.callable.sibling');
      fixture.environmentOwner.validateProviderOwnership(selected.binding);
      expect(
        fixture.environmentOwner.allowsEnvironmentHostService(
          selected.binding,
          AdeleEnvironmentHostService.bufferedProcess,
        ),
        isFalse,
      );
      final independent = fixture.capabilities.resolve(
        bufferedCapability,
        providerId: ProviderId('test.callable.a'),
      );
      expect(
        fixture.callableOwner.allowsEnvironmentHostService(
          independent,
          AdeleEnvironmentHostService.bufferedProcess,
        ),
        isTrue,
      );
      press(tester, 'Default');
      await waitForText(tester, 'selection:unavailable');
      expect(
        fixture.calls((await tester.runAsync(fixture.snapshot))!),
        isEmpty,
      );
      // Explicit independent selection is possible; automatic permission-based
      // substitution of the existing sibling is not.
      await select(tester, button: 'Select A');
      expect(
        fixture.calls((await tester.runAsync(fixture.snapshot))!),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing optional facet in selected A fails through the real adapter without primary fallback',
    (tester) async {
      await mount(tester, noBufferedFacet: true, concurrent: true);
      await select(tester);
      await select(tester, pane: 'b');
      press(tester, 'hash');
      await waitForText(tester, 'process:unavailable');
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      expect(
        (await tester.runAsync(() => callableSnapshot(fixture)))!['failures'],
        [environmentBufferedProcessUnavailableCode],
      );
      press(tester, 'hash', pane: 'b');
      await waitForText(tester, bufferedResult([0, 128, 66]), pane: 'b');
      final processes =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .cast<Map<Object?, Object?>>();
      expect(processes, hasLength(1));
      expect(processes.single['environmentId'], 'primary');
      expect(processes.single['providerId'], 'test.environment.b');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

List<Map<String, Object?>> _environmentExposures({
  bool noBufferedFacet = false,
}) => [
  for (final id in ['a', 'b'])
    AdeleCapabilityExposure(
      providerId: 'test.environment.$id',
      capabilityId: environmentProviderCapability.id.value,
      capabilityMajorVersion: environmentProviderCapability.majorVersion,
      serviceId: environmentProviderServiceId,
      displayName: id,
      configurationContext: noBufferedFacet && id == 'b'
          ? 'buffered'
          : 'shared',
    ).toMap(),
];

Future<String> _token(
  PreparedEnvironmentCapabilityInstallation h,
  String action,
) async =>
    h
            .calls(await callableSnapshot(h))
            .lastWhere(
              (request) => (request['payload'] as Map)['scope'] == action,
            )['hostInvocationContext']
        as String;

Map<String, Object?> _requestPayload() => {
  'request': {
    'program': 'git',
    'arguments': ['-c', 'adele.probeAction=attack', 'hash-object', '--stdin'],
    'relativeWorkingDirectory': '',
    'timeoutSeconds': 5,
    'stdinBase64': '',
  },
};
