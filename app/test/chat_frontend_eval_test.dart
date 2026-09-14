import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/plugins/chat_frontend_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/chat_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;

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
  });

  testWidgets('actual EVC renders history and submits accepted prompts', (
    WidgetTester tester,
  ) async {
    final _Source source = _Source();
    source.entries.addAll(const [
      ChatPresentationEntry(role: 'user', content: 'First question'),
      ChatPresentationEntry(role: 'assistant', content: 'First answer'),
    ]);
    await tester.pumpWidget(_host(generation, source));
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('First question'), findsOneWidget);
    expect(find.text('First answer'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('ADELE'), findsOneWidget);
    expect(find.text('Ask ADELE...'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Next question  ');
    await tester.tap(find.text('Send'));
    await tester.pump();
    await tester.pump();
    expect(source.submitted, ['  Next question  ']);
    expect(_draft(tester), isEmpty);
    expect(find.text('  Next question  '), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('actual EVC renders mixed entries in order with small activity', (
    WidgetTester tester,
  ) async {
    final _Source source = _Source();
    source.entries.addAll(const [
      ChatPresentationEntry(role: 'user', content: 'Inspect these files'),
      ChatPresentationEntry.activity(
        id: 'run-1/model-1',
        content: 'I will read the requested files.',
      ),
      ChatPresentationEntry(role: 'assistant', content: 'Inspection complete'),
    ]);
    await tester.pumpWidget(_host(generation, source));

    final Finder user = find.text('Inspect these files');
    final Finder activity = find.text(
      'ACTIVITY: I will read the requested files.',
    );
    final Finder assistant = find.text('Inspection complete');
    expect(user, findsOneWidget);
    expect(activity, findsOneWidget);
    expect(assistant, findsOneWidget);
    expect(
      tester.getBottomLeft(user).dy,
      lessThan(tester.getTopLeft(activity).dy),
    );
    expect(
      tester.getBottomLeft(activity).dy,
      lessThan(tester.getTopLeft(assistant).dy),
    );
    final TextStyle style = tester.widget<Text>(activity).style!;
    expect(style.color, Colors.grey);
    expect(style.fontSize, 12);
    expect(
      style.fontSize,
      lessThan(DefaultTextStyle.of(tester.element(assistant)).style.fontSize!),
    );
    expect(style.fontWeight, isNot(FontWeight.bold));
    expect(find.text('You'), findsOneWidget);
    expect(find.text('ADELE'), findsOneWidget);
    expect(find.textContaining('ACTIVITY: '), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(
      find.ancestor(
        of: activity,
        matching: find.byWidgetPredicate(
          (widget) => widget is InkWell || widget is GestureDetector,
        ),
      ),
      findsNothing,
    );
    expect(find.byType(TextButton), findsOneWidget);
    expect(find.text('Frontend unavailable.'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    expect(activity, findsOneWidget);
    expect(assistant, findsOneWidget);
    expect(tester.getBottomRight(activity).dx, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
  });

  for (final String fallback in ['Read File', '4 tool calls']) {
    testWidgets('actual EVC renders supplied activity fallback: $fallback', (
      WidgetTester tester,
    ) async {
      final _Source source = _Source();
      // A multi-call batch crosses the bridge as one DTO, not individual calls.
      source.entries.add(
        ChatPresentationEntry.activity(id: 'run-1/model-1', content: fallback),
      );
      await tester.pumpWidget(_host(generation, source));
      expect(find.text('ACTIVITY: $fallback'), findsOneWidget);
      expect(find.textContaining('ACTIVITY: '), findsOneWidget);
      expect(find.text('ADELE'), findsNothing);
      expect(find.text('You'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('actual EVC keeps one header per batch across mounted updates', (
    WidgetTester tester,
  ) async {
    const ChatPresentationEntry user = ChatPresentationEntry(
      role: 'user',
      content: 'Inspect four files',
    );
    final _Source source = _Source()..entries.add(user);
    await tester.pumpWidget(_host(generation, source));
    final TextEditingController controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    for (int update = 0; update < 4; update++) {
      final int reads = source.snapshotReads;
      final String content = 'Reading files, update $update';
      source.entries
        ..clear()
        ..addAll([
          user,
          ChatPresentationEntry.activity(id: 'run-1/model-1', content: content),
        ]);
      source.notifyListeners();
      source.notifyListeners();
      expect(source.snapshotReads, reads);
      await tester.pump();
      expect(source.snapshotReads, reads);
      await tester.pump();
      expect(source.snapshotReads, reads + 1);
      expect(find.text('ACTIVITY: $content'), findsOneWidget);
      expect(find.textContaining('ACTIVITY: '), findsOneWidget);
      expect(find.text('ADELE'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(controller),
      );
      expect(_draft(tester), 'Keep my draft');
    }

    source.entries.addAll(const [
      ChatPresentationEntry.activity(
        id: 'run-1/model-2',
        content: 'Reading files, update 3',
      ),
      ChatPresentationEntry(role: 'assistant', content: 'All files inspected'),
    ]);
    source.notifyListeners();
    await tester.pump();
    await tester.pump();
    final Finder activities = find.text('ACTIVITY: Reading files, update 3');
    expect(activities, findsNWidgets(2));
    expect(find.textContaining('ACTIVITY: '), findsNWidgets(2));
    expect(find.text('You'), findsOneWidget);
    expect(find.text('ADELE'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Inspect four files')).dy,
      lessThan(tester.getTopLeft(activities.at(0)).dy),
    );
    expect(
      tester.getBottomLeft(activities.at(0)).dy,
      lessThan(tester.getTopLeft(activities.at(1)).dy),
    );
    expect(
      tester.getBottomLeft(activities.at(1)).dy,
      lessThan(tester.getTopLeft(find.text('All files inspected')).dy),
    );
    expect(_draft(tester), 'Keep my draft');
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejection and host updates preserve the same composer', (
    WidgetTester tester,
  ) async {
    final _Source source = _Source()..accept = false;
    await tester.pumpWidget(_host(generation, source));
    final TextEditingController controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.tap(find.text('Send'));
    expect(_draft(tester), 'Keep this draft');
    source.entries.add(
      const ChatPresentationEntry(role: 'assistant', content: 'Updated answer'),
    );
    source.canSubmit = false;
    source.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(find.text('Updated answer'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(_draft(tester), 'Keep this draft');
    source.canSubmit = true;
    source.notifyListeners();
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(_host(generation, source));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller,
      same(controller),
    );
    source.accept = true;
    await tester.showKeyboard(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(_draft(tester), isEmpty);
    expect(source.submitted, ['Keep this draft', 'Keep this draft']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank, disabled and stale callbacks cannot submit', (
    WidgetTester tester,
  ) async {
    final _Source source = _Source();
    bool active = true;
    await tester.pumpWidget(_host(generation, source, isActive: () => active));
    await tester.enterText(find.byType(TextField), '  ');
    await tester.tap(find.text('Send'));
    expect(source.submitted, isEmpty);
    final VoidCallback send = tester
        .widget<TextButton>(find.byType(TextButton))
        .onPressed!;
    await tester.enterText(find.byType(TextField), 'Pending draft');
    source.canSubmit = false;
    send();
    expect(source.submitted, isEmpty);
    expect(_draft(tester), 'Pending draft');
    source.canSubmit = true;
    active = false;
    send();
    expect(source.submitted, isEmpty);
    expect(_draft(tester), 'Pending draft');
    active = true;
    generation.invalidate();
    send();
    expect(source.submitted, isEmpty);
    await tester.pump();
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    send();
    source.notifyListeners();
    await tester.pump();
    expect(source.submitted, isEmpty);
    expect(source.listening, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmount detaches subscriptions and rejects late callbacks', (
    WidgetTester tester,
  ) async {
    final _Source source = _Source();
    await tester.pumpWidget(_host(generation, source));
    await tester.enterText(find.byType(TextField), 'Late prompt');
    final VoidCallback send = tester
        .widget<TextButton>(find.byType(TextButton))
        .onPressed!;
    source.entries.add(
      const ChatPresentationEntry.activity(
        id: 'run-1/model-1',
        content: 'Queued before disposal',
      ),
    );
    final int reads = source.snapshotReads;
    source.notifyListeners();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.listening, isFalse);
    expect(source.snapshotReads, reads);
    send();
    source.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(source.submitted, isEmpty);
    expect(source.listening, isFalse);
    expect(source.snapshotReads, reads);
    expect(find.text('ACTIVITY: Queued before disposal'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a generation retains bytes and isolates multiple views', (
    WidgetTester tester,
  ) async {
    final PreparedFrontend retained = (await tester.runAsync(() async {
      final File copy = await artifact.copy('${temporary.path}/retained.evc');
      final PreparedFrontend loaded = await PreparedFrontend.load(copy);
      await copy.writeAsBytes([0, 1, 2]);
      return loaded;
    }))!;
    final _Source first = _Source();
    final _Source second = _Source();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: retained.createChatPresentation(
                  source: first,
                  isActive: () => true,
                ),
              ),
              Expanded(
                child: retained.createChatPresentation(
                  source: second,
                  isActive: () => true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Chat'), findsNWidgets(2));
    await tester.enterText(find.byType(TextField).at(0), 'First draft');
    await tester.enterText(find.byType(TextField).at(1), 'Second draft');
    await tester.tap(find.text('Send').at(1));
    await tester.pump();
    await tester.pump();
    expect(first.submitted, isEmpty);
    expect(second.submitted, ['Second draft']);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'First draft',
    );
    retained.invalidate();
    await tester.pump();
    expect(find.text('Frontend unavailable.'), findsNWidgets(2));
    expect(first.listening, isFalse);
    expect(second.listening, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new source gets a fresh composer within the same generation', (
    WidgetTester tester,
  ) async {
    final _Source first = _Source();
    final _Source second = _Source();
    await tester.pumpWidget(_host(generation, first));
    await tester.enterText(find.byType(TextField), 'Do not carry over');
    await tester.pumpWidget(_host(generation, second));
    expect(_draft(tester), isEmpty);
    expect(first.listening, isFalse);
    expect(second.listening, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host build notifications are deferred safely', (
    WidgetTester tester,
  ) async {
    final _Source source = _Source();
    late StateSetter rebuild;
    bool notify = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              if (notify) source.notifyListeners();
              return generation.createChatPresentation(
                source: source,
                isActive: () => true,
              );
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Survives host build');
    rebuild(() => notify = true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Chat'), findsOneWidget);
    expect(_draft(tester), 'Survives host build');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing and corrupt artifacts produce a bounded unavailable view',
    (WidgetTester tester) async {
      final _Source source = _Source();
      final PreparedFrontend missing = (await tester.runAsync(
        () => PreparedFrontend.load(File('${temporary.path}/missing.evc')),
      ))!;
      expect(missing.failure, isA<FileSystemException>());
      await tester.pumpWidget(_host(missing, source));
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      final PreparedFrontend broken = (await tester.runAsync(() async {
        final File corrupt = File('${temporary.path}/corrupt.evc');
        await corrupt.writeAsBytes([1, 2, 3]);
        return PreparedFrontend.load(corrupt);
      }))!;
      await tester.pumpWidget(_host(broken, source));
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(source.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final String body in [
    'int buildChat() => 42;',
    'int anotherEntry() => 42;',
    "int buildChat() { throw StateError('entry failure'); }",
    "Future<int> buildChat() async { throw StateError('async entry failure'); }",
  ]) {
    testWidgets('bounds invalid entrypoint: $body', (
      WidgetTester tester,
    ) async {
      final Compiler compiler = Compiler()
        ..entrypoints.add(chatFrontendLibrary);
      final program = compiler.compile({
        'chat_strategy_frontend': {'chat_strategy_frontend.dart': body},
      });
      final File invalid = File('${temporary.path}/entry.evc');
      final PreparedFrontend broken = (await tester.runAsync(() async {
        await invalid.writeAsBytes(program.write());
        return PreparedFrontend.load(invalid);
      }))!;
      final _Source source = _Source();
      await tester.pumpWidget(_host(broken, source));
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(source.listening, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  test('host snapshot copies and freezes its primitive entries', () {
    final List<ChatPresentationEntry> entries = [
      const ChatPresentationEntry(role: 'user', content: 'Immutable'),
      const ChatPresentationEntry.activity(
        id: 'run-1/model-1',
        content: 'Read File',
      ),
    ];
    final ChatPresentationSnapshot snapshot = ChatPresentationSnapshot(
      entries: entries,
      canSubmit: true,
    );
    entries.clear();
    expect(snapshot.entries, hasLength(2));
    expect(snapshot.entries.first.kind, 'message');
    expect(snapshot.entries.first.id, isNull);
    expect(snapshot.entries.first.role, 'user');
    expect(snapshot.entries.first.content, 'Immutable');
    expect(snapshot.entries.last.kind, 'activity');
    expect(snapshot.entries.last.id, 'run-1/model-1');
    expect(snapshot.entries.last.role, isNull);
    expect(snapshot.entries.last.content, 'Read File');
    expect(snapshot.entries.clear, throwsUnsupportedError);
  });

  test('compiled EVC reads primitive kinds and exact stable activity IDs', () {
    final _Source source = _Source();
    source.entries.addAll(const [
      ChatPresentationEntry(role: 'user', content: 'Inspect files'),
      ChatPresentationEntry.activity(id: 'run-1/model-1', content: 'Read File'),
    ]);
    final ChatFrontendBridge bridge = ChatFrontendBridge(
      source: source,
      isActive: () => true,
    );
    addTearDown(bridge.invalidate);
    final Compiler compiler = Compiler()
      ..addPlugin(const ChatFrontendDeclarations())
      ..entrypoints.add('package:probe/main.dart');
    final Program program = compiler.compile({
      'probe': {
        'main.dart': '''
import 'package:chat_strategy_frontend/src/chat_frontend_bridge.dart';

List<String?> inspectEntries() {
  final List<String?> result = <String?>[];
  for (final ChatPresentationEntry entry in readChatSnapshot().entries) {
    result.add(entry.kind);
    result.add(entry.id);
    result.add(entry.role);
    result.add(entry.content);
  }
  return result;
}
''',
      },
      'chat_strategy_frontend': {
        'src/chat_frontend_bridge.dart': File(
          '${Directory.current.parent.path}/plugins/chat_strategy/packages/'
          'frontend/lib/src/chat_frontend_bridge.dart',
        ).readAsStringSync(),
      },
    });
    final Runtime runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(bridge);
    expect(
      (runtime.executeLib('package:probe/main.dart', 'inspectEntries')
              as List<$Value>)
          .map((value) => value.$reified),
      [
        'message',
        null,
        'user',
        'Inspect files',
        'activity',
        'run-1/model-1',
        null,
        'Read File',
      ],
    );
    source.entries[1] = const ChatPresentationEntry.activity(
      id: 'run-1/model-1',
      content: 'Reading the next file',
    );
    expect(
      (runtime.executeLib('package:probe/main.dart', 'inspectEntries')
              as List<$Value>)
          .map((value) => value.$reified),
      [
        'message',
        null,
        'user',
        'Inspect files',
        'activity',
        'run-1/model-1',
        null,
        'Reading the next file',
      ],
    );
  });
}

Widget _host(
  PreparedFrontend generation,
  _Source source, {
  bool Function()? isActive,
}) => MaterialApp(
  home: Scaffold(
    body: generation.createChatPresentation(
      source: source,
      isActive: isActive ?? () => true,
    ),
  ),
);

String _draft(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

class _Source extends ChangeNotifier implements ChatFrontendSource {
  final List<ChatPresentationEntry> entries = [];
  final List<String> submitted = [];
  bool canSubmit = true;
  bool accept = true;
  int snapshotReads = 0;

  bool get listening => hasListeners;

  @override
  ChatPresentationSnapshot get snapshot {
    snapshotReads++;
    return ChatPresentationSnapshot(entries: entries, canSubmit: canSubmit);
  }

  @override
  bool submit(String prompt) {
    submitted.add(prompt);
    if (!accept) return false;
    entries.add(ChatPresentationEntry(role: 'user', content: prompt));
    notifyListeners();
    return true;
  }
}
