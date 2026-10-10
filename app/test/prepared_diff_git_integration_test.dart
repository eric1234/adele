@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
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
import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/stock_frontend_descriptors.dart';
import '../tool/diff_viewer_frontend_compiler.dart';
import '../tool/source_editor_frontend_compiler.dart';

const _gitPlugin = 'dev.adele.plugin.git-environment';
const _diffPlugin = 'dev.adele.diff-viewer';
const _sourcePlugin = 'dev.adele.source-editor';
const _punctuatedPath = "b tracked + [file]; 'quoted'\tname.txt";
const _bound = Duration(seconds: 20);
final _changes = CapabilityKey(
  id: CapabilityId('adele.diff.change-set-source'),
  majorVersion: 1,
);

void main() {
  late Directory artifacts;
  late Directory installations;
  late Directory frontendOnly;
  late File host;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-diff-artifacts-');
    installations = await Directory('${artifacts.path}/installed').create();
    frontendOnly = await Directory('${artifacts.path}/frontend-only').create();
    final repository = Directory.current.parent;
    final dart = _dartExecutable();
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    host = File('${artifacts.path}/host.aot');
    final git = await Directory('${installations.path}/git').create();
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: host,
      ),
      (
        entrypoint:
            'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
        artifact: File('${git.path}/backend.aot'),
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'prepared-diff-git',
      );
    }
    await _manifest(git, _gitPlugin, {
      'backend': {'artifact': 'backend.aot'},
    });
    final diff = await Directory('${installations.path}/diff').create();
    await compileDiffViewerFrontend(
      repositoryRoot: repository,
      sdkPath: File(dart).parent.parent.path,
      artifact: File('${diff.path}/frontend.evc'),
    );
    final component = {
      'frontend': {
        'artifact': 'frontend.evc',
        'presentations': stockFrontendDescriptors[_diffPlugin]!,
      },
    };
    await _manifest(diff, _diffPlugin, component);
    final alone = await Directory('${frontendOnly.path}/diff').create();
    await File('${diff.path}/frontend.evc').copy('${alone.path}/frontend.evc');
    await _manifest(alone, _diffPlugin, component);
    final source = await Directory('${installations.path}/source').create();
    await File('${source.path}/frontend.evc').writeAsBytes(
      await compileSourceEditorFrontend(repositoryRoot: repository),
    );
    await _manifest(source, _sourcePlugin, {
      'frontend': {
        'artifact': 'frontend.evc',
        'presentations': stockFrontendDescriptors[_sourcePlugin]!,
        'extensions': stockFrontendExtensionDescriptors[_sourcePlugin]!,
      },
    });
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create(
      installations: installations,
      host: host,
      aotRuntime: aotRuntime,
    );
  });
  tearDown(() => fixture.close());

  Future<void> mount(WidgetTester tester, {Directory? catalog}) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => fixture.start(catalog ?? installations));
    await tester.runAsync(
      () => tester.pumpWidget(fixture.widget(fixture.additionalSession)),
    );
    await _waitFor(
      tester,
      () => find.text('Unstaged changes').evaluate().isNotEmpty,
    );
  }

  testWidgets(
    'stock EVC shows real nonprimary Git hunks, additions, deletion and refresh without mutations',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.write(
          'a modified.txt',
          'context before\nAdditional edit\ncontext after\n',
        );
        await fixture.write('b new + [file].txt', 'A new untracked line\n');
        await fixture.file('c deleted.txt').delete();
        await fixture.write(
          'd staged.txt',
          'Staged only, never in this view\n',
        );
        await _git(fixture.additionalRoot, ['add', 'd staged.txt']);
        // A net HEAD comparison would hide this real unstaged reversal.
        await fixture.write('e reversal.txt', 'Index layer\n');
        await _git(fixture.additionalRoot, ['add', 'e reversal.txt']);
        await fixture.write('e reversal.txt', 'Original layer\n');
        await fixture.write('ignored.tmp', 'Ignored addition\n');
        await fixture.file('f binary.dat').writeAsBytes([0, 1, 2, 255]);
        await File(
          '${fixture.additionalWorktree.path}/outside.txt',
        ).writeAsString('Outside source scope\n');
        await File(
          '${fixture.primaryRoot.path}/a modified.txt',
        ).writeAsString('Primary worktree, not the selected Environment\n');
      });
      final before = (await tester.runAsync(fixture.fingerprint))!;
      await mount(tester);
      await _visible(tester, 'Additional edit');
      for (final text in [
        'a modified.txt',
        'Original text',
        'context before',
        'context after',
        'b new + [file].txt',
        'A new untracked line',
        'c deleted.txt',
        'Deleted baseline',
        'Index layer',
        'Original layer',
        'f binary.dat',
        'binary',
      ]) {
        expect(find.textContaining(text), findsWidgets);
      }
      expect(find.textContaining('@@ -'), findsWidgets);
      for (final absent in [
        'd staged.txt',
        'ignored.tmp',
        'outside.txt',
        'Primary worktree',
      ]) {
        expect(find.textContaining(absent), findsNothing);
      }
      expect(find.text('Diff'), findsOneWidget);
      expect(
        fixture.frontends.generations.map((generation) => generation.state),
        everyElement(InstalledFrontendState.active),
      );
      final diff = fixture.backends.catalog!.installations.singleWhere(
        (entry) => entry.metadata.id.value == _diffPlugin,
      );
      expect(diff.backendArtifactUri, isNull);
      expect(fixture.backends.backendForInstallation(diff), isNull);
      final descriptor = stockFrontendDescriptors[_diffPlugin]!.single;
      expect(descriptor['order'], 200);
      expect(descriptor['capabilities'], isNull);
      expect(descriptor['backendServices'], isNull);
      expect(descriptor['canRequestSourceDisplay'], isTrue);
      final changeBinding = fixture.capabilities.resolve(_changes);
      final environmentBinding = fixture.capabilities.resolve(
        environmentProviderCapability,
      );
      expect(
        fixture.backends.backends.single
            .associationFor(changeBinding)!
            .isSameRegistration(environmentBinding),
        isTrue,
      );
      expect(await tester.runAsync(fixture.fingerprint), before);

      await tester.runAsync(
        () => fixture.write(
          'a modified.txt',
          'context before\nRefreshed real content\ncontext after\n',
        ),
      );
      _refresh(tester);
      await _visible(tester, 'Refreshed real content');
      expect(find.textContaining('Additional edit'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual Diff opens a tracked punctuated nonprimary path in Source and repeats without another read or pane',
    (tester) async {
      const path = _punctuatedPath;
      const text = 'Additional Environment source content\n';
      await tester.runAsync(() async {
        await fixture.write(path, text);
        await File(
          '${fixture.primaryRoot.path}/$path',
        ).writeAsString('Primary Environment must not be read\n');
        await File(
          '${Directory.fromUri(fixture.project.sourceLocation).path}/$path',
        ).writeAsString('Original Project must not be read\n');
      });
      await mount(tester);
      await _visible(tester, 'Additional Environment source content');
      expect(find.text('$path  [modified]'), findsOneWidget);
      expect(
        fixture.store
            .requireSessionAuthority(fixture.additionalSession.id)
            .environmentId,
        fixture.additional.id,
      );
      expect(fixture.additional.role, EnvironmentRole.additional);
      expect(fixture.additionalRoot.path, isNot(fixture.primaryRoot.path));
      expect(
        fixture.environmentRuntime.currentMaterialization(fixture.primary.id),
        isNull,
      );
      expect(fixture.frontends.generations, hasLength(2));
      expect(
        DisplaySourceFileResolver(fixture.extensions).resolve().id,
        ExtensionId('$_sourcePlugin.main-content'),
      );
      for (final id in [_diffPlugin, _sourcePlugin]) {
        final installation = fixture.backends.catalog!.installations
            .singleWhere((entry) => entry.metadata.id.value == id);
        expect(installation.backendArtifactUri, isNull);
        expect(fixture.backends.backendForInstallation(installation), isNull);
      }
      expect(find.byType(CodeForge), findsNothing);
      expect(fixture.reads, isEmpty);

      // Use ordinary desktop pane widths for Source's existing toolbar. The
      // returned pane must be visible and focused through Main Content.
      tester.view.physicalSize = const Size(720, 1200);
      await tester.pump();
      await _openFromDiff(tester);
      final native = _editor(tester);
      final element = tester.element(find.byType(CodeForge));
      expect(native.controller!.text, text);
      expect(native.readOnly, isFalse);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      final bounds = tester.getRect(find.byType(CodeForge));
      final hostBounds = tester.getRect(find.byType(MainContentHost));
      expect(bounds.left, greaterThanOrEqualTo(hostBounds.left));
      expect(bounds.right, lessThanOrEqualTo(hostBounds.right));

      native.focusNode!.unfocus();
      await tester.pump();
      expect(native.focusNode!.hasFocus, isFalse);
      await _openFromDiff(tester);
      expect(find.byType(CodeForge), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(native.controller!.text, text);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      expect(
        await tester.runAsync(() => fixture.file(path).readAsString()),
        text,
      );
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'actual Diff focuses an existing dirty Source document without replacing text or undo',
    (tester) async {
      const path = 'a modified.txt';
      const openedText = 'Source buffer opened before the Diff action\n';
      const changedOnDisk =
          'Newer disk text must not replace the dirty buffer\n';
      await tester.runAsync(() => fixture.write(path, openedText));
      await mount(tester);
      await _visible(tester, 'Source buffer opened before the Diff action');

      // Establish the existing document through Source's normal contributed form,
      // not its implementation or the resolver used by the later Diff action.
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(TextButton, 'Open Source...')),
      );
      await _visible(tester, 'Open Source File');
      await tester.pumpAndSettle();
      expect(fixture.reads, isEmpty);
      await tester.enterText(find.byType(TextField), './$path');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await _visible(tester, 'Source Document opened.');
      await tester.tap(find.byTooltip('Close input'));
      await _waitFor(tester, () => find.byType(Dialog).evaluate().isEmpty);
      final native = _editor(tester);
      final element = tester.element(find.byType(CodeForge));
      expect(native.controller!.text, openedText);
      native.focusNode!.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.home, control: true);
      await _key(tester, LogicalKeyboardKey.delete);
      expect(native.controller!.text, openedText.substring(1));
      await _visible(tester, 'Possibly modified');

      await tester.runAsync(() => fixture.write(path, changedOnDisk));
      _refresh(tester);
      await _visible(
        tester,
        'Newer disk text must not replace the dirty buffer',
      );
      native.focusNode!.unfocus();
      await tester.pump();
      await _openFromDiff(tester);
      expect(find.byType(CodeForge), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(native.controller!.text, openedText.substring(1));
      expect(fixture.reads, [(fixture.additional.id.value, './$path')]);
      // Diff's ordinary Main Content focus must reach the retained native editor;
      // do not manually focus it before proving that its original undo still works.
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(native.controller!.text, openedText);
      expect(
        await tester.runAsync(() => fixture.file(path).readAsString()),
        changedOnDisk,
      );
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'navigation during a held actual Source read cannot publish or focus in the new Environment',
    (tester) async {
      const path = 'a modified.txt';
      const additionalText = 'Held additional Environment Source content\n';
      const primaryText = 'New Session primary Environment Source content\n';
      await tester.runAsync(() async {
        await fixture.write(path, additionalText);
        await File(
          '${fixture.primaryRoot.path}/$path',
        ).writeAsString(primaryText);
      });
      await mount(tester);
      await _visible(tester, 'Held additional Environment Source content');
      await _waitFor(tester, () => _sourceAction().evaluate().length == 1);
      fixture.holdNextRead = true;
      final staleOpen = tester.widget<TextButton>(_sourceAction()).onPressed!;
      await tester.tap(_sourceAction());
      await _waitFor(tester, () => fixture.readArrived.isCompleted);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      expect(find.byType(CodeForge), findsNothing);

      await fixture.navigate(
        tester,
        fixture.additionalSession,
        fixture.primarySession,
      );
      await _visible(tester, 'New Session primary Environment Source content');
      staleOpen();
      await _openFromDiff(tester);
      final primary = _editor(tester);
      expect(primary.controller!.text, primaryText);
      expect(fixture.reads, [
        (fixture.additional.id.value, path),
        (fixture.primary.id.value, path),
      ]);

      fixture.readRelease.complete();
      await tester.runAsync(fixture.mainContent.drainOperations);
      await tester.pump();
      expect(find.byType(CodeForge), findsOneWidget);
      expect(_editor(tester).controller, same(primary.controller));
      expect(primary.controller!.text, primaryText);
      expect(primary.focusNode!.hasFocus, isTrue);
      expect(find.textContaining('Held additional Environment'), findsNothing);

      await fixture.navigate(
        tester,
        fixture.primarySession,
        fixture.additionalSession,
      );
      await _waitFor(
        tester,
        () => find.byType(CodeForge).evaluate().length == 1,
      );
      expect(_editor(tester).controller, isNot(same(primary.controller)));
      expect(_editor(tester).controller!.text, additionalText);
      expect(fixture.reads, [
        (fixture.additional.id.value, path),
        (fixture.primary.id.value, path),
      ]);
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(fixture.store.runsForSession(fixture.primarySession.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'clean Environment is distinct from unavailable and Git failure',
    (tester) async {
      await mount(tester);
      await _visible(tester, 'No unstaged changes');
      // A Git executable failure cannot turn an unsuccessful observation into clean.
      await tester.runAsync(
        () => File('${fixture.gate.path}/fail').writeAsString('fail'),
      );
      _refresh(tester);
      await _visible(tester, 'Unable to load');
      expect(find.textContaining('No unstaged changes'), findsNothing);
      await tester.runAsync(() => File('${fixture.gate.path}/fail').delete());
      _refresh(tester);
      await _visible(tester, 'No unstaged changes');
      await tester.runAsync(
        () => fixture.backends.backends.single.retireProvider(
          fixture.capabilities.resolve(_changes),
        ),
      );
      _refresh(tester);
      await _visible(tester, 'unavailable');
      expect(find.textContaining('No unstaged changes'), findsNothing);
      expect(
        fixture.capabilities.providersFor(environmentProviderCapability),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'frontend-only installation retains Diff when change source is absent',
    (tester) async {
      await mount(tester, catalog: frontendOnly);
      await _visible(tester, 'unavailable');
      expect(find.text('Diff'), findsOneWidget);
      expect(find.textContaining('No unstaged changes'), findsNothing);
      expect(fixture.backends.backends, isEmpty);
      _refresh(tester);
      await _visible(tester, 'unavailable');
      expect(fixture.backends.backends, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final departure in ['navigation', 'provider retirement']) {
    testWidgets('$departure fences a pending actual Git snapshot', (
      tester,
    ) async {
      await mount(tester);
      await _visible(tester, 'No unstaged changes');
      expect(
        fixture.environmentRuntime.currentMaterialization(
          fixture.additional.id,
        ),
        isNotNull,
      );
      await tester.runAsync(() async {
        await fixture.write('a modified.txt', 'Old Session pending content\n');
        await File('${fixture.gate.path}/armed').writeAsString('armed');
      });
      final staleRefresh = _refreshCallback(tester);
      _refresh(tester);
      // This checkpoint is reached inside Git's actual snapshot operation, after
      // canonical materialization, contextual admission, and authority lookup.
      await _waitFor(
        tester,
        () => File('${fixture.gate.path}/arrived').existsSync(),
      );
      if (departure == 'navigation') {
        fixture.frontends.unbind(fixture.additionalSession);
        await tester.pumpWidget(fixture.widget(fixture.primarySession));
      } else {
        await tester.runAsync(
          () => fixture.backends.backends.single.retireProvider(
            fixture.capabilities.resolve(_changes),
          ),
        );
      }
      await tester.runAsync(fixture.releaseGate);
      if (departure == 'navigation') {
        await _visible(tester, 'No unstaged changes');
        staleRefresh();
      } else {
        await _visible(tester, 'Unable to load');
        _refresh(tester);
        await _visible(tester, 'unavailable');
        final materialized = fixture.environmentRuntime.currentMaterialization(
          fixture.additional.id,
        )!;
        final read = await tester.runAsync(
          () => materialized.provider.readFile(
            fixture.additional.id,
            'a modified.txt',
          ),
        );
        expect(read!.text, 'Old Session pending content\n');
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('Old Session pending content'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isLinux);
  }
}

final class _Fixture {
  _Fixture(
    this.root,
    this.gate,
    this.launcher,
    this.host,
    this.project,
    this.task,
    this.primary,
    this.additional,
  ) {
    final strategy = OrchestrationStrategyId('test.uninstalled-strategy');
    additionalSession = Session(
      id: SessionId('additional-session'),
      taskId: task.id,
      strategyId: strategy,
    );
    primarySession = Session(
      id: SessionId('primary-session'),
      taskId: task.id,
      strategyId: strategy,
    );
    store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [primary, additional],
      sessions: [additionalSession, primarySession],
      authorities: [
        (additionalSession.id, additional.id),
        (primarySession.id, primary.id),
      ],
      runRecords: const [],
    );
    environmentRuntime = EnvironmentRuntime(
      store: store,
      registry: capabilities,
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(
          _EnvironmentChannel(binding.requestChannel, this),
        ),
      ),
      retainEnvironment: store.replaceEnvironment,
    );
    backends = ApplicationPluginBootstrap(capabilities, extensions);
    mainContent = PreparedMainContentHost(
      environmentRuntime: environmentRuntime,
    );
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      mainContentHost: mainContent,
    );
  }

  static Future<_Fixture> create({
    required Directory installations,
    required File host,
    required String aotRuntime,
  }) async {
    final root = await Directory.systemTemp.createTemp('adele-diff-case-');
    final repository = await Directory('${root.path}/repository').create();
    final source = await Directory('${repository.path}/nested source').create();
    for (final entry in {
      'a modified.txt': 'context before\nOriginal text\ncontext after\n',
      if (Platform.isLinux) _punctuatedPath: 'Tracked source baseline\n',
      'c deleted.txt': 'Deleted baseline\n',
      'd staged.txt': 'Staged baseline\n',
      'e reversal.txt': 'Original layer\n',
      '.gitignore': '*.tmp\n',
    }.entries) {
      await File('${source.path}/${entry.key}').writeAsString(entry.value);
    }
    await File(
      '${repository.path}/outside.txt',
    ).writeAsString('Outside baseline\n');
    await _git(repository, ['init', '--initial-branch=main']);
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Diff integration baseline']);
    final capabilities = CapabilityRegistry();
    final extensions = ExtensionRegistry();
    final backends = ApplicationPluginBootstrap(capabilities, extensions);
    final lifecycle = ProductLifecycleCoordinator.generated(
      store: InMemoryProductStore(),
      registry: capabilities,
      extensions: extensions,
    );
    late Project project;
    late TaskCreationResult created;
    late Environment additional;
    try {
      await backends.start(
        installationRoot: installations.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: host.path,
        startupArguments: const {},
      );
      expect(
        backends.backends.single.state,
        InstalledBackendState.active,
        reason: '${backends.backends.single.failure}',
      );
      project = lifecycle.createProject(source.uri);
      created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Real Diff Task',
      );
      final binding = capabilities.resolve(environmentProviderCapability);
      final provider = GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(binding.requestChannel),
      );
      final value = Environment(
        id: EnvironmentId('additional-diff'),
        taskId: created.task.id,
        role: EnvironmentRole.additional,
        providerId: binding.provider.id,
        providerState: null,
      );
      final established = await provider.establish(
        LocalEnvironment(project: project, task: created.task, value: value),
      );
      additional = Environment(
        id: value.id,
        taskId: value.taskId,
        role: value.role,
        providerId: value.providerId,
        providerState: established.providerState,
      );
    } finally {
      await backends.close();
      await lifecycle.close();
    }
    final gate = await Directory('${root.path}/gate').create();
    var launcher = aotRuntime;
    if (Platform.isLinux) {
      final git = (await Process.run('which', [
        'git',
      ])).stdout.toString().trim();
      final fifo = '${gate.path}/release';
      final result = await Process.run('mkfifo', [fifo]);
      expect(result.exitCode, 0);
      // Test-only transparent launcher: production still executes Git directly.
      // A FIFO acknowledgement, not elapsed time, gates an admitted operation.
      await File('${gate.path}/git').writeAsString('''#!/bin/sh
if [ -f ${_quote('${gate.path}/fail')} ]; then exit 73; fi
if [ -f ${_quote('${gate.path}/armed')} ] && mv ${_quote('${gate.path}/armed')} ${_quote('${gate.path}/arrived')}; then
  IFS= read -r release < ${_quote(fifo)}
fi
exec ${_quote(git)} "\$@"
''');
      launcher = '${gate.path}/runtime';
      await File(launcher).writeAsString('''#!/bin/sh
export PATH=${_quote(gate.path)}:"\$PATH"
exec ${_quote(aotRuntime)} "\$@"
''');
      expect(
        (await Process.run('chmod', [
          '+x',
          '${gate.path}/git',
          launcher,
        ])).exitCode,
        0,
      );
    }
    return _Fixture(
      root,
      gate,
      launcher,
      host,
      project,
      created.task,
      created.environment,
      additional,
    );
  }

  final Directory root;
  final Directory gate;
  final String launcher;
  final File host;
  final Project project;
  final Task task;
  final Environment primary;
  final Environment additional;
  final capabilities = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final store = InMemoryProductStore();
  late final Session additionalSession;
  late final Session primarySession;
  late final EnvironmentRuntime environmentRuntime;
  late final ApplicationPluginBootstrap backends;
  late final PreparedMainContentHost mainContent;
  late final ApplicationFrontendBootstrap frontends;
  final reads = <(String, String)>[];
  bool holdNextRead = false;
  final readArrived = Completer<void>();
  final readRelease = Completer<void>();
  bool _released = false;

  Directory worktree(Environment environment) => Directory.fromUri(
    project.sourceLocation.resolve(
      '${environment.providerState!['worktreeRelativePath']}/',
    ),
  );
  Directory sourceRoot(Environment environment) => Directory(
    '${worktree(environment).path}/${environment.providerState!['sourceRelativePath']}',
  );
  Directory get additionalWorktree => worktree(additional);
  Directory get additionalRoot => sourceRoot(additional);
  Directory get primaryRoot => sourceRoot(primary);
  File file(String path) => File('${additionalRoot.path}/$path');
  Future<void> write(String path, String text) async =>
      file(path).writeAsString(text);
  Future<List<String>> fingerprint() async => [
    await _git(additionalWorktree, ['status', '--porcelain=v1', '-z']),
    await _git(additionalWorktree, ['diff', '--cached', '--binary']),
    await _git(additionalWorktree, ['diff', '--binary']),
    await _git(additionalWorktree, ['rev-parse', 'HEAD']),
    await file('b new + [file].txt').readAsString(),
  ];

  Future<void> start(Directory catalog) async {
    await backends.start(
      installationRoot: catalog.path,
      dartaotruntimeExecutable: launcher,
      hostArtifactPath: host.path,
      startupArguments: const {},
    );
    expect(backends.state, ApplicationPluginState.ready);
    expect(backends.failure, isNull);
    expect(backends.catalog!.issues, isEmpty);
    for (final backend in backends.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
    await frontends.start(backends.catalog!);
    for (final generation in frontends.generations) {
      expect(
        generation.state,
        InstalledFrontendState.active,
        reason: '${generation.failure}',
      );
    }
  }

  Widget widget(Session session) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: session,
        extensions: extensions,
        actionCoordinator: mainContent.actionCoordinator,
      ),
    ),
  );

  Future<void> navigate(
    WidgetTester tester,
    Session previous,
    Session next,
  ) async {
    await tester.runAsync(() => frontends.prepareToDeactivate(previous));
    frontends.unbind(previous);
    await tester.runAsync(() => tester.pumpWidget(widget(next)));
    await tester.pump();
  }

  Future<void> releaseGate() async {
    if (_released || !File('${gate.path}/arrived').existsSync()) return;
    _released = true;
    await File(
      '${gate.path}/release',
    ).writeAsString('release\n').timeout(_bound);
  }

  Future<void> close() async {
    if (!readRelease.isCompleted) readRelease.complete();
    await releaseGate();
    await frontends.close();
    await backends.close();
    await root.delete(recursive: true);
  }
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  const _EnvironmentChannel(this.delegate, this.fixture);

  final AdeleRequestChannel delegate;
  final _Fixture fixture;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method != environmentProviderServiceReadFileId) {
      return delegate.request(method, payload);
    }
    fixture.reads.add((
      payload['environmentId']! as String,
      payload['relativePath']! as String,
    ));
    final held = fixture.holdNextRead;
    fixture.holdNextRead = false;
    final result = await delegate.request(method, payload);
    if (held) {
      // The real Git AOT read has completed. Hold only delivery of its unchanged
      // response to Source, not a fabricated provider result or a timed delay.
      fixture.readArrived.complete();
      await fixture.readRelease.future;
    }
    return result;
  }
}

Future<void> _manifest(
  Directory directory,
  String id,
  Map<String, Object?> components,
) async {
  await File('${directory.path}/adele_plugin.installation.json').writeAsString(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {'id': id, 'version': '1.0.0', 'displayName': id},
      'components': components,
    }),
  );
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
    environment: {
      for (final entry in Platform.environment.entries)
        if (!entry.key.toUpperCase().startsWith('GIT_')) entry.key: entry.value,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_AUTHOR_NAME': 'ADELE Test',
      'GIT_AUTHOR_EMAIL': 'test@example.invalid',
      'GIT_COMMITTER_NAME': 'ADELE Test',
      'GIT_COMMITTER_EMAIL': 'test@example.invalid',
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_OPTIONAL_LOCKS': '0',
    },
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}

