import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/editor/native_rich_document_editor.dart';
import 'package:adele_desktop/editor/rich_document_markdown.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/rich_document_editor_bridge.dart';
import 'package:adele_desktop/frontend/scroll_view_bridge.dart';
import 'package:adele_desktop/frontend/session_content_inspection_bridge.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/main_content/main_content_controller.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/test/support/markdown_paste_fixture.dart';
import '../../../../../app/tool/chat_frontend_compiler.dart';
import '../../../../../tools/stock_frontend_descriptors.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;
  late _Source source;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-chat-eval-');
    artifact = File('${temporary.path}/chat.evc');
    await compileChatFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
      artifact: artifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    source = _Source();
    addTearDown(generation.invalidate);
  });

  test('stock Chat declares compact content and retrieval-only Inspection', () {
    expect(stockFrontendDescriptors[chatStrategyPluginId.value], [
      {
        'role': 'mainContent',
        'library': chatFrontendLibrary,
        'extensionId': 'dev.adele.plugin.chat-strategy.presentation',
        'order': 100,
        'initialize': 'initializeChatMainContent',
        'entrypoint': 'buildChat',
        'sessionExecution': true,
        'richDocumentEditor': true,
        'canInspectSessionContent': true,
        'backendServices': [chatSessionServiceId],
        'strategyAffinity': 'owningBackend',
      },
      {
        'role': 'sessionContentInspection',
        'library': chatFrontendLibrary,
        'extensionId': 'dev.adele.plugin.chat-strategy.feedback-inspection',
        'contentKind': chatFeedbackInspectionKind,
        'entrypoint': 'buildChatFeedbackInspection',
        'backendServices': [chatFeedbackInspectionServiceId],
      },
    ]);
    expect(
      stockFrontendDescriptors.values
          .expand((values) => values)
          .where((value) => value['canInspectSessionContent'] == true),
      hasLength(1),
    );
  });

  for (final matching in [true, false]) {
    for (final backendAvailable in [true, false]) {
      testWidgets(
        'compiled Chat initializer ${matching ? 'opens one pane' : 'opens nothing'} '
        'with backend ${backendAvailable ? 'present' : 'absent'}',
        (tester) async {
          final extensions = ExtensionRegistry();
          final session = Session(
            id: SessionId('session-opaque'),
            taskId: TaskId('task'),
            strategyId: matching
                ? chatStrategyId
                : OrchestrationStrategyId('test.independent'),
          );
          final controller = MainContentController(
            session: session,
            extensions: extensions,
          );
          addTearDown(controller.dispose);
          late Future<void> initialized;
          late MainContentBridge initializer;
          late MainContentAccess chatAccess;
          extensions.register(
            point: mainContentContributions,
            id: ExtensionId('test.chat'),
            value: MainContentContribution(
              order: 100,
              attach: (access) {
                chatAccess = access;
                return initialized = generation.invoke<void>(
                  library: chatFrontendLibrary,
                  entrypoint: 'initializeChatMainContent',
                  createBridge: () => initializer = MainContentBridge(
                    access: access,
                    context: {
                      'sessionId': access.session.id.value,
                      'strategyId': access.session.strategyId.value,
                      'taskId': access.session.taskId.value,
                    },
                    isActive: () => access.isActive,
                    open: (id, title, canClose) => access.open(
                      MainContentPane(
                        id: id,
                        title: title,
                        onClose: canClose ? () => access.remove(id) : null,
                        createPresentation: () => _presentation(
                          generation,
                          source,
                          backendAvailable: backendAvailable,
                        ),
                      ),
                    ),
                  ),
                  decodeResult: (value) {
                    expect(
                      value == null || (value as $Value).$reified == null,
                      isTrue,
                    );
                  },
                );
              },
            ),
          );
          extensions.register(
            point: mainContentContributions,
            id: ExtensionId('test.independent'),
            value: MainContentContribution(
              order: 300,
              attach: (access) => access.open(
                MainContentPane(
                  id: 'independent',
                  title: 'Independent',
                  createPresentation: () => const Text('Independent content'),
                ),
              ),
            ),
          );
          controller.reconcile();
          await initialized;
          expect(initializer.isActive, isFalse);
          expect(chatAccess.panes, hasLength(matching ? 1 : 0));
          if (matching) {
            expect(chatAccess.panes.single.id, 'chat');
            expect(chatAccess.panes.single.title, 'Chat');
            expect(chatAccess.panes.single.canClose, isFalse);
          }
          expect(source.serviceAcquisitions, 0);
          expect(source.executionReads, 0);
          expect(source.calls, isEmpty);
          expect(source.starts, 0);

          Widget workspace() => MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  for (final entry in controller.entries)
                    Expanded(child: entry.presentation),
                ],
              ),
            ),
          );
          await tester.pumpWidget(workspace());
          await _frames(tester);
          expect(find.text('Independent content'), findsOneWidget);
          final independent = tester.element(find.text('Independent content'));
          if (matching) {
            expect(source.serviceAcquisitions, 1);
            if (backendAvailable) {
              expect(find.byType(NativeRichDocumentEditorView), findsOneWidget);
              expect(find.byType(AppFlowyEditor), findsOneWidget);
              expect(find.byType(TextField), findsNothing);
              expect(source.calls.single.$1, 'chat.session.snapshot');
              expect(source.executionReads, greaterThan(0));
              final scroll = tester.widget<SingleChildScrollView>(
                find.byType(SingleChildScrollView).first,
              );
              expect(scroll.padding, const EdgeInsets.all(24));
              final composer = _owner(tester);
              final editorState = _state(tester);
              chatAccess.setTitle('chat', 'Renamed Chat');
              await tester.pumpWidget(workspace());
              await _frames(tester);
              expect(
                tester.widget<SingleChildScrollView>(
                  find.byType(SingleChildScrollView).first,
                ),
                same(scroll),
              );
              expect(_owner(tester), same(composer));
              expect(_state(tester), same(editorState));
              expect(source.serviceAcquisitions, 1);
              expect(source.calls, hasLength(1));
            } else {
              expect(find.text('Frontend unavailable.'), findsOneWidget);
              expect(source.calls, isEmpty);
            }
          } else {
            expect(find.text('Chat'), findsNothing);
            expect(find.text('Frontend unavailable.'), findsNothing);
            expect(source.serviceAcquisitions, 0);
            expect(source.executionReads, 0);
            expect(source.calls, isEmpty);
          }
          expect(
            tester.element(find.text('Independent content')),
            same(independent),
          );
          expect(source.starts, 0);
          expect(source.submitted, isEmpty);
          expect(source.writes, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(source.hasSubscriptions, isFalse);
        },
      );
    }
  }

  test(
    'prepared entrypoint returns a widget after generated snapshot loading',
    () async {
      final bridges = PreparedFrontendBridges([
        SessionPresentationLifecycleBridge(isActive: () => source.active),
        RichDocumentEditorBridge(isActive: () => source.active),
        SessionExecutionBridge(source: source, isActive: () => source.active),
        OwningBackendBridge(
          channels: {chatSessionServiceId: source},
          validateBinding: () {},
        ),
      ]);
      addTearDown(bridges.invalidate);
      final runtime = Runtime(artifact.readAsBytesSync().buffer.asByteData())
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const ScrollViewBridge())
        ..addPlugin(bridges);
      final result = await runtime.executeLib(chatFrontendLibrary, 'buildChat');
      expect(result is $Value ? result.$reified : result, isA<Widget>());
    },
  );

  testWidgets(
    'actual EVC reads canonical history through generated transport',
    (tester) async {
      source.entries.addAll(const [
        ChatEntry(
          id: 'u1',
          role: 'user',
          content: 'First question',
          runId: null,
          feedback: null,
        ),
        ChatEntry(
          id: 'a1',
          role: 'assistant',
          content: 'First answer',
          runId: null,
          feedback: null,
        ),
      ]);
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('First question'), findsOneWidget);
      expect(find.text('First answer'), findsOneWidget);
      expect(source.calls.single.$1, 'chat.session.snapshot');
      expect(source.calls.single.$2, {'sessionId': 'session-opaque'});
      await _enterText(tester, '  Next question  ');
      await tester.tap(find.text('Send'));
      await _frames(tester);
      const submitted = '&#32;&#32;Next question&#32;&#32;';
      expect(source.submitted, [submitted]);
      expect(source.starts, 1);
      expect(_draft(tester), isEmpty);
      expect(find.text(submitted), findsOneWidget);
      expect(source.running, isTrue);
      expect(
        source.configurations,
        0,
        reason: 'Defaults belong to the backend.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feedback metadata alone selects compact rows and exact Inspect',
    (tester) async {
      source.entries.addAll([
        _feedbackEntry('review-first', 1, runId: 'review-run'),
        const ChatEntry(
          id: 'ordinary',
          role: 'user',
          content: 'Review feedback: 99 comments (ordinary user text)',
          runId: null,
          feedback: null,
        ),
        _feedbackEntry('review-second', 12),
        const ChatEntry(
          id: 'assistant',
          role: 'assistant',
          content: 'Ordinary assistant answer',
          runId: null,
          feedback: null,
        ),
      ]);
      source.draftRequest = 'Unchanged draft';
      source.historicalHandles['review-run'] = 'feedback-activity';
      source.activities['feedback-activity'] = [
        _model('review-model', [_tool('review-tool', 'read_file')]),
      ];
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(find.text('Review feedback \u00b7 1 comment'), findsOneWidget);
      expect(find.text('Review feedback \u00b7 12 comments'), findsOneWidget);
      expect(find.text('You'), findsNWidgets(3));
      expect(
        find.textContaining('Hidden canonical model content'),
        findsNothing,
      );
      expect(
        find.text('Review feedback: 99 comments (ordinary user text)'),
        findsOneWidget,
      );
      expect(find.text('Ordinary assistant answer'), findsOneWidget);
      expect(find.text('COMPACT review-tool'), findsOneWidget);
      expect(_draft(tester), 'Unchanged draft');
      expect(source.contentInspections, isEmpty);
      expect(source.calls.map((call) => call.$1), ['chat.session.snapshot']);
      final inspect = tester
          .widgetList<TextButton>(find.widgetWithText(TextButton, 'Inspect'))
          .toList();
      inspect[0].onPressed!();
      inspect[1].onPressed!();
      await _frames(tester);
      expect(source.contentInspections, [
        (chatFeedbackInspectionKind, 'review-first'),
        (chatFeedbackInspectionKind, 'review-second'),
      ]);
      expect(source.starts, 0);
      expect(source.submitted, isEmpty);
      expect(source.writes, isEmpty);
      expect(source.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    (
      name: 'assistant role',
      role: 'assistant',
      count: 1,
      submissionId: 'valid',
    ),
    (name: 'zero count', role: 'user', count: 0, submissionId: 'valid'),
    (name: 'negative count', role: 'user', count: -1, submissionId: 'valid'),
    (name: 'oversized count', role: 'user', count: 129, submissionId: 'valid'),
    (name: 'empty ID', role: 'user', count: 1, submissionId: ''),
    (name: 'blank ID', role: 'user', count: 1, submissionId: '   '),
    (name: 'untrimmed ID', role: 'user', count: 1, submissionId: ' valid '),
    (name: 'control ID', role: 'user', count: 1, submissionId: 'bad\nID'),
    (name: 'C1 ID', role: 'user', count: 1, submissionId: 'bad\u0085ID'),
    (
      name: 'unpaired surrogate ID',
      role: 'user',
      count: 1,
      submissionId: 'bad\uD800ID',
    ),
    (name: 'oversized ID', role: 'user', count: 1, submissionId: 'x' * 257),
  ]) {
    testWidgets(
      'typed feedback metadata rejects ${invalid.name} without raw fallback',
      (tester) async {
        source.entries.add(
          _feedbackEntry(
            'invalid',
            invalid.count,
            role: invalid.role,
            submissionId: invalid.submissionId,
          ),
        );
        source.draftRequest = 'Preserved draft';
        await tester.pumpWidget(_host(generation, source));
        await _frames(tester);
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(find.text('Review feedback is unavailable.'), findsOneWidget);
        expect(find.text('Inspect'), findsNothing);
        expect(find.text('You'), findsNothing);
        expect(
          find.textContaining('Hidden canonical model content'),
          findsNothing,
        );
        expect(find.textContaining('Review feedback \u00b7'), findsNothing);
        expect(_draft(tester), 'Preserved draft');
        expect(source.contentInspections, isEmpty);
        expect(source.calls.map((call) => call.$1), ['chat.session.snapshot']);
        expect(source.starts, 0);
        expect(source.submitted, isEmpty);
        expect(source.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'missing and ambiguous renderers preserve compact occurrence and permit retry',
    (tester) async {
      final extensions = ExtensionRegistry();
      final window = WindowInspection();
      addTearDown(window.dispose);
      final session = Session(
        id: SessionId('session-opaque'),
        taskId: TaskId('task'),
        strategyId: chatStrategyId,
      );
      window.presentSession(session);
      source.inspectContent = (kind, occurrence) => window.inspectContent(
        session: session,
        kind: kind,
        occurrenceId: occurrence,
        extensions: extensions,
      );
      source.entries.add(_feedbackEntry('review-first', 2));
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await tester.tap(find.text('Inspect'));
      await _frames(tester);
      expect(window.cards, isEmpty);
      expect(find.text('Review feedback \u00b7 2 comments'), findsOneWidget);
      expect(find.text('Feedback Inspection is unavailable.'), findsOneWidget);
      expect(
        find.textContaining('Hidden canonical model content'),
        findsNothing,
      );
      extensions.register(
        point: sessionContentInspectionContributions,
        id: ExtensionId('test.feedback-inspection'),
        value: SessionContentInspectionContribution(
          kind: SessionContentKind(chatFeedbackInspectionKind),
          createPresentation: (_) => const SizedBox.shrink(),
        ),
      );
      final ambiguous = extensions.register(
        point: sessionContentInspectionContributions,
        id: ExtensionId('test.other-feedback-inspection'),
        value: SessionContentInspectionContribution(
          kind: SessionContentKind(chatFeedbackInspectionKind),
          createPresentation: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.tap(find.text('Inspect'));
      await _frames(tester);
      expect(window.cards, isEmpty);
      expect(find.text('Review feedback \u00b7 2 comments'), findsOneWidget);
      expect(find.text('Feedback Inspection is unavailable.'), findsOneWidget);
      await ambiguous.close();
      await tester.tap(find.text('Inspect'));
      await _frames(tester);
      final target =
          window.cards.single.target as SessionContentInspectionTarget;
      expect(target.sessionId, session.id);
      expect(target.kind.value, chatFeedbackInspectionKind);
      expect(target.occurrenceId.value, 'review-first');
      expect(find.text('Feedback Inspection is unavailable.'), findsNothing);
      expect(find.text('Review feedback \u00b7 2 comments'), findsOneWidget);
      expect(source.starts, 0);
      expect(source.writes, isEmpty);
      expect(source.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact feedback remains narrow and refreshes across remounts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    source.entries.add(
      _feedbackEntry(
        'retained-review',
        128,
        submissionId: '${'a' * 254}\u{1F600}',
      ),
    );
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    final label = tester.widget<Text>(
      find.text('Review feedback \u00b7 128 comments'),
    );
    expect(label.data!.length, lessThan(40));
    expect(
      tester.getTopRight(find.text('You')).dx,
      closeTo(
        tester.getTopRight(find.byType(SingleChildScrollView).first).dx - 24,
        0.1,
      ),
    );
    final oldInspect = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Inspect'))
        .onPressed!;
    final editor = _owner(tester);
    source.entries.add(_feedbackEntry('new-review', 1));
    source.finish();
    await _frames(tester);
    expect(find.text('Review feedback \u00b7 128 comments'), findsOneWidget);
    expect(find.text('Review feedback \u00b7 1 comment'), findsOneWidget);
    expect(_owner(tester), same(editor));
    expect(source.contentInspections, isEmpty);
    final gate = Completer<void>();
    source.snapshotGate = gate;
    source.finish();
    await _frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.hasSubscriptions, isFalse);
    source.active = true;
    source.entries.add(_feedbackEntry('fresh-review', 3));
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    gate.complete();
    oldInspect();
    await _frames(tester);
    expect(find.text('Review feedback \u00b7 3 comments'), findsOneWidget);
    expect(find.textContaining('Hidden canonical model content'), findsNothing);
    expect(source.contentInspections, isEmpty);
    expect(source.starts, 0);
    expect(source.writes, isEmpty);
    expect(source.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'frontend retirement fences cached feedback Inspect immediately',
    (tester) async {
      source.entries.add(_feedbackEntry('review', 1));
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      final inspect = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Inspect'))
          .onPressed!;
      generation.invalidate();
      inspect();
      await _frames(tester);
      expect(source.contentInspections, isEmpty);
      expect(source.starts, 0);
      expect(source.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compiled feedback Inspection renders full ordered safe provenance',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final context = _FeedbackContext();
      final backend = _FeedbackSource(_acceptedFeedback());
      await tester.pumpWidget(_inspectionHost(generation, context, backend));
      await _frames(tester);
      expect(backend.calls, hasLength(1));
      expect(
        backend.calls.single.$1,
        'chat.feedbackInspection.readAcceptedFeedback',
      );
      expect(backend.calls.single.$2, {
        'sessionId': 'session-opaque',
        'occurrenceId': 'review',
      });
      expect(find.text('Review feedback'), findsOneWidget);
      expect(find.text('3 comments'), findsOneWidget);
      expect(
        find.textContaining('Historical locations and excerpts'),
        findsOneWidget,
      );
      expect(find.text('Session: session-opaque'), findsOneWidget);
      expect(find.text('Occurrence: review'), findsOneWidget);
      expect(find.text('Submission: submission'), findsOneWidget);
      expect(find.text('Kind: codeReview'), findsOneWidget);
      expect(find.text('Run: historical-run'), findsOneWidget);
      final comments = backend.feedback.comments;
      final displayed = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .toList();
      expect(
        displayed.where((text) => text?.startsWith('Comment: ') ?? false),
        ['Comment: first', 'Comment: second', 'Comment: third'],
      );
      expect(
        find.text(r'Comment text: A\nB\r\t\u001B\u202E\u200B\\literal'),
        findsOneWidget,
      );
      expect(
        find.text(r'Source excerpt: old\r\n\u2066source\uFEFF'),
        findsOneWidget,
      );
      expect(find.text(r'Path: lib/\u200Bfirst.dart'), findsOneWidget);
      expect(find.text('Comment text: ${comments[1].text}'), findsOneWidget);
      expect(comments[1].text.length, greaterThan(2000));
      for (var index = 0; index < comments.length; index++) {
        final comment = comments[index];
        final anchor = comment.anchor;
        expect(
          find.text(
            'Version: ${comment.version}; sequence: ${comment.sequence}',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Environment: ${anchor.environmentId}'),
          findsOneWidget,
        );
        expect(
          find.text('Layer: ${anchor.layer.name}; side: ${anchor.side.name}'),
          findsOneWidget,
        );
        expect(
          find.text('Lines: ${anchor.startLine}-${anchor.endLine} (inclusive)'),
          findsOneWidget,
        );
        expect(
          find.text('Comparison: ${anchor.comparisonIdentity}'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Hunk index: ${anchor.hunkIndex}; line index: ${anchor.lineIndex} (zero-based)',
          ),
          findsOneWidget,
        );
      }
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(NativeRichDocumentEditorView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('feedback Inspection reports a singular comment total', (
    tester,
  ) async {
    final context = _FeedbackContext();
    final backend = _FeedbackSource(_acceptedFeedback(commentCount: 1));
    await tester.pumpWidget(_inspectionHost(generation, context, backend));
    await _frames(tester);
    expect(find.text('Review feedback'), findsOneWidget);
    expect(find.text('1 comment'), findsOneWidget);
    expect(find.text('Comment: first'), findsOneWidget);
    expect(find.text('Comment: second'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final failure in [
    'absent',
    'not_found',
    'corrupt',
    'native',
    'malformed',
    'wrong-session',
    'wrong-occurrence',
    'zero-count',
    'oversized-count',
    'invalid-submission',
  ]) {
    testWidgets('feedback Inspection safely contains $failure retrieval', (
      tester,
    ) async {
      final context = _FeedbackContext();
      final backend = _FeedbackSource(
        _acceptedFeedback(
          sessionId: failure == 'wrong-session' ? 'other' : 'session-opaque',
          occurrenceId: failure == 'wrong-occurrence' ? 'other' : 'review',
          commentCount: failure == 'zero-count'
              ? 0
              : failure == 'oversized-count'
              ? 129
              : 3,
          submissionId: failure == 'invalid-submission' ? ' ' : 'submission',
        ),
      );
      if (failure == 'not_found' || failure == 'corrupt') {
        backend.failure = ChatFeedbackInspectionFailure(
          code: failure,
          message: 'PRIVATE diagnostic with source text',
          details: const {},
        );
      }
      if (failure == 'native') {
        backend.failure = StateError('PRIVATE native failure');
      }
      await tester.pumpWidget(
        _inspectionHost(
          generation,
          context,
          failure == 'malformed'
              ? _ResponseChannel({'comments': <Object?>[]})
              : backend,
          backendAvailable: failure != 'absent',
        ),
      );
      await _frames(tester);
      expect(find.text('Review feedback is unavailable.'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.textContaining('Comment text:'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      if (failure == 'absent') expect(backend.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final retirement in ['card', 'frontend', 'backend', 'unmount']) {
    testWidgets('feedback Inspection fences late $retirement retrieval', (
      tester,
    ) async {
      final context = _FeedbackContext();
      final backend = _FeedbackSource(_acceptedFeedback());
      final gate = Completer<void>();
      backend.gate = gate;
      await tester.pumpWidget(_inspectionHost(generation, context, backend));
      await _frames(tester);
      expect(backend.calls, hasLength(1));
      if (retirement == 'card') context.retire();
      if (retirement == 'frontend') generation.invalidate();
      if (retirement == 'backend') backend.active = false;
      if (retirement == 'unmount') {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      gate.complete();
      await _frames(tester);
      expect(find.textContaining('Comment text:'), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(backend.calls, hasLength(1));
      if (retirement == 'card') expect(context.hasSubscriptions, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'restores exact draft and saves edits across presentation reopen',
    (tester) async {
      const restored = '  Saved draft\nwith whitespace  ';
      source.draftRequest = restored;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(_draft(tester), restored);
      expect(
        source.writes,
        isEmpty,
        reason: 'Restoration is not a local edit.',
      );
      const edited = '  New draft  ';
      const serialized = '&#32;&#32;New draft&#32;&#32;';
      await _enterText(tester, edited);
      expect(_draft(tester), serialized);
      expect(
        _state(tester).document.root.children.single.delta!.toPlainText(),
        edited,
      );
      await _frames(tester);
      expect(source.draftRequest, serialized);
      expect(source.writes, [serialized]);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(source.hasSubscriptions, isFalse);
      source.active = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(_draft(tester), serialized);
      await _enterText(tester, '   ');
      await _frames(tester);
      expect(source.draftRequest, '&#32;&#32;&#32;');
      await _enterText(tester, '');
      await _frames(tester);
      expect(source.draftRequest, isEmpty);
      expect(source.writes, [serialized, '&#32;&#32;&#32;', '']);
      expect(source.maxInFlightSaves, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rich draft hydration retains exact source without a save', (
    tester,
  ) async {
    const original =
        '# Heading\r\n\r\n**bold** and *italic* and `code`\r\n\r\n'
        '- parent\r\n  - child\r\n\r\n~~~dart\r\n  final x = 1;  \r\n~~~\r\n';
    source.draftRequest = original;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    final owner = _owner(tester);
    final state = _state(tester);
    expect(_draft(tester), original);
    expect(owner.revision, 0);
    expect(state.document.root.children.map((node) => node.type), [
      HeadingBlockKeys.type,
      ParagraphBlockKeys.type,
      BulletedListBlockKeys.type,
      RichDocumentMarkdown.codeBlockType,
    ]);
    expect(
      state.document.root.children[2].children.single.delta!.toPlainText(),
      'child',
    );
    expect(
      state.document.root.children.last.delta!.toPlainText(),
      '  final x = 1;  ',
    );
    expect(source.writes, isEmpty);
    source.notifyListeners();
    await _frames(tester);
    expect(_owner(tester), same(owner));
    expect(_state(tester), same(state));
    expect(_draft(tester), original);
    expect(source.writes, isEmpty);
    final departure = source.lifecycle.prepareToDeactivate();
    await _frames(tester);
    await departure;
    expect(source.writes, isEmpty);
    expect(source.submitted, isEmpty);
    expect(source.starts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'multiline input and native formatting save and submit Markdown',
    (tester) async {
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'First');
      await _insertText(tester, '\n');
      await _insertText(tester, 'Second');
      final state = _state(tester);
      expect(
        state.document.root.children.map((node) => node.delta!.toPlainText()),
        ['First', 'Second'],
      );
      expect(_draft(tester), 'First\n\nSecond');
      expect(
        source.submitted,
        isEmpty,
        reason: 'Enter edits, rather than sends.',
      );
      expect(source.starts, 0);
      await _select(
        tester,
        Selection.single(path: [0], startOffset: 0, endOffset: 5),
      );
      await _control(tester, LogicalKeyboardKey.keyB);
      await _select(
        tester,
        Selection.single(path: [1], startOffset: 0, endOffset: 6),
      );
      await _control(tester, LogicalKeyboardKey.keyI);
      const markdown = '**First**\n\n*Second*';
      expect(_draft(tester), markdown);
      expect(source.draftRequest, markdown);
      expect(source.writes.last, markdown);
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(source.submitted, [markdown]);
      expect(source.entries.single.content, markdown);
      expect(source.starts, 1);
      expect(_draft(tester), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compiled Chat imports a full clipboard Markdown prompt and submits it once',
    (tester) async {
      final saved = Completer<void>();
      source.saveGate = saved;
      addTearDown(() {
        if (!saved.isCompleted) saved.complete();
      });
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      final owner = _owner(tester);
      final state = _state(tester);
      expect(owner.revision, 0);
      expect(source.writes, isEmpty);
      await _select(tester, Selection.collapsed(Position(path: [0])));
      await _pasteClipboard(tester, markdownPasteFixture);

      final blocks = state.document.root.children;
      expect(
        blocks
            .where((node) => node.type == HeadingBlockKeys.type)
            .map(
              (node) => (node.attributes['level'], node.delta!.toPlainText()),
            ),
        [
          (1, 'ADELE \u2014 Implement Custom read_file Inspection Card'),
          (2, 'Goal'),
          (3, 'Tool approvals'),
          (2, '1. Rich Inspection card'),
          (3, 'Ownership and boundaries'),
          (2, '2. Compact activity summary'),
          (3, 'Examples'),
          (2, '3. Preview fidelity'),
          (2, '4. Lifecycle and safety'),
          (2, '5. Regression coverage'),
          (3, 'Native and evaluated presentation'),
          (2, '6. Validation'),
          (2, '7. Delivery'),
        ],
      );
      expect(
        blocks.first.delta!.toJson(),
        (Delta()
              ..insert('ADELE \u2014 Implement Custom ')
              ..insert('read_file', attributes: {'code': true})
              ..insert(' Inspection Card'))
            .toJson(),
      );
      expect(
        blocks
            .singleWhere(
              (node) => node.delta!.toPlainText().startsWith(
                'ADELE has already created',
              ),
            )
            .delta!
            .toJson(),
        (Delta()..insert(
              'ADELE has already created and selected the isolated Git worktree and Task branch.',
              attributes: {'bold': true},
            ))
            .toJson(),
      );
      expect(
        blocks.where((node) => node.type == BulletedListBlockKeys.type),
        hasLength(12),
      );
      expect(
        blocks.where((node) => node.type == NumberedListBlockKeys.type),
        hasLength(11),
      );
      final code = blocks.singleWhere(
        (node) => node.type == RichDocumentMarkdown.codeBlockType,
      );
      const commands =
          'dart tools/adele.dart test --target filesystem_tools_frontend\n'
          'dart tools/adele.dart analyze\n'
          'dart tools/adele.dart format --check\n'
          'dart tools/adele.dart generate --check\n'
          'git diff --check';
      expect(code.attributes['language'], 'sh');
      expect(code.delta!.toJson(), (Delta()..insert(commands)).toJson());
      // Independently spell the adapter's punctuation normalization, not a
      // decode/encode round trip that could hide missing prompt content.
      final markdown = markdownPasteFixture
          .trimRight()
          .replaceAll(':', r'\:')
          .replaceAllMapped(
            RegExp(r'^(## [1-7])\.', multiLine: true),
            (match) => '${match[1]}\\.',
          );
      expect(owner.snapshot, returnsNormally);
      expect(owner.snapshot(), {
        'markdown': markdown,
        'revision': 1,
        'readOnly': false,
        'editingEnabled': true,
        'isBlank': false,
        'unsupportedReason': null,
      });
      expect(_owner(tester), same(owner));
      expect(_state(tester), same(state));
      expect(source.writes, [markdown]);
      final writes = source.calls.where(
        (call) => call.$1 == 'chat.session.setDraftRequest',
      );
      expect(writes, hasLength(1));
      expect(writes.single.$2, {
        'sessionId': 'session-opaque',
        'content': markdown,
      });
      expect(source.inFlightSaves, 1);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      saved.complete();
      await _frames(tester);
      expect(source.events, [
        'save:$markdown',
        'saved:$markdown',
        'submit:$markdown',
        'accepted:$markdown',
        'start',
      ]);
      expect(source.submitted, [markdown]);
      expect(source.entries.single.role, 'user');
      expect(source.entries.single.content, markdown);
      expect(source.draftRequest, isEmpty);
      expect(source.writes, [markdown]);
      expect(source.starts, 1);
      expect(source.maxInFlightSaves, 1);
      expect(owner.isDisposed, isTrue);
      expect(state.isDisposed, isTrue);
      final replacement = _owner(tester);
      expect(replacement, isNot(same(owner)));
      expect(_state(tester), isNot(same(state)));
      expect(_draft(tester), isEmpty);
      source.finish();
      await _frames(tester);
      await _select(tester, Selection.collapsed(Position(path: [0])));
      await _control(tester, LogicalKeyboardKey.keyZ);
      expect(_owner(tester), same(replacement));
      expect(_draft(tester), isEmpty);
      expect(source.draftRequest, isEmpty);
      expect(source.writes, [markdown]);
      expect(source.submitted, [markdown]);
      expect(source.starts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compiled Chat rejects unsupported clipboard Markdown without mutation and allows literal recovery',
    (tester) async {
      source.draftRequest = 'Keep for Undo';
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, '');
      final owner = _owner(tester);
      final state = _state(tester);
      final undo = state.undoManager;
      final snapshot = owner.snapshot();
      final document = state.document.toJson();
      final selection = state.selection;
      expect(source.draftRequest, isEmpty);
      expect(source.writes, ['']);
      const unsupported = '![unsupported](image.png)';
      await _pasteClipboard(tester, unsupported);
      expect(_owner(tester), same(owner));
      expect(_state(tester), same(state));
      expect(state.undoManager, same(undo));
      expect(state.document.toJson(), document);
      expect(state.selection, selection);
      expect(owner.snapshot(), snapshot);
      expect(state.editable, isTrue);
      expect(owner.readOnly, isFalse);
      expect(
        find.descendant(
          of: find.byType(NativeRichDocumentEditorView),
          matching: find.textContaining(
            'Use Ctrl/Cmd+Shift+V to paste literally',
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Paste rejected:'), findsOneWidget);
      expect(find.textContaining('Draft unchanged.'), findsOneWidget);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(source.draftRequest, isEmpty);
      expect(source.writes, ['']);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(source.writes, ['']);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      await _select(tester, Selection.collapsed(Position(path: [0])));
      await _control(tester, LogicalKeyboardKey.keyZ);
      expect(_draft(tester), 'Keep for Undo');
      await _control(tester, LogicalKeyboardKey.keyY);
      expect(_draft(tester), isEmpty);
      expect(source.writes, ['', 'Keep for Undo', '']);
      await _pasteClipboard(tester, unsupported, literal: true);
      expect(state.document.root.children.single.type, ParagraphBlockKeys.type);
      expect(
        state.document.root.children.single.delta!.toJson(),
        (Delta()..insert(unsupported)).toJson(),
      );
      expect(_draft(tester), r'!\[unsupported\](image.png)');
      expect(source.draftRequest, r'!\[unsupported\](image.png)');
      expect(source.writes, [
        '',
        'Keep for Undo',
        '',
        r'!\[unsupported\](image.png)',
      ]);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      expect(source.maxInFlightSaves, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compiled Chat keeps clipboard Markdown literal in existing text',
    (tester) async {
      source.draftRequest = 'Prefix&#32;';
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      final owner = _owner(tester);
      final state = _state(tester);
      await _select(
        tester,
        Selection.collapsed(Position(path: [0], offset: 7)),
      );
      const clipboard = '# literal\n**not bold**';
      await _pasteClipboard(tester, clipboard);
      expect(state.document.root.children.single.type, ParagraphBlockKeys.type);
      expect(
        state.document.root.children.single.delta!.toJson(),
        (Delta()..insert('Prefix $clipboard')).toJson(),
      );
      const markdown = 'Prefix \\# literal\n\\*\\*not bold\\*\\*';
      expect(_draft(tester), markdown);
      expect(owner.revision, 1);
      expect(source.draftRequest, markdown);
      expect(source.writes, [markdown]);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('typed fence and code keyboard input remain literal in Chat', (
    tester,
  ) async {
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, '```dart');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _frames(tester);
    final state = _state(tester);
    final code = state.document.root.children.single;
    expect(code.type, RichDocumentMarkdown.codeBlockType);
    expect(code.attributes['language'], 'dart');
    expect(_owner(tester).snapshot()['isBlank'], isTrue);
    await tester.tap(find.text('Send'));
    await _frames(tester);
    expect(
      source.submitted,
      isEmpty,
      reason: 'Empty code fences are not a prompt.',
    );
    await _select(tester, Selection.collapsed(Position(path: [0])));
    await _insertText(tester, '  **literal**');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _frames(tester);
    await _insertText(tester, '`code`  ');
    const literal = '  **literal**\n\t`code`  ';
    expect(code.delta!.toJson(), (Delta()..insert(literal)).toJson());
    await _select(
      tester,
      Selection.single(path: [0], startOffset: 0, endOffset: 13),
    );
    await _control(tester, LogicalKeyboardKey.keyB);
    expect(code.delta!.toJson(), (Delta()..insert(literal)).toJson());
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _frames(tester);
    await _insertText(tester, 'After');
    const markdown = '```dart\n$literal\n```\n\nAfter';
    expect(_draft(tester), markdown);
    expect(source.draftRequest, markdown);
    expect(source.submitted, isEmpty);
    await tester.tap(find.text('Send'));
    await _frames(tester);
    expect(source.submitted, [markdown]);
    expect(source.entries.single.content, markdown);
    expect(source.starts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported original Markdown can be sent unchanged, not edited', (
    tester,
  ) async {
    const original =
        'Before\r\n\r\n![alt](https://example.invalid/image.png)\r\n\r\nAfter  \r\n';
    source.draftRequest = original;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    final owner = _owner(tester);
    expect(owner.readOnly, isTrue);
    expect(owner.unsupportedReason, isNotNull);
    expect(_draft(tester), original);
    expect(find.byType(AppFlowyEditor), findsNothing);
    expect(
      find.textContaining('preserved read-only and can be sent unchanged.'),
      findsOneWidget,
    );
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(source.writes, isEmpty);
    await tester.tap(find.text('Send'));
    await _frames(tester);
    expect(source.submitted, [original]);
    expect(source.entries.single.content, original);
    expect(source.writes, isEmpty);
    expect(source.starts, 1);
    expect(owner.isDisposed, isTrue);
    expect(_owner(tester), isNot(same(owner)));
    expect(_draft(tester), isEmpty);
    expect(find.byType(AppFlowyEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final pendingSave in [false, true]) {
    testWidgets(
      'unsupported serialization blocks finalization and Undo recovers${pendingSave ? ' after an older pending write' : ''}',
      (tester) async {
        source.draftRequest = 'Stored';
        final gate = Completer<void>();
        if (pendingSave) source.saveGate = gate;
        await tester.pumpWidget(_host(generation, source));
        await _frames(tester);
        await _enterText(tester, 'Newer');
        final owner = _owner(tester);
        final state = _state(tester);
        // Fault injection only: the admitted UI deliberately has no underline action.
        await state.apply(
          state.transaction..formatText(
            state.document.root.children.single,
            0,
            5,
            {'underline': true},
          ),
        );
        await _frames(tester);
        if (pendingSave) {
          expect(source.draftRequest, 'Stored');
          expect(source.writes, ['Newer']);
          gate.complete();
          await _frames(tester);
        }
        expect(owner.snapshot, throwsFormatException);
        expect(source.draftRequest, 'Newer');
        expect(source.writes, ['Newer']);
        expect(
          find.textContaining('This edit cannot be saved as Markdown.'),
          findsOneWidget,
        );
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(state.editable, isTrue);
        await tester.tap(find.text('Send'));
        await _frames(tester);
        final rejected = expectLater(
          source.lifecycle.prepareToDeactivate(),
          throwsStateError,
        );
        await _frames(tester);
        await rejected;
        expect(source.submitted, isEmpty);
        expect(source.starts, 0);
        expect(source.writes, ['Newer']);
        expect(_owner(tester), same(owner));
        expect(_state(tester), same(state));
        expect(
          state.document.root.children.single.delta!.toPlainText(),
          'Newer',
        );
        await _select(
          tester,
          Selection.collapsed(Position(path: [0], offset: 5)),
        );
        await _control(tester, LogicalKeyboardKey.keyZ);
        expect(_draft(tester), 'Newer');
        expect(
          find.textContaining('This edit cannot be saved as Markdown.'),
          findsNothing,
        );
        expect(source.draftRequest, 'Newer');
        expect(source.writes, ['Newer', 'Newer']);
        final departure = source.lifecycle.prepareToDeactivate();
        await _frames(tester);
        await departure;
        await tester.tap(find.text('Send'));
        await _frames(tester);
        expect(source.submitted, ['Newer']);
        expect(source.starts, 1);
        expect(source.maxInFlightSaves, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'execution disable and enable retain owner, document and undo redo',
    (tester) async {
      source.draftRequest = 'Keep';
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      final owner = _owner(tester);
      final state = _state(tester);
      await _select(
        tester,
        Selection.collapsed(Position(path: [0], offset: 4)),
      );
      await _insertText(tester, '!');
      expect(source.writes, ['Keep!']);
      source.running = true;
      source.notifyListeners();
      await _frames(tester);
      expect(state.editable, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(owner.snapshot()['editingEnabled'], isFalse);
      await _control(tester, LogicalKeyboardKey.keyZ);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await _frames(tester);
      expect(_draft(tester), 'Keep!');
      expect(source.writes, ['Keep!']);
      expect(_owner(tester), same(owner));
      expect(_state(tester), same(state));
      source.finish();
      await _frames(tester);
      expect(_owner(tester), same(owner));
      expect(_state(tester), same(state));
      expect(owner.snapshot()['editingEnabled'], isTrue);
      expect(state.editable, isTrue);
      await _select(
        tester,
        Selection.collapsed(Position(path: [0], offset: 5)),
      );
      await _control(tester, LogicalKeyboardKey.keyZ);
      expect(_draft(tester), 'Keep');
      expect(source.draftRequest, 'Keep');
      await _control(tester, LogicalKeyboardKey.keyY);
      expect(_draft(tester), 'Keep!');
      expect(source.writes, ['Keep!', 'Keep', 'Keep!']);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'acceptance replaces the owner and cannot undo submitted content',
    (tester) async {
      source.submitGate = Completer<void>();
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'Accepted');
      final owner = _owner(tester);
      final state = _state(tester);
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(_owner(tester), same(owner));
      expect(_draft(tester), 'Accepted');
      expect(owner.isDisposed, isFalse);
      expect(state.editable, isFalse);
      source.submitGate!.complete();
      await _frames(tester);
      final replacement = _owner(tester);
      final replacementState = _state(tester);
      expect(replacement, isNot(same(owner)));
      expect(replacementState, isNot(same(state)));
      expect(owner.isDisposed, isTrue);
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(replacementState.editable, isFalse);
      expect(_draft(tester), isEmpty);
      source.finish();
      await _frames(tester);
      expect(_owner(tester), same(replacement));
      await _select(tester, Selection.collapsed(Position(path: [0])));
      await _control(tester, LogicalKeyboardKey.keyZ);
      expect(_draft(tester), isEmpty);
      expect(source.writes, ['Accepted']);
      await _insertText(tester, 'Next');
      expect(_draft(tester), 'Next');
      expect(source.draftRequest, 'Next');
      expect(source.submitted, ['Accepted']);
      expect(source.starts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final changesText in [false, true]) {
    testWidgets(
      'IME ${changesText ? 'replacement' : 'composition-only transition'} blocks Send and navigation until commit',
      (tester) async {
        source.draftRequest = 'seed';
        await tester.pumpWidget(_host(generation, source));
        await _frames(tester);
        final owner = _owner(tester);
        final state = _state(tester);
        await _select(
          tester,
          Selection.collapsed(Position(path: [0], offset: 4)),
        );
        final before = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        final composing = changesText
            ? TextEditingValue(
                text: '${before.text}\u4e2d',
                selection: TextSelection.collapsed(
                  offset: before.text.length + 1,
                ),
                composing: TextRange(
                  start: before.text.length,
                  end: before.text.length + 1,
                ),
              )
            : before.copyWith(
                composing: TextRange(
                  start: before.text.length - 4,
                  end: before.text.length,
                ),
              );
        await _input(tester, composing);
        final revision = owner.revision;
        expect(owner.snapshot()['markdown'], isNull);
        expect(owner.snapshot()['error'], 'composition_pending');
        expect(source.writes, isEmpty);
        expect(source.draftRequest, 'seed');
        await tester.tap(find.text('Send'));
        await _frames(tester);
        final rejected = expectLater(
          source.lifecycle.prepareToDeactivate(),
          throwsStateError,
        );
        await _frames(tester);
        await rejected;
        expect(source.submitted, isEmpty);
        expect(source.starts, 0);
        expect(source.writes, isEmpty);
        expect(_owner(tester), same(owner));
        expect(_state(tester), same(state));
        expect(state.editable, isTrue);
        expect(find.textContaining('Finish text composition'), findsOneWidget);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        await _input(tester, composing.copyWith(composing: TextRange.empty));
        final committed = changesText ? 'seed\u4e2d' : 'seed';
        expect(_draft(tester), committed);
        expect(
          owner.revision,
          revision,
          reason: 'Composition completion alone is not a document edit.',
        );
        expect(find.textContaining('Finish text composition'), findsNothing);
        expect(source.draftRequest, committed);
        expect(source.writes, changesText ? [committed] : isEmpty);
        final departure = source.lifecycle.prepareToDeactivate();
        await _frames(tester);
        await departure;
        await tester.tap(find.text('Send'));
        await _frames(tester);
        expect(source.submitted, [committed]);
        expect(source.entries.single.content, committed);
        expect(source.starts, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('rapid edits coalesce to latest and all saves stay sequential', (
    tester,
  ) async {
    final first = Completer<void>();
    final latest = Completer<void>();
    source.saveGate = first;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, 'First');
    await _enterText(tester, 'Skipped');
    await _enterText(tester, 'Latest');
    await _frames(tester);
    expect(_draft(tester), 'Latest');
    expect(source.writes, ['First']);
    expect(source.inFlightSaves, 1);
    source.saveGate = latest;
    first.complete();
    await _frames(tester);
    expect(source.writes, ['First', 'Latest']);
    expect(source.draftRequest, 'First');
    await _enterText(tester, 'Next');
    await _enterText(tester, 'Final');
    latest.complete();
    await _frames(tester);
    expect(source.writes, ['First', 'Latest', 'Final']);
    expect(source.draftRequest, 'Final');
    await _enterText(tester, 'Sequential');
    await _frames(tester);
    expect(source.writes, ['First', 'Latest', 'Final', 'Sequential']);
    expect(source.draftRequest, 'Sequential');
    expect(source.maxInFlightSaves, 1);
    expect(source.inFlightSaves, 0);
    expect(source.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'deactivation waits for the latest sequential save acknowledgement',
    (tester) async {
      final first = Completer<void>();
      final latest = Completer<void>();
      source.saveGate = first;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'First');
      await _enterText(tester, 'Skipped');
      await _enterText(tester, '  Latest draft  ');
      const latestDraft = '&#32;&#32;Latest draft&#32;&#32;';
      var prepared = false;
      final pending = source.lifecycle.prepareToDeactivate().then((_) {
        prepared = true;
      });
      await _frames(tester);
      expect(prepared, isFalse);
      expect(source.writes, ['First']);
      expect(source.hasSubscriptions, isTrue);
      source.saveGate = latest;
      first.complete();
      await _frames(tester);
      expect(source.writes, ['First', latestDraft]);
      expect(source.draftRequest, 'First');
      expect(prepared, isFalse);
      latest.complete();
      await _frames(tester);
      await pending;
      expect(prepared, isTrue);
      expect(source.draftRequest, latestDraft);
      expect(source.maxInFlightSaves, 1);
      expect(source.inFlightSaves, 0);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      final retired = source.lifecycle;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(source.hasSubscriptions, isFalse);
      source.active = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(_draft(tester), latestDraft);
      expect(source.lifecycle, isNot(same(retired)));
      await expectLater(retired.prepareToDeactivate(), throwsStateError);
      final reopened = source.lifecycle.prepareToDeactivate();
      await _frames(tester);
      await reopened;
      expect(source.writes, ['First', latestDraft]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed deactivation preserves the mounted composer and retries',
    (tester) async {
      final gate = Completer<void>();
      source.saveGate = gate;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      final controller = _owner(tester);
      final editorState = _state(tester);
      await _enterText(tester, 'Keep unsaved text');
      final pending = expectLater(
        source.lifecycle.prepareToDeactivate(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'safe failure',
            'Session presentation could not prepare to deactivate.',
          ),
        ),
      );
      gate.completeError(StateError('private native storage failure'));
      await _frames(tester);
      await pending;
      expect(_draft(tester), 'Keep unsaved text');
      expect(source.hasSubscriptions, isTrue);
      expect(_owner(tester), same(controller));
      expect(_state(tester), same(editorState));
      expect(
        find.text('Draft was not saved. Your text is preserved.'),
        findsOneWidget,
      );
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(source.draftRequest, isEmpty);
      expect(source.writes, ['Keep unsaved text']);
      expect(source.starts, 0);
      expect(source.submitted, isEmpty);
      final retry = source.lifecycle.prepareToDeactivate();
      await _frames(tester);
      await retry;
      expect(source.draftRequest, 'Keep unsaved text');
      expect(_draft(tester), 'Keep unsaved text');
      expect(find.text('Retry save'), findsNothing);
      expect(source.hasSubscriptions, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retirement during deactivation rejects late save acknowledgement',
    (tester) async {
      final gate = Completer<void>();
      source.saveGate = gate;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'In flight');
      await _enterText(tester, 'Queued');
      final pending = expectLater(
        source.lifecycle.prepareToDeactivate(),
        throwsStateError,
      );
      generation.invalidate();
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      await _frames(tester);
      await pending;
      expect(source.writes, ['In flight']);
      expect(source.hasSubscriptions, isFalse);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deactivation refuses a pending Send without disposing it', (
    tester,
  ) async {
    source.submitGate = Completer<void>();
    await _submit(tester, generation, source, 'Pending acceptance');
    final pending = expectLater(
      source.lifecycle.prepareToDeactivate(),
      throwsStateError,
    );
    await _frames(tester);
    await pending;
    expect(source.hasSubscriptions, isTrue);
    expect(_draft(tester), 'Pending acceptance');
    expect(source.starts, 0);
    source.submitGate!.complete();
    await _frames(tester);
    expect(source.starts, 1);
    expect(_draft(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed save retains latest text, stops, and explicitly retries',
    (tester) async {
      final gate = Completer<void>();
      source.saveGate = gate;
      source.failSave = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'First');
      await _enterText(tester, 'Keep latest');
      gate.complete();
      await _frames(tester);
      expect(_draft(tester), 'Keep latest');
      expect(source.writes, ['First', 'Keep latest']);
      expect(source.draftRequest, isEmpty);
      expect(
        find.text('Draft was not saved. Your text is preserved.'),
        findsOneWidget,
      );
      expect(_state(tester).editable, isTrue);
      source.notifyListeners();
      await _frames(tester);
      expect(
        source.writes,
        ['First', 'Keep latest'],
        reason: 'No busy auto-retry loop for the failed latest value.',
      );
      source.failSave = false;
      await tester.tap(find.text('Retry save'));
      await _frames(tester);
      expect(source.writes, ['First', 'Keep latest', 'Keep latest']);
      expect(source.draftRequest, 'Keep latest');
      expect(_draft(tester), 'Keep latest');
      expect(find.text('Retry save'), findsNothing);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
    },
  );

  testWidgets('another local edit retries a failed save', (tester) async {
    source.failSave = true;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, 'Failed');
    await _frames(tester);
    expect(find.text('Retry save'), findsOneWidget);
    source.failSave = false;
    await _enterText(tester, 'Edited after failure');
    await _frames(tester);
    expect(source.writes, ['Failed', 'Edited after failure']);
    expect(source.draftRequest, 'Edited after failure');
    expect(_draft(tester), 'Edited after failure');
    expect(find.text('Retry save'), findsNothing);
  });

  testWidgets('failed older save still flushes a newer queued edit for Send', (
    tester,
  ) async {
    final first = Completer<void>();
    final latest = Completer<void>();
    source.saveGate = first;
    source.failSave = true;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, 'Older');
    await _enterText(tester, 'Newest');
    await tester.tap(find.text('Send'));
    await _frames(tester);
    source.saveGate = latest;
    first.complete();
    await _frames(tester);
    expect(source.writes, ['Older', 'Newest']);
    expect(source.submitted, isEmpty);
    expect(source.starts, 0);
    expect(_draft(tester), 'Newest');
    source.failSave = false;
    latest.complete();
    await _frames(tester);
    expect(source.events, [
      'save:Older',
      'save:Newest',
      'saved:Newest',
      'submit:Newest',
      'accepted:Newest',
      'start',
    ]);
    expect(source.maxInFlightSaves, 1);
    expect(source.submitted, ['Newest']);
    expect(source.entries.single.content, 'Newest');
    expect(_draft(tester), isEmpty);
    expect(
      find.text('Draft was not saved. Your text is preserved.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Send flushes latest draft before acceptance and Run scheduling',
    (tester) async {
      final first = Completer<void>();
      final latest = Completer<void>();
      source.saveGate = first;
      source.submitGate = Completer<void>();
      source.startGate = Completer<void>();
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'First');
      await _enterText(tester, 'Skipped');
      await _enterText(tester, '  Latest  ');
      const latestDraft = '&#32;&#32;Latest&#32;&#32;';
      final send = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
          .onPressed!;
      send();
      send();
      await _frames(tester);
      expect(source.events, ['save:First']);
      expect(_state(tester).editable, isFalse);
      source.saveGate = latest;
      first.complete();
      await _frames(tester);
      expect(source.events, ['save:First', 'saved:First', 'save:$latestDraft']);
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      expect(_draft(tester), latestDraft);
      latest.complete();
      await _frames(tester);
      expect(source.submitted, [latestDraft]);
      expect(source.starts, 0);
      expect(_draft(tester), latestDraft);
      source.submitGate!.complete();
      await _frames(tester);
      expect(_draft(tester), isEmpty);
      expect(source.draftRequest, isEmpty);
      expect(source.events, [
        'save:First',
        'saved:First',
        'save:$latestDraft',
        'saved:$latestDraft',
        'submit:$latestDraft',
        'accepted:$latestDraft',
        'start',
      ]);
      send();
      expect(source.starts, 1);
      source.startGate!.complete();
      await _frames(tester);
      expect(source.maxInFlightSaves, 1);
      expect(source.submitted, [latestDraft]);
      expect(source.entries.single.content, latestDraft);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed Send flush preserves draft and retries without submitting',
    (tester) async {
      final gate = Completer<void>();
      source.saveGate = gate;
      source.failSave = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'Keep for Send');
      await tester.tap(find.text('Send'));
      await _frames(tester);
      gate.complete();
      await _frames(tester);
      expect(_draft(tester), 'Keep for Send');
      expect(source.submitted, isEmpty);
      expect(source.starts, 0);
      expect(source.entries, isEmpty);
      expect(source.writes, ['Keep for Send']);
      expect(
        find.text('Draft was not saved. Your text is preserved.'),
        findsOneWidget,
      );
      expect(_state(tester).editable, isTrue);
      source.failSave = false;
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(source.writes, ['Keep for Send', 'Keep for Send']);
      expect(source.submitted, ['Keep for Send']);
      expect(source.starts, 1);
      expect(_draft(tester), isEmpty);
      expect(find.text('Retry save'), findsNothing);
    },
  );

  testWidgets('acceptance and scheduling both exclude duplicate submits', (
    tester,
  ) async {
    source.submitGate = Completer<void>();
    source.startGate = Completer<void>();
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, 'Send once');
    final send = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
        .onPressed!;
    send();
    send();
    await _frames(tester);
    expect(source.submitted, ['Send once']);
    expect(source.starts, 0);
    expect(_draft(tester), 'Send once');
    source.submitGate!.complete();
    await _frames(tester);
    send();
    expect(source.starts, 1);
    expect(_draft(tester), isEmpty);
    source.startGate!.complete();
    await _frames(tester);
    expect(_draft(tester), isEmpty);
    expect(source.submitted, ['Send once']);
    expect(
      source.running,
      isTrue,
      reason: 'Draft clears on acceptance, not scheduling or completion.',
    );
  });

  testWidgets('blank drafts and unavailable execution never submit', (
    tester,
  ) async {
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, '  \n ');
    final send = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
        .onPressed!;
    send();
    await _frames(tester);
    expect(source.submitted, isEmpty);
    await _enterText(tester, 'Draft');
    source.running = true;
    source.notifyListeners();
    await _frames(tester);
    send();
    expect(source.submitted, isEmpty);
    expect(_draft(tester), 'Draft');
  });

  testWidgets('empty formatting scaffolding never becomes a request', (
    tester,
  ) async {
    const markdown = '# \n\n- \n\n```\n\n```';
    source.draftRequest = markdown;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    expect(_owner(tester).snapshot()['isBlank'], isTrue);
    expect(_draft(tester), markdown);
    await tester.tap(find.text('Send'));
    await _frames(tester);
    expect(source.submitted, isEmpty);
    expect(source.writes, isEmpty);
    expect(source.draftRequest, markdown);
    expect(source.starts, 0);
  });

  testWidgets(
    'compact native viewport scrolls and survives narrow rebuilding',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      source.draftRequest = List.generate(
        20,
        (index) => 'Paragraph $index with wrapping text in a narrow Chat pane.',
      ).join('\n\n');
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      final owner = _owner(tester);
      final state = _state(tester);
      expect(tester.getSize(find.byType(AppFlowyEditor)).height, 180);
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(AppFlowyEditor),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.drag(find.byType(AppFlowyEditor), const Offset(0, -180));
      await _frames(tester);
      expect(scroll.position.pixels, greaterThan(0));
      source.notifyListeners();
      await _frames(tester);
      expect(_owner(tester), same(owner));
      expect(_state(tester), same(state));
      expect(_draft(tester), source.draftRequest);
      expect(source.writes, isEmpty);
      expect(find.text('Send'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale terminal snapshot cannot erase a newer accepted occurrence',
    (tester) async {
      await _submit(tester, generation, source, 'Repeated text');
      final gate = Completer<void>();
      source.snapshotGate = gate;
      source.finish();
      await _frames(tester);
      await _enterText(tester, 'Repeated text');
      expect(_draft(tester), 'Repeated text');
      expect(source.writes, ['Repeated text', 'Repeated text']);
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(source.submitted, ['Repeated text', 'Repeated text']);
      expect(source.entries, hasLength(2));
      expect(find.text('Repeated text'), findsNWidgets(2));
      gate.complete();
      await _frames(tester);
      expect(find.text('Repeated text'), findsNWidgets(2));
      expect(source.entries.map((entry) => entry.id).toSet(), hasLength(2));
      expect(source.starts, 2);
    },
  );

  for (final savePending in [false, true]) {
    testWidgets(
      'terminal snapshot cannot overwrite newer ${savePending ? 'pending' : 'saved'} draft',
      (tester) async {
        await _submit(tester, generation, source, 'First request');
        final snapshotGate = Completer<void>();
        final saveGate = Completer<void>();
        source.snapshotGate = snapshotGate;
        source.entries.add(
          const ChatEntry(
            id: 'answer',
            role: 'assistant',
            content: 'Answer',
            runId: null,
            feedback: null,
          ),
        );
        source.finish();
        await _frames(tester);
        if (savePending) source.saveGate = saveGate;
        await _enterText(tester, 'New local draft');
        await _frames(tester);
        snapshotGate.complete();
        await _frames(tester);
        expect(_draft(tester), 'New local draft');
        expect(find.text('Answer'), findsOneWidget);
        if (savePending) {
          expect(source.draftRequest, isEmpty);
          saveGate.complete();
          await _frames(tester);
        }
        expect(source.draftRequest, 'New local draft');
        expect(source.submitted, ['First request']);
        expect(source.starts, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Run already terminal at scheduling refreshes canonical answer', (
    tester,
  ) async {
    source.finishDuringStart = true;
    await _submit(tester, generation, source, 'Quick prompt');
    expect(find.text('Quick canonical answer'), findsOneWidget);
    expect(_draft(tester), isEmpty);
    expect(_state(tester).editable, isTrue);
  });

  testWidgets(
    'submission failure preserves draft and does not invent history',
    (tester) async {
      source.failSubmit = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'Keep this draft');
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(_draft(tester), 'Keep this draft');
      expect(source.entries, isEmpty);
      expect(source.starts, 0);
      expect(
        find.text('Message was not accepted. Your draft is preserved.'),
        findsOneWidget,
      );
      expect(find.text('ADELE'), findsNothing);
      source.failSubmit = false;
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(source.entries.single.content, 'Keep this draft');
      expect(_draft(tester), isEmpty);
    },
  );

  testWidgets('scheduling retry reuses the accepted canonical occurrence', (
    tester,
  ) async {
    source.failStart = true;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    await _enterText(tester, 'Accepted once');
    await tester.tap(find.text('Send'));
    await _frames(tester);
    expect(source.entries, hasLength(1));
    expect(_draft(tester), isEmpty);
    expect(source.draftRequest, isEmpty);
    expect(_state(tester).editable, isFalse);
    expect(
      find.text('Message accepted, but Run could not start. Retry Send.'),
      findsOneWidget,
    );
    source.failStart = false;
    await tester.tap(find.text('Send'));
    await _frames(tester);
    expect(source.submitted, ['Accepted once']);
    expect(source.writes, ['Accepted once']);
    expect(source.starts, 2);
    expect(_draft(tester), isEmpty);
    source.models.add(_model('retry-activity', [_tool('retry-tool', 'read')]));
    source.notifyListeners();
    await _frames(tester);
    expect(find.text('COMPACT retry-tool'), findsOneWidget);
  });

  for (final resume in [false, true]) {
    testWidgets(
      'refreshes canonical history at terminal${resume ? ' after approval resume' : ''}',
      (tester) async {
        await _submit(tester, generation, source, 'Question');
        if (resume) {
          source.advancing = false;
          source.notifyListeners();
          await _frames(tester);
          expect(_state(tester).editable, isFalse);
          source.advancing = true;
          source.notifyListeners();
          await _frames(tester);
        }
        final reads = source.snapshotReads;
        source.entries.add(
          const ChatEntry(
            id: 'answer',
            role: 'assistant',
            content: 'Canonical final answer',
            runId: null,
            feedback: null,
          ),
        );
        source.finish();
        await _frames(tester);
        expect(source.snapshotReads, greaterThan(reads));
        expect(find.text('Canonical final answer'), findsOneWidget);
        expect(find.text('ADELE'), findsOneWidget);
        expect(_state(tester).editable, isTrue);
      },
    );
  }

  testWidgets(
    'failed Run keeps accepted user history without assistant failure',
    (tester) async {
      await _submit(tester, generation, source, 'Failed Run question');
      source.failure = 'Run failed';
      source.finish();
      await _frames(tester);
      expect(find.text('Failed Run question'), findsOneWidget);
      expect(find.text('ADELE'), findsNothing);
      expect(
        find.text('Run failed'),
        findsNothing,
        reason: 'Run status is host-owned.',
      );
    },
  );

  testWidgets(
    'Chat groups completed proposals and safe native outputs in timeline order',
    (tester) async {
      await _submit(tester, generation, source, 'Inspect files');
      source.models.addAll([
        _model('single', [_tool('read', 'read_file')]),
        _model('batch', [
          _text('Read these two files'),
          _tool('one', 'read_file'),
          _tool('two', 'read_file'),
        ]),
        _model('native', [
          _text('Not batch narration'),
          _native('n1', 'Safe summary'),
          _native('n2', 'Other summary'),
        ]),
        _model('opaque', [_native('hidden', 'Never display', safe: false)]),
        _model('failed', [
          _tool('bad1', 'bad'),
          _tool('bad2', 'bad'),
        ], settlement: 'failed'),
        _model('pending', [_tool('pending1', 'pending')], settlement: null),
      ]);
      source.entries.add(
        const ChatEntry(
          id: 'a1',
          role: 'assistant',
          content: 'Inspection complete',
          runId: null,
          feedback: null,
        ),
      );
      source.finish();
      await _frames(tester);
      expect(find.text('COMPACT read'), findsOneWidget);
      expect(find.text('Read these two files'), findsOneWidget);
      expect(find.text('Safe summary'), findsOneWidget);
      expect(find.text('Not batch narration'), findsNothing);
      expect(find.text('Never display'), findsNothing);
      expect(find.text('COMPACT bad1'), findsNothing);
      expect(find.text('COMPACT pending1'), findsNothing);
      expect(source.built.toSet(), {'read'});
      final user = tester.getTopLeft(find.text('Inspect files')).dy;
      final single = tester.getTopLeft(find.text('COMPACT read')).dy;
      final batch = tester.getTopLeft(find.text('Read these two files')).dy;
      final answer = tester.getTopLeft(find.text('Inspection complete')).dy;
      expect(user, lessThan(single));
      expect(single, lessThan(batch));
      expect(batch, lessThan(answer));
      await tester.tap(find.text('COMPACT read'));
      await tester.tap(find.text('Read these two files'));
      await tester.tap(find.text('Safe summary'));
      expect(source.inspected, ['read', 'batch', 'native']);
      final style = tester
          .widget<Text>(find.text('Read these two files'))
          .style!;
      expect(style.fontSize, 12);
      expect(style.color, Colors.grey);
      expect(find.byType(Card), findsNothing);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _frames(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single safe native is compact; groups use safe text then operation count',
    (tester) async {
      await _submit(tester, generation, source, 'Observe');
      source.models.addAll([
        _model('single-native', [
          _text('Final text is not narration'),
          _native('safe', 'Native compact'),
        ]),
        _model('mixed', [
          _tool('tool', 'run'),
          _native('native', 'Safe\u202E heading'),
        ]),
        _model('count', [_tool('t1', 'read'), _tool('t2', 'write')]),
      ]);
      source.notifyListeners();
      await _frames(tester);
      expect(find.text('COMPACT safe'), findsOneWidget);
      expect(find.text(r'Safe\u202E heading'), findsOneWidget);
      expect(find.text('2 operations'), findsOneWidget);
      expect(find.text('Final text is not narration'), findsNothing);
      expect(find.text('1 operations'), findsNothing);
    },
  );

  testWidgets(
    'retained activity opens on snapshot without scheduling and precedes answers',
    (tester) async {
      source.entries.addAll(const [
        ChatEntry(
          id: 'u1',
          role: 'user',
          content: 'Historical question',
          runId: 'historical-run',
          feedback: null,
        ),
        ChatEntry(
          id: 'a1',
          role: 'assistant',
          content: 'Historical answer',
          runId: null,
          feedback: null,
        ),
        ChatEntry(
          id: 'u2',
          role: 'user',
          content: 'Evidence unavailable',
          runId: 'missing-run',
          feedback: null,
        ),
        ChatEntry(
          id: 'u3',
          role: 'user',
          content: 'Not associated',
          runId: null,
          feedback: null,
        ),
      ]);
      source.historicalHandles['historical-run'] = 'retained-handle';
      source.activities['retained-handle'] = [
        _model('historical-single', [_tool('historical-tool', 'read_file')]),
        _model('historical-group', [
          _text('Retained tool and summary'),
          _tool('group-tool', 'run_command'),
          _native('group-native', 'Approved summary'),
        ]),
        _model('historical-opaque', [
          _native('hidden', 'Never display', safe: false),
        ]),
      ];
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(source.opened, ['historical-run', 'missing-run']);
      expect(source.starts, 0);
      expect(source.submitted, isEmpty);
      expect(source.writes, isEmpty);
      expect(find.text('COMPACT historical-tool'), findsOneWidget);
      expect(find.text('Retained tool and summary'), findsOneWidget);
      expect(find.text('Never display'), findsNothing);
      expect(find.text('Evidence unavailable'), findsOneWidget);
      expect(find.text('Not associated'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Historical question')).dy,
        lessThan(tester.getTopLeft(find.text('COMPACT historical-tool')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Retained tool and summary')).dy,
        lessThan(tester.getTopLeft(find.text('Historical answer')).dy),
      );
      await tester.tap(find.text('COMPACT historical-tool'));
      await tester.tap(find.text('Retained tool and summary'));
      expect(source.inspected, ['historical-tool', 'historical-group']);
      expect(source.starts, 0);
      source.notifyListeners();
      await _frames(tester);
      expect(source.opened, ['historical-run', 'missing-run']);
      expect(find.text('COMPACT historical-tool'), findsOneWidget);
      expect(find.text('Retained tool and summary'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'snapshot association never replaces or duplicates a live handle',
    (tester) async {
      await _submit(tester, generation, source, 'Live question');
      source.models.add(
        _model('live-model', [_tool('live-tool', 'read_file')]),
      );
      final entry = source.entries.single;
      source.entries[0] = ChatEntry(
        id: entry.id,
        role: entry.role,
        content: entry.content,
        runId: 'recorded-run',
        feedback: entry.feedback,
      );
      source.historicalHandles['recorded-run'] = 'retained-handle';
      source.activities['retained-handle'] = [
        _model('duplicate', [_tool('duplicate-tool', 'read_file')]),
      ];
      source.finish();
      await _frames(tester);
      expect(source.opened, isEmpty);
      expect(find.text('COMPACT live-tool'), findsOneWidget);
      expect(find.text('COMPACT duplicate-tool'), findsNothing);
      expect(source.starts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      source.active = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(source.opened, ['recorded-run']);
      expect(find.text('COMPACT live-tool'), findsNothing);
      expect(find.text('COMPACT duplicate-tool'), findsOneWidget);
      expect(source.starts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final duringHydration in [false, true]) {
    for (final waiting in [false, true]) {
      testWidgets(
        'reattach discovers ${waiting ? 'waiting' : 'live'} association ${duringHydration ? 'during' : 'after'} hydration without evidence polling',
        (tester) async {
          source.running = true;
          source.advancing = !waiting;
          source.entries.add(
            const ChatEntry(
              id: 'accepted',
              role: 'user',
              content: 'Retained request',
              runId: null,
              feedback: null,
            ),
          );
          final gate = Completer<void>();
          if (duringHydration) source.snapshotGate = gate;
          await tester.pumpWidget(_host(generation, source));
          await _frames(tester);
          expect(source.snapshotReads, 1);
          source.entries[0] = const ChatEntry(
            id: 'accepted',
            role: 'user',
            content: 'Retained request',
            runId: 'retained-live',
            feedback: null,
          );
          source.historicalHandles['retained-live'] = 'fresh-live-handle';
          source.activities['fresh-live-handle'] = [
            _model('retained-model', [_tool('retained-tool', 'read_file')]),
          ];
          source.sessionStateRevision++;
          source.notifyListeners();
          if (duringHydration) gate.complete();
          await _frames(tester);
          expect(source.snapshotReads, 2);
          expect(source.opened, ['retained-live']);
          expect(find.text('Retained request'), findsOneWidget);
          expect(find.text('COMPACT retained-tool'), findsOneWidget);
          expect(_state(tester).editable, isFalse);
          for (var evidence = 0; evidence < 3; evidence++) {
            source.notifyListeners();
            await _frames(tester);
          }
          expect(source.snapshotReads, 2);
          expect(source.opened, ['retained-live']);
          await tester.tap(find.text('COMPACT retained-tool'));
          expect(source.inspected, ['retained-tool']);
          expect(source.starts, 0);
          expect(source.writes, isEmpty);
          expect(source.submitted, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final initialHydration in [false, true]) {
    testWidgets(
      'completion during ${initialHydration ? 'initial' : 'association'} hydration publishes final answer exactly once',
      (tester) async {
        source.running = true;
        source.advancing = true;
        source.entries.add(
          const ChatEntry(
            id: 'accepted',
            role: 'user',
            content: 'Finishing request',
            runId: null,
            feedback: null,
          ),
        );
        final gate = Completer<void>();
        if (initialHydration) source.snapshotGate = gate;
        await tester.pumpWidget(_host(generation, source));
        await _frames(tester);
        if (!initialHydration) source.snapshotGate = gate;
        source.entries[0] = const ChatEntry(
          id: 'accepted',
          role: 'user',
          content: 'Finishing request',
          runId: 'finishing-run',
          feedback: null,
        );
        source.historicalHandles['finishing-run'] = 'fresh-finished-handle';
        source.activities['fresh-finished-handle'] = [
          _model('finishing-model', [_tool('finishing-tool', 'read_file')]),
        ];
        source.sessionStateRevision++;
        source.notifyListeners();
        await _frames(tester);
        source.entries.add(
          const ChatEntry(
            id: 'final',
            role: 'assistant',
            content: 'Final canonical answer',
            runId: null,
            feedback: null,
          ),
        );
        source.finish();
        await _frames(tester);
        gate.complete();
        await _frames(tester);
        expect(find.text('Finishing request'), findsOneWidget);
        expect(find.text('Final canonical answer'), findsOneWidget);
        expect(find.text('COMPACT finishing-tool'), findsOneWidget);
        expect(source.snapshotReads, initialHydration ? 2 : 3);
        final reads = source.snapshotReads;
        source.notifyListeners();
        await _frames(tester);
        expect(source.snapshotReads, reads);
        expect(source.starts, 0);
        expect(source.submitted, isEmpty);
        expect(
          tester.getTopLeft(find.text('COMPACT finishing-tool')).dy,
          lessThan(tester.getTopLeft(find.text('Final canonical answer')).dy),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unassociated activity remains presentation-local across follow-up snapshots',
    (tester) async {
      await _submit(tester, generation, source, 'First prompt');
      source.models.add(
        _model('first-batch', [_tool('t1', 'read'), _tool('t2', 'read')]),
      );
      source.finish();
      await _frames(tester);
      await _enterText(tester, 'Follow-up');
      await tester.tap(find.text('Send'));
      await _frames(tester);
      expect(find.text('2 operations'), findsOneWidget);
      expect(source.entries, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(source.hasSubscriptions, isFalse);
      source.active = true;
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      expect(find.text('First prompt'), findsOneWidget);
      expect(find.text('2 operations'), findsNothing);
    },
  );

  testWidgets('initial snapshot failure is visible and explicitly retryable', (
    tester,
  ) async {
    source.failSnapshot = true;
    source.draftRequest = '  Restored after retry\n ';
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    expect(
      find.text('Chat history is unavailable. Retry to refresh.'),
      findsOneWidget,
    );
    expect(find.byType(NativeRichDocumentEditorView), findsNothing);
    expect(find.byType(AppFlowyEditor), findsNothing);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    final gate = Completer<void>();
    source.snapshotGate = gate;
    source.failSnapshot = false;
    await tester.tap(find.text('Retry history'));
    await _frames(tester);
    expect(find.byType(NativeRichDocumentEditorView), findsNothing);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    gate.complete();
    await _frames(tester);
    expect(_state(tester).editable, isTrue);
    expect(_draft(tester), '  Restored after retry\n ');
    expect(source.writes, isEmpty);
  });

  testWidgets(
    'history retry after initial recovery cannot replace local edits',
    (tester) async {
      source.failSnapshot = true;
      source.draftRequest = 'Original';
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      source.failSnapshot = false;
      await tester.tap(find.text('Retry history'));
      await _frames(tester);
      expect(_draft(tester), 'Original');
      source.running = true;
      source.notifyListeners();
      await _frames(tester);
      source.failSnapshot = true;
      source.finish();
      await _frames(tester);
      expect(find.text('Retry history'), findsOneWidget);
      source.failSnapshot = false;
      final gate = Completer<void>();
      source.snapshotGate = gate;
      await tester.tap(find.text('Retry history'));
      await _frames(tester);
      await _enterText(tester, 'Newer local text');
      await _frames(tester);
      gate.complete();
      await _frames(tester);
      expect(_draft(tester), 'Newer local text');
      expect(source.draftRequest, 'Newer local text');
      expect(find.text('Retry history'), findsNothing);
      expect(source.writes, ['Newer local text']);
    },
  );

  testWidgets('initial snapshot retry admits no input before canonical load', (
    tester,
  ) async {
    source.failSnapshot = true;
    source.draftRequest = 'Stored draft';
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    source.failSnapshot = false;
    final gate = Completer<void>();
    source.snapshotGate = gate;
    await tester.tap(find.text('Retry history'));
    await _frames(tester);
    expect(find.byType(NativeRichDocumentEditorView), findsNothing);
    expect(find.byType(AppFlowyEditor), findsNothing);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(source.writes, isEmpty);
    expect(source.submitted, isEmpty);
    expect(source.starts, 0);
    gate.complete();
    await _frames(tester);
    expect(_draft(tester), 'Stored draft');
    expect(source.draftRequest, 'Stored draft');
    expect(_state(tester).editable, isTrue);
    expect(source.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final sending in [false, true]) {
    testWidgets(
      'disposal during save stops queued edits${sending ? ' and Send' : ''}',
      (tester) async {
        final gate = Completer<void>();
        source.saveGate = gate;
        await tester.pumpWidget(_host(generation, source));
        await _frames(tester);
        await _enterText(tester, 'In flight');
        await _enterText(tester, 'Queued');
        if (sending) await tester.tap(find.text('Send'));
        await _frames(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(source.hasSubscriptions, isFalse);
        gate.complete();
        await _frames(tester);
        expect(source.writes, ['In flight']);
        expect(source.submitted, isEmpty);
        expect(source.starts, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('disposal rejects late history retry settlement', (tester) async {
    source.failSnapshot = true;
    await tester.pumpWidget(_host(generation, source));
    await _frames(tester);
    source.failSnapshot = false;
    source.draftRequest = 'Late restored text';
    final gate = Completer<void>();
    source.snapshotGate = gate;
    await tester.tap(find.text('Retry history'));
    await _frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await _frames(tester);
    expect(source.hasSubscriptions, isFalse);
    expect(source.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retirement rejects late submission settlement and removes subscriptions',
    (tester) async {
      source.submitGate = Completer<void>();
      await tester.pumpWidget(_host(generation, source));
      await _frames(tester);
      await _enterText(tester, 'Late submission');
      await tester.tap(find.text('Send'));
      await _frames(tester);
      generation.invalidate();
      await tester.pumpWidget(const SizedBox.shrink());
      source.submitGate!.complete();
      await _frames(tester);
      expect(source.starts, 0);
      expect(source.hasSubscriptions, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'real EVC generated codecs reject malformed canonical snapshots',
    () async {
      final sources = await chatFrontendSources(
        Directory.current.parent.parent.parent.parent,
      );
      const library = 'package:probe/main.dart';
      sources['probe'] = {
        'main.dart': '''
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
Future<String> read() async {
  final result = await settleSessionOperation(ChatSessionServiceClient(OwningBackendRequestChannel(chatSessionServiceId)).snapshot('session'));
  if (result[0] != true) return 'rejected';
  final snapshot = result[1] as ChatSessionSnapshot;
  return snapshot.entries[0].content;
}
Future<bool> configure() async {
  final client = ChatSessionServiceClient(OwningBackendRequestChannel(chatSessionServiceId));
  final String instructions = 'configured instructions';
  final result = await settleSessionOperation(client.configureSession('session', instructions));
  return result[0] == true;
}
''',
      };
      final compiler = Compiler()
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const ScrollViewBridge())
        ..addPlugin(const MainContentDeclarations())
        ..addPlugin(const RichDocumentEditorDeclarations())
        ..addPlugin(const SessionContentInspectionDeclarations())
        ..addPlugin(const OwningBackendDeclarations())
        ..addPlugin(const SessionExecutionDeclarations())
        ..addPlugin(const SessionPresentationLifecycleDeclarations())
        ..entrypoints.add('package:adele_contract/adele_contract.dart')
        ..entrypoints.add(
          'package:chat_strategy_contract/chat_strategy_contract.dart',
        )
        ..entrypoints.add(library);
      final program = compiler.compile(sources);
      final valid = <String, Object?>{
        'entries': [
          {
            'id': 'entry',
            'role': 'user',
            'content': 'decoded',
            'runId': null,
            'feedback': null,
          },
        ],
        'instructions': '',
        'draftRequest': '',
      };
      for (final data in <Object?>[
        valid,
        for (final feedback in <Object?>[
          'review',
          {'kind': 'unknown', 'submissionId': 'submission', 'commentCount': 1},
          {'kind': 'codeReview', 'submissionId': 42, 'commentCount': 1},
          {
            'kind': 'codeReview',
            'submissionId': 'submission',
            'commentCount': '1',
          },
          {'kind': 'codeReview', 'submissionId': 'submission'},
        ])
          {
            ...valid,
            'entries': [
              {
                'id': 'entry',
                'role': 'user',
                'content': 'decoded',
                'runId': null,
                'feedback': feedback,
              },
            ],
          },
        {...valid, 'unknown': true},
        {'entries': valid['entries'], 'instructions': ''},
        {...valid, 'maxModelInvocations': 3},
        {...valid}..remove('draftRequest'),
        {...valid, 'draftRequest': null},
        {...valid, 'draftRequest': 42},
        {
          ...valid,
          'entries': [
            {'id': 'entry', 'role': 'user', 'content': 'decoded'},
          ],
        },
        {
          ...valid,
          'entries': [
            {'id': 'entry', 'role': 'user', 'content': 'decoded', 'runId': 42},
          ],
        },
        {
          ...valid,
          'entries': [
            {'id': 'entry', 'role': 'user'},
          ],
        },
        {
          ...valid,
          'entries': [
            {'id': 'entry', 'role': 'user', 'content': null},
          ],
        },
        {
          ...valid,
          'entries': [42],
        },
      ]) {
        final bridge = OwningBackendBridge(
          channels: {chatSessionServiceId: _ResponseChannel(data)},
          validateBinding: () {},
        );
        final runtime = Runtime(program.write().buffer.asByteData())
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge)
          ..addPlugin(
            SessionExecutionBridge(source: source, isActive: () => true),
          );
        final result = await runtime.executeLib(library, 'read');
        expect(
          result is $Value ? result.$reified : result,
          identical(data, valid) ? 'decoded' : 'rejected',
        );
        bridge.invalidate();
      }
      for (final data in <Object?>[null, true, <String, Object?>{}]) {
        final channel = _ResponseChannel(data);
        final bridge = OwningBackendBridge(
          channels: {chatSessionServiceId: channel},
          validateBinding: () {},
        );
        final runtime = Runtime(program.write().buffer.asByteData())
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge)
          ..addPlugin(
            SessionExecutionBridge(source: source, isActive: () => true),
          );
        final result = await runtime.executeLib(library, 'configure');
        expect((result as $Value).$reified, data == null);
        expect(channel.calls.single.$1, 'chat.session.configureSession');
        expect(channel.calls.single.$2, {
          'sessionId': 'session',
          'instructions': 'configured instructions',
        });
        bridge.invalidate();
      }
    },
  );
}

ChatEntry _feedbackEntry(
  String id,
  int count, {
  String? runId,
  String role = 'user',
  String? submissionId,
}) => ChatEntry(
  id: id,
  role: role,
  content: 'Hidden canonical model content for $id',
  runId: runId,
  feedback: ChatEntryFeedback(
    kind: ChatFeedbackKind.codeReview,
    submissionId: submissionId ?? 'submission-$id',
    commentCount: count,
  ),
);

ChatAcceptedFeedback _acceptedFeedback({
  String sessionId = 'session-opaque',
  String occurrenceId = 'review',
  String submissionId = 'submission',
  int commentCount = 3,
}) => ChatAcceptedFeedback(
  sessionId: sessionId,
  occurrenceId: occurrenceId,
  submissionId: submissionId,
  kind: ChatFeedbackKind.codeReview,
  runId: 'historical-run',
  comments: [
    for (var index = 0; index < commentCount; index++)
      ChatFeedbackComment(
        id: index < 3 ? ['first', 'second', 'third'][index] : 'comment-$index',
        text: index == 0
            ? 'A\nB\r\t\u001B\u202E\u200B\\literal'
            : index == 1
            ? 'Full long comment ${'x' * 2200} end'
            : 'Final original comment',
        version: index + 2,
        sequence: index * 3 + 1,
        anchor: ChatFeedbackAnchor(
          environmentId: 'environment-$index',
          relativePath: index == 0
              ? 'lib/\u200Bfirst.dart'
              : 'lib/file-$index.dart',
          layer: ChatFeedbackComparisonLayer.values[index % 3],
          side: index == 0
              ? ChatFeedbackComparisonSide.oldSide
              : ChatFeedbackComparisonSide.newSide,
          startLine: index + 10,
          endLine: index + 12,
          comparisonIdentity: 'comparison-$index',
          sourceExcerpt: index == 0
              ? 'old\r\n\u2066source\uFEFF'
              : 'original excerpt $index',
          hunkIndex: index,
          lineIndex: index * 2,
        ),
      ),
  ],
);

Widget _inspectionHost(
  PreparedFrontend generation,
  _FeedbackContext context,
  AdeleRequestChannel backend, {
  bool backendAvailable = true,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: generation.createPresentation(
        library: chatFrontendLibrary,
        entrypoint: 'buildChatFeedbackInspection',
        key: ObjectKey(context),
        createBridge: () {
          OwningBackendBridge? owning;
          final facts = SessionContentInspectionBridge(
            context: context,
            isActive: () => true,
            onInvalidate: () => owning?.invalidate(),
          );
          final backendBridge = OwningBackendBridge(
            channels: {
              if (backendAvailable) chatFeedbackInspectionServiceId: backend,
            },
            validateBinding: () {
              facts.validate();
              if (backend is _FeedbackSource && !backend.active) {
                throw StateError('PRIVATE backend retired');
              }
            },
          );
          owning = backendBridge;
          return PreparedFrontendBridges([facts, backendBridge]);
        },
      ),
    ),
  ),
);

final class _FeedbackContext extends ChangeNotifier
    implements SessionContentInspectionContext {
  @override
  final session = Session(
    id: SessionId('session-opaque'),
    taskId: TaskId('task'),
    strategyId: chatStrategyId,
  );
  @override
  final kind = SessionContentKind(chatFeedbackInspectionKind);
  @override
  final occurrenceId = SessionContentOccurrenceId('review');
  @override
  bool isActive = true;
  bool get hasSubscriptions => hasListeners;

  void retire() {
    isActive = false;
    notifyListeners();
  }
}

final class _FeedbackSource
    implements ChatFeedbackInspectionService, AdeleRequestChannel {
  _FeedbackSource(this.feedback);
  final ChatAcceptedFeedback feedback;
  late final dispatcher = ChatFeedbackInspectionServiceDispatcher(this);
  final calls = <(String, Map<String, Object?>)>[];
  Completer<void>? gate;
  Object? failure;
  bool active = true;

  @override
  Future<ChatAcceptedFeedback> readAcceptedFeedback(
    String sessionId,
    String occurrenceId,
  ) async {
    await gate?.future;
    final error = failure;
    if (error != null) throw error;
    return feedback;
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method, payload));
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': calls.length,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) throw StateError('PRIVATE rejected retrieval');
    return response['payload'];
  }
}

Future<void> _submit(
  WidgetTester tester,
  PreparedFrontend generation,
  _Source source,
  String prompt,
) async {
  await tester.pumpWidget(_host(generation, source));
  await _frames(tester);
  await _enterText(tester, prompt);
  await tester.tap(find.text('Send'));
  await _frames(tester);
}

Widget _host(PreparedFrontend generation, _Source source) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.linux),
  home: Scaffold(body: _presentation(generation, source)),
);

Widget _presentation(
  PreparedFrontend generation,
  _Source source, {
  bool backendAvailable = true,
}) => generation.createPresentation(
  library: chatFrontendLibrary,
  entrypoint: 'buildChat',
  key: ObjectKey(source),
  createBridge: () {
    source.serviceAcquisitions++;
    if (!backendAvailable) throw StateError('Backend unavailable');
    return PreparedFrontendBridges([
      MainContentBridge(
        context: const {'sessionId': 'session-opaque'},
        isActive: () => source.active,
        inspectSessionContent: (kind, occurrence) {
          source.contentInspections.add((kind.value, occurrence.value));
          return source.inspectContent?.call(kind, occurrence) ?? true;
        },
      ),
      source.lifecycle = SessionPresentationLifecycleBridge(
        isActive: () => source.active,
      ),
      RichDocumentEditorBridge(isActive: () => source.active),
      SessionExecutionBridge(source: source, isActive: () => source.active),
      OwningBackendBridge(
        channels: {chatSessionServiceId: source},
        validateBinding: () {
          if (!source.active) throw StateError('Retired fixture');
        },
      ),
    ]);
  },
);

NativeRichDocumentEditor _owner(WidgetTester tester) => tester
    .widget<NativeRichDocumentEditorView>(
      find.byType(NativeRichDocumentEditorView),
    )
    .editor;

EditorState _state(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

String _draft(WidgetTester tester) =>
    _owner(tester).snapshot()['markdown']! as String;

Future<void> _frames(WidgetTester tester) async {
  // AppFlowy cursor and selection animations do not necessarily settle.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _select(WidgetTester tester, Selection selection) async {
  tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .focusNode!
      .requestFocus();
  await _frames(tester);
  _state(tester).selection = selection;
  await _frames(tester);
  expect(tester.testTextInput.hasAnyClients, isTrue);
}

Future<void> _enterText(WidgetTester tester, String text) async {
  final nodes = _state(tester).document.root.children;
  await _select(
    tester,
    Selection(
      start: Position(path: nodes.first.path),
      end: Position(path: nodes.last.path, offset: nodes.last.delta!.length),
    ),
  );
  await _insertText(tester, text);
}

Future<void> _insertText(WidgetTester tester, String text) async {
  final value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  final range = value.selection;
  await _input(
    tester,
    TextEditingValue(
      text: value.text.replaceRange(range.start, range.end, text),
      selection: TextSelection.collapsed(offset: range.start + text.length),
    ),
  );
}

Future<void> _input(WidgetTester tester, TextEditingValue value) async {
  // The test IME does not retain updates, and AppFlowy need not echo them.
  tester.testTextInput.editingState = value.toJSON();
  tester.testTextInput.updateEditingValue(value);
  await _frames(tester);
}

Future<void> _control(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _frames(tester);
}

Future<void> _pasteClipboard(
  WidgetTester tester,
  String text, {
  bool literal = false,
}) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  final previous = messenger.allMessagesHandler;
  final channel = SystemChannels.platform;
  var reads = 0;
  messenger.allMessagesHandler = (name, handler, message) {
    if (name == channel.name && message != null) {
      final call = channel.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.getData') {
        expect(call.arguments, Clipboard.kTextPlain);
        reads++;
        return Future.value(
          channel.codec.encodeSuccessEnvelope({'text': text}),
        );
      }
    }
    if (previous != null) return previous(name, handler, message);
    return handler != null
        ? handler(message)
        : messenger.delegate.send(name, message);
  };
  try {
    if (literal) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _control(tester, LogicalKeyboardKey.keyV);
    expect(reads, 1);
  } finally {
    if (literal) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    messenger.allMessagesHandler = previous;
  }
}

Map<String, Object?> _model(
  String handle,
  List<Map<String, Object?>> outputs, {
  String? settlement = 'completed',
}) => {
  'handle': handle,
  'sequence': 0,
  'settlement': settlement,
  'outputs': outputs,
};
Map<String, Object?> _tool(String handle, String alias) => {
  'kind': 'tool',
  'handle': handle,
  'alias': alias,
};
Map<String, Object?> _text(String content) => {
  'kind': 'text',
  'handle': 'text-$content',
  'content': content,
};
Map<String, Object?> _native(
  String handle,
  String compactText, {
  bool safe = true,
}) => {
  'kind': 'native',
  'handle': handle,
  'compactText': compactText,
  'presentation': safe ? {'compactText': compactText} : null,
};

class _ResponseChannel implements AdeleRequestChannel {
  _ResponseChannel(this.response);
  final Object? response;
  final calls = <(String, Map<String, Object?>)>[];
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method, payload));
    return response;
  }
}

class _Source extends ChangeNotifier
    implements SessionExecutionSource, ChatSessionService, AdeleRequestChannel {
  // Match the actual backend so the frontend, not transport serialization,
  // must enforce sequential saves while history snapshots are pending.
  late final dispatcher = ChatSessionServiceDispatcher(this, concurrent: true);
  late SessionPresentationLifecycleBridge lifecycle;
  bool get hasSubscriptions => hasListeners;
  final entries = <ChatEntry>[];
  final submitted = <String>[];
  final writes = <String>[];
  final events = <String>[];
  final inspected = <String>[];
  final contentInspections = <(String, String)>[];
  bool Function(SessionContentKind, SessionContentOccurrenceId)? inspectContent;
  final built = <String>[];
  final opened = <String>[];
  final historicalHandles = <String, String>{};
  final calls = <(String, Map<String, Object?>)>[];
  final activities = <String, List<Map<String, Object?>>>{};
  List<Map<String, Object?>> get models => activities['run-$starts']!;
  Completer<void>? submitGate;
  Completer<void>? saveGate;
  Completer<void>? startGate;
  Completer<void>? snapshotGate;
  bool active = true;
  bool running = false;
  bool advancing = false;
  bool failSubmit = false;
  bool failSave = false;
  bool failSnapshot = false;
  bool failStart = false;
  bool finishDuringStart = false;
  String? failure;
  int starts = 0;
  int serviceAcquisitions = 0;
  int executionReads = 0;
  int snapshotReads = 0;
  int sessionStateRevision = 0;
  int configurations = 0;
  int inFlightSaves = 0;
  int maxInFlightSaves = 0;
  String draftRequest = '';

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method, payload));
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': calls.length,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) throw StateError('Backend rejected request');
    return response['payload'];
  }

  @override
  Future<ChatSessionSnapshot> snapshot(String sessionId) async {
    snapshotReads++;
    if (failSnapshot) throw StateError('Unavailable');
    final snapshot = ChatSessionSnapshot(
      entries: entries,
      instructions: 'Backend defaults',
      draftRequest: draftRequest,
    );
    final gate = snapshotGate;
    snapshotGate = null;
    await gate?.future;
    return snapshot;
  }

  @override
  Future<ChatEntry> appendUserMessage(String sessionId, String content) async {
    throw StateError('The composer must submit the durable Draft Request.');
  }

  @override
  Future<void> setDraftRequest(String sessionId, String content) async {
    writes.add(content);
    events.add('save:$content');
    inFlightSaves++;
    if (inFlightSaves > maxInFlightSaves) maxInFlightSaves = inFlightSaves;
    final gate = saveGate;
    saveGate = null;
    try {
      await gate?.future;
      if (failSave) {
        throw const ChatSessionFailure(
          code: 'session_busy',
          message: 'Busy fixture',
          details: {},
        );
      }
      draftRequest = content;
      events.add('saved:$content');
    } finally {
      inFlightSaves--;
    }
  }

  @override
  Future<ChatEntry> submitDraftRequest(String sessionId) async {
    final content = draftRequest;
    submitted.add(content);
    events.add('submit:$content');
    await submitGate?.future;
    if (failSubmit) throw StateError('Rejected');
    if (inFlightSaves != 0) throw StateError('Save still pending');
    if (content.trim().isEmpty) throw StateError('Blank draft');
    final entry = ChatEntry(
      id: 'entry-${entries.length}',
      role: 'user',
      content: content,
      runId: null,
      feedback: null,
    );
    entries.add(entry);
    draftRequest = '';
    events.add('accepted:$content');
    return entry;
  }

  @override
  Future<void> configureSession(String sessionId, String instructions) async {
    configurations++;
  }

  @override
  String currentSessionId() {
    executionReads++;
    return 'session-opaque';
  }

  @override
  String? openRunActivity(String runId) {
    opened.add(runId);
    return historicalHandles[runId];
  }

  @override
  Map<String, Object?> readExecution() {
    executionReads++;
    return {
      'canStart': active && !running,
      'running': running,
      'advancing': advancing,
      'failure': failure,
      'sessionStateRevision': sessionStateRevision,
    };
  }

  @override
  Future<String> startRun() async {
    events.add('start');
    starts++;
    await startGate?.future;
    if (failStart) throw StateError('Scheduling failed');
    running = true;
    advancing = true;
    final handle = 'run-$starts';
    activities[handle] = [];
    if (finishDuringStart) {
      entries.add(
        const ChatEntry(
          id: 'quick-answer',
          role: 'assistant',
          content: 'Quick canonical answer',
          runId: null,
          feedback: null,
        ),
      );
      running = false;
      advancing = false;
      sessionStateRevision++;
    }
    notifyListeners();
    return handle;
  }

  void finish() {
    running = false;
    advancing = false;
    sessionStateRevision++;
    notifyListeners();
  }

  @override
  Map<String, Object?> readRunActivity(String handle) => {
    'runHandle': handle,
    'state': running ? 'running' : 'completed',
    'models': activities[handle] ?? [],
  };
  @override
  bool inspectActivity(String handle) {
    if (!active) return false;
    inspected.add(handle);
    return true;
  }

  @override
  Widget buildActivity(String handle) {
    built.add(handle);
    return TextButton(
      onPressed: () => inspectActivity(handle),
      child: Text('COMPACT $handle'),
    );
  }

  @override
  Widget buildStatus() => const SizedBox.shrink();

  @override
  void invalidate() => active = false;
}
