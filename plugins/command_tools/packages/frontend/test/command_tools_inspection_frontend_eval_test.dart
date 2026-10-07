import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../../app/test/support/prepared_frontend_installations.dart';
import '../../../../../app/tool/tool_inspection_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File commandArtifact;
  late Directory installations;
  late ExtensionRegistry extensions;
  late ApplicationFrontendBootstrap frontends;
  late InstalledFrontendActivation command;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'command_tools-inspection-',
    );
    commandArtifact = File('${temporary.path}/command.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
      artifact: commandArtifact,
      frontend: ToolInspectionFrontend.command,
    );
    installations = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/installed'),
      artifacts: {'dev.adele.plugin.command-tools': commandArtifact},
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    final catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
    frontends = ApplicationFrontendBootstrap(extensions: extensions);
    await frontends.start(catalog);
    expect(frontends.generations, hasLength(1));
    expect(
      frontends.generations.map((generation) => generation.state),
      everyElement(InstalledFrontendState.active),
    );
    command = frontends.generations.single;
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
    'same command artifact has independent live compact and rich views',
    (tester) async {
      final source = _Source(_activity());
      await tester.pumpWidget(
        _host(Column(children: [compact(source), presentation(source)])),
      );
      expect(find.text('Run Command'), findsOneWidget);
      final title = find.text('Run Command: "dart" ["test", "a b; c"]');
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
      'command ${retireCompact ? 'compact' : 'rich'} retirement leaves sibling live',
      (tester) async {
        final source = _Source(_activity());
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
        await command.retire(
          retireCompact
              ? toolActivityCompactPresentationContributions
              : toolActivityInspectionContributions,
          retireCompact ? compactBinding.id : richBinding.id,
        );
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
          expect(find.text('Run Command'), findsOneWidget);
        } else {
          expect(richBinding.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(() => richFactory(source), throwsStateError);
          compactBinding.validate();
          expect(
            find.text('Run Command: "dart" ["test", "a b; c"]'),
            findsOneWidget,
          );
        }
        expect(source.listening, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('actual command EVC retains live lifecycle presentation', (
    tester,
  ) async {
    final _Source source = _Source(_activity());
    await tester.pumpWidget(_host(presentation(source)));
    expect(find.text('Run Command'), findsOneWidget);
    expect(find.text('Status: Prepared'), findsOneWidget);
    expect(find.text('Tool delivery: Pending'), findsOneWidget);
    expect(source.subscriptions, 1);
    final Element retained = tester.element(find.text('Run Command'));

    for (final stage in const [
      (kind: ToolActivityKind.approvalRequested, label: 'Waiting for approval'),
      (kind: ToolActivityKind.approvalResolved, label: 'approvalResolved'),
      (kind: ToolActivityKind.executionStarted, label: 'Running'),
    ]) {
      final int reads = source.reads;
      source.value = _activity(kind: stage.kind, progress: true);
      source.notifyListeners();
      source.notifyListeners();
      expect(source.reads, reads);
      await tester.pump();
      await tester.pump();
      expect(find.text('Status: ${stage.label}'), findsOneWidget);
      expect(find.text('Lifecycle: ${stage.kind.name}'), findsOneWidget);
      expect(source.reads, reads + 1);
      expect(source.subscriptions, 1);
      expect(tester.element(find.text('Run Command')), same(retained));
    }
    source.value = _activity(
      kind: ToolActivityKind.completed,
      disposition: ToolOutcomeDisposition.success,
      data: {
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
    expect(find.text('Status: Completed'), findsOneWidget);
    expect(find.text('Tool delivery: success'), findsOneWidget);

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

    await tester.pumpWidget(_host(presentation(source)));
    expect(source.subscriptions, 1);
    expect(tester.element(find.text('Run Command')), same(retained));
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
  });

  for (final disposition in [
    ToolOutcomeDisposition.userRejected,
    ToolOutcomeDisposition.policyDenied,
    ToolOutcomeDisposition.failure,
  ]) {
    testWidgets('actual command EVC shows ${disposition.name}', (tester) async {
      final String code = 'spawn_failed';
      final _Source source = _Source(
        _activity(
          kind: ToolActivityKind.completed,
          disposition: disposition,
          data: disposition == ToolOutcomeDisposition.failure
              ? {'code': code}
              : {},
        ),
      );
      await tester.pumpWidget(_host(presentation(source)));
      expect(find.text('Tool delivery: ${disposition.name}'), findsOneWidget);
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

        expect(find.text('Failure detail: Tool outcome.'), findsOneWidget);
      }

      expect(find.text('Process termination: Not reported'), findsOneWidget);
      expect(find.text('Exit code: Not reported'), findsOneWidget);

      expect(find.byType(TextButton), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'compact direct argv preserves token boundaries and live identity without status details',
    (tester) async {
      final source = _Source(
        _activity(
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
    'actual EVC escapes metadata and omits duplicate plaintext model output',
    (tester) async {
      const String unsafe = 'a\n\r\t\u001b[31m\u202E\u200B\\n';
      final String escaped = inspectionDisplayText(unsafe);
      final _Source source = _Source(
        _activity(
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
      expect(find.textContaining('Bounded model result'), findsNothing);
      expect(find.textContaining('stdout'), findsNothing);
      expect(find.textContaining('stderr'), findsNothing);
      expect(find.textContaining('HIDDEN-END'), findsNothing);
      for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data, isNot(contains('\u001b')));
        expect(text.data, isNot(contains('\u202E')));
        expect(text.data, isNot(contains('\n')));
      }
      expect(source.value.canonicalArguments['program'], unsafe);
      expect(
        source.value.outcome!.hostData['stdout'],
        '$unsafe${'x' * 5000}HIDDEN-END',
      );
      expect(source.value.outcome!.hostData['stderr'], unsafe);
      expect(source.value.outcome!.hostData['stdoutTruncated'], isTrue);
      expect(source.value.outcome!.modelContent, 'Tool outcome.');
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
    },
  );
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

ToolInvocationActivity _activity({
  int proposalSequence = 1,
  ToolActivityKind kind = ToolActivityKind.prepared,
  bool progress = false,
  ToolOutcomeDisposition? disposition,
  Map<String, Object?>? arguments,
  Map<String, Object?> data = const {},
  String content = 'Tool outcome.',
}) => ToolInvocationActivity(
  id: ToolInvocationId('command-1'),
  preparedSequence: proposalSequence + 10,
  modelInvocationId: ModelInvocationId('model-1'),
  proposalSequence: proposalSequence,
  toolId: runCommandToolId,
  alias: 'run_command',
  providerCallId: 'call-1',
  canonicalArguments:
      arguments ??
      {
        'program': 'dart',
        'arguments': ['test', 'a b; c'],
        'workingDirectory': '',
        'timeoutSeconds': 120,
      },
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