VoidCallback _refreshCallback(WidgetTester tester) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, 'Refresh'))
    .onPressed!;
void _refresh(WidgetTester tester) => _refreshCallback(tester)();

Finder _sourceAction() => find.widgetWithText(TextButton, 'Open in Source');

CodeForge _editor(WidgetTester tester) =>
    tester.widget<CodeForge>(find.byType(CodeForge));

Future<void> _openFromDiff(WidgetTester tester) async {
  bool enabled() =>
      _sourceAction().evaluate().length == 1 &&
      tester.widget<TextButton>(_sourceAction()).onPressed != null;
  await _waitFor(tester, enabled);
  await tester.ensureVisible(_sourceAction());
  await tester.pump();
  await tester.runAsync(() => tester.tap(_sourceAction()));
  await _waitFor(
    tester,
    () =>
        find.byType(CodeForge).evaluate().length == 1 &&
        _editor(tester).focusNode!.hasFocus,
  );
  await _waitFor(tester, enabled);
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.sendKeyEvent(key);
  } finally {
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

Future<void> _visible(WidgetTester tester, String text) async {
  await _waitFor(tester, () => find.textContaining(text).evaluate().isNotEmpty);
  expect(find.textContaining(text), findsWidgets);
}

Future<void> _waitFor(WidgetTester tester, bool Function() complete) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (!complete() && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(
    complete(),
    isTrue,
    reason: 'Timed out waiting for actual AOT/EVC checkpoint.',
  );
}

String _quote(String text) => "'${text.replaceAll("'", "'\\''")}'";
String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final executable = File('${directory.path}/dart-sdk/bin/dart');
    if (executable.existsSync()) return executable.path;
    directory = directory.parent;
  }
  throw StateError('Cannot locate the running Flutter toolchain Dart SDK.');
}
