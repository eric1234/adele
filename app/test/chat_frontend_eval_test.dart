import 'dart:io';

import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/plugins/chat_frontend_bridge.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart';
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
    addTearDown(generation.invalidate);
  });

  testWidgets(
    'opaque native slots nest separate EVC runtimes and contain child failures',
    (tester) async {
      const library = 'package:compact_probe/main.dart';
      final compiler = Compiler()
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const ModelNativeActivityDeclarations())
        ..entrypoints.add(library);
      final program = compiler.compile({
        'compact_probe': {
          'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/model_native_activity_bridge.dart';

Widget buildCompact() => Compact();

class Compact extends StatefulWidget {
  State<Compact> createState() => CompactState();
}

class CompactState extends State<Compact> {
  int count = 0;
  Widget build(BuildContext context) {
    final data = readModelNativeActivityData();
    if (data['broken'] == true && count > 0) {
      throw StateError('private child failure');
    }
    return TextButton(
      onPressed: () { setState(() { count = count + 1; }); },
      child: Text(data['label'] + ': ' + count.toString()),
    );
  }
}
''',
        },
        'adele_ui': {
          'model_native_activity_bridge.dart': File(
            '${Directory.current.parent.path}/packages/ui/lib/'
            'model_native_activity_bridge.dart',
          ).readAsStringSync(),
        },
      });
      final PreparedFrontend child = (await tester.runAsync(() async {
        final file = File('${temporary.path}/compact.evc');
        await file.writeAsBytes(program.write());
        return PreparedFrontend.load(file);
      }))!;
      addTearDown(child.invalidate);
      final source = _Source()
        ..entries.addAll(const [
          ChatPresentationEntry.activity(id: 'first', content: 'First'),
          ChatPresentationEntry.activity(id: 'second', content: 'Second'),
        ]);
      addTearDown(source.dispose);
      final bridges = <ModelNativeActivityBridge>[];
      Widget? slot(String id) => Builder(
        key: ValueKey(id),
        builder: (context) => TextButton(
          key: ValueKey('inspect-$id'),
          onPressed: () {
            if (ChatActivityHostScope.isActiveOf(context)) {
              source.inspectActivity(id);
            }
          },
          child: child.createPresentation(
            key: ValueKey(id),
            library: library,
            entrypoint: 'buildCompact',
            createBridge: () {
              final bridge = ModelNativeActivityBridge(
                presentation: ModelNativePresentation(
                  kind: 'dev.example.compact',
                  compactText: id,
                  data: {'label': id, 'broken': id == 'first'},
                ),
                isActive: () => true,
              );
              bridges.add(bridge);
              return bridge;
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: generation.createChatPresentation(
              source: source,
              isActive: () => true,
              buildActivity: slot,
            ),
          ),
        ),
      );
      expect(find.text('first: 0'), findsOneWidget);
      expect(find.text('second: 0'), findsOneWidget);
      expect(bridges, hasLength(2));
      final inspectFirst = tester
          .widget<TextButton>(find.byKey(const ValueKey('inspect-first')))
          .onPressed!;
      inspectFirst();
      expect(source.inspected, ['first']);
      final runtimes = tester
          .widgetList<$StatefulWidget$bridge>(
            find.byWidgetPredicate(
              (widget) => widget is $StatefulWidget$bridge,
            ),
          )
          .map((widget) => widget.$runtime)
          .toSet();
      expect(runtimes, hasLength(3));
      final chatElement = tester.element(find.text('Chat'));
      final secondElement = tester.element(find.text('second: 0'));
      await tester.enterText(find.byType(TextField), 'Retain Chat draft');
      source.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(bridges, hasLength(2));
      expect(tester.element(find.text('second: 0')), same(secondElement));
      await tester.tap(find.text('second: 0'));
      await tester.pump();
      expect(find.text('second: 1'), findsOneWidget);
      expect(find.text('first: 0'), findsOneWidget);
      await tester.tap(find.text('first: 0'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('second: 1'), findsOneWidget);
      expect(tester.element(find.text('Chat')), same(chatElement));
      expect(_draft(tester), 'Retain Chat draft');
      inspectFirst();
      expect(source.inspected, ['first', 'first']);
      child.invalidate();
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(find.text('Chat'), findsOneWidget);
      expect(_draft(tester), 'Retain Chat draft');
      expect(source.listening, isTrue);
      inspectFirst();
      expect(source.inspected, ['first', 'first', 'first']);
      generation.invalidate();
      inspectFirst();
      expect(source.inspected, ['first', 'first', 'first']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

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
      find.ancestor(of: activity, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(find.byType(TextButton), findsNWidgets(2));
    await tester.tap(activity);
    expect(source.inspected, ['run-1/model-1']);
    expect(source.submitted, isEmpty);
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

  for (final String heading in ['Reading files', '4 operations']) {
    testWidgets('actual EVC renders native activity heading: $heading', (
      WidgetTester tester,
    ) async {
      final _Source source = _Source();
      // A multi-call batch crosses the bridge as one DTO, not individual calls.
      source.entries.add(
        ChatPresentationEntry.activity(id: 'run-1/model-1', content: heading),
      );
      await tester.pumpWidget(_host(generation, source));
      expect(find.text('ACTIVITY: $heading'), findsOneWidget);
      expect(find.textContaining('ACTIVITY: '), findsOneWidget);
      expect(find.text('ADELE'), findsNothing);
      expect(find.text('You'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final supplied in [false, true]) {
    testWidgets(
      '${supplied ? 'null' : 'absent'} native slot never renders an interpreted activity or action',
      (tester) async {
        final source = _Source()
          ..canSubmit = false
          ..entries.addAll(const [
            ChatPresentationEntry(
              role: 'user',
              content: 'Retained user message',
            ),
            ChatPresentationEntry.activity(id: 'single', content: 'read_file'),
            ChatPresentationEntry.activity(
              id: 'group',
              content: '4 operations',
            ),
            ChatPresentationEntry(
              role: 'assistant',
              content: 'Retained answer',
            ),
          ]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: generation.createChatPresentation(
                source: source,
                isActive: () => true,
                buildActivity: supplied ? (_) => null : null,
              ),
            ),
          ),
        );
        expect(find.text('Retained user message'), findsOneWidget);
        expect(find.text('Retained answer'), findsOneWidget);
        expect(find.textContaining('ACTIVITY'), findsNothing);
        expect(find.textContaining('read_file'), findsNothing);
        expect(find.textContaining('4 operations'), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        source.canSubmit = true;
        source.notifyListeners();
        await tester.pump();
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'Still usable');
        expect(find.byType(TextButton), findsOneWidget);
        expect(find.textContaining('ACTIVITY'), findsNothing);
        expect(source.inspected, isEmpty);
        expect(_draft(tester), 'Still usable');
        expect(tester.takeException(), isNull);
      },
    );
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
      await tester.tap(find.text('ACTIVITY: $content'));
      expect(source.inspected.last, 'run-1/model-1');
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
    await tester.tap(activities.at(1));
    expect(source.inspected.last, 'run-1/model-2');
    expect(source.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'activity navigation is independent of submission and revocable',
    (WidgetTester tester) async {
      const String id = '["run/opaque","model,opaque"]';
      final _Source source = _Source()
        ..canSubmit = false
        ..entries.add(
          const ChatPresentationEntry.activity(
            id: id,
            content: 'Inspect while running or awaiting approval',
          ),
        );
      bool active = true;
      await tester.pumpWidget(
        _host(generation, source, isActive: () => active),
      );
      final Finder activity = find.textContaining('ACTIVITY: ');
      final VoidCallback retained = tester
          .widget<TextButton>(
            find.ancestor(of: activity, matching: find.byType(TextButton)),
          )
          .onPressed!;
      await tester.tap(activity);
      expect(source.inspected, [id]);
      expect(source.submitted, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

      source.entries.clear();
      retained();
      expect(source.inspected, [id]);
      source.entries.add(
        const ChatPresentationEntry.activity(
          id: id,
          content: 'Restored retained evidence',
        ),
      );
      active = false;
      retained();
      expect(source.inspected, [id]);
      active = true;
      retained();
      expect(source.inspected, [id, id]);
      source.closed = true;
      retained();
      expect(source.inspected, [id, id]);
      source.closed = false;
      generation.invalidate();
      retained();
      await tester.pumpWidget(const SizedBox.shrink());
      retained();
      expect(source.inspected, [id, id]);
      expect(source.submitted, isEmpty);
      expect(source.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

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
    bool active = true;
    source.entries.addAll(const [
      ChatPresentationEntry(role: 'user', content: 'Inspect files'),
      ChatPresentationEntry.activity(id: 'run-1/model-1', content: 'Read File'),
    ]);
    final ChatFrontendBridge bridge = ChatFrontendBridge(
      source: source,
      isActive: () => active,
    );
    addTearDown(bridge.invalidate);
    final Compiler compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const ChatFrontendDeclarations())
      ..entrypoints.add('package:probe/main.dart');
    final Program program = compiler.compile({
      'probe': {
        'main.dart': '''
import 'package:chat_strategy_frontend/src/chat_frontend_bridge.dart';

bool inspect(String id) => inspectChatActivity(id);

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
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
    bool inspect(String id) =>
        runtime.executeLib('package:probe/main.dart', 'inspect', [$String(id)])
            as bool;
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
    source.canSubmit = false;
    expect(inspect('run-1/model-1'), isTrue);
    for (final String unknown in [
      '',
      '0',
      'run-1/model-2',
      '["run-1","model-1"]',
    ]) {
      expect(inspect(unknown), isFalse);
    }
    expect(source.inspected, ['run-1/model-1']);
    expect(source.submitted, isEmpty);
    source.entries.clear();
    expect(inspect('run-1/model-1'), isFalse);
    source.entries.add(
      const ChatPresentationEntry.activity(
        id: 'run-1/model-1',
        content: 'Still retained',
      ),
    );
    source.closed = true;
    expect(inspect('run-1/model-1'), isFalse);
    source.closed = false;
    active = false;
    expect(inspect('run-1/model-1'), isFalse);
    active = true;
    bridge.invalidate();
    expect(inspect('run-1/model-1'), isFalse);
    expect(source.inspected, ['run-1/model-1']);
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
      buildActivity: (id) {
        final entry = source.entries
            .where((entry) => entry.kind == 'activity' && entry.id == id)
            .firstOrNull;
        if (entry == null) return null;
        return Builder(
          key: ValueKey((source, id)),
          builder: (context) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TextButton(
              onPressed: () {
                if (ChatActivityHostScope.isActiveOf(context) &&
                    (isActive?.call() ?? true)) {
                  source.inspectActivity(id);
                }
              },
              child: Text(
                'ACTIVITY: ${entry.content}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ),
        );
      },
    ),
  ),
);

String _draft(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

class _Source extends ChangeNotifier implements ChatFrontendSource {
  final List<ChatPresentationEntry> entries = [];
  final List<String> submitted = [];
  final List<String> inspected = [];
  bool closed = false;
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

  @override
  bool inspectActivity(String id) {
    if (closed ||
        !entries.any((entry) => entry.kind == 'activity' && entry.id == id)) {
      return false;
    }
    inspected.add(id);
    return true;
  }
}
