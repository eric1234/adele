import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_desktop/plugins/chat_frontend_bridge.dart';
import 'package:adele_desktop/plugins/stock_tool_inspection_frontends.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/chat_frontend_compiler.dart';
import '../tool/tool_inspection_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File filesystemArtifact;
  late File commandArtifact;
  late File chatArtifact;
  late ExtensionRegistry extensions;
  late StockToolInspectionFrontend filesystem;
  late StockToolInspectionFrontend command;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-tool-inspection-');
    filesystemArtifact = File('${temporary.path}/filesystem.evc');
    commandArtifact = File('${temporary.path}/command.evc');
    chatArtifact = File('${temporary.path}/chat.evc');
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
    await compileChatFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: chatArtifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    filesystem = await StockToolInspectionFrontend.activateFilesystem(
      extensions: extensions,
      artifactPath: filesystemArtifact.path,
    );
    command = await StockToolInspectionFrontend.activateCommand(
      extensions: extensions,
      artifactPath: commandArtifact.path,
    );
  });
  tearDown(() async {
    await filesystem.close();
    await command.close();
  });

  Widget presentation(_Source source) => ToolActivityInspectionResolver(
    extensions,
  ).resolve(source.value.toolId).value.createPresentation(source);

  Widget compact(_Source source, {String fallback = 'Factual tool fallback'}) =>
      ToolActivityCompactHost(
        extensions: extensions,
        source: source,
        fallback: Text(fallback),
      );

  for (final patch in [true, false]) {
    testWidgets(
      'same ${patch ? 'patch' : 'command'} artifact has independent live compact and rich views',
      (tester) async {
        final source = _Source(_activity(patch: patch));
        await tester.pumpWidget(
          _host(Column(children: [compact(source), presentation(source)])),
        );
        expect(
          find.text(patch ? 'Apply Patch' : 'Run Command'),
          findsOneWidget,
        );
        final title = find.text(
          patch
              ? 'Apply Patch: "lib/main.dart" / 2 edits'
              : 'Run Command: "dart" ["test", "a b; c"]',
        );
        expect(title, findsOneWidget);
        final element = tester.element(title);
        final compactText = find.descendant(
          of: find.byType(ToolActivityCompactHost),
          matching: find.byType(Text),
        );
        expect(compactText, findsOneWidget);
        expect(source.subscriptions, 2);
        final reads = source.reads;
        source.value = _activity(
          patch: patch,
          kind: ToolActivityKind.approvalRequested,
          progress: true,
        );
        source.notifyListeners();
        source.notifyListeners();
        await tester.pumpAndSettle();
        // Rich details change; the concise action summary retains its identity.
        expect(find.text('Status: Waiting for approval'), findsOneWidget);
        expect(tester.element(title), same(element));
        expect(source.reads, reads + 2);
        expect(source.subscriptions, 2);
        expect(find.byType(TextButton), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(source.listening, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    for (final retireCompact in [true, false]) {
      testWidgets(
        '${patch ? 'patch' : 'command'} ${retireCompact ? 'compact' : 'rich'} retirement leaves sibling live',
        (tester) async {
          final source = _Source(_activity(patch: patch));
          final compactBinding = ToolActivityCompactPresentationResolver(
            extensions,
          ).resolve(source.value.toolId);
          final richBinding = ToolActivityInspectionResolver(
            extensions,
          ).resolve(source.value.toolId);
          final compactFactory = compactBinding.value.createPresentation;
          final richFactory = richBinding.value.createPresentation;
          await tester.pumpWidget(
            _host(Column(children: [compact(source), presentation(source)])),
          );
          final frontend = patch ? filesystem : command;
          if (retireCompact) {
            await frontend.retireCompact();
          } else {
            await frontend.retireInspection();
          }
          source.notifyListeners();
          await tester.pumpAndSettle();
          if (retireCompact) {
            expect(
              compactBinding.validate,
              throwsA(isA<StaleExtensionBinding>()),
            );
            expect(() => compactFactory(source), throwsStateError);
            richBinding.validate();
            expect(find.text('Factual tool fallback'), findsOneWidget);
            expect(
              find.text(patch ? 'Apply Patch' : 'Run Command'),
              findsOneWidget,
            );
          } else {
            expect(richBinding.validate, throwsA(isA<StaleExtensionBinding>()));
            expect(() => richFactory(source), throwsStateError);
            compactBinding.validate();
            expect(
              find.text(
                patch
                    ? 'Apply Patch: "lib/main.dart" / 2 edits'
                    : 'Run Command: "dart" ["test", "a b; c"]',
              ),
              findsOneWidget,
            );
          }
          expect(source.listening, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'compact patch count is canonical requested count, not applied or diff stats',
    (tester) async {
      final source = _Source(
        _activity(
          arguments: {
            'relativePath': 'a\u202E${'x' * 5000}',
            'edits': List.filled(10000, {
              'search': 'PRIVATE SEARCH',
              'replace': 'PRIVATE REPLACE',
            }),
          },
          kind: ToolActivityKind.completed,
          disposition: ToolOutcomeDisposition.failure,
          data: {'editCount': 999, 'failedEditIndex': 2},
        ),
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(compact(source)));
      expect(find.byType(Text), findsOneWidget);
      expect(find.textContaining('Status:'), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.textContaining('999'), findsNothing);
      final summary = tester.widget<Text>(find.textContaining('Apply Patch:'));
      final title = summary.data!;
      expect(title.length, lessThanOrEqualTo(147));
      expect(title, endsWith('..." / 10000 edits'));
      expect(title, isNot(contains('\u202E')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact direct argv preserves token boundaries and live identity without status details',
    (tester) async {
      final source = _Source(
        _activity(
          patch: false,
          arguments: {
            'program': 'p"\\\u202E',
            'arguments': [
              '',
              '  ',
              'a && b',
              '"\\\n',
              'PRIVATE-OMITTED',
              'more',
            ],
            'workingDirectory': '',
            'timeoutSeconds': 20,
          },
          kind: ToolActivityKind.completed,
          disposition: ToolOutcomeDisposition.success,
          data: {
            'termination': 'exited',
            'exitCode': 7,
            'stdout': 'PRIVATE-OUTPUT',
          },
        ),
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(compact(source)));
      final summary = find.text(
        r'Run Command: "p\"\\\u202E" ["", "  ", "a && b", "\"\\\n"] (2 more arguments)',
      );
      expect(summary, findsOneWidget);
      expect(find.byType(Text), findsOneWidget);
      final element = tester.element(summary);
      expect(find.textContaining('Status:'), findsNothing);
      expect(find.textContaining('Succeeded'), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      final reads = source.reads;
      source.value = _activity(
        patch: false,
        arguments: source.value.canonicalArguments,
        kind: ToolActivityKind.completed,
        disposition: ToolOutcomeDisposition.success,
        data: {'termination': 'timedOut', 'exitCode': null},
      );
      source.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.element(summary), same(element));
      expect(source.reads, reads + 1);
      expect(find.byType(Text), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
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

  test(
    'second-role registration failure rolls back only acquired registrations',
    () async {
      final registry = ExtensionRegistry();
      final blocker = registry.register(
        point: toolActivityCompactPresentationContributions,
        id: ExtensionId('dev.adele.plugin.filesystem-tools.compact'),
        value: ToolActivityCompactPresentationContribution(
          toolId: applyPatchToolId,
          createPresentation: (_) => const SizedBox.shrink(),
        ),
      );
      await expectLater(
        StockToolInspectionFrontend.activateFilesystem(
          extensions: registry,
          artifactPath: filesystemArtifact.path,
        ),
        throwsA(isA<ExtensionRegistrationException>()),
      );
      expect(registry.discover(toolActivityInspectionContributions), isEmpty);
      expect(
        registry.discover(toolActivityCompactPresentationContributions),
        hasLength(1),
      );
      expect(blocker.isClosed, isFalse);
      await blocker.close();
    },
  );

  for (final bool patch in [true, false]) {
    testWidgets(
      'actual ${patch ? 'patch' : 'command'} EVC retains live lifecycle presentation',
      (tester) async {
        final _Source source = _Source(_activity(patch: patch));
        await tester.pumpWidget(_host(presentation(source)));
        expect(
          find.text(patch ? 'Apply Patch' : 'Run Command'),
          findsOneWidget,
        );
        expect(find.text('Status: Prepared'), findsOneWidget);
        expect(find.text('Tool delivery: Pending'), findsOneWidget);
        expect(source.subscriptions, 1);
        final Element retained = tester.element(
          find.text(patch ? 'Apply Patch' : 'Run Command'),
        );

        for (final stage in const [
          (
            kind: ToolActivityKind.approvalRequested,
            label: 'Waiting for approval',
          ),
          (kind: ToolActivityKind.approvalResolved, label: 'approvalResolved'),
          (kind: ToolActivityKind.executionStarted, label: 'Running'),
        ]) {
          final int reads = source.reads;
          source.value = _activity(
            patch: patch,
            kind: stage.kind,
            progress: true,
          );
          source.notifyListeners();
          source.notifyListeners();
          expect(source.reads, reads);
          await tester.pump();
          await tester.pump();
          expect(find.text('Status: ${stage.label}'), findsOneWidget);
          expect(find.text('Lifecycle: ${stage.kind.name}'), findsOneWidget);
          expect(source.reads, reads + 1);
          expect(source.subscriptions, 1);
          expect(
            tester.element(find.text(patch ? 'Apply Patch' : 'Run Command')),
            same(retained),
          );
        }
        source.value = _activity(
          patch: patch,
          kind: ToolActivityKind.completed,
          disposition: ToolOutcomeDisposition.success,
          data: patch
              ? {'newRevision': 'revision-2', 'editCount': 2}
              : {
                  'termination': 'exited',
                  'exitCode': 7,
                  'stdout': 'result',
                  'stderr': '',
                  'stdoutTruncated': false,
                  'stderrTruncated': false,
                },
        );
        source.notifyListeners();
        await tester.pump();
        await tester.pump();
        expect(
          find.text('Status: ${patch ? 'Succeeded' : 'Completed'}'),
          findsOneWidget,
        );
        expect(find.text('Tool delivery: success'), findsOneWidget);
        if (patch) {
          expect(find.text('Relative path: "lib/main.dart"'), findsOneWidget);
          expect(find.text('Edit count: 2'), findsOneWidget);
          expect(find.text('New revision: revision-2'), findsOneWidget);
        } else {
          expect(find.text('Program: "dart"'), findsOneWidget);
          expect(find.text('[0]: "test"'), findsOneWidget);
          expect(find.text('[1]: "a b; c"'), findsOneWidget);
          expect(
            find.text('Working directory: "" (Environment root)'),
            findsOneWidget,
          );
          expect(find.text('Timeout seconds: 120'), findsOneWidget);
          expect(find.text('Process termination: exited'), findsOneWidget);
          expect(find.text('Exit code: 7'), findsOneWidget);
        }
        await tester.pumpWidget(_host(presentation(source)));
        expect(source.subscriptions, 1);
        expect(
          tester.element(find.text(patch ? 'Apply Patch' : 'Run Command')),
          same(retained),
        );
        expect(find.byType(TextButton), findsNothing);
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(tester.takeException(), isNull);
        source.notifyListeners();
        final int reads = source.reads;
        await tester.pumpWidget(const SizedBox.shrink());
        source.notifyListeners();
        await tester.pump();
        expect(source.listening, isFalse);
        expect(source.reads, reads);
        expect(tester.takeException(), isNull);
      },
    );

    for (final disposition in [
      ToolOutcomeDisposition.userRejected,
      ToolOutcomeDisposition.policyDenied,
      ToolOutcomeDisposition.failure,
    ]) {
      testWidgets(
        'actual ${patch ? 'patch' : 'command'} EVC shows ${disposition.name}',
        (tester) async {
          final String code = patch ? 'patch_target_not_found' : 'spawn_failed';
          final _Source source = _Source(
            _activity(
              patch: patch,
              kind: ToolActivityKind.completed,
              disposition: disposition,
              data: disposition == ToolOutcomeDisposition.failure
                  ? {'code': code, if (patch) 'failedEditIndex': 0}
                  : {},
            ),
          );
          await tester.pumpWidget(_host(presentation(source)));
          expect(
            find.text('Tool delivery: ${disposition.name}'),
            findsOneWidget,
          );
          expect(
            find.text(
              'Status: ${switch (disposition) {
                ToolOutcomeDisposition.userRejected => 'User rejected',
                ToolOutcomeDisposition.policyDenied => 'Policy denied',
                _ => 'Failed',
              }}',
            ),
            findsOneWidget,
          );
          if (disposition == ToolOutcomeDisposition.failure) {
            expect(find.text('Failure kind: domain'), findsOneWidget);
            expect(find.text('Failure code: $code'), findsOneWidget);
            if (patch) {
              expect(
                find.text('Failed edit index (zero-based): 0'),
                findsOneWidget,
              );
            }
          }
          if (!patch) {
            expect(
              find.text('Process termination: Not reported'),
              findsOneWidget,
            );
            expect(find.text('Exit code: Not reported'), findsOneWidget);
          }
          expect(find.byType(TextButton), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'actual EVC escapes controls in fields, argv and bounded output',
    (tester) async {
      const String unsafe = 'a\n\r\t\u001b[31m\u202E\u200B\\n';
      final String escaped = inspectionDisplayText(unsafe);
      final _Source source = _Source(
        _activity(
          patch: false,
          kind: ToolActivityKind.completed,
          disposition: ToolOutcomeDisposition.success,
          arguments: {
            'program': unsafe,
            'arguments': [unsafe, '', 'x && y'],
            'workingDirectory': unsafe,
            'timeoutSeconds': 30,
          },
          data: {
            'termination': 'timedOut',
            'exitCode': null,
            'stdout': '$unsafe${'x' * 5000}HIDDEN-END',
            'stderr': unsafe,
            'stdoutTruncated': true,
            'stderrTruncated': false,
          },
        ),
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(presentation(source)));
      expect(find.text('Program: "$escaped"'), findsOneWidget);
      expect(find.text('[0]: "$escaped"'), findsOneWidget);
      expect(find.text('[1]: ""'), findsOneWidget);
      expect(find.text('[2]: "x && y"'), findsOneWidget);
      expect(find.text('Working directory: "$escaped"'), findsOneWidget);
      expect(find.text('Process termination: timedOut'), findsOneWidget);
      expect(find.text('Tool delivery: success'), findsOneWidget);
      expect(find.text('Exit code: Not reported'), findsOneWidget);
      expect(find.text('stdout truncated: true'), findsOneWidget);
      expect(find.text('stderr truncated: false'), findsOneWidget);
      expect(find.text('stdout preview truncated.'), findsOneWidget);
      expect(find.text('stderr preview: $escaped'), findsOneWidget);
      expect(find.textContaining('HIDDEN-END'), findsNothing);
      for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data, isNot(contains('\u001b')));
        expect(text.data, isNot(contains('\u202E')));
        expect(text.data, isNot(contains('\n')));
      }
      expect(source.value.canonicalArguments['program'], unsafe);
      expect(tester.takeException(), isNull);

      final _Source patch = _Source(
        _activity(
          arguments: {'relativePath': unsafe, 'edits': []},
          kind: ToolActivityKind.completed,
          disposition: ToolOutcomeDisposition.failure,
          data: {'newRevision': unsafe, 'code': unsafe},
          content: unsafe,
        ),
      );
      await tester.pumpWidget(_host(presentation(patch)));
      expect(find.text('Relative path: "$escaped"'), findsOneWidget);
      expect(find.text('New revision: $escaped'), findsOneWidget);
      expect(find.text('Failure code: $escaped'), findsOneWidget);
      expect(find.text('Outcome: $escaped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual EVC preserves empty, whitespace and quoted argument boundaries',
    (tester) async {
      const List<String> argv = [
        '',
        '   ',
        'value ',
        ' value',
        '"',
        r'\"',
        'x && y',
      ];
      final _Source source = _Source(
        _activity(
          patch: false,
          arguments: {
            'program': ' program" ',
            'arguments': argv,
            'workingDirectory': r' directory\" ',
            'timeoutSeconds': 30,
          },
        ),
      );
      await tester.pumpWidget(_host(presentation(source)));
      for (final String line in [
        '[0]: ""',
        '[1]: "   "',
        '[2]: "value "',
        '[3]: " value"',
        r'[4]: "\""',
        r'[5]: "\\\""',
        '[6]: "x && y"',
        r'Program: " program\" "',
        r'Working directory: " directory\\\" "',
      ]) {
        expect(find.text(line), findsOneWidget);
      }
      expect(find.textContaining('Arguments (direct argv)'), findsOneWidget);
      expect(source.value.canonicalArguments['arguments'], orderedEquals(argv));
      expect(tester.takeException(), isNull);

      final _Source patch = _Source(
        _activity(arguments: {'relativePath': r' file\" ', 'edits': []}),
      );
      await tester.pumpWidget(_host(presentation(patch)));
      expect(find.text(r'Relative path: " file\\\" "'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stock activations and simultaneous presenters retire independently',
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

  testWidgets('actual Chat summary first-mounts one-edit waiting patch EVC', (
    tester,
  ) async {
    final PreparedFrontend chat = (await tester.runAsync(
      () => PreparedFrontend.load(chatArtifact),
    ))!;
    addTearDown(chat.invalidate);
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
          sessionId: SessionId('chat-session'),
          runId: RunId('chat-run'),
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
    final _InspectionChatSource source = _InspectionChatSource(() {
      rebuild(() => selected = true);
    });
    addTearDown(source.dispose);
    final Widget chatView = chat.createChatPresentation(
      source: source,
      isActive: () => true,
      buildActivity: (id) => id == 'group'
          ? TextButton(
              onPressed: () => source.inspectActivity(id),
              child: const Text('ACTIVITY: Update and validate'),
            )
          : null,
    );
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (_, setState) {
            rebuild = setState;
            return Column(
              children: [
                chatView,
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
    final Element chatElement = tester.element(find.text('Chat'));
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
    expect(tester.element(find.text('Chat')), same(chatElement));
    expect(activity.tools.single, same(patch));
    expect(patch.outcome, isNull);
    expect(tester.takeException(), isNull);
  });

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
      await expectLater(
        StockToolInspectionFrontend.activateFilesystem(
          extensions: extensions,
          artifactPath: '',
        ),
        throwsStateError,
      );
      await tester.runAsync(() async {
        await expectLater(
          StockToolInspectionFrontend.activateFilesystem(
            extensions: extensions,
            artifactPath: '${temporary.path}/missing.evc',
          ),
          throwsStateError,
        );
      });
      expect(
        extensions.discover(toolActivityInspectionContributions),
        hasLength(1),
      );
      final _Source process = _Source(_activity(patch: false));
      await tester.pumpWidget(_host(presentation(process)));
      expect(find.text('Run Command'), findsOneWidget);
      filesystem = (await tester.runAsync(() async {
        final File corrupt = File('${temporary.path}/corrupt.evc');
        await corrupt.writeAsBytes([1, 2, 3]);
        return StockToolInspectionFrontend.activateFilesystem(
          extensions: extensions,
          artifactPath: corrupt.path,
        );
      }))!;
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

class _InspectionChatSource extends ChangeNotifier
    implements ChatFrontendSource {
  _InspectionChatSource(this.openInspection);

  final VoidCallback openInspection;

  @override
  ChatPresentationSnapshot get snapshot => ChatPresentationSnapshot(
    entries: const [
      ChatPresentationEntry.activity(
        id: 'group',
        content: 'Update and validate',
      ),
    ],
    canSubmit: false,
  );

  @override
  bool submit(String prompt) => false;

  @override
  bool inspectActivity(String id) {
    if (id != 'group') return false;
    openInspection();
    return true;
  }
}
