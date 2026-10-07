import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../../app/test/support/prepared_frontend_installations.dart';
import '../../../../../app/tool/tool_inspection_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File filesystemArtifact;
  late Directory installations;
  late ExtensionRegistry extensions;
  late ApplicationFrontendBootstrap frontends;
  late InstalledFrontendActivation filesystem;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'filesystem_tools-inspection-',
    );
    filesystemArtifact = File('${temporary.path}/filesystem.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
      artifact: filesystemArtifact,
      frontend: ToolInspectionFrontend.filesystem,
    );
    installations = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/installed'),
      artifacts: {'dev.adele.plugin.filesystem-tools': filesystemArtifact},
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
    filesystem = frontends.generations.single;
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
    'same patch artifact has independent live compact and rich views',
    (tester) async {
      final source = _Source(_activity());
      await tester.pumpWidget(
        _host(Column(children: [compact(source), presentation(source)])),
      );
      expect(find.text('Apply Patch'), findsOneWidget);
      final title = find.text('Apply Patch: "lib/main.dart" / 2 edits');
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
      'patch ${retireCompact ? 'compact' : 'rich'} retirement leaves sibling live',
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
        await filesystem.retire(
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
          expect(find.text('Apply Patch'), findsOneWidget);
        } else {
          expect(richBinding.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(() => richFactory(source), throwsStateError);
          compactBinding.validate();
          expect(
            find.text('Apply Patch: "lib/main.dart" / 2 edits'),
            findsOneWidget,
          );
        }
        expect(source.listening, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('actual patch EVC retains live lifecycle presentation', (
    tester,
  ) async {
    final _Source source = _Source(_activity());
    await tester.pumpWidget(_host(presentation(source)));
    expect(find.text('Apply Patch'), findsOneWidget);
    expect(find.text('Status: Prepared'), findsOneWidget);
    expect(find.text('Tool delivery: Pending'), findsOneWidget);
    expect(source.subscriptions, 1);
    final Element retained = tester.element(find.text('Apply Patch'));

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
      expect(tester.element(find.text('Apply Patch')), same(retained));
    }
    source.value = _activity(
      kind: ToolActivityKind.completed,
      disposition: ToolOutcomeDisposition.success,
      data: {'newRevision': 'revision-2', 'editCount': 2},
    );
    source.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(find.text('Status: Succeeded'), findsOneWidget);
    expect(find.text('Tool delivery: success'), findsOneWidget);

    expect(find.text('Relative path: "lib/main.dart"'), findsOneWidget);
    expect(find.text('Edit count: 2'), findsOneWidget);
    expect(find.text('New revision: revision-2'), findsOneWidget);

    await tester.pumpWidget(_host(presentation(source)));
    expect(source.subscriptions, 1);
    expect(tester.element(find.text('Apply Patch')), same(retained));
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
    testWidgets('actual patch EVC shows ${disposition.name}', (tester) async {
      final String code = 'patch_target_not_found';
      final _Source source = _Source(
        _activity(
          kind: ToolActivityKind.completed,
          disposition: disposition,
          data: disposition == ToolOutcomeDisposition.failure
              ? {'code': code, 'failedEditIndex': 0}
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

        expect(find.text('Failed edit index (zero-based): 0'), findsOneWidget);
      }

      expect(find.byType(TextButton), findsNothing);
      expect(tester.takeException(), isNull);
    });
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

  test(
    'second-role registration failure rolls back only acquired registrations',
    () async {
      final registry = ExtensionRegistry();
      final blocker = registry.register(
        point: toolActivityCompactPresentationContributions,
        id: ToolActivityCompactPresentationResolver(
          extensions,
        ).resolve(applyPatchToolId).id,
        value: ToolActivityCompactPresentationContribution(
          toolId: applyPatchToolId,
          createPresentation: (_) => const SizedBox.shrink(),
        ),
      );
      final root = await prepareFrontendInstallations(
        root: Directory('${temporary.path}/collision'),
        artifacts: {'dev.adele.plugin.filesystem-tools': filesystemArtifact},
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final bootstrap = ApplicationFrontendBootstrap(extensions: registry);
      addTearDown(bootstrap.close);
      await bootstrap.start(catalog);
      expect(bootstrap.generations.single.state, InstalledFrontendState.failed);
      expect(
        bootstrap.generations.single.failure,
        isA<ExtensionRegistrationException>(),
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

  testWidgets('actual patch EVC escapes metadata and outcome text', (
    tester,
  ) async {
    const String unsafe = 'a\n\r\t\u001b[31m\u202E\u200B\\n';
    final String escaped = inspectionDisplayText(unsafe);
    final _Source patch = _Source(
      _activity(
        arguments: {'relativePath': unsafe, 'edits': []},
        kind: ToolActivityKind.completed,
        disposition: ToolOutcomeDisposition.failure,
        data: {'newRevision': unsafe, 'code': unsafe},
        content: unsafe,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(presentation(patch)));
    expect(find.text('Relative path: "$escaped"'), findsOneWidget);
    expect(find.text('New revision: $escaped'), findsOneWidget);
    expect(find.text('Failure code: $escaped'), findsOneWidget);
    expect(find.text('Outcome: $escaped'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'actual patch EVC preserves whitespace and quoted path boundaries',
    (tester) async {
      final _Source patch = _Source(
        _activity(arguments: {'relativePath': r' file\" ', 'edits': []}),
      );
      await tester.pumpWidget(_host(presentation(patch)));
      expect(find.text(r'Relative path: " file\\\" "'), findsOneWidget);
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
  id: ToolInvocationId('patch-1'),
  preparedSequence: proposalSequence + 10,
  modelInvocationId: ModelInvocationId('model-1'),
  proposalSequence: proposalSequence,
  toolId: applyPatchToolId,
  alias: 'apply_patch',
  providerCallId: 'call-1',
  canonicalArguments:
      arguments ??
      {
        'relativePath': 'lib/main.dart',
        'expectedRevision': 'revision-1',
        'edits': [
          {'search': 'a', 'replace': 'b'},
          {'search': 'c', 'replace': 'd'},
        ],
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
