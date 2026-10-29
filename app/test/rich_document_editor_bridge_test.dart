import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/rich_document_editor_bridge.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:rich_document_probe/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late File artifact;
  late Program program;
  late PreparedFrontend generation;
  String? clipboard;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-rich-document-');
    artifact = File('${temporary.path}/rich-document.evc');
    program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const RichDocumentEditorDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'rich_document_probe': {
                'main.dart': await File(
                  'test/fixtures/rich_document_frontend.dart',
                ).readAsString(),
              },
              'adele_ui': {
                'rich_document_editor_bridge.dart': await File(
                  '${Directory.current.parent.path}/packages/ui/lib/rich_document_editor_bridge.dart',
                ).readAsString(),
              },
            });
    await artifact.writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
    generation = await PreparedFrontend.load(artifact);
    expect(generation.failure, isNull);
  });
  tearDown(() {
    generation.invalidate();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget presentation({
    String entrypoint = 'buildView',
    RichDocumentEditorBridge? bridge,
  }) => generation.createPresentation(
    library: _library,
    entrypoint: entrypoint,
    createBridge: () =>
        bridge ?? RichDocumentEditorBridge(isActive: () => true),
  );

  Runtime bind(RichDocumentEditorBridge bridge) {
    addTearDown(bridge.invalidate);
    return Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
  }

  test('compile declarations cannot be used as native runtime access', () {
    expect(
      () => const RichDocumentEditorDeclarations().configureForRuntime(
        Runtime.ofProgram(program),
      ),
      throwsUnsupportedError,
    );
  });

  test('compiled asynchronous hydration returns a native widget', () async {
    final runtime = bind(RichDocumentEditorBridge(isActive: () => true));
    final value = await runtime.executeLib(_library, 'buildHydratedView');
    expect(value is $Value ? value.$reified : value, isA<Widget>());
  });

  testWidgets(
    'prepared EVC observes native input and explicitly snapshots it',
    (tester) async {
      await tester.pumpWidget(_host(presentation()));
      final state = await _select(tester, 'ab');
      final before = _notifications(tester);
      await _append(tester, '\u{1f600}');
      expect(_notifications(tester), greaterThan(before));
      expect(find.text('Snapshot text: (not requested)'), findsOneWidget);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), contains('ab\u{1f600}'));
      expect(find.text('Snapshot readOnly: false'), findsOneWidget);
      expect(find.text('Snapshot error: '), findsOneWidget);
      final captured = _snapshotText(tester);

      _press(tester, 'Unsubscribe');
      await _frames(tester);
      final unsubscribed = _notifications(tester);
      await _append(tester, '!');
      expect(_notifications(tester), unsubscribed);
      expect(_snapshotText(tester), captured);
      _press(tester, 'Subscribe');
      await _append(tester, '?');
      expect(_notifications(tester), greaterThan(unsubscribed));
      expect(_snapshotText(tester), captured);

      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 2,
      );
      await _frames(tester);
      await _control(tester, LogicalKeyboardKey.keyB);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), contains('**ab**'));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'prepared EVC edits literal code with Enter, multiline paste and Alt+Enter',
    (tester) async {
      await tester.pumpWidget(_host(presentation(entrypoint: 'buildCodeView')));
      final state = await _select(tester, 'ab');
      final node = state.document.root.children.single;
      expect(node.type, 'code_block', reason: '${state.document.toJson()}');
      expect(node.attributes['language'], 'dart');
      expect(node.delta!.toJson(), [
        {'insert': 'ab'},
      ]);
      expect(_notifications(tester), 0);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), '```dart\nab\n```');
      expect(find.text('Snapshot revision: 0'), findsOneWidget);
      expect(find.text('Snapshot readOnly: false'), findsOneWidget);

      await _append(tester, ' **x**');
      expect(_notifications(tester), greaterThan(0));
      expect(_snapshotText(tester), '```dart\nab\n```');
      expect(find.text('Snapshot revision: 0'), findsOneWidget);
      _press(tester, 'Snapshot');
      await _frames(tester);
      final captured = _snapshotText(tester);
      expect(captured, '```dart\nab **x**\n```');
      expect(find.text('Snapshot revision: 0'), findsNothing);

      // Ordinary Enter reaches AppFlowy's character shortcuts through text input.
      await _append(tester, '\n');
      expect(state.document.root.children.single, same(node));
      expect(node.delta!.toPlainText(), 'ab **x**\n');
      await Clipboard.setData(
        const ClipboardData(text: '\t# [x](u) & <b>  \r\n\r\n```  \r\n'),
      );
      await _control(tester, LogicalKeyboardKey.keyV);
      const text = 'ab **x**\n\t# [x](u) & <b>  \n\n```  \n';
      expect(state.document.root.children.single, same(node));
      expect(node.delta!.toJson(), [
        {'insert': text},
      ]);
      expect(node.attributes['language'], 'dart');
      expect(_snapshotText(tester), captured);
      final notices = _notifications(tester);
      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 2,
      );
      await _frames(tester);
      expect(_notifications(tester), notices);
      state.selection = Selection.collapsed(
        Position(path: [0], offset: text.length),
      );
      await _frames(tester);
      _press(tester, 'Snapshot');
      await _frames(tester);
      const serialized = '````dart\n$text\n````';
      expect(_snapshotText(tester), serialized);
      expect(find.text('Snapshot error: '), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await _frames(tester);
      expect(state.document.root.children.map((node) => node.type), [
        'code_block',
        ParagraphBlockKeys.type,
      ]);
      expect(node.delta!.toPlainText(), text);
      await _append(tester, 'after');
      expect(state.document.root.children.last.delta!.toPlainText(), 'after');
      expect(_snapshotText(tester), serialized);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), '$serialized\n\nafter');
      state.selection = Selection.collapsed(Position(path: [0], offset: 2));
      await _frames(tester);
      final beforeRelease = _notifications(tester);
      _press(tester, 'Release');
      expect(state.editable, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await _frames(tester);
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(_notifications(tester), beforeRelease);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compiled editing gate preserves undo and rejects retired handles',
    (tester) async {
      final bridge = RichDocumentEditorBridge(isActive: () => true);
      final runtime = bind(bridge);
      final handle = _create(runtime, 'ab');
      final view = _invoke(runtime, 'buildHandle', [$String(handle)]) as Widget;
      await tester.pumpWidget(_host(view));
      final state = await _select(tester, 'ab');
      await _append(tester, '!');
      _invoke(runtime, 'enableHandle', [$String(handle), false]);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(state.editable, isFalse);
      final snapshot =
          _invoke(runtime, 'snapshotHandle', [$String(handle)]) as Map;
      expect(snapshot['markdown'], 'ab!');
      expect(snapshot['readOnly'], isFalse);
      expect(snapshot['editingEnabled'], isFalse);
      expect(snapshot['isBlank'], isFalse);
      await _frames(tester);
      await _select(tester, 'ab!');
      expect(tester.testTextInput.hasAnyClients, isFalse);
      _invoke(runtime, 'enableHandle', [$String(handle), true]);
      await _frames(tester);
      expect(await _select(tester, 'ab!'), same(state));
      await _control(tester, LogicalKeyboardKey.keyZ);
      expect(state.document.root.children.single.delta!.toPlainText(), 'ab');
      bridge.invalidate();
      expect(
        () => _invoke(runtime, 'enableHandle', [$String(handle), true]),
        throwsA(anything),
      );
      expect(state.editable, isFalse);
      await _frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composition-only commit invalidates the compiled safe snapshot',
    (tester) async {
      await tester.pumpWidget(_host(presentation()));
      final state = await _select(tester, 'ab');
      var value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
      _input(
        tester,
        value.copyWith(composing: const TextRange(start: 1, end: 3)),
      );
      await _frames(tester);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), '(unavailable)');
      expect(find.text('Snapshot error: composition_pending'), findsOneWidget);
      expect(find.text('Snapshot revision: 0'), findsOneWidget);
      final notices = _notifications(tester);
      value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
      _input(tester, value.copyWith(composing: TextRange.empty));
      await _frames(tester);
      expect(_notifications(tester), greaterThan(notices));
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), 'ab');
      expect(find.text('Snapshot revision: 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (fence, language) in [
    ('```dart', 'dart'),
    ('~~~python', 'python'),
  ]) {
    testWidgets('prepared EVC creates code from $fence and ordinary Enter', (
      tester,
    ) async {
      await tester.pumpWidget(_host(presentation()));
      final state = await _select(tester, 'ab');
      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 2,
      );
      await _frames(tester);
      final value = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      _input(
        tester,
        TextEditingValue(
          text: value.text.replaceRange(
            value.selection.start,
            value.selection.end,
            fence,
          ),
          selection: TextSelection.collapsed(
            offset: value.selection.start + fence.length,
          ),
        ),
      );
      await _frames(tester);
      expect(state.document.root.children.single.type, ParagraphBlockKeys.type);
      expect(state.document.root.children.single.delta!.toPlainText(), fence);
      expect(
        state.selection,
        Selection.collapsed(Position(path: [0], offset: fence.length)),
      );
      await _append(tester, '\n');
      expect(
        state.document.root.children,
        hasLength(1),
        reason: '${state.document.toJson()}',
      );
      final node = state.document.root.children.single;
      expect(node.type, 'code_block', reason: '${state.document.toJson()}');
      expect(node.attributes['language'], language);
      expect(node.delta!.toPlainText(), '');
      expect(_notifications(tester), greaterThan(0));
      expect(find.text('Snapshot text: (not requested)'), findsOneWidget);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), '```$language\n\n```');
      await _append(tester, '\t**x**  ');
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), '```$language\n\t**x**  \n```');
      expect(find.text('Snapshot error: '), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final code in [false, true]) {
    testWidgets(
      'rebuild and native unmount retain content and undo/redo (code: $code)',
      (tester) async {
        await tester.pumpWidget(
          _host(presentation(entrypoint: code ? 'buildCodeView' : 'buildView')),
        );
        final state = await _select(tester, 'ab');
        await _append(tester, '!');
        final element = tester.element(find.byType(AppFlowyEditor));
        _press(tester, 'Rebuild');
        await _frames(tester);
        expect(tester.element(find.byType(AppFlowyEditor)), same(element));
        expect(find.text('Rebuilds: 1'), findsOneWidget);
        _press(tester, 'Toggle');
        await _frames(tester);
        expect(element.mounted, isFalse);
        expect(state.isDisposed, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        _press(tester, 'Snapshot');
        await _frames(tester);
        expect(_snapshotText(tester), code ? '```dart\nab!\n```' : 'ab!');
        _press(tester, 'Toggle');
        await _frames(tester);
        expect(await _select(tester, 'ab!'), same(state));
        await _control(tester, LogicalKeyboardKey.keyZ);
        expect(state.document.root.children.single.delta!.toPlainText(), 'ab');
        _press(tester, 'Snapshot');
        await _frames(tester);
        expect(_snapshotText(tester), code ? '```dart\nab\n```' : 'ab');
        await _control(tester, LogicalKeyboardKey.keyY);
        expect(state.document.root.children.single.delta!.toPlainText(), 'ab!');
        _press(tester, 'Snapshot');
        await _frames(tester);
        expect(_snapshotText(tester), code ? '```dart\nab!\n```' : 'ab!');
        await tester.pumpWidget(const SizedBox.shrink());
        expect(state.isDisposed, isTrue);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'plugin can create after asynchronous hydration and import marks',
    (tester) async {
      await tester.pumpWidget(
        _host(presentation(entrypoint: 'buildHydratedView')),
      );
      expect(find.byType(AppFlowyEditor), findsNothing);
      await _frames(tester);
      expect(find.text('hydrated text', findRichText: true), findsOneWidget);
      final state = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      expect(state.document.root.children.single.delta!.toJson(), [
        {'insert': 'hydrated '},
        {
          'insert': 'text',
          'attributes': {'bold': true},
        },
      ]);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), 'hydrated **text**');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retired asynchronous hydration cannot construct a late owner', (
    tester,
  ) async {
    final bridge = RichDocumentEditorBridge(isActive: () => true);
    await tester.pumpWidget(
      _host(presentation(entrypoint: 'buildHydratedView', bridge: bridge)),
    );
    generation.retainPresentations();
    await _frames(tester);
    expect(find.byType(AppFlowyEditor), findsNothing);
    generation.releasePresentations();
    await _frames(tester);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(
      () => bridge.configureForRuntime(Runtime.ofProgram(program)),
      throwsStateError,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only and unsupported imports preserve source explicitly', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(presentation(entrypoint: 'buildReadOnlyView')),
    );
    final state = await _select(tester, 'read-only');
    expect(state.editable, isFalse);
    await _control(tester, LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _frames(tester);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(_snapshotText(tester), 'read-only');
    expect(find.text('Snapshot readOnly: true'), findsOneWidget);
    expect(find.text('Snapshot revision: 0'), findsOneWidget);
    await tester.pumpWidget(
      _host(presentation(entrypoint: 'buildUnsupportedView')),
    );
    await _frames(tester);
    expect(state.isDisposed, isTrue);
    expect(find.byType(AppFlowyEditor), findsNothing);
    expect(find.textContaining('Read-only Markdown:'), findsOneWidget);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(
      _snapshotText(tester),
      '![unsupported](https://example.test/image.png)',
    );
    expect(find.text('Snapshot readOnly: true'), findsOneWidget);
    expect(find.text('Snapshot reason: '), findsNothing);
    expect(find.text('Snapshot error: '), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'prepared read-only code selects and copies without input clients',
    (tester) async {
      await tester.pumpWidget(
        _host(presentation(entrypoint: 'buildReadOnlyCodeView')),
      );
      const text = '  read-only\t**x**  \n';
      final state = await _select(tester, text);
      final node = state.document.root.children.single;
      expect(node.type, 'code_block');
      expect(node.attributes['language'], 'dart');
      expect(node.delta!.toPlainText(), text);
      expect(state.editable, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: text.length,
      );
      await _frames(tester);
      await _control(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, text);
      expect(AppFlowyClipboard.lastText, text);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await Clipboard.setData(const ClipboardData(text: 'denied\npaste'));
      await _control(tester, LogicalKeyboardKey.keyV);
      await _control(tester, LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await _frames(tester);
      expect(node.delta!.toPlainText(), text);
      expect(_notifications(tester), 0);
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester), '~~~dart\n$text\n~~~\n');
      expect(find.text('Snapshot readOnly: true'), findsOneWidget);
      expect(find.text('Snapshot revision: 0'), findsOneWidget);
      expect(find.text('Snapshot error: '), findsOneWidget);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'handles are bounded, runtime-local, copied and permanently revoked',
    (tester) async {
      var active = true;
      final bridge = RichDocumentEditorBridge(isActive: () => active);
      final runtime = bind(bridge);
      final second = bind(RichDocumentEditorBridge(isActive: () => true));
      final handle = _create(runtime, 'original');
      final foreign = _create(second, 'foreign');
      expect(handle, matches(RegExp(r'^[0-9a-f]{48}$')));
      expect(foreign, isNot(handle));
      expect(
        () => bridge.configureForRuntime(Runtime.ofProgram(program)),
        throwsStateError,
      );
      final listener = $Function((_, _, _) => null);
      for (final method in [
        'buildHandle',
        'snapshotHandle',
        'observeHandle',
        'unobserveHandle',
        'releaseHandle',
        'enableHandle',
      ]) {
        for (final invalid in ['', 'fabricated', '$handle ', foreign]) {
          expect(
            () => _invoke(runtime, method, [
              $String(invalid),
              if (method.endsWith('observeHandle')) listener,
              if (method == 'enableHandle') true,
            ]),
            throwsA(anything),
          );
        }
      }
      final captured =
          runtime.executeLib(_library, 'snapshotHandle', [$String(handle)])
              as $Map;
      expect(captured.$reified, {
        'markdown': 'original',
        'revision': 0,
        'readOnly': false,
        'editingEnabled': true,
        'isBlank': false,
        'unsupportedReason': null,
      });
      expect(
        () => captured.$value[$String('markdown')] = $String('modified'),
        throwsUnsupportedError,
      );
      final handles = [
        handle,
        for (var i = 1; i < 16; i++) _create(runtime, '$i'),
      ];
      expect(handles.toSet(), hasLength(16));
      expect(() => _create(runtime, 'excess'), throwsA(anything));
      _invoke(runtime, 'releaseHandle', [$String(handle)]);
      final replacement = _create(runtime, 'replacement');
      expect(replacement, isNot(handle));
      expect(
        () => _invoke(runtime, 'snapshotHandle', [$String(handle)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(runtime, 'releaseHandle', [$String(handle)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(runtime, 'enableHandle', [$String(handle), true]),
        throwsA(anything),
      );
      active = false;
      expect(
        () => _invoke(runtime, 'snapshotHandle', [$String(replacement)]),
        throwsA(anything),
      );
      active = true;
      expect(() => _create(runtime, 'cannot revive'), throwsA(anything));
      final fresh = bind(RichDocumentEditorBridge(isActive: () => true));
      final freshHandle = _create(fresh, 'new presentation');
      expect(
        () => _invoke(runtime, 'snapshotHandle', [$String(freshHandle)]),
        throwsA(anything),
      );
      expect(
        () =>
            _invoke(runtime, 'observeHandle', [$String(freshHandle), listener]),
        throwsA(anything),
      );
      expect(
        () => _invoke(fresh, 'snapshotHandle', [$String(handle)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(runtime, 'buildHandle', [$String(replacement)]),
        throwsA(anything),
      );
      _invoke(runtime, 'unobserveHandle', [$String(replacement), listener]);
      _invoke(runtime, 'releaseHandle', [$String(replacement)]);
      expect(
        (_invoke(second, 'snapshotHandle', [$String(foreign)])
            as Map)['markdown'],
        'foreign',
      );
      expect(captured.$reified['markdown'], 'original');
    },
  );

  test(
    'editing enable cannot upgrade fixed read-only or unsupported imports',
    () {
      final runtime = bind(RichDocumentEditorBridge(isActive: () => true));
      for (final (source, readOnly) in [
        ('read-only', true),
        ('![image](unsupported.png)', false),
      ]) {
        final handle = _create(runtime, source, readOnly: readOnly);
        _invoke(runtime, 'enableHandle', [$String(handle), false]);
        _invoke(runtime, 'enableHandle', [$String(handle), true]);
        final snapshot =
            _invoke(runtime, 'snapshotHandle', [$String(handle)]) as Map;
        expect(snapshot['readOnly'], isTrue);
        expect(snapshot['editingEnabled'], isFalse);
        expect(snapshot['markdown'], source);
      }
    },
  );

  for (final code in [false, true]) {
    testWidgets(
      'independent handles retain and release only their own editor (code: $code)',
      (tester) async {
        String markdown(String text) => code ? '```dart\n$text\n```' : text;
        final bridge = RichDocumentEditorBridge(isActive: () => true);
        final runtime = bind(bridge);
        final first = _create(runtime, markdown('first'));
        final second = _create(runtime, markdown('second'));
        final notices = [0, 0];
        for (final (index, handle) in [first, second].indexed) {
          _invoke(runtime, 'observeHandle', [
            $String(handle),
            $Function((_, _, arguments) {
              expect(arguments, isEmpty);
              notices[index]++;
              return null;
            }),
          ]);
        }
        final firstView =
            _invoke(runtime, 'buildHandle', [$String(first)]) as Widget;
        final secondView =
            _invoke(runtime, 'buildHandle', [$String(second)]) as Widget;
        expect(
          _invoke(runtime, 'buildHandle', [$String(first)]),
          same(firstView),
        );
        await tester.pumpWidget(_host(firstView));
        final firstState = await _select(tester, 'first');
        final oldSnapshot =
            _invoke(runtime, 'snapshotHandle', [$String(first)]) as Map;
        await _append(tester, '!');
        expect(notices, [1, 0]);
        await tester.pumpWidget(_host(secondView));
        final secondState = await _select(tester, 'second');
        expect(secondState, isNot(same(firstState)));
        expect(firstState.isDisposed, isFalse);
        expect(
          (_invoke(runtime, 'snapshotHandle', [$String(first)])
              as Map)['markdown'],
          markdown('first!'),
        );
        expect(
          (_invoke(runtime, 'snapshotHandle', [$String(second)])
              as Map)['markdown'],
          markdown('second'),
        );
        expect(oldSnapshot['markdown'], markdown('first'));
        expect(oldSnapshot['revision'], 0);
        _invoke(runtime, 'releaseHandle', [$String(first)]);
        expect(firstState.isDisposed, isTrue);
        expect(secondState.isDisposed, isFalse);
        await _append(tester, '?');
        expect(notices, [1, 1]);
        expect(
          (_invoke(runtime, 'snapshotHandle', [$String(second)])
              as Map)['markdown'],
          markdown('second?'),
        );
        bridge.invalidate();
        expect(secondState.editable, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await _frames(tester);
        expect(secondState.isDisposed, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final failure in ['false', 'throw']) {
    testWidgets(
      'native notification observes $failure liveness without revival',
      (tester) async {
        var active = true;
        final bridge = RichDocumentEditorBridge(
          isActive: () {
            if (!active && failure == 'throw') throw StateError('retired');
            return active;
          },
        );
        final runtime = bind(bridge);
        final handle = _create(runtime, 'ab');
        await tester.pumpWidget(
          _host(_invoke(runtime, 'buildHandle', [$String(handle)]) as Widget),
        );
        final state = await _select(tester, 'ab');
        active = false;
        // No eval subscriber is needed to notice retirement, and revocation must
        // not dispose ChangeNotifier inside its own notification stack.
        await state.apply(
          state.transaction
            ..insertText(state.document.root.children.single, 2, '!'),
        );
        await _frames(tester);
        expect(state.isDisposed, isTrue);
        active = true;
        expect(() => _create(runtime, 'cannot revive'), throwsA(anything));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final code in [false, true]) {
    testWidgets(
      'exit retention fences mounted native input and selection (code: $code)',
      (tester) async {
        await tester.pumpWidget(
          _host(presentation(entrypoint: code ? 'buildCodeView' : 'buildView')),
        );
        final state = await _select(tester, 'ab');
        await _append(tester, '!');
        final selectionService = state.service.selectionService;
        final element = tester.element(find.byType(AppFlowyEditor));
        final before = state.document.root.toJson();
        final client = tester.testTextInput.log.lastWhere(
          (call) => call.method == 'TextInput.setClient',
        );
        generation.retainPresentations();
        expect(element.mounted, isTrue);
        expect(state.editable, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        selectionService.updateSelection(
          Selection.collapsed(Position(path: [0], offset: 1)),
        );
        expect(state.selection, isNull);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.textInput.name,
          SystemChannels.textInput.codec.encodeMethodCall(
            MethodCall('TextInputClient.updateEditingState', [
              (client.arguments as List).first,
              const TextEditingValue(
                text: 'stale input',
                selection: TextSelection.collapsed(offset: 11),
              ).toJSON(),
            ]),
          ),
          (_) {},
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        expect(state.document.root.toJson(), before);
        await _frames(tester);
        expect(state.isDisposed, isTrue);
        expect(find.byType(AppFlowyEditor), findsNothing);
        generation.releasePresentations();
        await _frames(tester);
        expect(find.text('Frontend unavailable.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final retirement in ['Release', 'Fail', 'Fail observer', 'dispose']) {
    testWidgets('$retirement revokes owners and fences queued notifications', (
      tester,
    ) async {
      final bridge = RichDocumentEditorBridge(isActive: () => true);
      await tester.pumpWidget(_host(presentation(bridge: bridge)));
      final state = await _select(tester, 'ab');
      var failures = 0;
      final reportFailure = bridge.onFailure!;
      bridge.onFailure = () {
        failures++;
        reportFailure();
      };
      if (retirement != 'Fail observer') {
        await state.apply(
          state.transaction
            ..insertText(state.document.root.children.single, 2, '!'),
        );
        expect(_notifications(tester), 0);
      }
      if (retirement == 'dispose') {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        _press(tester, retirement);
        if (retirement == 'Fail observer') await _append(tester, '!');
      }
      await _frames(tester);
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(failures, retirement == 'Fail observer' ? 1 : 0);
      if (retirement == 'Release') expect(_notifications(tester), 0);
      if (retirement.startsWith('Fail')) {
        expect(find.text('Frontend unavailable.'), findsOneWidget);
      }
      bridge.invalidate();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'observer identity, coalescing and release during dispatch are safe',
    (tester) async {
      final runtime = bind(RichDocumentEditorBridge(isActive: () => true));
      final handle = _create(runtime, 'ab');
      await tester.pumpWidget(
        _host(_invoke(runtime, 'buildHandle', [$String(handle)]) as Widget),
      );
      final state = await _select(tester, 'ab');
      var notifications = 0;
      final listener = $Function((_, _, _) {
        notifications++;
        return null;
      });
      for (var i = 0; i < 2; i++) {
        _invoke(runtime, 'observeHandle', [$String(handle), listener]);
      }
      final node = state.document.root.children.single;
      await state.apply(state.transaction..insertText(node, 2, '!'));
      await state.apply(state.transaction..insertText(node, 3, '?'));
      expect(notifications, 0);
      await _frames(tester);
      expect(notifications, 1);
      _invoke(runtime, 'unobserveHandle', [$String(handle), listener]);
      final releasing = $Function((_, _, _) {
        _invoke(runtime, 'releaseHandle', [$String(handle)]);
        return null;
      });
      _invoke(runtime, 'observeHandle', [$String(handle), releasing]);
      _invoke(runtime, 'observeHandle', [$String(handle), listener]);
      await state.apply(state.transaction..insertText(node, 4, '.'));
      await _frames(tester);
      expect(notifications, 1);
      expect(state.isDisposed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in [false, true]) {
    testWidgets(
      'unsupported post-edit attributes serialize safely (code: $code)',
      (tester) async {
        await tester.pumpWidget(
          _host(presentation(entrypoint: code ? 'buildCodeView' : 'buildView')),
        );
        final state = await _select(tester, 'ab');
        await _append(tester, '!');
        final node = state.document.root.children.single;
        // Fault injection only: this unsupported attribute has no UI command.
        await state.apply(
          state.transaction..formatText(node, 0, 2, {'underline': true}),
        );
        await _frames(tester);
        _press(tester, 'Snapshot');
        await _frames(tester);
        expect(_snapshotText(tester), '(unavailable)');
        expect(
          find.text('Snapshot error: unsupported_serialization'),
          findsOneWidget,
        );
        expect(find.text('Snapshot reason: '), findsOneWidget);
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(state.editable, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(state.isDisposed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('observer failure releases every owner and reports only once', (
    tester,
  ) async {
    final bridge = RichDocumentEditorBridge(isActive: () => true);
    final runtime = bind(bridge);
    var failures = 0;
    bridge.onFailure = () => failures++;
    final first = _create(runtime, 'first');
    final second = _create(runtime, 'second');
    await tester.pumpWidget(
      _host(_invoke(runtime, 'buildHandle', [$String(first)]) as Widget),
    );
    final firstState = await _select(tester, 'first');
    await tester.pumpWidget(
      _host(_invoke(runtime, 'buildHandle', [$String(second)]) as Widget),
    );
    final secondState = await _select(tester, 'second');
    _invoke(runtime, 'observeHandle', [
      $String(second),
      $Function((_, _, _) => throw StateError('observer failed')),
    ]);
    await _append(tester, '!');
    expect(failures, 1);
    expect(firstState.isDisposed, isTrue);
    expect(secondState.isDisposed, isTrue);
    bridge.invalidate();
    expect(failures, 1);
    expect(() => _create(runtime, 'cannot revive'), throwsA(anything));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('fabricated prepared handles fail closed without native owners', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(presentation(entrypoint: 'buildFabricatedView')),
    );
    await _frames(tester);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.byType(AppFlowyEditor), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.linux),
  home: Scaffold(body: child),
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<EditorState> _select(WidgetTester tester, String text) async {
  await _frames(tester);
  await tester.tapAt(tester.getCenter(find.text(text, findRichText: true)));
  await _frames(tester);
  final state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  state.selection = Selection.collapsed(
    Position(path: [0], offset: text.length),
  );
  await _frames(tester);
  return state;
}

Future<void> _append(WidgetTester tester, String text) async {
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  _input(
    tester,
    TextEditingValue(
      text: '${value.text}$text',
      selection: TextSelection.collapsed(
        offset: value.text.length + text.length,
      ),
    ),
  );
  await _frames(tester);
}

void _input(WidgetTester tester, TextEditingValue value) {
  // TestTextInput remembers host writes, not platform input. Keep the simulated
  // IME value current even when AppFlowy correctly avoids echoing it to the host.
  tester.testTextInput.editingState = value.toJSON();
  tester.testTextInput.updateEditingValue(value);
}

Future<void> _control(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _frames(tester);
}

void _press(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!();

int _notifications(WidgetTester tester) => int.parse(
  tester
      .widget<Text>(find.textContaining('Notifications: '))
      .data!
      .split(': ')
      .last,
);

String _snapshotText(WidgetTester tester) => tester
    .widget<Text>(find.textContaining('Snapshot text: '))
    .data!
    .substring('Snapshot text: '.length);

String _create(Runtime runtime, String markdown, {bool readOnly = false}) =>
    _invoke(runtime, 'createHandle', [$String(markdown), readOnly]) as String;

Object? _invoke(
  Runtime runtime,
  String method, [
  List<dynamic> args = const [],
]) {
  final value = runtime.executeLib(_library, method, args);
  return value is $Value ? value.$reified : value;
}
