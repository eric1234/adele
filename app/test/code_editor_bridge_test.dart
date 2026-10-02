import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_ui/code_editor_bridge.dart' as public_bridge;
import 'package:code_forge/code_forge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/code_editor_smoke/compile_frontend.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late Program program;
  late PreparedFrontend generation;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-editor-bridge-');
    artifact = File('${temporary.path}/editor.evc');
    program = await compileCodeEditorFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    expect(generation.failure, isNull);
  });
  tearDown(() => generation.invalidate());

  Widget presentation(
    NativeCodeEditor editor, {
    PreparedFrontend? frontend,
    Key? key,
    String entrypoint = 'buildView',
  }) => (frontend ?? generation).createPresentation(
    key: key,
    library: codeEditorFrontendLibrary,
    entrypoint: entrypoint,
    createBridge: () => CodeEditorBridge(editor: editor, isActive: () => true),
  );

  Runtime bind(CodeEditorBridge bridge) {
    addTearDown(bridge.invalidate);
    return Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
  }

  test('public stubs and compile declarations grant no native access', () {
    expect(public_bridge.requestCodeEditor, throwsUnsupportedError);
    expect(() => public_bridge.buildCodeEditor('fake'), throwsUnsupportedError);
    expect(
      () => public_bridge.readCodeEditorState('fake'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.snapshotCodeEditor('fake'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.subscribeCodeEditor('fake', () {}),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.unsubscribeCodeEditor('fake', () {}),
      throwsUnsupportedError,
    );
    expect(
      () => const CodeEditorDeclarations().configureForRuntime(
        Runtime.ofProgram(program),
      ),
      throwsUnsupportedError,
    );
  });

  testWidgets('prepared EVC observes ordinary edits and snapshots on demand', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    await tester.pumpWidget(_host(presentation(editor)));
    await _focus(tester, editor);
    await _key(tester, LogicalKeyboardKey.home, control: true);
    await _frames(tester);
    final revision = editor.readState()['revision'] as int;
    final notifications = _notifications(tester);
    final element = tester.element(find.byType(CodeForge));
    await _insert(tester, '\u{1f600}');
    await _frames(tester);
    expect(editor.readState()['revision'], greaterThan(revision));
    expect(_notifications(tester), greaterThan(notifications));
    expect(find.text('Snapshot text: (not requested)'), findsOneWidget);
    expect(find.textContaining('ready=true readOnly=false'), findsOneWidget);
    final captured = editor.snapshot();
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: \u{1f600}ab'), findsOneWidget);
    expect(
      find.text('Snapshot revision: ${captured['revision']}'),
      findsOneWidget,
    );
    _press(tester, 'Rebuild');
    await tester.pump();
    expect(tester.element(find.byType(CodeForge)), same(element));
    _press(tester, 'Unsubscribe');
    await _frames(tester);
    final unsubscribed = _notifications(tester);
    await _insert(tester, 'x');
    await _frames(tester);
    expect(_notifications(tester), unsubscribed);
    _press(tester, 'Subscribe');
    await _insert(tester, 'y');
    await _frames(tester);
    expect(_notifications(tester), greaterThan(unsubscribed));
    expect(find.text('Snapshot text: \u{1f600}ab'), findsOneWidget);
    expect(captured['text'], '\u{1f600}ab');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(editor.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('independent read-only EVC copies without editing either owner', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final editable = await _editor(tester, 'editable');
    final reference = await _editor(tester, 'read-only', readOnly: true);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': 'paste'};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _host(
        Row(
          children: [
            Expanded(
              child: presentation(editable, key: const ValueKey('edit')),
            ),
            Expanded(
              child: presentation(reference, key: const ValueKey('read')),
            ),
          ],
        ),
      ),
    );
    await _frames(tester);
    expect(find.byType(CodeForge), findsNWidgets(2));
    await _focus(tester, editable);
    await _key(tester, LogicalKeyboardKey.end, control: true);
    await _insert(tester, '!');
    await _focus(tester, reference);
    await _key(tester, LogicalKeyboardKey.keyA, control: true);
    await _key(tester, LogicalKeyboardKey.keyC, control: true);
    await _frames(tester);
    expect(copied, 'read-only');
    for (final key in [
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyZ,
    ]) {
      await _key(tester, key, control: key != LogicalKeyboardKey.backspace);
    }
    await _frames(tester);
    expect(reference.snapshot()['text'], 'read-only');
    expect(editable.snapshot()['text'], 'editable!');
    await _focus(tester, editable);
    expect(editable.snapshot()['text'], 'editable!');
    for (final button
        in find.widgetWithText(TextButton, 'Snapshot').evaluate()) {
      (button.widget as TextButton).onPressed!();
    }
    await _frames(tester);
    expect(find.text('Snapshot text: editable!'), findsOneWidget);
    expect(find.text('Snapshot text: read-only'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compiled handles are exact, runtime-local and permanently revoked',
    (tester) async {
      final editor = await _editor(tester, 'ab');
      var active = true;
      final bridge = CodeEditorBridge(editor: editor, isActive: () => active);
      final first = bind(bridge);
      final second = bind(
        CodeEditorBridge(editor: editor, isActive: () => true),
      );
      final handle = _invoke(first, 'requestHandle') as String;
      final foreign = _invoke(second, 'requestHandle') as String;
      expect(handle, matches(RegExp(r'^[0-9a-f]{48}$')));
      expect(foreign, isNot(handle));
      expect(_invoke(first, 'requestHandle'), handle);
      expect(
        () => bridge.configureForRuntime(Runtime.ofProgram(program)),
        throwsStateError,
      );
      final listener = $Function((_, _, _) => null);
      for (final method in [
        'buildHandle',
        'readHandle',
        'snapshotHandle',
        'observeHandle',
        'unobserveHandle',
      ]) {
        for (final invalid in ['', 'fabricated', '$handle ', foreign]) {
          expect(
            () => _invoke(first, method, [
              $String(invalid),
              if (method.endsWith('observeHandle')) listener,
            ]),
            throwsA(anything),
          );
        }
      }
      final args = [$String(handle)];
      final state =
          first.executeLib(codeEditorFrontendLibrary, 'readHandle', args)
              as $Map;
      expect(state.$reified, {
        'ready': true,
        'revision': editor.readState()['revision'],
        'readOnly': false,
        'language': 'dart',
      });
      expect(
        () => state.$value[$String('revision')] = $int(-1),
        throwsUnsupportedError,
      );
      final snapshot =
          first.executeLib(codeEditorFrontendLibrary, 'snapshotHandle', args)
              as $Map;
      expect(snapshot.$reified, {
        'text': 'ab',
        'revision': editor.readState()['revision'],
      });
      expect(
        () => snapshot.$value[$String('text')] = $String('modified'),
        throwsUnsupportedError,
      );
      active = false;
      expect(() => _invoke(first, 'readHandle', args), throwsA(anything));
      active = true;
      for (final method in [
        'requestHandle',
        'buildHandle',
        'readHandle',
        'snapshotHandle',
        'observeHandle',
      ]) {
        expect(
          () => _invoke(
            first,
            method,
            method == 'requestHandle'
                ? []
                : [...args, if (method == 'observeHandle') listener],
          ),
          throwsA(anything),
        );
      }
      expect(
        (_invoke(second, 'snapshotHandle', [$String(foreign)]) as Map)['text'],
        'ab',
      );
      await tester.pumpWidget(
        _host(presentation(editor, entrypoint: 'buildFabricatedView')),
      );
      await _frames(tester);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(editor.isDisposed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fresh EVC remount retains the owner text and undo', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    await tester.pumpWidget(_host(presentation(editor)));
    await _focus(tester, editor);
    await _key(tester, LogicalKeyboardKey.end, control: true);
    await _insert(tester, '\u{1f600}');
    await _frames(tester);
    final oldElement = tester.element(find.byType(CodeForge));
    await tester.pumpWidget(const SizedBox.shrink());
    generation.invalidate();
    expect(oldElement.mounted, isFalse);
    expect(editor.isDisposed, isFalse);
    final fresh = (await tester.runAsync(
      () => PreparedFrontend.load(artifact),
    ))!;
    addTearDown(fresh.invalidate);
    expect(fresh.failure, isNull);
    await tester.pumpWidget(_host(presentation(editor, frontend: fresh)));
    await _frames(tester);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: ab\u{1f600}'), findsOneWidget);
    await _focus(tester, editor);
    await _key(tester, LogicalKeyboardKey.keyZ, control: true);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: ab'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owner close rejects old EVC access without retargeting a replacement',
    (tester) async {
      final editor = await _editor(tester, 'old');
      final runtime = bind(
        CodeEditorBridge(editor: editor, isActive: () => true),
      );
      final handle = _invoke(runtime, 'requestHandle') as String;
      await tester.pumpWidget(_host(presentation(editor)));
      await _frames(tester);
      editor.dispose();
      await _frames(tester);
      expect(editor.isDisposed, isTrue);
      expect(find.byType(CodeForge), findsNothing);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      final replacement = await _editor(tester, 'replacement');
      await tester.pumpWidget(_host(presentation(replacement)));
      await _frames(tester);
      for (final method in [
        'requestHandle',
        'buildHandle',
        'readHandle',
        'snapshotHandle',
      ]) {
        expect(
          () => _invoke(
            runtime,
            method,
            method == 'requestHandle' ? [] : [$String(handle)],
          ),
          throwsA(anything),
        );
      }
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(find.text('Snapshot text: replacement'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

Future<NativeCodeEditor> _editor(
  WidgetTester tester,
  String text, {
  bool readOnly = false,
}) async {
  final directory =
      Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
  if (directory == null || directory.isEmpty) {
    throw StateError(
      'Supply the prepared real native editor library directory.',
    );
  }
  expect(File('$directory/libcode_forge.so').existsSync(), isTrue);
  final editor = NativeCodeEditor(text: text, readOnly: readOnly);
  addTearDown(editor.dispose);
  await tester.runAsync(editor.initialize);
  expect(editor.isInitialized, isTrue);
  return editor;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _frames(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump();
}

Future<void> _focus(WidgetTester tester, NativeCodeEditor editor) async {
  await _frames(tester);
  expect(editor.requestFocus(), isTrue);
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

Object? _invoke(
  Runtime runtime,
  String method, [
  List<$Value> args = const [],
]) {
  final value = runtime.executeLib(codeEditorFrontendLibrary, method, args);
  return value is $Value ? value.$reified : value;
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.sendKeyEvent(key);
  } finally {
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
}

Future<void> _insert(WidgetTester tester, String text) async {
  expect(tester.testTextInput.hasAnyClients, isTrue);
  expect(tester.testTextInput.setClientArgs!['enableDeltaModel'], isTrue);
  final attach = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  final value = TextEditingValue.fromJSON(
    Map<String, dynamic>.from(tester.testTextInput.editingState!),
  );
  expect(value.selection.isValid, isTrue);
  expect(value.selection.end, lessThanOrEqualTo(value.text.length));
  final start = value.selection.start;
  final reply = Completer<void>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        (attach.arguments as List)[0] as int,
        {
          'deltas': [
            {
              'oldText': value.text,
              'deltaText': text,
              'deltaStart': start,
              'deltaEnd': value.selection.end,
              'selectionBase': start + text.length,
              'selectionExtent': start + text.length,
              'selectionAffinity': 'TextAffinity.downstream',
              'selectionIsDirectional': false,
              'composingBase': -1,
              'composingExtent': -1,
            },
          ],
        },
      ]),
    ),
    (_) => reply.complete(),
  );
  await reply.future;
}
