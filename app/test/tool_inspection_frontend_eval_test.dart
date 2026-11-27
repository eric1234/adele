import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tool_inspection_fixture.dart';

void main() {
  late Directory temporary;
  late File sessionArtifact;
  late Directory installations;
  late ExtensionRegistry extensions;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-tool-inspection-');
    final prepared = await prepareToolInspectionFrontends(temporary);
    installations = prepared.installations;
    sessionArtifact = File('${temporary.path}/session.evc');
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
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    await startToolInspectionFrontends(installations, extensions);
  });

  testWidgets(
    'generic Session activity first-mounts one-edit waiting patch EVC',
    (tester) async {
      final PreparedFrontend sessionFrontend = (await tester.runAsync(
        () => PreparedFrontend.load(sessionArtifact),
      ))!;
      addTearDown(sessionFrontend.invalidate);
      final ToolInvocationActivity patch = toolActivity(
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
        inspectionHostApp(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return Column(
                children: [
                  sessionView,
                  if (selected)
                    InspectionHost(
                      card: inspectionGroupCard(
                        activity,
                        selection.modelInvocationId,
                      ),
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
      // Command has a compact presenter, but a proposal alone must not mount it.
      final commandBinding = ToolActivityCompactPresentationResolver(
        extensions,
      ).resolve(runCommandToolId);
      expect(
        commandBinding.id,
        ExtensionId('dev.adele.plugin.command-tools.compact'),
      );
      await tester.tap(find.text('ACTIVITY: Update and validate'));
      await tester.pumpAndSettle();
      final compactHost = find.byType(
        ToolActivityCompactHost,
        skipOffstage: false,
      );
      expect(compactHost, findsOneWidget);
      expect(
        tester.widget<ToolActivityCompactHost>(compactHost).source.snapshot,
        same(patch),
      );
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
