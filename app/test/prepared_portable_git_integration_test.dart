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
const _selectedBranch = 'selected-task';
const _selectedBranchRef = 'refs/heads/$_selectedBranch';
const _library = 'package:portable_git_consumer/main.dart';
final _capability = CapabilityKey(
  id: CapabilityId('adele.diff.change-set-source'),
  majorVersion: 1,
);

void main() {
  late Directory temporary;
  late Map<String, String> roots;
  late String selectedBaseline;
  late String primaryBaseline;
  late String committedRoot;
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
      await _git(repository, [
        'init',
        '--initial-branch=${id == 'additional' ? _selectedBranch : 'main'}',
      ]);
      final files = id == 'additional'
          ? {
              'file with spaces.txt': 'old selected\n',
              'deleted.txt': 'deleted selected\n',
              'staged-only.txt': 'old staged\n',
              'staged deleted.txt': 'deleted staged\n',
              'partial.txt': 'head partial\n',
              'cancel.txt': 'head cancellation\n',
              'conflicted.txt': 'base conflict\n',
              'committed-only.txt': 'baseline committed\n',
              'committed deleted.txt': 'baseline deleted\n',
              'three-layer.txt': 'baseline layer\n',
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
        // Retain the fixture's exact baseline before subsequent commits. Startup
        // provisions this value into B; no invocation derives it from current HEAD.
        selectedBaseline = await _git(repository, ['rev-parse', 'HEAD']);
        for (final side in ['conflict-side', _selectedBranch]) {
          await _git(repository, [
            'checkout',
            if (side == 'conflict-side') '-b',
            side,
          ]);
          await File(
            '${repository.path}/conflicted.txt',
          ).writeAsString('$side conflict\n');
          if (side == _selectedBranch) {
            for (final entry in {
              'committed-only.txt': 'head committed\n',
              'committed added.txt': 'head added\n',
              'three-layer.txt': 'head layer\n',
            }.entries) {
              await File(
                '${repository.path}/${entry.key}',
              ).writeAsString(entry.value);
            }
            await File('${repository.path}/committed deleted.txt').delete();
            await _git(repository, ['add', '--all']);
          }
          await _git(repository, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-am',
            side,
          ]);
        }
        await _git(repository, [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'merge',
          '--no-commit',
          'conflict-side',
        ], exitCode: 1);
        for (final entry in {
          'staged-only.txt': 'new staged\n',
          'added\nstaged.txt': 'added staged\n',
          'partial.txt': 'index partial\n',
          'cancel.txt': 'index cancellation\n',
          'three-layer.txt': 'index layer\n',
        }.entries) {
          await File(
            '${repository.path}/${entry.key}',
          ).writeAsString(entry.value);
          await _git(repository, ['add', '--', entry.key]);
        }
        await _git(repository, ['rm', '--', 'staged deleted.txt']);
        await File(
          '${repository.path}/partial.txt',
        ).writeAsString('work partial\n');
        await File(
          '${repository.path}/cancel.txt',
        ).writeAsString('head cancellation\n');
        await File(
          '${repository.path}/three-layer.txt',
        ).writeAsString('baseline layer\n');
        await File(
          '${repository.path}/file with spaces.txt',
        ).writeAsString('new selected\n');
        await File('${repository.path}/deleted.txt').delete();
        await File(
          '${repository.path}/line\nname.txt',
        ).writeAsString('added selected\n');
      } else {
        primaryBaseline = await _git(repository, ['rev-parse', 'HEAD']);
        await File(
          '${repository.path}/primary-only.txt',
        ).writeAsString('new primary\n');
      }
    }
    expect(selectedBaseline, isNot(primaryBaseline));
    expect(
      await _git(Directory(roots['additional']!), ['rev-parse', 'HEAD']),
      isNot(selectedBaseline),
    );
    // Clone committed history only, leaving the layered/conflicted fixture intact.
    await _git(temporary, [
      'clone',
      '--no-hardlinks',
      '--single-branch',
      '--branch',
      _selectedBranch,
      roots['additional']!,
      'committed-only',
    ]);
    committedRoot = await Directory(
      '${temporary.path}/committed-only',
    ).resolveSymbolicLinks();
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
    String? additionalRoot,
    bool withTaskAnchor = true,
    String? baselineCommit,
    String expectedBranchRef = _selectedBranchRef,
  }) async {
    final selectedRoots = {...roots, 'additional': ?additionalRoot};
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
            providerState: {'root': selectedRoots[id]},
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
              'roots': selectedRoots,
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
              if (withTaskAnchor)
                'taskAnchor': {
                  'baselineCommit': baselineCommit ?? selectedBaseline,
                  'expectedBranchRef': expectedBranchRef,
                },
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
      expect(b, contains('GitPortableUnstagedSnapshotService('));
      expect(b, contains('processes: processes,'));
      expect(b, contains('taskAnchor: taskAnchor,'));
      expect(b, contains("state.options['taskAnchor']"));
      expect(
        b.indexOf('GitTaskComparisonAnchor('),
        lessThan(b.indexOf('createDispatcher:')),
      );
      expect(b, contains('return await snapshots.snapshotUncommitted();'));
      expect(b, contains('return await snapshots.snapshotTaskChanges();'));
      expect(b, contains('AuthorizedEnvironmentBufferedProcessServiceClient('));
      for (final source in [b, c]) {
        expect(source, isNot(contains("import 'dart:io'")));
        expect(source, isNot(contains('Process.start')));
        expect(source, isNot(contains('package:adele_desktop')));
        expect(source, isNot(contains('package:plugin_runtime')));
        expect(source, isNot(contains('GitWorktree')));
      }
      expect(c, contains('ChangeSetSourceServiceClient('));
      expect(
        c,
        contains('final UncommittedChangeSetSnapshot value = result[1];'),
      );
      expect(c, contains('renderFiles(value.staged.files)'));
      expect(c, contains('renderFiles(value.unstaged.files)'));
      expect(c, contains('renderFiles(value.conflicts)'));
      expect(c, contains('final TaskChangeSetSnapshot value = result[1];'));
      expect(c, contains('renderFiles(value.committed.files)'));
      expect(c, contains('renderFiles(value.uncommitted.staged.files)'));
      expect(c, contains('renderFiles(value.uncommitted.unstaged.files)'));
      expect(c, contains('renderFiles(value.uncommitted.conflicts)'));
      expect(c, isNot(contains('baselineCommit')));
      expect(c, isNot(contains('expectedBranchRef')));
      expect(c, isNot(contains('taskAnchor')));
      expect(c, isNot(contains('package:adele_environment')));
      expect(c, isNot(contains('EnvironmentBufferedProcessRequest')));
      expect(c, isNot(contains('runBufferedProcess')));
      expect(c, isNot(contains('package:git_backend')));
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    testWidgets(
      'real independent AOT repositories produce typed nonprimary EVC $scope changes',
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
        final elapsed = Stopwatch()..start();
        _press(tester, scope);
        final additional = await _snapshot(tester);
        elapsed.stop();
        _expectAdditional(additional, scope: scope);
        final selectedCalls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(selectedCalls, hasLength(1));
        expect(selectedCalls.single['method'], _method(scope));
        expect(selectedCalls.single['payload'], isEmpty);
        final selectedEvidence = (await tester.runAsync(fixture.snapshot))!;
        final selectedProcesses = (selectedEvidence['processes'] as List)
            .cast<Map<Object?, Object?>>();
        expect(selectedProcesses, isNotEmpty);
        expect(
          selectedProcesses.every(
            (process) => process['environmentId'] == 'additional',
          ),
          isTrue,
        );
        debugPrint(
          'Prepared portable $scope layered fixture: '
          '${selectedProcesses.length} process requests, '
          '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
        );
        _press(tester, scope, pane: 'b');
        if (scope == 'Task') {
          // The single fixed B anchor belongs to the selected repository, not
          // this unrelated primary. No inference, substitution, or clean result.
          await _text(tester, 'snapshot:unavailable', pane: 'b');
          expect(
            _pane('b', find.textContaining('primary-only.txt|')),
            findsNothing,
          );
          final probe =
              (await tester.runAsync(() => fixture.control('snapshot')))!
                  as Map;
          expect(probe['failures'], ['baseline_unavailable']);
        } else {
          final primary = await _snapshot(tester, pane: 'b');
          expect(
            primary,
            contains('primary-only.txt|modified|text\n@@1,1:1,1'),
          );
          expect(primary, contains('deletion:old primary:false'));
          expect(primary, contains('addition:new primary:false'));
          expect(primary, isNot(contains('selected')));
          expect(primary, isNot(contains('partial.txt')));
          expect(primary, isNot(contains('conflicted.txt')));
          if (scope == 'Uncommitted') {
            expect(
              primary,
              startsWith('snapshot\nstaged\nunstaged\nprimary-only.txt|'),
            );
            expect(primary, endsWith('\nconflicts'));
          }
        }
        final evidence = (await tester.runAsync(fixture.snapshot))!;
        expect(evidence['reads'], isEmpty);
        final processes = (evidence['processes'] as List)
            .cast<Map<Object?, Object?>>();
        expect(processes, isNotEmpty);
        final primaryProcesses = processes.skip(selectedProcesses.length);
        expect(primaryProcesses, isNotEmpty);
        expect(
          primaryProcesses.every(
            (process) => process['environmentId'] == 'primary',
          ),
          isTrue,
        );
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
          expect(call['method'], _method(scope));
          expect(call['payload'], isEmpty);
          await tester.runAsync(
            () => _denied(fixture, call['hostInvocationContext'] as String),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final count in [100, 160, 500, 900]) {
    testWidgets(
      'clean nonprimary prepared snapshots batch $count files across backends',
      (tester) async {
        final repository = (await tester.runAsync(() async {
          final root = await Directory(
            '${temporary.path}/scaling-$count',
          ).create();
          await _git(root, ['init', '--initial-branch=main']);
          await Directory('${root.path}/tracked').create();
          for (var i = 0; i < count; i++) {
            await File(
              '${root.path}/tracked/file $i.txt',
            ).writeAsString('clean selected $i\n');
          }
          await _git(root, ['add', '--all']);
          await _git(root, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-m',
            'baseline',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
        final baseline = (await tester.runAsync(
          () => _git(Directory(repository), ['rev-parse', 'HEAD']),
        ))!;
        await mount(
          tester,
          additionalRoot: repository,
          baselineCommit: baseline,
          expectedBranchRef: 'refs/heads/main',
        );
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        await _select(tester);
        var previousProcessCount = 0;
        var semanticCallCount = 0;
        for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
          final elapsed = Stopwatch()..start();
          _press(tester, scope);
          await _text(tester, switch (scope) {
            'Unstaged' => 'snapshot',
            'Task' => 'snapshot\ncommitted\nstaged\nunstaged\nconflicts',
            _ => 'snapshot\nstaged\nunstaged\nconflicts',
          });
          elapsed.stop();
          final evidence = (await tester.runAsync(fixture.snapshot))!;
          expect(evidence['reads'], isEmpty);
          final processes = (evidence['processes'] as List)
              .cast<Map<Object?, Object?>>();
          final requests = (evidence['requests'] as List)
              .cast<Map<Object?, Object?>>()
              .where(
                (request) =>
                    request['method'] ==
                    environmentProviderServiceRunBufferedProcessId,
              );
          expect(requests, hasLength(processes.length));
          final processCount = processes.length - previousProcessCount;
          final batches = (count + 127) ~/ 128;
          if (scope == 'Unstaged') {
            expect(processCount, 21 + 4 * batches);
          } else if (scope == 'Uncommitted') {
            expect(processCount, 27 + 4 * batches);
          } else {
            // Fixed anchor/tree validation plus the same working-file batches.
            // No subprocess per clean tracked object is permitted.
            expect(processCount, lessThanOrEqualTo(40 + 4 * batches));
          }
          debugPrint(
            'Prepared portable $scope $count clean files: '
            '$processCount process requests, '
            '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
          );
          for (final process in processes) {
            expect(process['environmentId'], 'additional');
            expect(process['providerId'], 'test.environment.a');
            expect(process['cwd'], repository);
            expect(process['exitCode'], 0);
          }
          final calls = (await tester.runAsync(() => _calls(fixture)))!;
          expect(calls, hasLength(++semanticCallCount));
          expect(calls.last['method'], _method(scope));
          expect(calls.last['payload'], isEmpty);
          expect(
            calls.map((call) => call['hostInvocationContext']).toSet(),
            hasLength(semanticCallCount),
          );
          await tester.runAsync(
            () =>
                _denied(fixture, calls.last['hostInvocationContext'] as String),
          );
          previousProcessCount = processes.length;
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

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

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    testWidgets(
      '$scope wrong service and explicit missing provider do not select the available provider',
      (tester) async {
        await mount(tester);
        for (final label in ['Wrong service', 'Missing provider']) {
          _press(tester, label);
          await _text(tester, 'selection:unavailable');
        }
        expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await _select(tester);
        _press(tester, scope);
        _expectAdditional(await _snapshot(tester), scope: scope);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final noFacet in [true, false]) {
      testWidgets(
        '$scope ${noFacet ? 'absent process facet' : 'explicit unavailable Environment'} never falls back to primary',
        (tester) async {
          await mount(
            tester,
            noBufferedFacet: noFacet,
            unavailable: !noFacet,
            concurrent: true,
          );
          await _select(tester);
          _press(tester, scope);
          await _text(tester, 'snapshot:unavailable');
          expect(
            (await tester.runAsync(fixture.snapshot))!['processes'],
            isEmpty,
          );
          await _select(tester, pane: 'b');
          _press(tester, scope, pane: 'b');
          if (scope == 'Task') {
            await _text(tester, 'snapshot:unavailable', pane: 'b');
          } else {
            expect(
              await _snapshot(tester, pane: 'b'),
              contains('primary-only.txt|modified|text'),
            );
          }
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
  }

  testWidgets(
    'Task retains committed-only nonprimary changes after Uncommitted is clean',
    (tester) async {
      await mount(tester, additionalRoot: committedRoot);
      await _select(tester);
      _press(tester, 'Uncommitted');
      await _text(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      var previousProcessCount =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .length;
      for (var refresh = 0; refresh < 2; refresh++) {
        final elapsed = Stopwatch()..start();
        _press(tester, 'Task');
        final snapshot = await _snapshot(tester);
        elapsed.stop();
        final processCount =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .length;
        debugPrint(
          'Prepared portable Task committed-only: '
          '${processCount - previousProcessCount} process requests, '
          '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
        );
        previousProcessCount = processCount;
        _expectCommitted(snapshot);
        expect(snapshot, endsWith('\nstaged\nunstaged\nconflicts'));
        expect(snapshot, isNot(contains('primary-only.txt')));
        final calls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(calls, hasLength(2 + refresh));
        expect(calls.first['method'], _method('Uncommitted'));
        for (final call in calls.skip(1)) {
          expect(call['method'], _method('Task'));
          expect(call['payload'], isEmpty);
        }
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(calls.length),
        );
        await tester.runAsync(
          () => _denied(fixture, calls.last['hostInvocationContext'] as String),
        );
      }
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], committedRoot);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (invalid, code) in [
    ('missing anchor', 'baseline_unavailable'),
    ('empty baseline', 'invalid_baseline'),
    ('invalid baseline', 'invalid_baseline'),
    ('unavailable baseline', 'baseline_unavailable'),
    ('invalid branch', 'invalid_branch'),
    ('wrong branch', 'unexpected_branch'),
    ('detached HEAD', 'detached_head'),
  ]) {
    testWidgets('Task $invalid fails without inferring or replacing its anchor', (
      tester,
    ) async {
      var repository = committedRoot;
      if (invalid == 'wrong branch' || invalid == 'detached HEAD') {
        repository = (await tester.runAsync(() async {
          final name = 'invalid-anchor-${sequence++}';
          await _git(temporary, [
            'clone',
            '--no-hardlinks',
            committedRoot,
            name,
          ]);
          final root = Directory('${temporary.path}/$name');
          await _git(root, [
            'checkout',
            if (invalid == 'wrong branch') ...[
              '-b',
              'unexpected-task',
            ] else
              '--detach',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
      }
      await mount(
        tester,
        additionalRoot: repository,
        withTaskAnchor: invalid != 'missing anchor',
        baselineCommit: switch (invalid) {
          'empty baseline' => '',
          'invalid baseline' => 'HEAD',
          // A real but unrelated primary commit must not cause primary fallback.
          'unavailable baseline' => primaryBaseline,
          _ => selectedBaseline,
        },
        expectedBranchRef: invalid == 'invalid branch'
            ? 'HEAD'
            : _selectedBranchRef,
      );
      await _select(tester);
      _press(tester, 'Task');
      await _text(tester, 'snapshot:unavailable');
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], _method('Task'));
      expect(calls.single['payload'], isEmpty);
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], [code]);
      await tester.runAsync(
        () => _denied(fixture, calls.single['hostInvocationContext'] as String),
      );
      final failedEvidence = (await tester.runAsync(fixture.snapshot))!;
      if (invalid == 'missing anchor') {
        expect(failedEvidence['processes'], isEmpty);
      }
      // Optional Task metadata must not disable either existing scope, including
      // on the detached checkout. These calls still inspect the selected root.
      _press(tester, 'Unstaged');
      await _text(tester, 'snapshot');
      _press(tester, 'Uncommitted');
      await _text(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      final allCalls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(allCalls.map((call) => call['method']), [
        _method('Task'),
        _method('Unstaged'),
        _method('Uncommitted'),
      ]);
      expect(
        allCalls.every((call) => (call['payload'] as Map).isEmpty),
        isTrue,
      );
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], repository);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'pending Task grants no extra services or foreign activation authority',
    (tester) async {
      await mount(tester);
      await _select(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'process:completed'}),
      );
      _press(tester, 'Task');
      await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => _token(fixture)))!;
      await tester.runAsync(() async {
        expect(
          await fixture.controlOn(
            fixture.environmentConnection,
            'attackBuffered',
            {'token': token},
          ),
          {'ok': false},
        );
        for (final (service, method, arguments) in [
          (
            authorizedEnvironmentReadServiceId,
            authorizedEnvironmentReadServiceReadFileId,
            <String, Object?>{'relativePath': 'committed-only.txt'},
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
        await fixture.control('release', {'key': 'process:completed'});
      });
      _expectAdditional(await _snapshot(tester), scope: 'Task');
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], _method('Task'));
      expect(calls.single['payload'], isEmpty);
      await tester.runAsync(() => _denied(fixture, token));
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      expect(
        (evidence['processes'] as List).cast<Map<Object?, Object?>>().every(
          (process) => process['environmentId'] == 'additional',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    for (final side in ['environment', 'callable']) {
      testWidgets(
        '$scope exact $side retirement fences outstanding real process result',
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
          _press(tester, scope);
          await tester.runAsync(
            () => fixture.wait(tester, 'process:completed'),
          );
          final token = (await tester.runAsync(() => _token(fixture)))!;
          final stale = _callback(tester, scope);
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
            await fixture.wait(tester, 'settled:${scope.toLowerCase()}');
          });
          _press(tester, scope, pane: 'b');
          if (side == 'environment' && scope != 'Task') {
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
          final calls = (await tester.runAsync(() => _calls(fixture)))!;
          expect(calls, hasLength(side == 'environment' ? 2 : 1));
          expect(
            calls.every((call) => call['method'] == _method(scope)),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '$scope departure suppresses outstanding snapshot without moving its authority',
      (tester) async {
        await mount(tester);
        await _select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:completed'}),
        );
        _press(tester, scope);
        await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
        final token = (await tester.runAsync(() => _token(fixture)))!;
        final stale = _callback(tester, scope);
        fixture.frontends.unbind(fixture.sessionA);
        await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
        await tester.pumpAndSettle();
        stale();
        await tester.runAsync(() async {
          await _denied(fixture, token);
          await fixture.control('release', {'key': 'process:completed'});
          await fixture.wait(tester, 'settled:${scope.toLowerCase()}');
        });
        expect(await tester.runAsync(() => _calls(fixture)), hasLength(1));
        expect(find.textContaining('file with spaces.txt|'), findsNothing);
        await _select(tester);
        _press(tester, scope);
        if (scope == 'Task') {
          await _text(tester, 'snapshot:unavailable');
        } else {
          expect(
            await _snapshot(tester),
            contains('primary-only.txt|modified|text'),
          );
        }
        final processes =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .cast<Map<Object?, Object?>>();
        expect(
          processes.where(
            (process) => process['environmentId'] == 'additional',
          ),
          hasLength(1),
        );
        expect(
          processes
              .skip(1)
              .every((process) => process['environmentId'] == 'primary'),
          isTrue,
        );
        final calls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(calls, hasLength(2));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$scope same-ID replacement never revives a retained generated client or token',
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
        final stale = _callback(tester, scope);
        await tester.runAsync(
          () => old.control('hold', {'key': 'process:completed'}),
        );
        _press(tester, scope);
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
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await tester.pumpWidget(fixture.widget());
        await tester.pumpAndSettle();
        await _select(tester);
        _press(tester, scope);
        _expectAdditional(await _snapshot(tester), scope: scope);
        final calls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(calls, hasLength(1));
        expect(calls.single['method'], _method(scope));
        expect(calls.single['payload'], isEmpty);
        await tester.runAsync(
          () =>
              _denied(fixture, calls.single['hostInvocationContext'] as String),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
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

Future<String> _git(
  Directory root,
  List<String> arguments, {
  int exitCode = 0,
}) async {
  final result = await Process.run(
    '/usr/bin/git',
    arguments,
    workingDirectory: root.path,
  );
  expect(
    result.exitCode,
    exitCode,
    reason: '${result.stdout}\n${result.stderr}',
  );
  return (result.stdout as String).trim();
}

String _method(String scope) =>
    '$_service.snapshot${scope == 'Task' ? 'TaskChanges' : scope}';

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
  String token, {
  String? service,
  String? method,
  Map<String, Object?>? arguments,
}) async {
  expect(
    await fixture.control('attackBuffered', {
      'token': token,
      'service': ?service,
      'method': ?method,
      'arguments': ?arguments,
    }),
    {'ok': false},
  );
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

void _expectAdditional(String snapshot, {String scope = 'Unstaged'}) {
  final unstaged = scope == 'Unstaged'
      ? snapshot
      : snapshot.split('\nunstaged\n')[1].split('\nconflicts\n')[0];
  expect(unstaged, contains('file with spaces.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:old selected:false'));
  expect(unstaged, contains('addition:new selected:false'));
  expect(unstaged, contains('deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(unstaged, contains('deletion:deleted selected:false'));
  expect(unstaged, contains('line\nname.txt|added|text\n@@0,0:1,1'));
  expect(unstaged, contains('addition:added selected:false'));
  expect(snapshot, isNot(contains('primary')));
  if (scope == 'Unstaged') {
    expect(snapshot, isNot(contains('staged-only.txt')));
    return;
  }
  final staged = snapshot.split('\nstaged\n')[1].split('\nunstaged\n')[0];
  final conflicts = snapshot.split('\nconflicts\n')[1];
  expect(staged, contains('staged-only.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:old staged:false'));
  expect(staged, contains('addition:new staged:false'));
  expect(staged, contains('added\nstaged.txt|added|text\n@@0,0:1,1'));
  expect(staged, contains('addition:added staged:false'));
  expect(staged, contains('staged deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(staged, contains('deletion:deleted staged:false'));
  expect(staged, contains('partial.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:head partial:false'));
  expect(staged, contains('addition:index partial:false'));
  expect(unstaged, contains('partial.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:index partial:false'));
  expect(unstaged, contains('addition:work partial:false'));
  expect(staged, contains('cancel.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:head cancellation:false'));
  expect(staged, contains('addition:index cancellation:false'));
  expect(unstaged, contains('cancel.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:index cancellation:false'));
  expect(unstaged, contains('addition:head cancellation:false'));
  expect(staged, isNot(contains('file with spaces.txt')));
  expect(unstaged, isNot(contains('staged-only.txt')));
  expect(unstaged, isNot(contains('staged deleted.txt')));
  expect(unstaged, isNot(contains('added\nstaged.txt')));
  expect(staged, isNot(contains('conflicted.txt')));
  expect(unstaged, isNot(contains('conflicted.txt')));
  expect(conflicts, 'conflicted.txt|conflicted|conflicted');
  if (scope == 'Task') {
    _expectCommitted(snapshot);
    expect(staged, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
    expect(staged, contains('deletion:head layer:false'));
    expect(staged, contains('addition:index layer:false'));
    expect(unstaged, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
    expect(unstaged, contains('deletion:index layer:false'));
    expect(unstaged, contains('addition:baseline layer:false'));
  }
}

void _expectCommitted(String snapshot) {
  expect(snapshot, startsWith('snapshot\ncommitted\n'));
  final committed = snapshot.split('\ncommitted\n')[1].split('\nstaged')[0];
  expect(committed, contains('committed-only.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:baseline committed:false'));
  expect(committed, contains('addition:head committed:false'));
  expect(committed, contains('committed added.txt|added|text\n@@0,0:1,1'));
  expect(committed, contains('addition:head added:false'));
  expect(committed, contains('committed deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(committed, contains('deletion:baseline deleted:false'));
  expect(committed, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:baseline layer:false'));
  expect(committed, contains('addition:head layer:false'));
  // A currently unmerged path retains its independent committed change too.
  expect(committed, contains('conflicted.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:base conflict:false'));
  expect(committed, contains('addition:$_selectedBranch conflict:false'));
  expect(committed, isNot(contains('index layer')));
  expect(committed, isNot(contains('staged-only.txt')));
  expect(committed, isNot(contains('file with spaces.txt')));
}
