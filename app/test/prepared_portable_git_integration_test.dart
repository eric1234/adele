@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'prepared_environment_capability_integration_test.dart'
    show PreparedEnvironmentCapabilityInstallation;

const _bound = Duration(seconds: 15);
const _environmentPlugin = 'test.environment.only';
const _callablePlugin = 'test.capability.only';
const _service = 'diff.changeSetSource';
const _library = 'package:portable_git_consumer/main.dart';
final _capability = CapabilityKey(
  id: CapabilityId('adele.diff.change-set-source'),
  majorVersion: 1,
);

void main() {
  late Directory temporary;
  late Map<String, String> roots;
  late File hostArtifact;
  late File environmentArtifact;
  late File callableArtifact;
  late File frontendArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('prepared-portable-git-');
    roots = {};
    for (final id in ['additional', 'primary']) {
      final repository = await Directory(
        '${temporary.absolute.path}/$id',
      ).create();
      roots[id] = await repository.resolveSymbolicLinks();
      await _git(repository, ['init', '--initial-branch=main']);
      final files = id == 'additional'
          ? {
              'file with spaces.txt': 'old selected\n',
              'deleted.txt': 'deleted selected\n',
            }
          : {'primary-only.txt': 'old primary\n'};
      for (final entry in files.entries) {
        await File(
          '${repository.path}/${entry.key}',
        ).writeAsString(entry.value);
      }
      await _git(repository, ['add', '--all']);
      await _git(repository, [
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-m',
        'baseline',
      ]);
      if (id == 'additional') {
        await File(
          '${repository.path}/file with spaces.txt',
        ).writeAsString('new selected\n');
        await File('${repository.path}/deleted.txt').delete();
        await File(
          '${repository.path}/line\nname.txt',
        ).writeAsString('added selected\n');
      } else {
        await File(
          '${repository.path}/primary-only.txt',
        ).writeAsString('new primary\n');
      }
    }
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    final sdk = File(dart).parent.parent.path;
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    for (final name in [
      'prepared_environment_capability_support',
      'portable_git_environment',
      'portable_git_callable',
    ]) {
      await File('${temporary.path}/$name.dart').writeAsString(
        await File('test/fixtures/$name.dart.txt').readAsString(),
      );
    }
    hostArtifact = File('${temporary.path}/host.aot');
    environmentArtifact = File('${temporary.path}/environment.aot');
    callableArtifact = File('${temporary.path}/callable.aot');
    frontendArtifact = File('${temporary.path}/frontend.evc');
    await _compileFrontend(sdk, frontendArtifact);
    for (final target in [
      (
        'packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact,
      ),
      (
        '${temporary.absolute.path}/portable_git_environment.dart',
        environmentArtifact,
      ),
      (
        '${temporary.absolute.path}/portable_git_callable.dart',
        callableArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.$1,
        artifact: target.$2.absolute,
        stage: 'prepared-portable-git',
      );
    }
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late PreparedEnvironmentCapabilityInstallation fixture;
  Future<void> mount(
    WidgetTester tester, {
    bool processGrant = true,
    bool providerPermission = true,
    bool providerPresent = true,
    bool noBufferedFacet = false,
    bool unavailable = false,
    bool concurrent = false,
    bool present = true,
    CapabilityRegistry? registry,
  }) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    fixture = PreparedEnvironmentCapabilityInstallation(
      files: temporary,
      independent: true,
      capabilities: registry,
      environments: [
        for (final id in ['additional', 'primary'])
          Environment(
            id: EnvironmentId(id),
            taskId: TaskId('task'),
            role: id == 'additional'
                ? EnvironmentRole.additional
                : EnvironmentRole.primary,
            providerId: ProviderId(
              'test.environment.${id == 'additional' ? 'a' : 'b'}',
            ),
            providerState: {'root': roots[id]},
          ),
      ],
    );
    addTearDown(fixture.close);
    await tester.runAsync(() async {
      final root = await Directory(
        '${temporary.path}/case-${sequence++}',
      ).create();
      for (final (id, artifact) in [
        (_environmentPlugin, environmentArtifact),
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
      await _manifest(consumer, 'test.portable.git.consumer', {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [
            {
              'role': 'mainContent',
              'extensionId': 'test.portable.git.pane',
              'order': 100,
              'library': _library,
              'initialize': 'initialize',
              'entrypoint': 'buildPane',
              'capabilities': [
                {'id': _capability.id.value, 'majorVersion': 1},
              ],
              if (processGrant)
                'environmentBufferedProcessCapabilities': [
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
          _environmentPlugin: [
            jsonEncode({
              'roots': roots,
              'noBufferedFacet': noBufferedFacet,
              'unavailable': unavailable,
              'exposures': [
                for (final id in ['a', 'b'])
                  AdeleCapabilityExposure(
                    providerId: 'test.environment.$id',
                    capabilityId: environmentProviderCapability.id.value,
                    capabilityMajorVersion:
                        environmentProviderCapability.majorVersion,
                    serviceId: environmentProviderServiceId,
                    displayName: id,
                    configurationContext: id,
                  ).toMap(),
              ],
            }),
          ],
          _callablePlugin: [
            jsonEncode({
              'exposures': [
                if (providerPresent)
                  AdeleCapabilityExposure(
                    providerId: 'test.callable.a',
                    capabilityId: _capability.id.value,
                    capabilityMajorVersion: 1,
                    serviceId: _service,
                    displayName: 'Independent portable Git',
                    configurationContext: 'callable-shared',
                    environmentBound: true,
                    environmentHostServices: [
                      if (providerPermission)
                        AdeleEnvironmentHostService.bufferedProcess,
                    ],
                  ).toMap(),
              ],
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
    });
    if (present) {
      await tester.pumpWidget(fixture.widget(concurrent: concurrent));
      await tester.pumpAndSettle();
      expect(find.text('idle'), findsNWidgets(concurrent ? 2 : 1));
    }
  }

  test(
    'independent A and semantic B/C preserve implementation boundaries',
    () async {
      final a = await File(
        'test/fixtures/portable_git_environment.dart.txt',
      ).readAsString();
      final b = await File(
        'test/fixtures/portable_git_callable.dart.txt',
      ).readAsString();
      final c = await File(
        'test/fixtures/portable_git_frontend.dart.txt',
      ).readAsString();
      expect(a, contains('Process.start('));
      expect(a, isNot(contains('git_backend')));
      expect(a, isNot(contains('diff_viewer_contract')));
      expect(
        b,
        contains('GitPortableUnstagedSnapshotService(processes: processes)'),
      );
      expect(b, contains('AuthorizedEnvironmentBufferedProcessServiceClient('));
      for (final source in [b, c]) {
        expect(source, isNot(contains("import 'dart:io'")));
        expect(source, isNot(contains('Process.start')));
        expect(source, isNot(contains('package:adele_desktop')));
        expect(source, isNot(contains('package:plugin_runtime')));
        expect(source, isNot(contains('GitWorktree')));
      }
      expect(c, contains('ChangeSetSourceServiceClient('));
      expect(c, isNot(contains('package:adele_environment')));
      expect(c, isNot(contains('EnvironmentBufferedProcessRequest')));
      expect(c, isNot(contains('runBufferedProcess')));
      expect(c, isNot(contains('package:git_backend')));
    },
  );

  testWidgets(
    'real independent AOT repositories produce typed nonprimary EVC changes',
    (tester) async {
      await mount(tester, concurrent: true);
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final selected = (await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(_capability),
      ))!;
      expect(selected.environment.id.value, 'additional');
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(
        selected.materialization.binding.provider.id.value,
        'test.environment.a',
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
      _press(tester, 'Unstaged');
      final additional = await _snapshot(tester);
      _expectAdditional(additional);
      _press(tester, 'Unstaged', pane: 'b');
      final primary = await _snapshot(tester, pane: 'b');
      expect(primary, contains('primary-only.txt|modified|text\n@@1,1:1,1'));
      expect(primary, contains('deletion:old primary:false'));
      expect(primary, contains('addition:new primary:false'));
      expect(primary, isNot(contains('selected')));
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      final processes = (evidence['processes'] as List)
          .cast<Map<Object?, Object?>>();
      expect(processes, isNotEmpty);
      for (final process in processes) {
        expect(process['cwd'], roots[process['environmentId']]);
        expect(process['exitCode'], isA<int>());
        expect(
          process['providerId'],
          process['environmentId'] == 'additional'
              ? 'test.environment.a'
              : 'test.environment.b',
        );
      }
      final calls = await tester.runAsync(() => _calls(fixture));
      expect(calls, hasLength(2));
      expect(
        calls!.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(2),
      );
      for (final call in calls) {
        expect(call['payload'], isEmpty);
        await tester.runAsync(
          () => _denied(fixture, call['hostInvocationContext'] as String),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final denial in [
    'frontend declaration',
    'provider permission',
    'absent provider',
  ]) {
    testWidgets('$denial prevents portable Git admission without fallback', (
      tester,
    ) async {
      await mount(
        tester,
        processGrant: denial != 'frontend declaration',
        providerPermission: denial != 'provider permission',
        providerPresent: denial != 'absent provider',
      );
      _press(tester, 'Select');
      await _text(tester, 'selection:unavailable');
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'wrong service and explicit missing provider do not select the available provider',
    (tester) async {
      await mount(tester);
      for (final label in ['Wrong service', 'Missing provider']) {
        _press(tester, label);
        await _text(tester, 'selection:unavailable');
      }
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await _select(tester);
      _press(tester, 'Unstaged');
      _expectAdditional(await _snapshot(tester));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final noFacet in [true, false]) {
    testWidgets(
      '${noFacet ? 'absent process facet' : 'explicit unavailable Environment'} never falls back to primary',
      (tester) async {
        await mount(
          tester,
          noBufferedFacet: noFacet,
          unavailable: !noFacet,
          concurrent: true,
        );
        await _select(tester);
        _press(tester, 'Unstaged');
        await _text(tester, 'snapshot:unavailable');
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await _select(tester, pane: 'b');
        _press(tester, 'Unstaged', pane: 'b');
        expect(
          await _snapshot(tester, pane: 'b'),
          contains('primary-only.txt|modified|text'),
        );
        final processes =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .cast<Map<Object?, Object?>>();
        expect(processes, isNotEmpty);
        expect(
          processes.every((process) => process['environmentId'] == 'primary'),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'the other Diff scopes are explicitly unsupported without process work',
    (tester) async {
      await mount(tester);
      await _select(tester);
      for (final scope in ['Uncommitted', 'Task']) {
        _press(tester, scope);
        await _text(tester, 'snapshot:unavailable');
      }
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls.map((call) => call['method']), [
        '$_service.snapshotUncommitted',
        '$_service.snapshotTaskChanges',
      ]);
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['unsupported_scope', 'unsupported_scope']);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final side in ['environment', 'callable']) {
    testWidgets(
      'exact $side retirement fences outstanding real process result',
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
        final owner = side == 'environment'
            ? fixture.environmentOwner
            : fixture.callableOwner;
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:completed'}),
        );
        _press(tester, 'Unstaged');
        await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
        final token = (await tester.runAsync(() => _token(fixture)))!;
        final stale = _callback(tester, 'Unstaged');
        await tester.runAsync(() => owner.retireProvider(target));
        await _text(tester, 'snapshot:unavailable');
        expect(
          () => target.requestChannel,
          throwsA(isA<ProviderUnavailable>()),
        );
        fixture.environmentOwner.validate();
        fixture.callableOwner.validate();
        expect(fixture.connection.isClosed, isFalse);
        expect(fixture.environmentConnection.isClosed, isFalse);
        await tester.runAsync(() => _denied(fixture, token));
        stale();
        _press(tester, 'Select');
        await _text(tester, 'selection:unavailable');
        await tester.runAsync(() async {
          await fixture.control('release', {'key': 'process:completed'});
          await fixture.wait(tester, 'settled:unstaged');
        });
        _press(tester, 'Unstaged', pane: 'b');
        if (side == 'environment') {
          expect(
            await _snapshot(tester, pane: 'b'),
            contains('primary-only.txt|modified|text'),
          );
        } else {
          await _text(tester, 'snapshot:unavailable', pane: 'b');
        }
        expect(
          _pane('a', find.textContaining('file with spaces.txt|')),
          findsNothing,
        );
        final processes =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .cast<Map<Object?, Object?>>();
        expect(
          processes.where(
            (process) => process['environmentId'] == 'additional',
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'departure suppresses outstanding snapshot without moving its authority',
    (tester) async {
      await mount(tester);
      await _select(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'process:completed'}),
      );
      _press(tester, 'Unstaged');
      await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => _token(fixture)))!;
      final stale = _callback(tester, 'Unstaged');
      fixture.frontends.unbind(fixture.sessionA);
      await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
      await tester.pumpAndSettle();
      stale();
      await tester.runAsync(() async {
        await _denied(fixture, token);
        await fixture.control('release', {'key': 'process:completed'});
        await fixture.wait(tester, 'settled:unstaged');
      });
      expect(await tester.runAsync(() => _calls(fixture)), hasLength(1));
      expect(find.textContaining('file with spaces.txt|'), findsNothing);
      await _select(tester);
      _press(tester, 'Unstaged');
      expect(
        await _snapshot(tester),
        contains('primary-only.txt|modified|text'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'same-ID replacement never revives a retained generated client or token',
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
      final stale = _callback(tester, 'Unstaged');
      await tester.runAsync(
        () => old.control('hold', {'key': 'process:completed'}),
      );
      _press(tester, 'Unstaged');
      await tester.runAsync(() => old.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => _token(old)))!;
      await tester.runAsync(old.backends.close);
      await _text(tester, 'snapshot:unavailable');
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
      await _text(tester, 'snapshot:unavailable');
      await tester.runAsync(() => _denied(fixture, token));
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'Unstaged');
      _expectAdditional(await _snapshot(tester));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _compileFrontend(String sdk, File artifact) async {
  final root = Directory.current.parent.path;
  final generated = await ContractGenerator(sdkPath: sdk).generateEvalClient(
    File(
      '$root/plugins/diff_viewer/packages/contract/lib/diff_viewer_contract.dart',
    ),
  );
  final program =
      (Compiler()
            ..addPlugin(flutterEvalPlugin)
            ..addPlugin(const MainContentDeclarations())
            ..addPlugin(const EnvironmentCapabilityAccessDeclarations())
            ..entrypoints.addAll([
              _library,
              'package:diff_viewer_contract/diff_viewer_contract.dart',
              'package:adele_contract/adele_contract.dart',
            ]))
          .compile({
            'portable_git_consumer': {
              'main.dart': await File(
                'test/fixtures/portable_git_frontend.dart.txt',
              ).readAsString(),
            },
            'diff_viewer_contract': {'diff_viewer_contract.dart': generated},
            'adele_contract': {
              'adele_contract.dart': evalContractSupportSource,
            },
            'adele_ui': {
              for (final library in [
                'environment_capability_bridge',
                'main_content_bridge',
              ])
                '$library.dart': await File(
                  '$root/packages/ui/lib/$library.dart',
                ).readAsString(),
            },
          });
  await artifact.writeAsBytes(program.write());
}

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

Future<void> _git(Directory root, List<String> arguments) async {
  final result = await Process.run(
    '/usr/bin/git',
    arguments,
    workingDirectory: root.path,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

Future<List<Map<Object?, Object?>>> _calls(
  PreparedEnvironmentCapabilityInstallation fixture,
) async {
  final snapshot = (await fixture.control('snapshot'))! as Map;
  return (snapshot['requests'] as List)
      .cast<Map<Object?, Object?>>()
      .where((call) => call['serviceId'] == _service)
      .toList();
}

Future<String> _token(
  PreparedEnvironmentCapabilityInstallation fixture,
) async => (await _calls(fixture)).last['hostInvocationContext'] as String;

Future<void> _denied(
  PreparedEnvironmentCapabilityInstallation fixture,
  String token,
) async {
  expect(await fixture.control('attackBuffered', {'token': token}), {
    'ok': false,
  });
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
}) async => _waitFor(tester, _pane(pane, find.text(text)));

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  await tester.pump();
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(
    finder,
    findsOneWidget,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .join(' | '),
  );
}

Future<void> _select(WidgetTester tester, {String pane = 'a'}) async {
  _press(tester, 'Select', pane: pane);
  await _text(tester, 'selected', pane: pane);
}

Future<String> _snapshot(WidgetTester tester, {String pane = 'a'}) async {
  final finder = _pane(
    pane,
    find.byWidgetPredicate(
      (widget) =>
          widget is Text && (widget.data?.startsWith('snapshot\n') ?? false),
    ),
  );
  await _waitFor(tester, finder);
  return tester.widget<Text>(finder).data!;
}

void _expectAdditional(String snapshot) {
  expect(snapshot, contains('file with spaces.txt|modified|text\n@@1,1:1,1'));
  expect(snapshot, contains('deletion:old selected:false'));
  expect(snapshot, contains('addition:new selected:false'));
  expect(snapshot, contains('deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(snapshot, contains('deletion:deleted selected:false'));
  expect(snapshot, contains('line\nname.txt|added|text\n@@0,0:1,1'));
  expect(snapshot, contains('addition:added selected:false'));
  expect(snapshot, isNot(contains('primary')));
}
