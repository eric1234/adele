@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/prepared_environment_capability_frontend_compiler.dart';
import 'prepared_environment_capability_integration_test.dart'
    show PreparedEnvironmentCapabilityInstallation;

const _bound = Duration(seconds: 15);
const _stockPlugin = 'dev.adele.plugin.git';
const _stockProvider = 'dev.adele.environment.git-worktree';
const _environmentPlugin = 'test.environment.only';
const _callablePlugin = 'test.capability.only';
const _service = 'test.capability.probe';
const _binaryInput = [0, 255, 195, 40, 128, 97, 0];
final _capability = CapabilityKey(
  id: CapabilityId('test.capability.buffered'),
  majorVersion: 1,
);

void main() {
  late Directory temporary;
  late Directory repository;
  late List<Environment> stockEnvironments;
  late File hostArtifact;
  late File stockArtifact;
  late File environmentArtifact;
  late File siblingArtifact;
  late File callableArtifact;
  late File frontendArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('prepared-buffered-process-');
    repository = await Directory(
      '${temporary.absolute.path}/repository',
    ).create();
    await _git(repository, ['init', '--initial-branch=main']);
    await File('${repository.path}/seed.txt').writeAsString('baseline\n');
    await _git(repository, ['add', '--', 'seed.txt']);
    await _git(repository, [
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '-m',
      'baseline',
    ]);
    stockEnvironments = [];
    for (final id in ['additional', 'primary']) {
      final relative = '.adele/worktrees/$id';
      await _git(repository, ['worktree', 'add', '-b', 'adele-$id', relative]);
      final checkout = Directory('${repository.path}/$relative');
      final names = id == 'additional'
          ? ['file with spaces.txt', 'line\nname.txt', 'overflow.bin']
          : ['primary-only.txt'];
      for (final name in names) {
        if (name == 'overflow.bin') {
          await File('${checkout.path}/$name').writeAsBytes(
            List<int>.filled(environmentBufferedProcessStdoutLimit + 1, 255),
          );
        } else {
          await File('${checkout.path}/$name').writeAsString('$id\n');
        }
      }
      await _git(checkout, ['add', '--', ...names]);
      stockEnvironments.add(
        Environment(
          id: EnvironmentId(id),
          taskId: TaskId('task'),
          role: id == 'additional'
              ? EnvironmentRole.additional
              : EnvironmentRole.primary,
          providerId: ProviderId(_stockProvider),
          providerState: {
            'schemaVersion': 2,
            'environmentId': id,
            'sourceRelativePath': '',
            'worktreeRelativePath': relative,
            'branch': 'adele-$id',
          },
        ),
      );
    }
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    final sdk = File(dart).parent.parent.path;
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    final contract = File(
      '${temporary.path}/prepared_capability_contract.dart',
    );
    await contract.writeAsString(
      await File(
        'test/fixtures/prepared_capability_contract.dart.txt',
      ).readAsString(),
    );
    for (final name in [
      'prepared_environment_capability_environment',
      'prepared_environment_capability_backend',
      'prepared_environment_capability_callable',
      'prepared_environment_capability_support',
      'prepared_environment_buffered_process_environment',
      'prepared_environment_buffered_process_callable',
    ]) {
      await File('${temporary.path}/$name.dart').writeAsString(
        await File('test/fixtures/$name.dart.txt').readAsString(),
      );
    }
    await ContractGenerator(sdkPath: sdk).apply(contract, check: false);
    hostArtifact = File('${temporary.path}/host.aot');
    stockArtifact = File('${temporary.path}/stock.aot');
    environmentArtifact = File('${temporary.path}/environment.aot');
    siblingArtifact = File('${temporary.path}/sibling.aot');
    callableArtifact = File('${temporary.path}/callable.aot');
    frontendArtifact = File('${temporary.path}/frontend.evc');
    await compilePreparedEnvironmentCapabilityFrontend(
      repositoryRoot: Directory.current.parent,
      contract: contract,
      sdkPath: sdk,
      artifact: frontendArtifact,
      frontendFixture:
          'prepared_environment_buffered_process_frontend.dart.txt',
    );
    for (final target in [
      (
        'packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact,
      ),
      ('plugins/git/packages/backend/bin/git_backend.dart', stockArtifact),
      (
        '${temporary.absolute.path}/prepared_environment_buffered_process_environment.dart',
        environmentArtifact,
      ),
      (
        '${temporary.absolute.path}/prepared_environment_capability_backend.dart',
        siblingArtifact,
      ),
      (
        '${temporary.absolute.path}/prepared_environment_buffered_process_callable.dart',
        callableArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.$1,
        artifact: target.$2.absolute,
        stage: 'prepared-buffered-process',
      );
    }
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late PreparedEnvironmentCapabilityInstallation fixture;
  Future<void> mount(
    WidgetTester tester, {
    bool stock = false,
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
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    fixture = PreparedEnvironmentCapabilityInstallation(
      capabilities: registry,
      files: temporary,
      independent: true,
      environmentPlugin: stock ? _stockPlugin : _environmentPlugin,
      sourceLocation: stock ? repository.uri : null,
      environments: stock ? stockEnvironments : null,
    );
    addTearDown(fixture.close);
    await tester.runAsync(() async {
      final root = await Directory(
        '${temporary.path}/case-${sequence++}',
      ).create();
      for (final (id, artifact) in [
        (
          stock ? _stockPlugin : _environmentPlugin,
          stock
              ? stockArtifact
              : readOnlySibling
              ? siblingArtifact
              : environmentArtifact,
        ),
        (_callablePlugin, callableArtifact),
      ]) {
        final installation = await Directory('${root.path}/$id').create();
        await artifact.copy('${installation.path}/backend.aot');
        await _manifest(installation, id, {
          'backend': {'artifact': 'backend.aot'},
        });
      }
      final consumer = await Directory('${root.path}/consumer').create();
      await frontendArtifact.copy('${consumer.path}/frontend.evc');
      await _manifest(consumer, 'test.buffered.consumer', {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [
            {
              'role': 'mainContent',
              'extensionId': 'test.buffered.pane',
              'order': 100,
              'library': preparedEnvironmentCapabilityFrontendLibrary,
              'initialize': 'initialize',
              'entrypoint': 'buildPane',
              'capabilities': [
                {'id': _capability.id.value, 'majorVersion': 1},
              ],
              if (processGrant)
                'environmentBufferedProcessCapabilities': [
                  {'id': _capability.id.value, 'majorVersion': 1},
                ],
              if (readGrant)
                'environmentReadCapabilities': [
                  {'id': _capability.id.value, 'majorVersion': 1},
                ],
            },
          ],
        },
      });
      await fixture.backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          if (!stock)
            _environmentPlugin: [
              jsonEncode({
                'noBufferedFacet': noBufferedFacet,
                'exposures': [
                  ..._environmentExposures(noBufferedFacet: noBufferedFacet),
                  if (readOnlySibling)
                    AdeleCapabilityExposure(
                      providerId: 'test.callable.sibling',
                      capabilityId: _capability.id.value,
                      capabilityMajorVersion: 1,
                      serviceId: _service,
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
          _callablePlugin: [
            jsonEncode({
              'exposures': _callableExposures(
                providers,
                permissions,
                secondPermissions,
              ),
            }),
          ],
        },
      );
      expect(fixture.backends.state, ApplicationPluginState.ready);
      expect(fixture.backends.failure, isNull);
      expect(fixture.backends.catalog!.issues, isEmpty);
      expect(fixture.backends.catalog!.installations, hasLength(3));
      expect(fixture.backends.backends, hasLength(2));
      for (final backend in fixture.backends.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
        expect(backend.installation.frontend, isNull);
      }
      await fixture.frontends.start(fixture.backends.catalog!);
      final frontend = fixture.frontends.generations.single;
      expect(
        frontend.state,
        InstalledFrontendState.active,
        reason: '${frontend.failure}',
      );
      expect(frontend.installation.backendArtifactUri, isNull);
      expect(
        fixture.backends.backendForInstallation(frontend.installation),
        isNull,
      );
    });
    if (present) {
      await tester.pumpWidget(fixture.widget(concurrent: concurrent));
      await tester.pumpAndSettle();
      expect(
        find.text('idle'),
        findsNWidgets(concurrent ? 2 : 1),
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(' | '),
      );
    }
  }

  test(
    'semantic B and EVC C depend only on public APIs and cannot start processes',
    () async {
      final backend = await File(
        'test/fixtures/prepared_environment_buffered_process_callable.dart.txt',
      ).readAsString();
      final frontend = await File(
        'test/fixtures/prepared_environment_buffered_process_frontend.dart.txt',
      ).readAsString();
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

  testWidgets(
    'stock AOT A hashes binary stdin and returns NUL-delimited nonprimary paths through independent B and EVC C',
    (tester) async {
      await mount(tester, stock: true, concurrent: true);
      expect(
        fixture.environmentOwner.installation.metadata.id.value,
        _stockPlugin,
      );
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      expect(
        fixture.callableOwner.installation.backendArtifactUri,
        isNot(fixture.environmentOwner.installation.backendArtifactUri),
      );
      expect(
        fixture.connection.capabilityExposures.every(
          (exposure) =>
              exposure.capabilityId != environmentProviderCapability.id.value,
        ),
        isTrue,
      );
      final selected = await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(_capability),
      );
      expect(selected!.environment.id.value, 'additional');
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(
        selected.materialization.binding.provider.id.value,
        _stockProvider,
      );
      expect(selected.binding.provider.id.value, 'test.callable.a');
      expect(fixture.callableOwner.associationFor(selected.binding), isNull);
      fixture.environmentOwner.validateProviderOwnership(
        selected.materialization.binding,
      );
      fixture.callableOwner.validateProviderOwnership(selected.binding);
      expect(
        () => fixture.environmentOwner.validateProviderOwnership(
          selected.binding,
        ),
        throwsStateError,
      );
      await _select(tester);
      await _select(tester, pane: 'b');

      _press(tester, 'hash');
      // Git blob identity is independently computed, not compared to another Git invocation.
      final digest = sha1.convert([
        ...utf8.encode('blob ${_binaryInput.length}\x00'),
        ..._binaryInput,
      ]);
      await _text(tester, _result(utf8.encode('$digest\n')));
      _press(tester, 'files');
      await _text(
        tester,
        _result(
          utf8.encode(
            'file with spaces.txt\x00line\nname.txt\x00overflow.bin\x00seed.txt\x00',
          ),
        ),
      );
      _press(tester, 'files', pane: 'b');
      await _text(
        tester,
        _result(utf8.encode('primary-only.txt\x00seed.txt\x00')),
        pane: 'b',
      );
      _press(tester, 'empty');
      await _text(tester, _result([]));
      _press(tester, 'stdin-bound');
      final fullInput = List<int>.filled(
        environmentBufferedProcessStdinLimit,
        255,
      );
      final fullDigest = sha1.convert([
        ...utf8.encode('blob ${fullInput.length}\x00'),
        ...fullInput,
      ]);
      await _text(tester, _result(utf8.encode('$fullDigest\n')));
      _press(tester, 'nonzero');
      await _text(
        tester,
        _result(
          [],
          exitCode: 128,
          stderr: utf8.encode('fatal: Needed a single revision\n'),
        ),
      );
      for (final (action, code) in [
        ('timeout', 'process_timed_out'),
        ('stdout-overflow', 'process_output_overflow'),
      ]) {
        _press(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'settled:$action'));
        await _text(tester, 'process:unavailable');
        expect(
          ((await tester.runAsync(() => _probe(fixture)))!['failures'] as List)
              .last,
          code,
        );
      }
      final requests = fixture.calls(
        (await tester.runAsync(() => _probe(fixture)))!,
      );
      expect(requests, hasLength(8));
      expect(
        requests.map((r) => r['hostInvocationContext']).toSet(),
        hasLength(8),
      );
      expect(
        requests.every((r) => r['configurationContext'] == 'callable-shared'),
        isTrue,
      );
      for (final request in requests) {
        expect((request['payload'] as Map).keys, ['scope']);
        await tester.runAsync(
          () => _denied(fixture, request['hostInvocationContext'] as String),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
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
        _press(tester, 'Default');
        await _text(tester, 'selection:unavailable');
        _press(tester, 'Forged handle');
        await _text(tester, 'process:unavailable');
        expect(
          fixture.calls((await tester.runAsync(() => _probe(fixture)))!),
          isEmpty,
        );
        if (frontend == 'read-only') {
          await _select(tester, button: 'Read grant');
          _press(tester, 'hash');
          await _text(tester, 'process:unavailable');
        }
        _press(tester, 'Ordinary');
        await _text(tester, 'process:unavailable');
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
        _press(tester, 'Default');
        await _text(tester, 'selection:unavailable');
        final binding = fixture.capabilities.resolve(
          _capability,
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
          ).resolve(_capability),
        );
        var called = false;
        await tester.runAsync(
          () => expectLater(
            invokeEnvironmentCapabilityWithBufferedProcess<void>(
              selection: selection!,
              backends: fixture.backends,
              serviceId: _service,
              invoke: (_) async {
                called = true;
              },
            ),
            throwsStateError,
          ),
        );
        expect(called, isFalse);
        expect(
          fixture.calls((await tester.runAsync(() => _probe(fixture)))!),
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
      _press(tester, 'Check denials');
      await _text(tester, 'denials:passed');
      expect(
        fixture.calls((await tester.runAsync(() => _probe(fixture)))!),
        isEmpty,
      );
      await _select(tester);
      _press(tester, 'Forge payload');
      await _text(tester, 'forgery:rejected');
      for (final action in ['foreign-id', 'read-service']) {
        _press(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'settled:$action'));
        await _text(tester, 'process:unavailable');
      }
      final snapshot = (await tester.runAsync(fixture.snapshot))!;
      expect(snapshot['processes'], isEmpty);
      expect(snapshot['reads'], isEmpty);
      expect(fixture.calls(snapshot), hasLength(3));
      _press(tester, 'hash');
      await _text(tester, _result([0, 255, 195, 40]));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live operation grants reject foreign activations services methods and authority selectors, then expire',
    (tester) async {
      await mount(tester);
      await _select(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'after:hash'}),
      );
      _press(tester, 'hash');
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
        await _denied(fixture, 'invented');
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
          await _denied(
            fixture,
            token,
            service: service,
            method: method,
            arguments: arguments,
          );
        }
        await _denied(fixture, token, method: 'wrong-method');
        for (final field in [
          'environmentId',
          'sessionId',
          'providerId',
          'hostInvocationContext',
        ]) {
          await _denied(
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
          await _denied(fixture, token, arguments: {'request': request});
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
      await _text(tester, _result([0, 255, 195, 40]));
      await tester.runAsync(() async {
        await _denied(fixture, token);
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
      await _select(tester);
      _press(tester, 'empty');
      await _text(tester, _result([]));
      _press(tester, 'nonzero');
      await _text(
        tester,
        _result([0, 255, 195, 40], exitCode: 17, stderr: [255, 0]),
      );
      for (final (action, code) in [
        ('stdout-overflow', 'process_output_overflow'),
        ('timeout', 'process_timed_out'),
        ('unavailable', environmentBufferedProcessUnavailableCode),
      ]) {
        _press(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'settled:$action'));
        await _text(tester, 'process:unavailable');
        final snapshot = (await tester.runAsync(() => _probe(fixture)))!;
        expect((snapshot['failures'] as List).last, code);
        await tester.runAsync(
          () async => _denied(fixture, await _token(fixture, action)),
        );
        expect(find.textContaining('SECRET'), findsNothing);
        _press(tester, 'hash');
        await _text(tester, _result([0, 255, 195, 40]));
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
        await _select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        _press(tester, 'held');
        await tester.runAsync(() => fixture.wait(tester, 'process:held'));
        final token = (await tester.runAsync(() => _token(fixture, 'held')))!;
        final staleCall = _callback(tester, 'hash');
        final staleResolve = _callback(tester, 'Default');
        if (departure == 'release') {
          _press(tester, 'Release');
          await _text(tester, 'released');
          _press(tester, 'Release');
          await _text(tester, 'already released');
        } else if (departure == 'navigation') {
          fixture.frontends.unbind(fixture.sessionA);
          await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
          await tester.pumpAndSettle();
        } else if (departure == 'raw registration') {
          fixture.frontends.generations.single.registrations.single.close();
        } else {
          await tester.runAsync(fixture.frontends.generations.single.close);
        }
        await tester.runAsync(() => _denied(fixture, token));
        staleCall();
        if (departure != 'release') staleResolve();
        await tester.runAsync(() async {
          await fixture.control('release', {'key': 'process:held'});
          await fixture.wait(tester, 'settled:held');
        });
        await tester.pumpAndSettle();
        expect(find.text(_result([0, 255, 195, 40])), findsNothing);
        expect(
          fixture.calls((await tester.runAsync(() => _probe(fixture)))!),
          hasLength(1),
        );
        if (departure == 'release' || departure == 'navigation') {
          await _select(tester);
          _press(tester, 'hash');
          await _text(
            tester,
            _result(
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
        _press(tester, 'Default');
        await _text(tester, 'selection:unavailable');
        _press(tester, 'Select A');
        await _text(tester, 'selection:unavailable');
        expect(
          fixture.calls((await tester.runAsync(() => _probe(fixture)))!),
          isEmpty,
        );
        if (count == 2) {
          await _select(tester, button: 'Select B');
          _press(tester, 'hash');
          await _text(tester, _result([0, 255, 195, 40]));
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
      await _select(tester);
      await _select(tester, pane: 'b');
      for (final action in ['one', 'two']) {
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:$action'}),
        );
      }
      _press(tester, 'one');
      _press(tester, 'two', pane: 'b');
      await tester.runAsync(() async {
        await fixture.wait(tester, 'process:one');
        await fixture.wait(tester, 'process:two');
      });
      final firstToken = (await tester.runAsync(() => _token(fixture, 'one')))!;
      final secondToken = (await tester.runAsync(
        () => _token(fixture, 'two'),
      ))!;
      expect(firstToken, isNot(secondToken));
      _press(tester, 'Release');
      await _text(tester, 'process:unavailable');
      await tester.runAsync(() async {
        await _denied(fixture, firstToken);
        await fixture.control('release', {'key': 'process:two'});
      });
      await _text(tester, _result([0, 128, 66]), pane: 'b');
      await tester.runAsync(() async {
        await _denied(fixture, secondToken);
        await fixture.control('release', {'key': 'process:one'});
        await fixture.wait(tester, 'settled:one');
      });
      expect(find.text(_result([0, 255, 195, 40])), findsNothing);
      _press(tester, 'fresh', pane: 'b');
      await _text(tester, _result([0, 128, 66]), pane: 'b');
      final freshToken = (await tester.runAsync(
        () => _token(fixture, 'fresh'),
      ))!;
      expect({firstToken, secondToken, freshToken}, hasLength(3));
      await tester.runAsync(() => _denied(fixture, freshToken));
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
        await _select(tester);
        await _select(tester, pane: 'b');
        final environment = fixture.capabilities.resolve(
          environmentProviderCapability,
          providerId: ProviderId('test.environment.a'),
        );
        final callable = fixture.capabilities.resolve(
          _capability,
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
        _press(tester, 'held');
        await tester.runAsync(() => fixture.wait(tester, 'process:held'));
        final token = (await tester.runAsync(() => _token(fixture, 'held')))!;
        await tester.runAsync(() => owner.retireProvider(target));
        await _text(tester, 'process:unavailable');
        expect(
          () => target.requestChannel,
          throwsA(isA<ProviderUnavailable>()),
        );
        fixture.environmentOwner.validate();
        fixture.callableOwner.validate();
        expect(fixture.connection.isClosed, isFalse);
        expect(fixture.environmentConnection.isClosed, isFalse);
        await tester.runAsync(() => _denied(fixture, token));
        _press(tester, 'Default');
        await _text(tester, 'selection:unavailable');
        _press(tester, 'hash', pane: 'b');
        await _text(
          tester,
          side == 'environment' ? _result([0, 128, 66]) : 'process:unavailable',
          pane: 'b',
        );
        await tester.runAsync(() async {
          await fixture.control('release', {'key': 'process:held'});
          await fixture.wait(tester, 'settled:held');
          await _denied(fixture, token);
        });
        expect(otherRetirements, 0);
        expect(find.text(_result([0, 255, 195, 40])), findsNothing);
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
        await _select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        _press(tester, 'held');
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
          await terminating.terminated.timeout(_bound);
        });
        await _text(tester, 'process:unavailable');
        expect(terminating.isClosed, isTrue);
        expect(surviving.isClosed, isFalse);
        expect(fixture.backends.host!.isClosed, isFalse);
        _press(tester, 'Default');
        await _text(tester, 'selection:unavailable');
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
        expect(find.text(_result([0, 255, 195, 40])), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'same-ID backend replacement never revives retained process clients or tokens',
    (tester) async {
      await mount(tester);
      await _select(tester);
      final old = fixture;
      final oldBinding = old.capabilities.resolve(
        _capability,
        providerId: ProviderId('test.callable.a'),
      );
      final oldEnvironment = old.capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      final stale = _callback(tester, 'hash');
      await tester.runAsync(() => old.control('hold', {'key': 'process:held'}));
      _press(tester, 'held');
      await tester.runAsync(() => old.wait(tester, 'process:held'));
      final token = (await tester.runAsync(() => _token(old, 'held')))!;
      await tester.runAsync(old.backends.close);
      await _text(tester, 'process:unavailable');
      await mount(tester, present: false, registry: old.capabilities);
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.capabilities
            .resolve(_capability, providerId: ProviderId('test.callable.a'))
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
      await _text(tester, 'process:unavailable');
      expect(
        fixture.calls((await tester.runAsync(() => _probe(fixture)))!),
        isEmpty,
      );
      await tester.runAsync(() => _denied(fixture, token));
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'hash');
      await _text(tester, _result([0, 255, 195, 40]));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final identityOnly in [false, true]) {
    testWidgets(
      'queued reverse ${identityOnly ? 'identity' : 'process'} is revoked before service entry after held cleanup',
      (tester) async {
        await mount(tester);
        await _select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:held'}),
        );
        _press(tester, 'held');
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
        _press(tester, 'Release');
        await _text(tester, 'process:unavailable');
        // Both reverse callers settle while the first provider process stays held.
        expect(await tester.runAsync(() => fixture.control('queuedResult')), {
          'ok': false,
        });
        await tester.runAsync(() async {
          await _denied(fixture, token);
          await fixture.control('release', {'key': 'process:held'});
          await fixture.wait(tester, 'settled:held');
        });
        await tester.pumpAndSettle();
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          hasLength(1),
        );
        expect(find.text(_result([0, 255, 195, 40])), findsNothing);
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
              capabilities: [_capability],
              bufferedProcessCapabilities: [_capability],
              isActive: () => true,
            );
        final access = bridge();
        final foreign = bridge();
        addTearDown(access.invalidate);
        addTearDown(foreign.invalidate);
        Future<String?> resolve(bool process) => process
            ? access.resolveBufferedProcess(
                _capability.id.value,
                1,
                _service,
                null,
              )
            : access.resolve(_capability.id.value, 1, _service, null);
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
          foreign.request(handles[1], '$_service.read', {'scope': 'hash'}),
          throwsStateError,
        );
        await expectLater(
          access.request(handles[0], '$_service.read', {'scope': 'hash'}),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        await expectLater(
          access.request(handles[1], '$_service.read', {
            'scope': 'read-service',
          }),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        expect((await fixture.snapshot())['processes'], isEmpty);
        final result =
            (await access.request(handles[1], '$_service.read', {
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
          access.request(handles[0], '$_service.read', {'scope': 'hash'}),
          throwsStateError,
        );
        // Reuse of the one live process handle opens independent unary grants.
        await access.request(handles[1], '$_service.read', {'scope': 'fresh'});
        expect((await fixture.snapshot())['processes'], hasLength(2));
        final calls = fixture.calls(await _probe(fixture));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(4),
        );
        for (final call in calls) {
          await _denied(fixture, call['hostInvocationContext'] as String);
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
          ).resolve(_capability);
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
            serviceId: _service,
            invoke: (channel) =>
                channel.request('$_service.read', {'scope': 'identity'}),
          );
          expect(result, {
            'provider': 'identity',
            'configuration': session.id.value,
            'sequence': 0,
            'text': environmentId,
          });
          final token = await _token(fixture, 'identity');
          tokens.add(token);
          await _denied(fixture, token);
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
          ).resolve(_capability);
          await fixture.control('hold', {'key': '$checkpoint:identity'});
          late void Function() retire;
          final pending = invokeEnvironmentCapabilityWithBufferedProcess(
            selection: selection,
            backends: fixture.backends,
            serviceId: _service,
            onRetire: (revoke) {
              retire = revoke;
              return () {};
            },
            invoke: (channel) =>
                channel.request('$_service.read', {'scope': 'identity'}),
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
          await _denied(fixture, token);
          expect(
            await fixture.control('retainedBufferedIdentity', {
              'key': 'identity',
            }),
            {'ok': false},
          );
          await fixture.control('release', {'key': '$checkpoint:identity'});
          await failed.timeout(_bound);
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
        ).resolve(_capability);
        final received = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        late AdeleRequestChannel retained;
        final pending = invokeEnvironmentCapabilityWithBufferedProcess(
          selection: selection,
          backends: fixture.backends,
          serviceId: _service,
          invoke: (channel) async {
            retained = channel;
            final result = await channel.request('$_service.read', {
              'scope': 'hash',
            });
            received.complete();
            await release.future;
            return result;
          },
        );
        await received.future.timeout(_bound);
        await _denied(fixture, await _token(fixture, 'hash'));
        expect(await fixture.control('retainedBuffered', {'key': 'hash'}), {
          'ok': false,
        });
        await expectLater(
          retained.request('$_service.read', {'scope': 'fresh'}),
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
          _press(tester, 'Default');
          await _text(tester, 'selection:unavailable');
          if (readGrant) {
            await _select(tester, button: 'Read grant');
            _press(tester, 'hash');
            await _text(tester, 'process:unavailable');
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
        ).resolve(_capability),
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
        _capability,
        providerId: ProviderId('test.callable.a'),
      );
      expect(
        fixture.callableOwner.allowsEnvironmentHostService(
          independent,
          AdeleEnvironmentHostService.bufferedProcess,
        ),
        isTrue,
      );
      _press(tester, 'Default');
      await _text(tester, 'selection:unavailable');
      expect(
        fixture.calls((await tester.runAsync(fixture.snapshot))!),
        isEmpty,
      );
      // Explicit independent selection is possible; automatic permission-based
      // substitution of the existing sibling is not.
      await _select(tester, button: 'Select A');
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
      await _select(tester);
      await _select(tester, pane: 'b');
      _press(tester, 'hash');
      await _text(tester, 'process:unavailable');
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      expect((await tester.runAsync(() => _probe(fixture)))!['failures'], [
        environmentBufferedProcessUnavailableCode,
      ]);
      _press(tester, 'hash', pane: 'b');
      await _text(tester, _result([0, 128, 66]), pane: 'b');
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

List<Map<String, Object?>> _callableExposures(
  int count,
  List<AdeleEnvironmentHostService> permissions,
  List<AdeleEnvironmentHostService>? secondPermissions,
) => [
  for (final id in [
    ...['a', 'b'].take(count),
    'context-free',
  ])
    AdeleCapabilityExposure(
      providerId: 'test.callable.$id',
      capabilityId: _capability.id.value,
      capabilityMajorVersion: 1,
      serviceId: _service,
      displayName: id,
      configurationContext: id == 'context-free' ? id : 'callable-shared',
      rank: id == 'a' ? 1 : 100,
      environmentBound: id != 'context-free',
      environmentHostServices: id == 'context-free'
          ? const []
          : id == 'b'
          ? secondPermissions ?? permissions
          : permissions,
    ).toMap(),
];

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

Future<void> _manifest(
  Directory root,
  String id,
  Map<String, Object?> components,
) => File('${root.path}/adele_plugin.installation.json').writeAsString(
  jsonEncode({
    'manifestVersion': 1,
    'metadata': {'id': id, 'version': '1', 'displayName': id},
    'components': components,
  }),
);

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}

Finder _pane(String pane, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);
VoidCallback _callback(
  WidgetTester tester,
  String label, {
  String pane = 'a',
}) => tester
    .widget<TextButton>(_pane(pane, find.widgetWithText(TextButton, label)))
    .onPressed!;
void _press(WidgetTester tester, String label, {String pane = 'a'}) =>
    _callback(tester, label, pane: pane)();

Future<void> _text(
  WidgetTester tester,
  String text, {
  String pane = 'a',
}) async {
  await tester.pump();
  final finder = _pane(pane, find.text(text));
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(finder, findsOneWidget);
}

Future<void> _select(
  WidgetTester tester, {
  String pane = 'a',
  String button = 'Default',
}) async {
  _press(tester, button, pane: pane);
  await _text(tester, 'selected', pane: pane);
}

String _result(
  List<int> stdout, {
  int exitCode = 0,
  List<int> stderr = const [],
}) => 'buffered|${base64Encode(stdout)}|$exitCode|${base64Encode(stderr)}';

Future<Map<Object?, Object?>> _probe(
  PreparedEnvironmentCapabilityInstallation h,
) async => (await h.control('snapshot'))! as Map<Object?, Object?>;

Future<String> _token(
  PreparedEnvironmentCapabilityInstallation h,
  String action,
) async =>
    h
            .calls(await _probe(h))
            .lastWhere(
              (request) => (request['payload'] as Map)['scope'] == action,
            )['hostInvocationContext']
        as String;

Future<void> _denied(
  PreparedEnvironmentCapabilityInstallation h,
  String token, {
  String? service,
  String? method,
  Map<String, Object?>? arguments,
}) async {
  expect(
    await h.control('attackBuffered', {
      'token': token,
      'service': ?service,
      'method': ?method,
      'arguments': ?arguments,
    }),
    {'ok': false},
  );
  if (service == null && method == null && arguments == null) {
    expect(
      await h.control('attackBuffered', {
        'token': token,
        'method': authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
        'arguments': <String, Object?>{},
      }),
      {'ok': false},
    );
  }
}

Map<String, Object?> _requestPayload() => {
  'request': {
    'program': 'git',
    'arguments': ['-c', 'adele.probeAction=attack', 'hash-object', '--stdin'],
    'relativeWorkingDirectory': '',
    'timeoutSeconds': 5,
    'stdinBase64': '',
  },
};
