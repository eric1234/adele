import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/tool_inspection_frontend_compiler.dart';
import 'support/prepared_frontend_installations.dart';

void main() {
  late Directory temporary;
  late File filesystemArtifact;
  late File commandArtifact;
  late File sessionArtifact;
  late Directory installations;
  late ExtensionRegistry extensions;
  late ApplicationFrontendBootstrap frontends;
  late InstalledFrontendActivation filesystem;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-tool-inspection-');
    filesystemArtifact = File('${temporary.path}/filesystem.evc');
    commandArtifact = File('${temporary.path}/command.evc');
    sessionArtifact = File('${temporary.path}/session.evc');
    // Exercise Command without first loading another frontend's declarations.
    for (final frontend in [
      ToolInspectionFrontend.command,
      ToolInspectionFrontend.filesystem,
    ]) {
      await compileToolInspectionFrontend(
        repositoryRoot: Directory.current.parent,
        artifact: frontend == ToolInspectionFrontend.filesystem
            ? filesystemArtifact
            : commandArtifact,
        frontend: frontend,
      );
    }
    final program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const SessionExecutionDeclarations())
              ..entrypoints.add('package:session_probe/main.dart'))
            .compile({
              'session_probe': {
                'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/session_execution_bridge.dart';
Future<Widget> buildSession() async {
  final runHandle = await startSessionRun();
  final activity = readSessionRunActivity(runHandle);
  final models = activity['models'] as List<Map<String, Object?>>;
  final groupHandle = models[0]['handle'] as String;
  return Column(children: [
    const Text('Session'),
    TextButton(
      onPressed: () { inspectSessionActivity(groupHandle); },
      child: const Text('ACTIVITY: Update and validate'),
    ),
  ]);
}
''',
              },
              'adele_ui': {
                'session_execution_bridge.dart': File(
                  '${Directory.current.parent.path}/packages/ui/lib/session_execution_bridge.dart',
                ).readAsStringSync(),
              },
            });
    await sessionArtifact.writeAsBytes(program.write());
    installations = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/installed'),
      artifacts: {
        'dev.adele.plugin.filesystem-tools': filesystemArtifact,
        'dev.adele.plugin.command-tools': commandArtifact,
      },
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    final catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
    frontends = ApplicationFrontendBootstrap(extensions: extensions);
    await frontends.start(catalog);
    expect(frontends.generations, hasLength(2));
    expect(
      frontends.generations.map((generation) => generation.state),
      everyElement(InstalledFrontendState.active),
    );
    filesystem = frontends.generations.singleWhere(
      (generation) =>
          generation.installation.metadata.id.value ==
          'dev.adele.plugin.filesystem-tools',
    );
  });
  tearDown(() => frontends.close());

  Widget presentation(_Source source) => ToolActivityInspectionResolver(
    extensions,
  ).resolve(source.value.toolId).value.createPresentation(source);

  Widget compact(_Source source, {String fallback = 'Factual tool fallback'}) =>
      ToolActivityCompactHost(
        extensions: extensions,
        source: source,
        fallback: Text(fallback),
      );

  testWidgets(
    'failed compact EVC preserves refreshed facts without retry or sibling failure',
    (tester) async {
      final source = _Source(
        _activity(arguments: {'relativePath': 42, 'edits': []}),
      );
      final healthy = _Source(_activity(patch: false));
      await tester.pumpWidget(
        _host(Column(children: [compact(source), compact(healthy)])),
      );
      await tester.pumpAndSettle();
      expect(find.text('Factual tool fallback'), findsOneWidget);
      expect(
        find.text('Run Command: "dart" ["test", "a b; c"]'),
        findsOneWidget,
      );
      expect(source.listening, isFalse);
      final reads = source.reads;
      source.value = _activity();
      source.notifyListeners();
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              compact(source, fallback: 'Updated facts'),
              compact(healthy),
            ],
          ),
        ),
      );
      expect(find.text('Updated facts'), findsOneWidget);
      // Host resolution reads identity; a failed EVC never subscribes again.
      expect(source.reads, reads + 1);
      expect(source.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'installed activations and simultaneous presenters retire independently',
    (tester) async {
      final backend = const FilesystemToolsPlugin().activate(extensions);
      final commandBackend = const CommandToolsPlugin().activate(extensions);
      addTearDown(backend.close);
      addTearDown(commandBackend.close);
      final _Source first = _Source(_activity());
      final _Source second = _Source(
        _activity(arguments: {'relativePath': 'second.dart', 'edits': []}),
      );
      final _Source process = _Source(_activity(patch: false));
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              presentation(first),
              presentation(second),
              presentation(process),
            ],
          ),
        ),
      );
      expect(find.text('Apply Patch'), findsNWidgets(2));
      expect(find.text('Run Command'), findsOneWidget);
      second.value = _activity(
        kind: ToolActivityKind.approvalRequested,
        arguments: {'relativePath': 'second.dart', 'edits': []},
      );
      second.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.text('Status: Waiting for approval'), findsOneWidget);
      expect(find.text('Status: Prepared'), findsNWidgets(2));
      final retainedBinding = ToolActivityInspectionResolver(
        extensions,
      ).resolve(applyPatchToolId);
      final retainedFactory = retainedBinding.value.createPresentation;
      await tester.runAsync(filesystem.close);
      await tester.pump();
      expect(retainedBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(find.text('Run Command'), findsOneWidget);
      expect(first.listening, isFalse);
      expect(second.listening, isFalse);
      expect(process.listening, isTrue);
      expect(extensions.discover(modelToolContributions), hasLength(2));
      expect(
        extensions.discover(toolActivityInspectionContributions),
        hasLength(1),
      );
      expect(() => retainedFactory(first), throwsStateError);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generic Session activity first-mounts one-edit waiting patch EVC',
    (tester) async {
      final PreparedFrontend sessionFrontend = (await tester.runAsync(
        () => PreparedFrontend.load(sessionArtifact),
      ))!;
      addTearDown(sessionFrontend.invalidate);
      final ToolInvocationActivity patch = _activity(
        proposalSequence: 2,
        kind: ToolActivityKind.approvalRequested,
        arguments: {
          'relativePath': 'lib/task_answer.dart',
          'expectedRevision': 'opaque-task-revision',
          'edits': [
            {
              'search': 'const taskAnswer = "task-worktree-only";',
              'replace': 'const taskAnswer = "approved-task-value";',
            },
          ],
        },
      );
      final ActivityGroupInspectionTarget selection =
          ActivityGroupInspectionTarget(
            sessionId: SessionId('inspection-session'),
            runId: RunId('inspection-run'),
            modelInvocationId: patch.modelInvocationId,
          );
      final RunActivitySnapshot activity = RunActivitySnapshot(
        runId: selection.runId,
        sessionId: selection.sessionId,
        state: RunState.waiting,
        sequence: 20,
        models: [
          ModelInvocationActivity(
            id: patch.modelInvocationId,
            startSequence: 1,
            settlement: ModelSettlement.completed,
            terminalSequence: 4,
            outputs: [
              ModelOutputActivity(
                sequence: patch.proposalSequence,
                item: ModelToolProposalOutput(
                  ProviderToolProposal(
                    providerCallId: patch.providerCallId,
                    alias: patch.alias,
                    arguments: patch.canonicalArguments,
                  ),
                ),
              ),
              ModelOutputActivity(
                sequence: 3,
                item: ModelToolProposalOutput(
                  ProviderToolProposal(
                    providerCallId: 'command',
                    alias: 'run_command',
                    arguments: const {
                      'program': 'git',
                      'arguments': ['diff', '--check'],
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
        tools: [patch],
      );
      bool selected = false;
      late StateSetter rebuild;
      final _InspectionSessionSource source = _InspectionSessionSource(() {
        rebuild(() => selected = true);
      });
      addTearDown(source.dispose);
      final Widget sessionView = sessionFrontend.createPresentation(
        library: 'package:session_probe/main.dart',
        entrypoint: 'buildSession',
        createBridge: () =>
            SessionExecutionBridge(source: source, isActive: () => true),
      );
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return Column(
                children: [
                  sessionView,
                  if (selected)
                    InspectionHost(
                      card: _groupCard(activity, selection.modelInvocationId),
                      activity: activity,
                      heading: 'Update and validate',
                      extensions: extensions,
                      onCollapse: () {},
                      onExpand: () {},
                      onDismiss: () => rebuild(() => selected = false),
                      onInspectOutput: (_) {},
                    ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.activityRead, isTrue);
      final Element sessionElement = tester.element(find.text('Session'));
      expect(find.text('Apply Patch'), findsNothing);
      await tester.tap(find.text('ACTIVITY: Update and validate'));
      await tester.pumpAndSettle();
      expect(
        find.text('Apply Patch: "lib/task_answer.dart" / 1 edit'),
        findsOneWidget,
      );
      expect(find.text('Apply Patch'), findsNothing);
      expect(find.textContaining('Requested edits:'), findsNothing);
      expect(find.textContaining('Status:'), findsNothing);
      expect(find.text('Tool delivery: Pending'), findsNothing);
      expect(find.text('Proposal: run_command'), findsOneWidget);
      expect(tester.element(find.text('Session')), same(sessionElement));
      expect(activity.tools.single, same(patch));
      expect(patch.outcome, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual mixed EVC group follows proposal order and survives partial retirement',
    (tester) async {
      final backend = const FilesystemToolsPlugin().activate(extensions);
      final commandBackend = const CommandToolsPlugin().activate(extensions);
      addTearDown(backend.close);
      addTearDown(commandBackend.close);
      final ToolInvocationActivity patch = _activity(
        proposalSequence: 2,
        kind: ToolActivityKind.completed,
        disposition: ToolOutcomeDisposition.success,
        data: {'newRevision': 'mixed-revision-2', 'editCount': 2},
      );
      final ToolInvocationActivity running = _activity(
        patch: false,
        proposalSequence: 3,
        kind: ToolActivityKind.executionStarted,
      );
      final ProviderToolProposal rejectedProposal = ProviderToolProposal(
        providerCallId: 'call-1',
        alias: 'unsupported_operation',
        arguments: const {},
      );
      final ModelInvocationActivity model = ModelInvocationActivity(
        id: patch.modelInvocationId,
        startSequence: 1,
        terminalSequence: 5,
        settlement: ModelSettlement.completed,
        outputs: [
          for (final tool in [patch, running])
            ModelOutputActivity(
              sequence: tool.proposalSequence,
              item: ModelToolProposalOutput(
                ProviderToolProposal(
                  providerCallId: tool.providerCallId,
                  alias: tool.alias,
                  arguments: tool.canonicalArguments,
                ),
              ),
            ),
          ModelOutputActivity(
            sequence: 4,
            item: ModelToolProposalOutput(rejectedProposal),
          ),
        ],
      );
      final RejectedToolProposalActivity rejected =
          RejectedToolProposalActivity(
            sequence: 30,
            modelInvocationId: model.id,
            proposalSequence: 4,
            proposal: rejectedProposal,
            kind: ToolProposalFailureKind.unknownAlias,
            message: 'No registered tool matches this proposal.',
          );
      final ActivityGroupInspectionTarget selection =
          ActivityGroupInspectionTarget(
            sessionId: SessionId('mixed-session'),
            runId: RunId('mixed-run'),
            modelInvocationId: model.id,
          );
      RunActivitySnapshot snapshot(
        ToolInvocationActivity process,
      ) => RunActivitySnapshot(
        runId: selection.runId,
        sessionId: selection.sessionId,
        state: process.outcome == null ? RunState.running : RunState.completed,
        sequence: 40,
        models: [model],
        // Deliberately opposite the authoritative model-output proposal order.
        tools: [process, patch],
        rejectedProposals: [rejected],
      );
      final RunActivitySnapshot retained = snapshot(running);
      Widget group(RunActivitySnapshot activity) => _host(
        InspectionHost(
          card: _groupCard(activity, selection.modelInvocationId),
          activity: activity,
          heading: 'Patch source, then validate it',
          extensions: extensions,
          onCollapse: () {},
          onExpand: () {},
          onDismiss: () {},
          onInspectOutput: (_) {},
        ),
      );

      await tester.pumpWidget(group(retained));
      final Finder patchTitle = find.text(
        'Apply Patch: "lib/main.dart" / 2 edits',
      );
      final Finder commandTitle = find.text(
        'Run Command: "dart" ["test", "a b; c"]',
      );
      final Finder placeholder = find.text('Proposal: unsupported_operation');
      expect(find.byType(ToolActivityCompactHost), findsNWidgets(2));
      expect(patchTitle, findsOneWidget);
      expect(commandTitle, findsOneWidget);
      expect(find.textContaining('Requested edits:'), findsNothing);
      expect(find.text('New revision: mixed-revision-2'), findsNothing);
      expect(find.textContaining('Status:'), findsNothing);
      expect(find.text('Proposal rejected: unknownAlias.'), findsOneWidget);
      expect(
        tester.getTopLeft(patchTitle).dy,
        lessThan(tester.getTopLeft(commandTitle).dy),
      );
      expect(
        tester.getTopLeft(commandTitle).dy,
        lessThan(tester.getTopLeft(placeholder).dy),
      );
      final Element commandElement = tester.element(commandTitle);
      final ToolActivityInspectionSource commandSource = tester
          .widgetList<ToolActivityCompactHost>(
            find.byType(ToolActivityCompactHost),
          )
          .singleWhere((host) => host.source.snapshot.id == running.id)
          .source;
      expect(commandSource.snapshot, same(running));

      await tester.runAsync(filesystem.close);
      await tester.pumpAndSettle();
      expect(patchTitle, findsNothing);
      expect(find.text('Tool: apply_patch'), findsOneWidget);
      expect(tester.element(commandTitle), same(commandElement));
      expect(commandSource.snapshot, same(running));
      expect(
        find.text('Run Command: "dart" ["test", "a b; c"]'),
        findsOneWidget,
      );
      expect(find.text('Proposal rejected: unknownAlias.'), findsOneWidget);
      expect(extensions.discover(modelToolContributions), hasLength(2));
      expect(
        extensions.discover(toolActivityInspectionContributions),
        hasLength(1),
      );
      expect(retained.state, RunState.running);
      expect(retained.tools, orderedEquals([running, patch]));
      expect(
        retained.tools.last.outcome!.hostData['newRevision'],
        'mixed-revision-2',
      );
      expect(retained.rejectedProposals.single, same(rejected));

      final ToolInvocationActivity completed = _activity(
        patch: false,
        proposalSequence: 3,
        kind: ToolActivityKind.completed,
        disposition: ToolOutcomeDisposition.success,
        data: {
          'termination': 'exited',
          'exitCode': 0,
          'stdout': 'Validation complete',
          'stderr': '',
          'stdoutTruncated': false,
          'stderrTruncated': false,
        },
      );
      await tester.pumpWidget(group(snapshot(completed)));
      await tester.pumpAndSettle();
      expect(tester.element(commandTitle), same(commandElement));
      expect(commandSource.snapshot, same(completed));
      expect(find.text('stdout preview: Validation complete'), findsNothing);
      expect(find.textContaining('Status:'), findsNothing);
      expect(retained.tools.first.outcome, isNull);
      expect(retained.tools.last, same(patch));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing and corrupt EVC are bounded without retiring other plugins',
    (tester) async {
      await tester.runAsync(filesystem.close);
      await tester.runAsync(() async {
        final root = await prepareFrontendInstallations(
          root: Directory('${temporary.path}/missing-installation'),
          artifacts: {'dev.adele.plugin.filesystem-tools': filesystemArtifact},
        );
        final installedArtifact = File(
          '${root.path}/dev.adele.plugin.filesystem-tools/frontend.evc',
        );
        await installedArtifact.delete();
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, hasLength(1));
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.frontend,
        );
        expect(catalog.installations.single.frontend, isNull);
        final bootstrap = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(bootstrap.close);
        await bootstrap.start(catalog);
        expect(bootstrap.generations, isEmpty);

        await filesystemArtifact.copy(installedArtifact.path);
        final discovered = await PreparedPluginCatalog.discover(root.path);
        expect(discovered.issues, isEmpty);
        await installedArtifact.delete();
        final vanished = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(vanished.close);
        await vanished.start(discovered);
        expect(
          vanished.generations.single.state,
          InstalledFrontendState.failed,
        );
        expect(vanished.generations.single.failure, isA<FileSystemException>());
      });
      expect(
        extensions.discover(toolActivityInspectionContributions),
        hasLength(1),
      );
      final _Source process = _Source(_activity(patch: false));
      await tester.pumpWidget(_host(presentation(process)));
      expect(find.text('Run Command'), findsOneWidget);
      await tester.runAsync(() async {
        final File corrupt = File('${temporary.path}/corrupt.evc');
        await corrupt.writeAsBytes([1, 2, 3]);
        final root = await prepareFrontendInstallations(
          root: Directory('${temporary.path}/corrupt-installation'),
          artifacts: {'dev.adele.plugin.filesystem-tools': corrupt},
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final bootstrap = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(bootstrap.close);
        await bootstrap.start(catalog);
        filesystem = bootstrap.generations.single;
        // Bytes are retained at activation; decoding remains presentation-local.
        expect(filesystem.state, InstalledFrontendState.active);
      });
      final _Source patch = _Source(_activity());
      await tester.pumpWidget(
        _host(Column(children: [presentation(patch), presentation(process)])),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('Run Command'), findsOneWidget);
      expect(patch.listening, isFalse);
      expect(tester.takeException(), isNull);

      final PreparedFrontend missing = (await tester.runAsync(
        () => PreparedFrontend.load(File('${temporary.path}/missing.evc')),
      ))!;
      await tester.pumpWidget(
        _host(
          missing.createPresentation(
            library:
                'package:filesystem_tools_frontend/filesystem_tools_frontend.dart',
            entrypoint: 'buildApplyPatchInspection',
            createBridge: () => ToolActivityInspectionBridge(
              source: patch,
              isActive: () => true,
            ),
          ),
        ),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(patch.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

InspectionCard _groupCard(
  RunActivitySnapshot activity,
  ModelInvocationId model,
) {
  final session = Session(
    id: activity.sessionId,
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('dev.example.chat'),
  );
  final window = WindowInspection()..presentSession(session);
  window.inspectActivity(
    session: session,
    activity: activity,
    modelInvocationId: model,
  );
  final card = window.cards.single;
  window.dispose();
  return card;
}

ToolInvocationActivity _activity({
  bool patch = true,
  int proposalSequence = 1,
  ToolActivityKind kind = ToolActivityKind.prepared,
  bool progress = false,
  ToolOutcomeDisposition? disposition,
  Map<String, Object?>? arguments,
  Map<String, Object?> data = const {},
  String content = 'Tool outcome.',
}) => ToolInvocationActivity(
  id: ToolInvocationId(patch ? 'patch-1' : 'command-1'),
  preparedSequence: proposalSequence + 10,
  modelInvocationId: ModelInvocationId('model-1'),
  proposalSequence: proposalSequence,
  toolId: patch ? applyPatchToolId : runCommandToolId,
  alias: patch ? 'apply_patch' : 'run_command',
  providerCallId: 'call-1',
  canonicalArguments:
      arguments ??
      (patch
          ? {
              'relativePath': 'lib/main.dart',
              'expectedRevision': 'revision-1',
              'edits': [
                {'search': 'a', 'replace': 'b'},
                {'search': 'c', 'replace': 'd'},
              ],
            }
          : {
              'program': 'dart',
              'arguments': ['test', 'a b; c'],
              'workingDirectory': '',
              'timeoutSeconds': 120,
            }),
  changes: [
    ToolActivityChange(sequence: proposalSequence + 10, kind: kind),
    if (progress)
      ToolActivityChange(
        sequence: proposalSequence + 11,
        kind: ToolActivityKind.progress,
      ),
  ],
  outcome: disposition == null
      ? null
      : ToolOutcomeActivity(
          disposition: disposition,
          failureKind: disposition == ToolOutcomeDisposition.failure
              ? ToolFailureKind.domain
              : null,
          effectCertainty: EffectCertainty.uncertain,
          modelContent: content,
          hostData: data,
        ),
);

class _Source extends ChangeNotifier implements ToolActivityInspectionSource {
  _Source(this.value);

  @override
  final SessionId sessionId = SessionId('session');
  @override
  final RunId runId = RunId('run');
  ToolInvocationActivity value;
  int reads = 0;
  int subscriptions = 0;
  bool get listening => hasListeners;

  @override
  ToolInvocationActivity get snapshot {
    reads++;
    return value;
  }

  @override
  void addListener(VoidCallback listener) {
    subscriptions++;
    super.addListener(listener);
  }
}

class _InspectionSessionSource extends ChangeNotifier
    implements SessionExecutionSource {
  _InspectionSessionSource(this.openInspection);

  final VoidCallback openInspection;
  bool _runStarted = false;
  bool activityRead = false;

  @override
  String currentSessionId() => 'inspection-session';

  @override
  String? openRunActivity(String runId) => null;

  @override
  Map<String, Object?> readExecution() => {
    'canStart': !_runStarted,
    'running': _runStarted,
    'advancing': false,
  };

  @override
  Future<String> startRun() async {
    _runStarted = true;
    return 'inspection-run';
  }

  @override
  Map<String, Object?> readRunActivity(String handle) {
    if (!_runStarted || handle != 'inspection-run') {
      throw StateError('Run handle was not emitted by this fixture.');
    }
    activityRead = true;
    return const {
      'runHandle': 'inspection-run',
      'state': 'waiting',
      'models': [
        {
          'handle': 'group',
          'sequence': 1,
          'settlement': 'completed',
          'outputs': [
            {
              'handle': 'patch',
              'sequence': 2,
              'kind': 'tool',
              'alias': 'apply_patch',
            },
            {
              'handle': 'command',
              'sequence': 3,
              'kind': 'tool',
              'alias': 'run_command',
            },
          ],
        },
      ],
    };
  }

  @override
  Widget buildActivity(String handle) =>
      throw StateError('The probe EVC owns its group presentation.');

  @override
  Widget buildStatus() => const SizedBox.shrink();

  @override
  void invalidate() {}

  @override
  bool inspectActivity(String id) {
    if (!activityRead || id != 'group') return false;
    openInspection();
    return true;
  }
}
