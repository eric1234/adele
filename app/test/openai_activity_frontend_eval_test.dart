import 'dart:io';

import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/plugins/stock_openai_activity_frontend.dart';
import 'package:adele_desktop/plugins/stock_tool_inspection_frontends.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_native_activity/openai_native_activity.dart';

import '../tool/openai_activity_frontend_compiler.dart';
import '../tool/tool_inspection_frontend_compiler.dart';

const String _library = 'package:openai_frontend/openai_frontend.dart';
const String _secret = 'ENCRYPTED-PRIVATE-SECRET';

void main() {
  late Directory temporary;
  late File artifact;
  late File commandArtifact;
  late File filesystemArtifact;
  late File failingArtifact;
  late Program probe;
  late ExtensionRegistry extensions;
  late StockOpenAiActivityFrontendActivation openai;
  late StockToolInspectionFrontend command;
  late StockToolInspectionFrontend filesystem;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-openai-activity-');
    final root = Directory.current.parent;
    artifact = File('${temporary.path}/openai.evc');
    await artifact.writeAsBytes(
      await compileOpenAiActivityFrontend(repositoryRoot: root),
    );
    commandArtifact = File('${temporary.path}/command.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: root,
      artifact: commandArtifact,
      frontend: ToolInspectionFrontend.command,
    );
    filesystemArtifact = File('${temporary.path}/filesystem.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: root,
      artifact: filesystemArtifact,
      frontend: ToolInspectionFrontend.filesystem,
    );
    failingArtifact = File('${temporary.path}/failing.evc');
    final failing =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const ModelNativeActivityDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'openai_frontend': {'openai_frontend.dart': _failingFrontend},
            });
    await failingArtifact.writeAsBytes(failing.write());
    probe =
        (Compiler()
              ..addPlugin(const ModelNativeActivityDeclarations())
              ..entrypoints.add('package:probe/main.dart'))
            .compile({
              'probe': {
                'main.dart': '''
import 'package:adele_ui/model_native_activity_bridge.dart';
Map<String, dynamic> inspect() => readModelNativeActivityData();
''',
              },
            });
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    openai = await activateStockOpenAiActivityFrontend(
      extensions: extensions,
      artifactPath: artifact.path,
    );
    command = await StockToolInspectionFrontend.activateCommand(
      extensions: extensions,
      artifactPath: commandArtifact.path,
    );
    filesystem = await StockToolInspectionFrontend.activateFilesystem(
      extensions: extensions,
      artifactPath: filesystemArtifact.path,
    );
  });
  tearDown(() async {
    await openai.close();
    await command.close();
    await filesystem.close();
  });

  ModelNativeActivityPresentationContribution contribution() => extensions
      .discover(modelNativeActivityPresentationContributions)
      .single
      .value;

  for (final compactionOnly in [false, true]) {
    testWidgets(
      compactionOnly
          ? 'common Inspection omits compaction beside an interpreted tool'
          : 'common Inspection orders real OpenAI, Filesystem, OpenAI, Command EVCs',
      (tester) async {
        final modelId = ModelInvocationId('ordered-model');
        final patch = ToolInvocationActivity(
          id: ToolInvocationId('patch'),
          preparedSequence: 10,
          modelInvocationId: modelId,
          proposalSequence: 3,
          toolId: applyPatchToolId,
          alias: 'apply_patch',
          providerCallId: 'shared-provider-call',
          canonicalArguments: const {
            'relativePath': 'example.txt',
            'expectedRevision': 'revision',
            'edits': [
              {'oldText': 'before', 'newText': 'after'},
            ],
          },
          changes: const [],
        );
        final process = ToolInvocationActivity(
          id: ToolInvocationId('command'),
          preparedSequence: 11,
          modelInvocationId: modelId,
          proposalSequence: 5,
          toolId: runCommandToolId,
          alias: 'run_command',
          providerCallId: 'shared-provider-call',
          canonicalArguments: const {
            'program': 'dart',
            'arguments': ['test'],
            'workingDirectory': '',
            'timeoutSeconds': 30,
          },
          changes: const [],
        );
        final tools = [if (!compactionOnly) process, patch];
        final outputs = [
          ModelOutputActivity(
            sequence: 2,
            item: _output([
              compactionOnly ? 'Never present compaction' : 'Reasoning A',
            ], type: compactionOnly ? 'compaction' : 'reasoning'),
          ),
          if (!compactionOnly)
            ModelOutputActivity(sequence: 4, item: _output(['Reasoning B'])),
          for (final tool in tools)
            ModelOutputActivity(
              sequence: tool.proposalSequence,
              item: ModelToolProposalOutput(
                ProviderToolProposal(
                  providerCallId: 'shared-provider-call',
                  alias: tool.alias,
                  arguments: tool.canonicalArguments,
                ),
              ),
            ),
        ];
        final activity = RunActivitySnapshot(
          runId: RunId('ordered-run'),
          sessionId: SessionId('ordered-session'),
          state: RunState.waiting,
          sequence: 11,
          models: [
            ModelInvocationActivity(
              id: modelId,
              startSequence: 1,
              settlement: ModelSettlement.completed,
              terminalSequence: 6,
              // Sequence, not input-list order or repeated provider IDs, is authoritative.
              outputs: outputs,
            ),
          ],
          tools: tools,
          rejectedProposals: const [],
        );
        await tester.pumpWidget(
          _host([
            InspectionHost(
              selection: ActivityInspectionSelection(
                sessionId: activity.sessionId,
                runId: activity.runId,
                modelInvocationId: modelId,
              ),
              activity: activity,
              heading: 'Direct ordered activity',
              extensions: extensions,
              onClose: () {},
            ),
          ]),
        );
        final labels = compactionOnly
            ? ['Apply Patch']
            : ['Reasoning A', 'Apply Patch', 'Reasoning B', 'Run Command'];
        double previous = -1;
        for (final label in labels) {
          final finder = find.text(label);
          expect(finder, findsOneWidget);
          final y = tester.getTopLeft(finder).dy;
          expect(y, greaterThan(previous));
          previous = y;
        }
        expect(
          find.text('Reasoning summary'),
          findsNWidgets(compactionOnly ? 0 : 2),
        );
        expect(find.text('Never present compaction'), findsNothing);
        expect(find.textContaining('Model native activity'), findsNothing);
        expect(find.textContaining(_secret), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'compact Chat text escapes controls and remains bounded after escaping',
    () {
      for (final text in [
        'Unicode \u00E9 \u{1F600}\n\r\t\u001B\u202E\u200B\\n',
        'Unicode \u00E9 \u{1F600} ${List.filled(150, '\u202E').join()}',
      ]) {
        final output = _output([text]);
        final projected = contribution().project(output)!;
        final escaped = inspectionDisplayText(
          projectOpenAiReasoningSummary(
            output.providerNativeMetadata,
          )!.compactText,
        );
        expect(projected.compactText, startsWith('Unicode \u00E9 \u{1F600}'));
        expect(projected.compactText.runes.length, lessThanOrEqualTo(160));
        for (final control in [
          '\n',
          '\r',
          '\t',
          '\u001B',
          '\u202E',
          '\u200B',
        ]) {
          expect(projected.compactText, isNot(contains(control)));
        }
        expect(
          projected.compactText,
          escaped.runes.length <= 160
              ? escaped
              : '${String.fromCharCodes(escaped.runes.take(159))}\u2026',
        );
        expect(projected.data, {
          'summaryParts': [text],
          'truncated': false,
        });
      }
    },
  );

  for (final parts in <List<String>>[
    ['One approved summary'],
    [
      'First: \u00E9 e\u0301 \u{1F600}',
      'Second\n\r\t\u001b[31m\u202E\u200B\\n',
      'Third\u200D\u{E007F}',
    ],
  ]) {
    testWidgets(
      'actual EVC renders ${parts.length} parts in order and escapes controls',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final output = _output(parts);
        final presenter = contribution();
        expect(presenter.nativeKind, openAiResponsesItemKind);
        final projected = presenter.project(output)!;
        expect(projected.data, {'summaryParts': parts, 'truncated': false});
        final bridge = ModelNativeActivityBridge(
          projection: projected,
          isActive: () => true,
        );
        addTearDown(bridge.invalidate);
        final runtime = Runtime(probe.write().buffer.asByteData())
          ..addPlugin(bridge);
        final transported =
            runtime.executeLib('package:probe/main.dart', 'inspect') as $Value;
        expect(transported.$reified, projected.data);
        expect(transported.$reified.toString(), isNot(contains(_secret)));
        expect((transported.$reified as Map).keys, [
          'summaryParts',
          'truncated',
        ]);

        await tester.pumpWidget(_host([presenter.createInspection(projected)]));
        expect(find.text('Reasoning summary'), findsOneWidget);
        double previous = -1;
        for (final part in parts) {
          final finder = find.text(inspectionDisplayText(part));
          expect(finder, findsOneWidget);
          final y = tester.getTopLeft(finder).dy;
          expect(y, greaterThan(previous));
          previous = y;
        }
        expect(find.text('Reasoning summary truncated.'), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(find.byType(TextField), findsNothing);
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          expect(text.data, isNot(contains(_secret)));
          expect(text.data, isNot(contains('\u202E')));
          expect(text.data, isNot(contains('\n')));
        }
        expect(
          output.providerNativeMetadata.data.toString(),
          contains(_secret),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('actual projector truncation stays visible in EVC', (
    tester,
  ) async {
    final projected = contribution().project(
      _output(List.filled(129, 'Part')),
    )!;
    expect(projected.data['truncated'], true);
    await tester.pumpWidget(
      _host([contribution().createInspection(projected)]),
    );
    expect(find.text('Part'), findsNWidgets(128));
    expect(find.text('Reasoning summary truncated.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'stock projection declines unsupported and encrypted-only native output',
    () {
      for (final output in [
        _output([]),
        _output(['Approved'], kind: 'other.native'),
        _output(['Approved'], version: 2),
        _output(['Approved'], type: 'message'),
      ]) {
        expect(contribution().project(output), isNull);
      }
    },
  );

  testWidgets(
    'actual EVC rejects malformed safe maps without echoing any part',
    (tester) async {
      for (final data in <Map<String, Object?>>[
        {},
        {'summaryParts': _secret, 'truncated': false},
        {'summaryParts': <String>[], 'truncated': false},
        {
          'summaryParts': [_secret],
          'truncated': 'false',
        },
        {
          'summaryParts': [_secret, 7],
          'truncated': false,
        },
        {
          'summaryParts': [_secret, '  '],
          'truncated': false,
        },
        {
          'summaryParts': [_secret],
          'truncated': false,
          'unexpected': _secret,
        },
        {'summaryParts': List.filled(129, _secret), 'truncated': false},
        {
          'summaryParts': ['${'x' * 65537}$_secret'],
          'truncated': false,
        },
      ]) {
        final projected = ModelNativeActivityProjection(
          compactText: _secret,
          data: data,
        );
        await tester.pumpWidget(
          _host([contribution().createInspection(projected)]),
        );
        expect(find.text('Reasoning summary unavailable.'), findsOneWidget);
        expect(find.text('Reasoning summary'), findsNothing);
        expect(find.textContaining(_secret), findsNothing);
        expect(
          tester.widgetList<Text>(find.byType(Text)).map((text) => text.data),
          ['Reasoning summary unavailable.'],
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'retired OpenAI views never migrate and tool presentation stays live',
    (tester) async {
      final binding = extensions
          .discover(modelNativeActivityPresentationContributions)
          .single;
      final retained = binding.value;
      final first = retained.project(_output(['First view']))!;
      final second = retained.project(_output(['Second view']))!;
      final source = _CommandSource();
      addTearDown(source.dispose);
      final toolView = ToolActivityInspectionResolver(
        extensions,
      ).resolve(runCommandToolId).value.createPresentation(source);
      final views = [
        retained.createInspection(first),
        retained.createInspection(second),
        toolView,
      ];
      await tester.pumpWidget(_host(views));
      final toolElement = tester.element(find.text('Run Command'));
      expect(find.text('Reasoning summary'), findsNWidgets(2));
      await tester.runAsync(() async {
        final closing = openai.close();
        expect(openai.close(), same(closing));
        await closing;
      });
      await tester.pump();
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.createInspection(first), throwsStateError);
      expect(() => retained.project(_output(['Late'])), throwsStateError);
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(tester.element(find.text('Run Command')), same(toolElement));
      expect(source.listening, isTrue);
      openai = (await tester.runAsync(
        () => activateStockOpenAiActivityFrontend(
          extensions: extensions,
          artifactPath: artifact.path,
        ),
      ))!;
      final fresh = contribution().project(_output(['Fresh generation']))!;
      await tester.pumpWidget(
        _host([...views, contribution().createInspection(fresh)]),
      );
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(find.text('Fresh generation'), findsOneWidget);
      expect(tester.element(find.text('Run Command')), same(toolElement));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing, corrupt and failed OpenAI EVC leave tool presenter independent',
    (tester) async {
      final source = _CommandSource();
      addTearDown(source.dispose);
      final toolView = ToolActivityInspectionResolver(
        extensions,
      ).resolve(runCommandToolId).value.createPresentation(source);
      await tester.pumpWidget(_host([const SizedBox.shrink(), toolView]));
      final toolElement = tester.element(find.text('Run Command'));
      await tester.runAsync(openai.close);
      for (final path in ['', '${temporary.path}/missing.evc']) {
        await tester.runAsync(
          () => expectLater(
            activateStockOpenAiActivityFrontend(
              extensions: extensions,
              artifactPath: path,
            ),
            throwsStateError,
          ),
        );
        expect(
          extensions.discover(modelNativeActivityPresentationContributions),
          isEmpty,
        );
      }
      final missing = (await tester.runAsync(
        () => PreparedFrontend.load(File('${temporary.path}/missing.evc')),
      ))!;
      addTearDown(missing.invalidate);
      await tester.pumpWidget(
        _host([
          missing.createPresentation(
            library: _library,
            entrypoint: 'buildOpenAiReasoningInspection',
            createBridge: () =>
                throw StateError('Must not create a missing bridge'),
          ),
          toolView,
        ]),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);

      final corrupt = File('${temporary.path}/corrupt.evc');
      await tester.runAsync(() => corrupt.writeAsBytes([1, 2, 3]));
      for (final file in [corrupt, failingArtifact]) {
        openai = (await tester.runAsync(
          () => activateStockOpenAiActivityFrontend(
            extensions: extensions,
            artifactPath: file.path,
          ),
        ))!;
        final projected = contribution().project(
          _output(['Not a native fallback']),
        )!;
        await tester.pumpWidget(
          _host([contribution().createInspection(projected), toolView]),
        );
        await tester.pump();
        expect(find.text('Frontend unavailable.'), findsOneWidget);
        expect(find.text('Not a native fallback'), findsNothing);
        expect(find.textContaining('PRIVATE-BUILD-ERROR'), findsNothing);
        expect(tester.element(find.text('Run Command')), same(toolElement));
        expect(source.listening, isTrue);
        if (file == failingArtifact) {
          final sibling = contribution().project(
            _output(['Healthy OpenAI sibling']),
          )!;
          await tester.pumpWidget(
            _host([
              contribution().createInspection(projected),
              toolView,
              contribution().createInspection(sibling),
            ]),
          );
          expect(find.text('Frontend unavailable.'), findsOneWidget);
          expect(find.text('Healthy OpenAI sibling'), findsOneWidget);
          expect(tester.element(find.text('Run Command')), same(toolElement));
        }
        source.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Program: "dart"'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(openai.close);
      }
    },
  );
}

Widget _host(List<Widget> children) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: Column(children: children)),
  ),
);

ModelNativeOutput _output(
  List<String> parts, {
  String kind = openAiResponsesItemKind,
  int version = 1,
  String type = 'reasoning',
}) => ModelNativeOutput(
  providerItemId: 'private-item-id',
  providerNativeMetadata: ModelNativeEnvelope(
    kind: kind,
    compatibility: {'version': version, 'private': _secret},
    data: {
      'item': {
        'type': type,
        'id': 'private-item-id',
        'summary': [
          for (final text in parts)
            {'type': 'summary_text', 'text': text, 'private': _secret},
        ],
        'encrypted_content': _secret,
        'content': _secret,
        'unknown': _secret,
      },
      'private': _secret,
    },
  ),
);

class _CommandSource extends ChangeNotifier
    implements ToolActivityInspectionSource {
  bool get listening => hasListeners;

  @override
  final ToolInvocationActivity snapshot = ToolInvocationActivity(
    id: ToolInvocationId('command-1'),
    preparedSequence: 3,
    modelInvocationId: ModelInvocationId('model-1'),
    proposalSequence: 2,
    toolId: runCommandToolId,
    alias: 'run_command',
    providerCallId: 'call-1',
    canonicalArguments: const {
      'program': 'dart',
      'arguments': ['test'],
      'workingDirectory': '',
      'timeoutSeconds': 30,
    },
    changes: const [],
  );
}

const String _failingFrontend = '''
import 'package:adele_ui/model_native_activity_bridge.dart';
import 'package:flutter/material.dart';
Widget buildOpenAiReasoningInspection() => BrokenInspection();
class BrokenInspection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final String text = readModelNativeActivityData()['summaryParts'][0];
    if (text == 'Not a native fallback') throw StateError('PRIVATE-BUILD-ERROR');
    return Text(text);
  }
}
''';
