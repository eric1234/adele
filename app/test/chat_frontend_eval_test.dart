import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/chat_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;
  late _Source source;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-chat-eval-');
    artifact = File('${temporary.path}/chat.evc');
    await compileChatFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    source = _Source();
    addTearDown(generation.invalidate);
  });

  test(
    'prepared entrypoint returns a widget after generated snapshot loading',
    () async {
      final runtime = Runtime(artifact.readAsBytesSync().buffer.asByteData())
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(
          PreparedFrontendBridges([
            SessionExecutionBridge(
              source: source,
              isActive: () => source.active,
            ),
            OwningBackendBridge(
              channels: {chatSessionServiceId: source},
              validateBinding: () {},
            ),
          ]),
        );
      final result = await runtime.executeLib(chatFrontendLibrary, 'buildChat');
      expect(result is $Value ? result.$reified : result, isA<Widget>());
    },
  );

  testWidgets(
    'actual EVC reads canonical history through generated transport',
    (tester) async {
      source.entries.addAll(const [
        ChatEntry(id: 'u1', role: 'user', content: 'First question'),
        ChatEntry(id: 'a1', role: 'assistant', content: 'First answer'),
      ]);
      await tester.pumpWidget(_host(generation, source));
      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('First question'), findsOneWidget);
      expect(find.text('First answer'), findsOneWidget);
      expect(source.calls.single.$1, 'chat.session.snapshot');
      expect(source.calls.single.$2, {'sessionId': 'session-opaque'});
      await tester.enterText(find.byType(TextField), '  Next question  ');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(source.submitted, ['  Next question  ']);
      expect(source.starts, 1);
      expect(_draft(tester), isEmpty);
      expect(find.text('  Next question  '), findsOneWidget);
      expect(source.running, isTrue);
      expect(
        source.configurations,
        0,
        reason: 'Defaults belong to the backend.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('append and scheduling both exclude duplicate submits', (
    tester,
  ) async {
    source.appendGate = Completer<void>();
    source.startGate = Completer<void>();
    await tester.pumpWidget(_host(generation, source));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Send once');
    final send = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
        .onPressed!;
    send();
    send();
    await tester.pumpAndSettle();
    expect(source.submitted, ['Send once']);
    expect(source.starts, 0);
    expect(_draft(tester), 'Send once');
    source.appendGate!.complete();
    await tester.pumpAndSettle();
    send();
    expect(source.starts, 1);
    expect(_draft(tester), 'Send once');
    source.startGate!.complete();
    await tester.pumpAndSettle();
    expect(_draft(tester), isEmpty);
    expect(source.submitted, ['Send once']);
    expect(
      source.running,
      isTrue,
      reason: 'Draft clears on scheduling, not completion.',
    );
  });

  testWidgets('blank drafts and unavailable execution never append', (
    tester,
  ) async {
    await tester.pumpWidget(_host(generation, source));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  \n ');
    final send = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
        .onPressed!;
    send();
    await tester.pumpAndSettle();
    expect(source.submitted, isEmpty);
    await tester.enterText(find.byType(TextField), 'Draft');
    source.running = true;
    source.notifyListeners();
    await tester.pumpAndSettle();
    send();
    expect(source.submitted, isEmpty);
    expect(_draft(tester), 'Draft');
  });

  testWidgets(
    'stale terminal snapshot cannot erase a newer accepted occurrence',
    (tester) async {
      await _submit(tester, generation, source, 'Repeated text');
      final gate = Completer<void>();
      source.snapshotGate = gate;
      source.finish();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Repeated text');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Repeated text'), findsNWidgets(2));
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Repeated text'), findsNWidgets(2));
      expect(source.entries.map((entry) => entry.id).toSet(), hasLength(2));
      expect(source.starts, 2);
    },
  );

  testWidgets('Run already terminal at scheduling refreshes canonical answer', (
    tester,
  ) async {
    source.finishDuringStart = true;
    await _submit(tester, generation, source, 'Quick prompt');
    expect(find.text('Quick canonical answer'), findsOneWidget);
    expect(_draft(tester), isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('append failure preserves draft and does not invent history', (
    tester,
  ) async {
    source.failAppend = true;
    await tester.pumpWidget(_host(generation, source));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(_draft(tester), 'Keep this draft');
    expect(source.entries, isEmpty);
    expect(source.starts, 0);
    expect(
      find.text('Message was not accepted. Your draft is preserved.'),
      findsOneWidget,
    );
    expect(find.text('ADELE'), findsNothing);
    source.failAppend = false;
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(source.entries.single.content, 'Keep this draft');
    expect(_draft(tester), isEmpty);
  });

  testWidgets('scheduling retry reuses the accepted canonical occurrence', (
    tester,
  ) async {
    source.failStart = true;
    await tester.pumpWidget(_host(generation, source));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Accepted once');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(source.entries, hasLength(1));
    expect(_draft(tester), 'Accepted once');
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      find.text('Message accepted, but Run could not start. Retry Send.'),
      findsOneWidget,
    );
    source.failStart = false;
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(source.submitted, ['Accepted once']);
    expect(source.starts, 2);
    expect(_draft(tester), isEmpty);
  });

  for (final resume in [false, true]) {
    testWidgets(
      'refreshes canonical history at terminal${resume ? ' after approval resume' : ''}',
      (tester) async {
        await _submit(tester, generation, source, 'Question');
        if (resume) {
          source.advancing = false;
          source.notifyListeners();
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(find.byType(TextField)).enabled,
            isFalse,
          );
          source.advancing = true;
          source.notifyListeners();
          await tester.pumpAndSettle();
        }
        final reads = source.snapshotReads;
        source.entries.add(
          const ChatEntry(
            id: 'answer',
            role: 'assistant',
            content: 'Canonical final answer',
          ),
        );
        source.finish();
        await tester.pumpAndSettle();
        expect(source.snapshotReads, greaterThan(reads));
        expect(find.text('Canonical final answer'), findsOneWidget);
        expect(find.text('ADELE'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
      },
    );
  }

  testWidgets(
    'failed Run keeps accepted user history without assistant failure',
    (tester) async {
      await _submit(tester, generation, source, 'Failed Run question');
      source.failure = 'Run failed';
      source.finish();
      await tester.pumpAndSettle();
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
        ),
      );
      source.finish();
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(find.text('COMPACT safe'), findsOneWidget);
      expect(find.text(r'Safe\u202E heading'), findsOneWidget);
      expect(find.text('2 operations'), findsOneWidget);
      expect(find.text('Final text is not narration'), findsNothing);
      expect(find.text('1 operations'), findsNothing);
    },
  );

  testWidgets(
    'activity is presentation-lifetime and retained across follow-up snapshots',
    (tester) async {
      await _submit(tester, generation, source, 'First prompt');
      source.models.add(
        _model('first-batch', [_tool('t1', 'read'), _tool('t2', 'read')]),
      );
      source.finish();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Follow-up');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('2 operations'), findsOneWidget);
      expect(source.entries, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(source.hasSubscriptions, isFalse);
      source.active = true;
      await tester.pumpWidget(_host(generation, source));
      await tester.pumpAndSettle();
      expect(find.text('First prompt'), findsOneWidget);
      expect(find.text('2 operations'), findsNothing);
    },
  );

  testWidgets('initial snapshot failure is visible and explicitly retryable', (
    tester,
  ) async {
    source.failSnapshot = true;
    await tester.pumpWidget(_host(generation, source));
    await tester.pumpAndSettle();
    expect(
      find.text('Chat history is unavailable. Retry to refresh.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    source.failSnapshot = false;
    await tester.tap(find.text('Retry history'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets(
    'retirement rejects late append settlement and removes subscriptions',
    (tester) async {
      source.appendGate = Completer<void>();
      await tester.pumpWidget(_host(generation, source));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Late append');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      generation.invalidate();
      await tester.pumpWidget(const SizedBox.shrink());
      source.appendGate!.complete();
      await tester.pumpAndSettle();
      expect(source.starts, 0);
      expect(source.hasSubscriptions, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'real EVC generated codecs reject malformed canonical snapshots',
    () async {
      final sources = await chatFrontendSources(Directory.current.parent);
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
  final int budget = 2 + 3;
  final result = await settleSessionOperation(client.configureSession('session', instructions, budget));
  return result[0] == true;
}
''',
      };
      final compiler = Compiler()
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const OwningBackendDeclarations())
        ..addPlugin(const SessionExecutionDeclarations())
        ..entrypoints.add('package:adele_contract/adele_contract.dart')
        ..entrypoints.add(
          'package:chat_strategy_contract/chat_strategy_contract.dart',
        )
        ..entrypoints.add(library);
      final program = compiler.compile(sources);
      final valid = <String, Object?>{
        'entries': [
          {'id': 'entry', 'role': 'user', 'content': 'decoded'},
        ],
        'instructions': '',
        'maxModelInvocations': 3,
      };
      for (final data in <Object?>[
        valid,
        {...valid, 'unknown': true},
        {'entries': valid['entries'], 'instructions': ''},
        {...valid, 'maxModelInvocations': '3'},
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
          'maxModelInvocations': 5,
        });
        bridge.invalidate();
      }
    },
  );
}

Future<void> _submit(
  WidgetTester tester,
  PreparedFrontend generation,
  _Source source,
  String prompt,
) async {
  await tester.pumpWidget(_host(generation, source));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), prompt);
  await tester.tap(find.text('Send'));
  await tester.pumpAndSettle();
}

Widget _host(PreparedFrontend generation, _Source source) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: generation.createPresentation(
        library: chatFrontendLibrary,
        entrypoint: 'buildChat',
        key: ObjectKey(source),
        createBridge: () => PreparedFrontendBridges([
          SessionExecutionBridge(source: source, isActive: () => source.active),
          OwningBackendBridge(
            channels: {chatSessionServiceId: source},
            validateBinding: () {
              if (!source.active) throw StateError('Retired fixture');
            },
          ),
        ]),
      ),
    ),
  ),
);

String _draft(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;
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
  late final dispatcher = ChatSessionServiceDispatcher(this);
  bool get hasSubscriptions => hasListeners;
  final entries = <ChatEntry>[];
  final submitted = <String>[];
  final inspected = <String>[];
  final built = <String>[];
  final calls = <(String, Map<String, Object?>)>[];
  final activities = <String, List<Map<String, Object?>>>{};
  List<Map<String, Object?>> get models => activities['run-$starts']!;
  Completer<void>? appendGate;
  Completer<void>? startGate;
  Completer<void>? snapshotGate;
  bool active = true;
  bool running = false;
  bool advancing = false;
  bool failAppend = false;
  bool failSnapshot = false;
  bool failStart = false;
  bool finishDuringStart = false;
  String? failure;
  int starts = 0;
  int snapshotReads = 0;
  int configurations = 0;

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
      maxModelInvocations: 4,
    );
    final gate = snapshotGate;
    snapshotGate = null;
    await gate?.future;
    return snapshot;
  }

  @override
  Future<ChatEntry> appendUserMessage(String sessionId, String content) async {
    submitted.add(content);
    await appendGate?.future;
    if (failAppend) throw StateError('Rejected');
    final entry = ChatEntry(
      id: 'entry-${entries.length}',
      role: 'user',
      content: content,
    );
    entries.add(entry);
    return entry;
  }

  @override
  Future<void> configureSession(
    String sessionId,
    String instructions,
    int maxModelInvocations,
  ) async {
    configurations++;
  }

  @override
  String currentSessionId() => 'session-opaque';
  @override
  Map<String, Object?> readExecution() => {
    'canStart': active && !running,
    'running': running,
    'advancing': advancing,
    'failure': failure,
  };
  @override
  Future<String> startRun() async {
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
        ),
      );
      running = false;
      advancing = false;
    }
    notifyListeners();
    return handle;
  }

  void finish() {
    running = false;
    advancing = false;
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
  void invalidate() => active = false;
}
