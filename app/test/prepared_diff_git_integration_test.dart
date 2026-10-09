@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/stock_frontend_descriptors.dart';
import '../tool/diff_viewer_frontend_compiler.dart';

const _gitPlugin = 'dev.adele.plugin.git-environment';
const _diffPlugin = 'dev.adele.diff-viewer';
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
    await tester.pumpWidget(fixture.widget(fixture.additionalSession));
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
        fixture.frontends.generations.single.state,
        InstalledFrontendState.active,
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
        service: EnvironmentProviderServiceClient(binding.requestChannel),
      ),
      retainEnvironment: store.replaceEnvironment,
    );
    backends = ApplicationPluginBootstrap(capabilities, extensions);
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      mainContentHost: PreparedMainContentHost(
        environmentRuntime: environmentRuntime,
      ),
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
  late final ApplicationFrontendBootstrap frontends;
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
    expect(
      frontends.generations.single.state,
      InstalledFrontendState.active,
      reason: '${frontends.generations.single.failure}',
    );
  }

  Widget widget(Session session) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(session: session, extensions: extensions),
    ),
  );

  Future<void> releaseGate() async {
    if (_released || !File('${gate.path}/arrived').existsSync()) return;
    _released = true;
    await File(
      '${gate.path}/release',
    ).writeAsString('release\n').timeout(_bound);
  }

  Future<void> close() async {
    await releaseGate();
    await frontends.close();
    await backends.close();
    await root.delete(recursive: true);
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
