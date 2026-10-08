@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/prepared_environment_capability_frontend_compiler.dart';

const _bound = Duration(seconds: 10);
const _plugin = 'test.environment.capability.backend';
const _service = 'test.capability.probe';
const _fileContents = {
  'a': {
    'A': 'Violets bloom after rain.\n',
    'B': 'A copper key rests in the drawer.\n',
    'held': 'Paper lanterns at dusk.\n',
    'backend-failure': 'A sealed envelope beside the window.\n',
    'attack': 'An amber bead in a small wooden box.\n',
    'retained': 'A green ribbon on the bookshelf.\n',
  },
  'b': {
    'A': 'Three apples rest in a basket.\n',
    'B': 'The brass clock strikes seven.\n',
    'held': 'A folded map on the table.\n',
    'backend-failure': 'The last page contains a blue stamp.\n',
    'attack': 'A silver spoon beside a porcelain cup.\n',
    'retained': 'A red ribbon on the windowsill.\n',
  },
};
final _capability = CapabilityKey(
  id: CapabilityId('test.capability.read'),
  majorVersion: 1,
);

void main() {
  late Directory temporary;
  late Directory files;
  late File hostArtifact;
  late File providerArtifact;
  late File frontendArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('prepared-environment-capability-');
    files = await Directory('${temporary.path}/files').create();
    for (final environment in _fileContents.entries) {
      final root = await Directory('${files.path}/${environment.key}').create();
      for (final file in environment.value.entries) {
        await File('${root.path}/${file.key}').writeAsString(file.value);
      }
    }
    final dart = _dartExecutable();
    final sdk = File(dart).parent.parent.path;
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    final contract = File(
      '${temporary.path}/prepared_capability_contract.dart',
    );
    // One unchanged authored C1 declaration supplies native and eval transport.
    await contract.writeAsString(
      await File(
        'test/fixtures/prepared_capability_contract.dart.txt',
      ).readAsString(),
    );
    final backend = File(
      '${temporary.path}/prepared_environment_capability_backend.dart',
    );
    await backend.writeAsString(
      await File(
        'test/fixtures/prepared_environment_capability_backend.dart.txt',
      ).readAsString(),
    );
    await ContractGenerator(sdkPath: sdk).apply(contract, check: false);
    hostArtifact = File('${temporary.path}/host.aot');
    providerArtifact = File('${temporary.path}/provider.aot');
    frontendArtifact = File('${temporary.path}/frontend.evc');
    await compilePreparedEnvironmentCapabilityFrontend(
      repositoryRoot: Directory.current.parent,
      contract: contract,
      sdkPath: sdk,
      artifact: frontendArtifact,
    );
    for (final target in [
      (
        entrypoint:
            '${Directory.current.parent.path}/packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (entrypoint: backend.absolute.path, artifact: providerArtifact),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact.absolute,
        stage: 'prepared-environment-capability-integration',
      );
    }
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late _Installation fixture;
  setUp(() {
    fixture = _Installation(files: files);
    addTearDown(fixture.close);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool contextual = true,
    bool ordinary = true,
    bool concurrent = false,
    bool present = true,
  }) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final root = await Directory(
        '${temporary.path}/case-${sequence++}',
      ).create();
      final provider = await Directory('${root.path}/provider').create();
      await providerArtifact.copy('${provider.path}/backend.aot');
      await _manifest(provider, _plugin, {
        'backend': {'artifact': 'backend.aot'},
      });
      final consumer = await Directory('${root.path}/consumer').create();
      await frontendArtifact.copy('${consumer.path}/frontend.evc');
      await _manifest(consumer, 'test.environment.capability.consumer', {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [
            {
              'role': 'mainContent',
              'extensionId': 'test.consumer.pane',
              'order': 100,
              'library': preparedEnvironmentCapabilityFrontendLibrary,
              'initialize': 'initialize',
              'entrypoint': 'buildPane',
              if (contextual)
                'environmentReadCapabilities': [
                  {'id': _capability.id.value, 'majorVersion': 1},
                  {'id': _capability.id.value, 'majorVersion': 2},
                ],
              if (ordinary)
                'capabilities': [
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
          _plugin: [
            jsonEncode({'exposures': _exposures()}),
          ],
        },
      );
      expect(fixture.backends.state, ApplicationPluginState.ready);
      expect(fixture.backends.failure, isNull);
      expect(fixture.backends.catalog!.issues, isEmpty);
      final backend = fixture.backends.backends.single;
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
      expect(backend.connection!.capabilityExposures, hasLength(5));
      await fixture.frontends.start(fixture.backends.catalog!);
      final frontend = fixture.frontends.generations.single;
      expect(
        frontend.state,
        InstalledFrontendState.active,
        reason: '${frontend.failure}',
      );
    });
    if (!present) return;
    await tester.pumpWidget(fixture.widget(concurrent: concurrent));
    await tester.pumpAndSettle();
    expect(find.text('idle'), findsNWidgets(concurrent ? 2 : 1));
    expect(find.text('Independent content'), findsNWidgets(concurrent ? 2 : 1));
  }

  Future<void> select(
    WidgetTester tester, {
    String pane = 'a',
    String button = 'Default',
  }) async {
    _press(tester, button, pane: pane);
    await _text(tester, 'selected', pane: pane);
  }

  test(
    'independent frontend/backend fixtures depend only on public contracts',
    () async {
      final imports = RegExp(r"import '([^']+)';");
      Future<Set<String>> imported(String name) async => imports
          .allMatches(
            await File(
              'test/fixtures/prepared_environment_capability_$name.dart.txt',
            ).readAsString(),
          )
          .map((match) => match[1]!)
          .toSet();
      expect(await imported('frontend'), {
        'package:adele_ui/capability_bridge.dart',
        'package:adele_ui/environment_capability_bridge.dart',
        'package:adele_ui/main_content_bridge.dart',
        'package:capability_probe_contract/contract.dart',
        'package:flutter/material.dart',
      });
      expect(await imported('backend'), {
        'dart:async',
        'dart:convert',
        'dart:io',
        'dart:isolate',
        'package:adele_contract/adele_contract.dart',
        'package:adele_environment/adele_environment.dart',
        'package:adele_plugin_backend_support/adele_plugin_backend_support.dart',
        'prepared_capability_contract.dart',
      });
    },
  );

  testWidgets(
    'frontend-only EVC selects the nonprimary association and displays a generated real reverse read',
    (tester) async {
      await mount(tester);
      final catalog = fixture.backends.catalog!;
      expect(catalog.installations, hasLength(2));
      final consumer = catalog.installations.singleWhere(
        (entry) => entry.frontend != null,
      );
      expect(consumer.backendArtifactUri, isNull);
      expect(fixture.backends.backendForInstallation(consumer), isNull);
      expect(
        catalog.installations
            .singleWhere((entry) => entry.backendArtifactUri != null)
            .frontend,
        isNull,
      );
      expect(
        fixture.capabilities.providersFor(_capability).map((p) => p.id.value),
        ['test.callable.context-free', 'test.callable.b', 'test.callable.a'],
      );
      expect((await tester.runAsync(fixture.snapshot))!['requests'], isEmpty);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'restore:additional'}),
      );
      _press(tester, 'Default');
      await tester.runAsync(() => fixture.wait(tester, 'restore:additional'));
      expect(find.text('selected'), findsNothing);
      expect((await tester.runAsync(fixture.snapshot))!['reads'], isEmpty);
      await tester.runAsync(
        () => fixture.control('release', {'key': 'restore:additional'}),
      );
      await _text(tester, 'selected');
      await tester.runAsync(() => fixture.control('hold', {'key': 'read:A'}));
      _press(tester, 'Read A');
      await tester.runAsync(() => fixture.wait(tester, 'read:A'));
      expect(find.text(_value('a', 'A')), findsNothing);
      final pending = (await tester.runAsync(fixture.snapshot))!;
      expect(pending['reads'], [_read('a', 'A')]);
      final request = fixture.calls(pending).single;
      expect(request['configurationContext'], 'callable-shared');
      expect(request['serviceId'], _service);
      expect(request['hostInvocationContext'], isA<String>());
      await tester.runAsync(
        () => fixture.control('release', {'key': 'read:A'}),
      );
      await _text(tester, _value('a', 'A'));
      await tester.runAsync(
        () => fixture.denied(request['hostInvocationContext'] as String),
      );
      expect(
        await tester.runAsync(() => fixture.control('retained', {'key': 'A'})),
        {'ok': false},
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final ordinary in [false, true]) {
    testWidgets(
      '${ordinary ? 'C1-only declarations' : 'default-deny pane'} cannot acquire contextual authority',
      (tester) async {
        await mount(tester, contextual: false, ordinary: ordinary);
        _press(tester, 'Default');
        await _text(tester, 'selection:unavailable');
        _press(tester, 'Forged handle');
        await _text(tester, 'read:unavailable');
        expect((await tester.runAsync(fixture.snapshot))!['requests'], isEmpty);
        _press(tester, 'Context free');
        await _text(
          tester,
          ordinary
              ? 'context-free|context-free|0|ordinary'
              : 'context-free:unavailable',
        );
        if (ordinary) {
          _press(tester, 'Context free A');
          await _text(tester, 'read:unavailable');
        }
        final snapshot = (await tester.runAsync(fixture.snapshot))!;
        expect(snapshot['reads'], isEmpty);
        expect(fixture.calls(snapshot), hasLength(ordinary ? 2 : 0));
        expect(
          fixture
              .calls(snapshot)
              .every((r) => r['hostInvocationContext'] == null),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'ineligible providers, wrong service/version and forged payload never widen the captured route',
    (tester) async {
      await mount(tester);
      _press(tester, 'Check denials');
      await _text(tester, 'denials:passed');
      var snapshot = (await tester.runAsync(fixture.snapshot))!;
      expect(fixture.calls(snapshot), isEmpty);
      expect(snapshot['reads'], isEmpty);
      await select(tester);
      _press(tester, 'Forge payload');
      await _text(tester, 'forgery:rejected');
      snapshot = (await tester.runAsync(fixture.snapshot))!;
      expect(snapshot['reads'], isEmpty);
      final forged = fixture.calls(snapshot).single;
      expect(forged['configurationContext'], 'callable-shared');
      expect(forged['serviceId'], _service);
      expect(forged['hostInvocationContext'], isNot('forged'));
      expect((forged['payload'] as Map)['environmentId'], 'primary');
      await tester.runAsync(
        () => fixture.denied(forged['hostInvocationContext'] as String),
      );
      _press(tester, 'Read A');
      await _text(tester, _value('a', 'A'));
      expect((await tester.runAsync(fixture.snapshot))!['reads'], [
        _read('a', 'A'),
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'two presentations share backend configuration but never Session or Environment authority',
    (tester) async {
      await mount(tester, concurrent: true);
      await select(tester);
      await select(tester, pane: 'b');
      for (final key in ['read:A', 'read:B']) {
        await tester.runAsync(() => fixture.control('hold', {'key': key}));
      }
      _press(tester, 'Read A');
      _press(tester, 'Read B', pane: 'b');
      await tester.runAsync(() async {
        await fixture.wait(tester, 'read:A');
        await fixture.wait(tester, 'read:B');
      });
      final snapshot = (await tester.runAsync(fixture.snapshot))!;
      expect(
        snapshot['reads'],
        unorderedEquals([_read('a', 'A'), _read('b', 'B')]),
      );
      final calls = fixture.calls(snapshot);
      expect(calls, hasLength(2));
      expect(calls.map((r) => r['configurationContext']).toSet(), {
        'callable-shared',
      });
      expect(
        calls.map((r) => r['hostInvocationContext']).toSet(),
        hasLength(2),
      );
      await tester.runAsync(
        () => fixture.control('release', {'key': 'read:B'}),
      );
      await _text(tester, _value('b', 'B'), pane: 'b');
      expect(find.text(_value('a', 'A')), findsNothing);
      await tester.runAsync(
        () => fixture.control('release', {'key': 'read:A'}),
      );
      await _text(tester, _value('a', 'A'));
      for (final call in calls) {
        await tester.runAsync(
          () => fixture.denied(call['hostInvocationContext'] as String),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live read authority succeeds on replay fixture files and expires on settlement',
    (tester) async {
      await mount(tester);
      await select(tester);
      await tester.runAsync(() => fixture.control('hold', {'key': 'after:A'}));
      _press(tester, 'Read A');
      await tester.runAsync(() => fixture.wait(tester, 'after:A'));
      final token =
          fixture
                  .calls((await tester.runAsync(fixture.snapshot))!)
                  .single['hostInvocationContext']
              as String;
      // Replay denial must prove expired authority, not a missing fixture file.
      await tester.runAsync(() async {
        final replay = fixture.control('attack', {'token': token});
        await fixture.wait(tester, 'read:attack');
        expect(await replay, {'ok': true});
        final retained = fixture.control('retained', {'key': 'A'});
        await fixture.wait(tester, 'read:retained');
        expect(await retained, {'ok': true});
        await fixture.control('release', {'key': 'after:A'});
      });
      await _text(tester, _value('a', 'A'));
      await tester.runAsync(() async {
        await fixture.denied(token);
        expect(await fixture.control('retained', {'key': 'A'}), {'ok': false});
      });
      expect((await tester.runAsync(fixture.snapshot))!['reads'], [
        _read('a', 'A'),
        _read('a', 'attack'),
        _read('a', 'retained'),
      ]);
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
      '$departure revokes an admitted reverse read before gated backend cleanup',
      (tester) async {
        await mount(tester);
        await select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'read:held'}),
        );
        _press(tester, 'Held');
        await tester.runAsync(() => fixture.wait(tester, 'read:held'));
        final token =
            fixture
                    .calls((await tester.runAsync(fixture.snapshot))!)
                    .single['hostInvocationContext']
                as String;
        final staleRead = _callback(tester, 'Read A');
        final staleResolve = _callback(tester, 'Default');
        if (departure == 'release') {
          _press(tester, 'Release');
          await tester.pump();
          expect(find.text('released'), findsOneWidget);
          // Repeated release and the retained generated client remain inert.
          _press(tester, 'Release');
          await tester.pump();
          expect(find.text('already released'), findsOneWidget);
        } else if (departure == 'navigation') {
          fixture.frontends.unbind(fixture.sessionA);
          await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
          await tester.pumpAndSettle();
        } else if (departure == 'raw registration') {
          fixture.frontends.generations.single.registrations.single.close();
          // No frame/reconciliation may be needed to revoke already-issued grants.
        } else {
          await tester.runAsync(fixture.frontends.generations.single.close);
          await tester.pumpAndSettle();
          expect(find.text('Independent content'), findsOneWidget);
        }
        await tester.runAsync(() => fixture.denied(token));
        staleRead();
        if (departure != 'release') staleResolve();
        await tester.runAsync(() async {
          await fixture.control('release', {'key': 'read:held'});
          await fixture.wait(tester, 'settled:held');
        });
        await tester.pumpAndSettle();
        expect(find.text(_value('a', 'held')), findsNothing);
        final snapshot = (await tester.runAsync(fixture.snapshot))!;
        expect(snapshot['reads'], [_read('a', 'held')]);
        expect(fixture.calls(snapshot), hasLength(1));
        expect(fixture.capabilities.providersFor(_capability), hasLength(3));
        if (departure == 'release' || departure == 'navigation') {
          await select(
            tester,
            button: departure == 'navigation' ? 'Select B' : 'Select A',
          );
          _press(tester, departure == 'navigation' ? 'Read B' : 'Read A');
          await _text(
            tester,
            _value(
              departure == 'navigation' ? 'b' : 'a',
              departure == 'navigation' ? 'B' : 'A',
            ),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'navigation while resolution is gated cannot publish the old Session handle',
    (tester) async {
      await mount(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'restore:additional'}),
      );
      _press(tester, 'Default');
      await tester.runAsync(() => fixture.wait(tester, 'restore:additional'));
      fixture.frontends.unbind(fixture.sessionA);
      await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => fixture.control('release', {'key': 'restore:additional'}),
      );
      await select(tester, button: 'Select B');
      _press(tester, 'Read B');
      await _text(tester, _value('b', 'B'));
      expect((await tester.runAsync(fixture.snapshot))!['reads'], [
        _read('b', 'B'),
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'revoking one concurrent presentation does not revoke its sibling operation',
    (tester) async {
      await mount(tester, concurrent: true);
      await select(tester);
      await select(tester, pane: 'b');
      for (final key in ['read:A', 'read:B']) {
        await tester.runAsync(() => fixture.control('hold', {'key': key}));
      }
      _press(tester, 'Read A');
      _press(tester, 'Read B', pane: 'b');
      await tester.runAsync(() async {
        await fixture.wait(tester, 'read:A');
        await fixture.wait(tester, 'read:B');
      });
      final calls = fixture.calls((await tester.runAsync(fixture.snapshot))!);
      _press(tester, 'Release');
      final tokenA =
          calls.singleWhere(
                (r) => (r['payload'] as Map)['scope'] == 'A',
              )['hostInvocationContext']
              as String;
      await tester.runAsync(() => fixture.denied(tokenA));
      await tester.runAsync(() async {
        await fixture.control('release', {'key': 'read:B'});
        await fixture.control('release', {'key': 'read:A'});
        await fixture.wait(tester, 'settled:A');
      });
      await _text(tester, _value('b', 'B'), pane: 'b');
      await _text(tester, 'read:unavailable');
      expect(find.text(_value('a', 'A')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'backend failures are safe and fresh unary calls receive fresh authority',
    (tester) async {
      await mount(tester);
      await select(tester);
      for (final kind in ['backend', 'host']) {
        _press(tester, 'Fail $kind');
        await _text(tester, 'read:unavailable');
        _press(tester, 'Read A');
        await _text(tester, _value('a', 'A'));
      }
      final calls = fixture.calls((await tester.runAsync(fixture.snapshot))!);
      expect(calls, hasLength(4));
      expect(
        calls.map((r) => r['hostInvocationContext']).toSet(),
        hasLength(4),
      );
      for (final call in calls) {
        await tester.runAsync(
          () => fixture.denied(call['hostInvocationContext'] as String),
        );
      }
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'backend retirement and same-ID replacement do not revive retained EVC clients',
    (tester) async {
      await mount(tester);
      await select(tester);
      final old = fixture;
      final binding = old.capabilities.resolve(
        _capability,
        providerId: ProviderId('test.callable.a'),
      );
      await tester.runAsync(() => old.control('hold', {'key': 'read:held'}));
      _press(tester, 'Held');
      await tester.runAsync(() => old.wait(tester, 'read:held'));
      final token =
          old
                  .calls((await tester.runAsync(old.snapshot))!)
                  .single['hostInvocationContext']
              as String;
      final staleRead = _callback(tester, 'Read A');
      await tester.runAsync(old.backends.close);
      await _text(tester, 'read:unavailable');
      fixture = _Installation(capabilities: old.capabilities, files: files);
      addTearDown(fixture.close);
      // Keep the old evaluator mounted while identical provider IDs reappear.
      await mount(tester, present: false);
      expect(
        fixture.capabilities
            .resolve(_capability, providerId: ProviderId('test.callable.a'))
            .isSameRegistration(binding),
        isFalse,
      );
      staleRead();
      await tester.pumpAndSettle();
      expect(
        fixture.calls((await tester.runAsync(fixture.snapshot))!),
        isEmpty,
      );
      await tester.runAsync(() => fixture.denied(token));
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await select(tester);
      _press(tester, 'Read A');
      await _text(tester, _value('a', 'A'));
      expect((await tester.runAsync(fixture.snapshot))!['reads'], [
        _read('a', 'A'),
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final class _Installation {
  _Installation({CapabilityRegistry? capabilities, required Directory files})
    : capabilities = capabilities ?? CapabilityRegistry() {
    final task = Task(
      id: TaskId('task'),
      projectId: ProjectId('project'),
      title: 'C2c',
    );
    final strategy = OrchestrationStrategyId('test.uninstalled-strategy');
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
          providerState: {'root': '${files.absolute.path}/a'},
        ),
        Environment(
          id: EnvironmentId('primary'),
          taskId: task.id,
          role: EnvironmentRole.primary,
          providerId: ProviderId('test.environment.b'),
          providerState: {'root': '${files.absolute.path}/b'},
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
      registry: this.capabilities,
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(binding.requestChannel),
      ),
      retainEnvironment: store.replaceEnvironment,
    );
    backends = ApplicationPluginBootstrap(this.capabilities, extensions);
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      mainContentHost: PreparedMainContentHost(
        environmentRuntime: environmentRuntime,
      ),
    );
    extensions.register(
      point: mainContentContributions,
      id: ExtensionId('test.independent'),
      value: MainContentContribution(
        order: 200,
        attach: (access) => access.open(
          MainContentPane(
            id: 'independent',
            title: 'Independent',
            createPresentation: () => const Text('Independent content'),
          ),
        ),
      ),
    );
  }

  final CapabilityRegistry capabilities;
  final extensions = ExtensionRegistry();
  late final Session sessionA;
  late final Session sessionB;
  late final EnvironmentRuntime environmentRuntime;
  late final ApplicationPluginBootstrap backends;
  late final ApplicationFrontendBootstrap frontends;
  PluginBackendConnection get connection =>
      backends.backends.single.connection!;

  Future<Object?> control(
    String method, [
    Map<String, Object?> payload = const {},
  ]) => connection
      .channelFor(connection.defaultConfigurationContext, 'probe')
      .request(method, payload)
      .timeout(_bound);
  Future<void> wait(WidgetTester tester, String key) async {
    var completed = false;
    Object? failure;
    StackTrace? trace;
    final pending = control('wait', {'key': key}).then<void>(
      (_) => completed = true,
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        completed = true;
      },
    );
    // Reverse dispatch is hosted in the widget's fake-async zone. Pump it while
    // waiting for the explicit AOT checkpoint, rather than inferring progress.
    while (!completed) {
      await Future<void>(() {});
      await tester.pump();
    }
    await pending;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  Future<Map<Object?, Object?>> snapshot() async =>
      (await control('snapshot'))! as Map<Object?, Object?>;
  List<Map<Object?, Object?>> calls(Map<Object?, Object?> snapshot) =>
      (snapshot['requests'] as List)
          .cast<Map<Object?, Object?>>()
          .where((r) => r['serviceId'] == _service)
          .toList();
  Future<void> denied(String token) async {
    expect(await control('attack', {'token': token}), {'ok': false});
  }

  Widget widget({bool concurrent = false, Session? session}) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Expanded(
            child: MainContentHost(
              key: const ValueKey('a'),
              session: session ?? sessionA,
              extensions: extensions,
            ),
          ),
          if (concurrent)
            Expanded(
              child: MainContentHost(
                key: const ValueKey('b'),
                session: sessionB,
                extensions: extensions,
              ),
            ),
        ],
      ),
    ),
  );

  Future<void> close() async {
    await frontends.close();
    await backends.close();
  }
}

List<Map<String, Object?>> _exposures() => [
  for (final id in ['a', 'b', 'context-free'])
    AdeleCapabilityExposure(
      providerId: 'test.callable.$id',
      capabilityId: _capability.id.value,
      capabilityMajorVersion: 1,
      serviceId: _service,
      displayName: id,
      configurationContext: id == 'context-free' ? id : 'callable-shared',
      rank: id == 'context-free'
          ? 1000
          : id == 'b'
          ? 100
          : 1,
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

String _value(String id, String path) {
  final environment = id == 'a' ? 'additional' : 'primary';
  final session = id == 'a' ? 'nonprimary-session' : 'primary-session';
  final text = _fileContents[id]![path]!;
  return 'callable-shared|$session:$environment|${utf8.encode(text).length}|$text';
}

Map<String, Object?> _read(String id, String path) => {
  'environmentId': id == 'a' ? 'additional' : 'primary',
  'providerId': 'test.environment.$id',
  'path': path,
};

Future<void> _manifest(
  Directory directory,
  String id,
  Map<String, Object?> components,
) => File('${directory.path}/adele_plugin.installation.json').writeAsString(
  jsonEncode({
    'manifestVersion': 1,
    'metadata': {'id': id, 'version': '1', 'displayName': id},
    'components': components,
  }),
);

Finder _inPane(String pane, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);
VoidCallback _callback(
  WidgetTester tester,
  String label, {
  String pane = 'a',
}) => tester
    .widget<TextButton>(_inPane(pane, find.widgetWithText(TextButton, label)))
    .onPressed!;
void _press(WidgetTester tester, String label, {String pane = 'a'}) =>
    _callback(tester, label, pane: pane)();

// Gates observe real AOT admission. Yielding the I/O queue only waits for eval UI
// publication; no fixed sleep is used to infer backend progress or retirement.
Future<void> _text(
  WidgetTester tester,
  String text, {
  String pane = 'a',
}) async {
  final finder = _inPane(pane, find.text(text));
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(finder, findsOneWidget);
}

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dart = File('$root/bin/cache/dart-sdk/bin/dart');
    if (dart.existsSync()) return dart.path;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/bin/dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Pinned Dart SDK not found.');
    }
    directory = directory.parent;
  }
  return '${directory.path}/dart-sdk/bin/dart';
}
