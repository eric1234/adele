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

const _frame = Duration(milliseconds: 150);

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
    NativeCodeView view, {
    PreparedFrontend? frontend,
    Key? key,
    String entrypoint = 'buildView',
  }) => (frontend ?? generation).createPresentation(
    key: key,
    library: codeEditorFrontendLibrary,
    entrypoint: entrypoint,
    createBridge: () => CodeEditorBridge(view: view, isActive: () => true),
  );

  Future<PreparedFrontend> freshGeneration(WidgetTester tester) async {
    final fresh = (await tester.runAsync(
      () => PreparedFrontend.load(artifact),
    ))!;
    expect(fresh.failure, isNull);
    addTearDown(fresh.invalidate);
    return fresh;
  }

  Runtime bind(CodeEditorBridge bridge) {
    addTearDown(bridge.invalidate);
    return Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
  }

  test('public stubs grant no editor access or native initialization', () {
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

  testWidgets('prepared EVC edits native body and snapshots only on demand', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    await tester.pumpWidget(_host(presentation(editor.view)));
    await _frames(tester);
    expect(find.byType(CodeForge), findsOneWidget);
    expect(find.text('Snapshot text: (not requested)'), findsOneWidget);
    expect(editor.buffer.snapshotReads, 0);
    final element = tester.element(find.byType(CodeForge));
    await _focus(tester);
    await _key(tester, LogicalKeyboardKey.home, control: true);
    final before = editor.buffer.version;
    final notifications = _notifications(tester);

    // This is the current native input client mounted below the interpreted UI,
    // not a controller setter or an interpreted imitation of an editor.
    await _insert(tester, '\u{1f600}');
    expect(editor.buffer.version, greaterThan(before));
    await _frames(tester);
    expect(_notifications(tester), greaterThan(notifications));
    expect(find.text('Snapshot text: (not requested)'), findsOneWidget);
    expect(editor.buffer.snapshotReads, 0);
    expect(find.textContaining('ready=true readOnly=false'), findsOneWidget);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: \u{1f600}ab'), findsOneWidget);
    expect(find.text('Snapshot selection: 2:2'), findsOneWidget);
    expect(editor.buffer.snapshotReads, 1);
    expect(
      find.text('Snapshot version: ${editor.buffer.version}'),
      findsOneWidget,
    );
    for (var i = 1; i <= 3; i++) {
      _press(tester, 'Rebuild');
      await tester.pump();
      expect(find.text('Rebuilds: $i'), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
    }
    await _key(tester, LogicalKeyboardKey.keyZ, control: true);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: ab'), findsOneWidget);
    _press(tester, 'Unsubscribe');
    await tester.pump();
    final unsubscribed = _notifications(tester);
    await _insert(tester, 'x');
    await _frames(tester);
    expect(_notifications(tester), unsubscribed);
    _press(tester, 'Subscribe');
    await _insert(tester, 'y');
    await _frames(tester);
    expect(_notifications(tester), greaterThan(unsubscribed));
    expect(editor.buffer.snapshotReads, 2);
    expect(find.text('Snapshot text: ab'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(editor.buffer.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'two fresh EVC presentations isolate editable and read-only input',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final editable = await _editor(tester, 'editable');
      final readOnly = await _editor(tester, 'read-only', readOnly: true);
      String? copied;
      _clipboard(
        tester,
        read: () async => 'paste',
        write: (text) => copied = text,
      );
      await tester.pumpWidget(
        _host(
          Row(
            children: [
              Expanded(
                child: presentation(editable.view, key: const ValueKey('edit')),
              ),
              Expanded(
                child: presentation(readOnly.view, key: const ValueKey('read')),
              ),
            ],
          ),
        ),
      );
      await _frames(tester);
      expect(find.byType(CodeForge), findsNWidgets(2));
      expect(find.textContaining('readOnly=false'), findsOneWidget);
      expect(find.textContaining('readOnly=true'), findsOneWidget);
      await _focus(tester, find.byType(CodeForge).first);
      await _key(tester, LogicalKeyboardKey.end, control: true);
      await _insert(tester, '!');
      await _frames(tester);
      expect(editable.buffer.snapshot()['text'], 'editable!');
      expect(readOnly.buffer.snapshot()['text'], 'read-only');

      final oldEditableClient = _TextInputClientSnapshot.capture(tester);
      await _focus(tester, find.byType(CodeForge).last);
      await _key(tester, LogicalKeyboardKey.keyA, control: true);
      await _key(tester, LogicalKeyboardKey.keyC, control: true);
      await tester.pump();
      expect(copied, 'read-only');
      final version = readOnly.buffer.version;
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await oldEditableClient.insert(tester, 'blocked');
      await _key(tester, LogicalKeyboardKey.backspace);
      await _key(tester, LogicalKeyboardKey.keyV, control: true);
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      await _frames(tester);
      expect(readOnly.buffer.snapshot()['text'], 'read-only');
      expect(readOnly.buffer.version, version);
      expect(editable.buffer.snapshot()['text'], 'editable!');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('EVC snapshot includes a pending Unicode line without flushing', (
    tester,
  ) async {
    final editor = await _editor(tester, '\u{1f600}\nab');
    await tester.pumpWidget(_host(presentation(editor.view)));
    await _focus(tester);
    await _key(tester, LogicalKeyboardKey.end, control: true);
    await _frames(tester);
    await _key(tester, LogicalKeyboardKey.backspace);
    final version = editor.buffer.version;
    _press(tester, 'Snapshot');
    await tester.pump();
    expect(find.text('Snapshot text: \u{1f600}\na'), findsOneWidget);
    expect(find.text('Snapshot version: $version'), findsOneWidget);
    expect(editor.buffer.snapshotReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('full presentation disposal remounts retained state and undo', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    await tester.pumpWidget(_host(presentation(editor.view)));
    await _focus(tester);
    await _key(tester, LogicalKeyboardKey.end, control: true);
    await _insert(tester, '\u{1f600}');
    await _frames(tester);
    final oldElement = tester.element(find.byType(CodeForge));
    final version = editor.buffer.version;
    await tester.pumpWidget(const SizedBox.shrink());
    generation.invalidate();
    expect(oldElement.mounted, isFalse);
    expect(editor.buffer.isDisposed, isFalse);
    expect(editor.view.isDisposed, isFalse);

    final fresh = await freshGeneration(tester);
    await tester.pumpWidget(_host(presentation(editor.view, frontend: fresh)));
    await _frames(tester);
    expect(tester.element(find.byType(CodeForge)), isNot(same(oldElement)));
    expect(editor.buffer.version, version);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: ab\u{1f600}'), findsOneWidget);
    expect(find.text('Snapshot selection: 4:4'), findsOneWidget);
    await _focus(tester);
    await _key(tester, LogicalKeyboardKey.keyZ, control: true);
    _press(tester, 'Snapshot');
    await _frames(tester);
    expect(find.text('Snapshot text: ab'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.keyY, control: true);
    expect(editor.buffer.snapshot()['text'], 'ab\u{1f600}');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached retained native body is revoked before another frame', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    await tester.pumpWidget(_host(presentation(editor.view)));
    await _focus(tester);
    await _key(tester, LogicalKeyboardKey.end, control: true);
    final element = tester.element(find.byType(CodeForge));
    final oldClient = _TextInputClientSnapshot.capture(tester);
    final notifications = _notifications(tester);
    generation.retainPresentations();
    expect(element.mounted, isTrue);
    await oldClient.insert(tester, 'stale');
    await _key(tester, LogicalKeyboardKey.backspace);
    await _frames(tester);
    expect(editor.buffer.snapshot()['text'], 'ab');
    expect(_notifications(tester), notifications);
    // A revoked cached body may stop painting before the retained outer
    // presentation is released. Neither path can restore its input authority.
    generation.releasePresentations();
    await _frames(tester);
    expect(element.mounted, isFalse);
    expect(find.byType(CodeForge), findsNothing);
    expect(editor.buffer.isDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained attachment rejects a second view of the same buffer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final editor = await _editor(tester, 'one buffer');
    final competing = NativeCodeView(buffer: editor.buffer, readOnly: true);
    addTearDown(competing.dispose);
    final retained = presentation(editor.view);
    Widget pair(Widget second) => _host(
      Row(
        children: [
          Expanded(child: retained),
          Expanded(child: second),
        ],
      ),
    );
    await tester.pumpWidget(pair(const SizedBox.shrink()));
    await _frames(tester);
    final element = tester.element(find.byWidget(retained));
    generation.retainPresentations();
    final fresh = await freshGeneration(tester);
    await tester.pumpWidget(pair(presentation(competing, frontend: fresh)));
    await _frames(tester);
    expect(find.byType(CodeForge).evaluate().length, lessThanOrEqualTo(1));
    expect(tester.element(find.byWidget(retained)), same(element));
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(editor.buffer.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final retirement in ['retention', 'replacement', 'owner disposal']) {
    testWidgets('pending native paste is fenced after $retirement', (
      tester,
    ) async {
      final editor = await _editor(tester, 'ab');
      final pending = Completer<String?>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
      });
      var reads = 0;
      _clipboard(
        tester,
        read: () {
          reads++;
          return reads == 1 ? pending.future : Future.value('fresh');
        },
      );
      await tester.pumpWidget(_host(presentation(editor.view)));
      await _focus(tester);
      await _key(tester, LogicalKeyboardKey.home, control: true);
      await _key(tester, LogicalKeyboardKey.keyV, control: true);
      await tester.pump();
      expect(reads, 1);
      final oldClient = _TextInputClientSnapshot.capture(tester);
      if (retirement == 'owner disposal') {
        editor.buffer.dispose();
      } else {
        generation.retainPresentations();
      }
      if (retirement == 'replacement') {
        await tester.pumpWidget(const SizedBox.shrink());
        final fresh = await freshGeneration(tester);
        await tester.pumpWidget(
          _host(presentation(editor.view, frontend: fresh)),
        );
        await _focus(tester);
      }
      pending.complete('stale');
      await oldClient.insert(tester, 'old-client');
      await _frames(tester);
      if (retirement != 'owner disposal') {
        expect(editor.buffer.snapshot()['text'], 'ab');
      }
      if (retirement == 'replacement') {
        await _key(tester, LogicalKeyboardKey.home, control: true);
        await _key(tester, LogicalKeyboardKey.keyV, control: true);
        await _frames(tester);
        expect(editor.buffer.snapshot()['text'], 'freshab');
        expect(reads, 2);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final retirement in ['invalidate', 'failure', 'view disposal']) {
    testWidgets('$retirement releases EVC observation without owning buffer', (
      tester,
    ) async {
      final editor = await _editor(tester, 'ab');
      await tester.pumpWidget(_host(presentation(editor.view)));
      await _frames(tester);
      final element = tester.element(find.byType(CodeForge));
      switch (retirement) {
        case 'invalidate':
          generation.invalidate();
        case 'failure':
          _press(tester, 'Fail');
        case 'view disposal':
          editor.view.dispose();
      }
      await _frames(tester);
      expect(element.mounted, isFalse);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(editor.buffer.isDisposed, isFalse);
      expect(editor.buffer.snapshot()['text'], 'ab');
      await tester.pumpWidget(const SizedBox.shrink());
      final view = retirement == 'view disposal'
          ? NativeCodeView(buffer: editor.buffer)
          : editor.view;
      if (!identical(view, editor.view)) addTearDown(view.dispose);
      final fresh = await freshGeneration(tester);
      await tester.pumpWidget(_host(presentation(view, frontend: fresh)));
      await _frames(tester);
      expect(find.byType(CodeForge), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('fabricated handle fails only its prepared presentation', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    await tester.pumpWidget(
      _host(presentation(editor.view, entrypoint: 'buildFabricatedView')),
    );
    await _frames(tester);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.byType(CodeForge), findsNothing);
    expect(editor.buffer.isDisposed, isFalse);
    await tester.pumpWidget(_host(presentation(editor.view)));
    await _frames(tester);
    expect(find.byType(CodeForge), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed initialization contains a pending interpreted snapshot', (
    tester,
  ) async {
    final pending = Completer<void>();
    final buffer = NativeCodeBuffer(
      text: 'ab',
      initializeNative: () => pending.future,
    );
    final view = NativeCodeView(buffer: buffer);
    addTearDown(buffer.dispose);
    addTearDown(view.dispose);
    await tester.pumpWidget(_host(presentation(view)));
    expect(find.text('State: 0 ready=false readOnly=false'), findsOneWidget);
    _press(tester, 'Snapshot');
    pending.completeError(StateError('deterministic native init failure'));
    await _frames(tester);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.byType(CodeForge), findsNothing);
    expect(buffer.snapshotReads, 0);
    expect(buffer.isDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    final independent = await _editor(tester, 'independent');
    await tester.pumpWidget(_host(presentation(independent.view)));
    await _frames(tester);
    expect(find.byType(CodeForge), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compiled helpers enforce runtime handles and immutable metadata',
    (tester) async {
      final editor = await _editor(tester, '\u{1f600}ab');
      var active = true;
      final bridge = CodeEditorBridge(
        view: editor.view,
        isActive: () => active,
      );
      final first = bind(bridge);
      final second = bind(
        CodeEditorBridge(view: editor.view, isActive: () => true),
      );
      expect(
        () => _invoke(first, 'readHandle', [$String('unknown')]),
        throwsA(anything),
      );
      final firstHandle = _invoke(first, 'requestHandle') as String;
      final secondHandle = _invoke(second, 'requestHandle') as String;
      expect(firstHandle, matches(RegExp(r'^[0-9a-f]{48}$')));
      expect(secondHandle, isNot(firstHandle));
      expect(_invoke(first, 'requestHandle'), firstHandle);
      expect(
        () => bridge.configureForRuntime(Runtime.ofProgram(program)),
        throwsStateError,
      );
      for (final method in ['buildHandle', 'readHandle', 'snapshotHandle']) {
        for (final handle in ['', 'fabricated', secondHandle]) {
          expect(
            () => _invoke(first, method, [$String(handle)]),
            throwsA(anything),
          );
        }
        expect(
          () => _invoke(second, method, [$String(firstHandle)]),
          throwsA(anything),
        );
      }
      final listener = $Function((_, _, _) => null);
      for (final method in ['observeHandle', 'unobserveHandle']) {
        for (final handle in ['', 'fabricated', secondHandle]) {
          expect(
            () => _invoke(first, method, [$String(handle), listener]),
            throwsA(anything),
          );
        }
      }
      final args = [$String(firstHandle)];
      final widget = _invoke(first, 'buildHandle', args) as Widget;
      expect(_invoke(first, 'buildHandle', args), same(widget));
      await tester.pumpWidget(_host(widget));
      await _focus(tester);
      await _key(tester, LogicalKeyboardKey.end, control: true);
      await _frames(tester);
      final state = _invoke(first, 'readHandle', args) as Map;
      expect(
        state.keys,
        unorderedEquals([
          'ready',
          'readOnly',
          'version',
          'language',
          'focused',
          'horizontalOffset',
          'verticalOffset',
        ]),
      );
      expect(state['language'], 'dart');
      expect(state['ready'], isTrue);
      expect(state['readOnly'], isFalse);
      expect(state.containsKey('text'), isFalse);
      final raw =
          first.executeLib(codeEditorFrontendLibrary, 'readHandle', args)
              as $Map;
      expect(
        () => raw.$value[$String('version')] = $int(-1),
        throwsUnsupportedError,
      );
      final immutable =
          first.executeLib(codeEditorFrontendLibrary, 'snapshotHandle', args)
              as $Map;
      final capturedVersion = editor.buffer.version;
      expect(immutable.$reified, {
        'text': '\u{1f600}ab',
        'version': capturedVersion,
        'selectionBase': 4,
        'selectionExtent': 4,
        'selectionUnit': 'utf16',
      });
      expect(
        () => immutable.$value[$String('text')] = $String('modified'),
        throwsUnsupportedError,
      );
      await _insert(tester, 'X');
      expect(editor.buffer.version, greaterThan(capturedVersion));
      expect(immutable.$reified, {
        'text': '\u{1f600}ab',
        'version': capturedVersion,
        'selectionBase': 4,
        'selectionExtent': 4,
        'selectionUnit': 'utf16',
      });
      final immediate =
          first.executeLib(codeEditorFrontendLibrary, 'snapshotHandle', args)
              as $Map;
      final editedVersion = editor.buffer.version;
      await tester.pump();
      expect(immediate.$reified, {
        'text': '\u{1f600}abX',
        'version': editedVersion,
        'selectionBase': 5,
        'selectionExtent': 5,
        'selectionUnit': 'utf16',
      });
      active = false;
      expect(() => _invoke(first, 'readHandle', args), throwsA(anything));
      active = true;
      expect(() => _invoke(first, 'requestHandle'), throwsA(anything));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(editor.buffer.isDisposed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compiled observation coalesces and removes queued callbacks', (
    tester,
  ) async {
    final editor = await _editor(tester, 'abcdef');
    final bridge = CodeEditorBridge(view: editor.view, isActive: () => true);
    final runtime = bind(bridge);
    final handle = _invoke(runtime, 'requestHandle') as String;
    final args = [$String(handle)];
    await tester.pumpWidget(
      _host(_invoke(runtime, 'buildHandle', args) as Widget),
    );
    await _focus(tester);
    await _key(tester, LogicalKeyboardKey.home, control: true);
    await _frames(tester);
    var observed = 0;
    final listener = $Function((_, _, _) {
      observed++;
      expect(
        (_invoke(runtime, 'readHandle', args) as Map).containsKey('text'),
        isFalse,
      );
      return null;
    });
    _invoke(runtime, 'observeHandle', [...args, listener]);
    _invoke(runtime, 'observeHandle', [...args, listener]);
    for (var i = 0; i < 3; i++) {
      await _key(tester, LogicalKeyboardKey.delete);
    }
    expect(editor.buffer.snapshot()['text'], 'def');
    expect(editor.buffer.observerCount, 1);
    expect(observed, 0);
    await tester.pump();
    await tester.pump();
    expect(observed, 1);
    await _key(tester, LogicalKeyboardKey.delete);
    _invoke(runtime, 'unobserveHandle', [...args, listener]);
    _invoke(runtime, 'observeHandle', [...args, listener]);
    await _key(tester, LogicalKeyboardKey.delete);
    await tester.pump();
    await tester.pump();
    expect(observed, 2);
    await _key(tester, LogicalKeyboardKey.delete);
    _invoke(runtime, 'unobserveHandle', [...args, listener]);
    await tester.pump();
    expect(observed, 2);
    _invoke(runtime, 'observeHandle', [...args, listener]);
    await _insert(tester, 'X');
    bridge.invalidate();
    _invoke(runtime, 'unobserveHandle', [...args, listener]);
    await tester.pump();
    expect(observed, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued snapshot calls fail after immediate retirement', (
    tester,
  ) async {
    final editor = await _editor(tester, 'ab');
    final bridge = CodeEditorBridge(view: editor.view, isActive: () => true);
    final runtime = bind(bridge);
    final handle = _invoke(runtime, 'requestHandle') as String;
    final control =
        runtime.executeLib(codeEditorFrontendLibrary, 'snapshotHandle', [
              $String(handle),
            ])
            as $Map;
    expect(control.$reified, {
      'text': 'ab',
      'version': editor.buffer.version,
      'selectionBase': 0,
      'selectionExtent': 0,
      'selectionUnit': 'utf16',
    });
    final pending = Future.microtask(
      () => _invoke(runtime, 'snapshotHandle', [$String(handle)]),
    );
    final rejected = expectLater(pending, throwsA(anything));
    bridge.invalidate();
    await tester.pump();
    await rejected;
    expect(editor.buffer.snapshot()['text'], 'ab');
  });
}

Future<({NativeCodeBuffer buffer, NativeCodeView view})> _editor(
  WidgetTester tester,
  String text, {
  bool readOnly = false,
}) async {
  final nativeDirectory =
      Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
  if (nativeDirectory == null || nativeDirectory.isEmpty) {
    throw StateError(
      'Supply the prepared real native editor library directory.',
    );
  }
  expect(File('$nativeDirectory/libcode_forge.so').existsSync(), isTrue);
  final buffer = NativeCodeBuffer(text: text);
  addTearDown(buffer.dispose);
  await tester.runAsync(buffer.initialize);
  final view = NativeCodeView(buffer: buffer, readOnly: readOnly);
  addTearDown(view.dispose);
  return (buffer: buffer, view: view);
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _frames(WidgetTester tester) async {
  await tester.pump(_frame);
  await tester.pump();
}

Future<void> _focus(WidgetTester tester, [Finder? finder]) async {
  await _frames(tester);
  await tester.tap(finder ?? find.byType(CodeForge));
  await _frames(tester);
  final code = tester.widget<CodeForge>(finder ?? find.byType(CodeForge));
  expect(code.focusNode!.hasFocus, isTrue);
  expect(tester.testTextInput.hasAnyClients, !code.readOnly);
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

Future<void> _insert(WidgetTester tester, String text) =>
    _TextInputClientSnapshot.capture(tester).insert(tester, text);

/// Retains the actual advertised client/value so stale delivery tests cannot
/// silently obtain the replacement presentation's input authority.
class _TextInputClientSnapshot {
  _TextInputClientSnapshot(this.client, this.value);

  factory _TextInputClientSnapshot.capture(WidgetTester tester) {
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.testTextInput.setClientArgs!['enableDeltaModel'], isTrue);
    final attach = tester.testTextInput.log.lastWhere(
      (call) => call.method == 'TextInput.setClient',
    );
    final value = TextEditingValue.fromJSON(
      Map<String, dynamic>.from(tester.testTextInput.editingState!),
    );
    expect(value.selection.isValid, isTrue);
    expect(value.composing, TextRange.empty);
    return _TextInputClientSnapshot(
      (attach.arguments as List)[0] as int,
      value,
    );
  }

  final int client;
  final TextEditingValue value;

  Future<void> insert(WidgetTester tester, String text) async {
    final start = value.selection.start;
    final end = value.selection.end;
    expect(start, inInclusiveRange(0, value.text.length));
    expect(end, inInclusiveRange(start, value.text.length));
    final reply = Completer<void>();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          client,
          {
            'deltas': [
              {
                'oldText': value.text,
                'deltaText': text,
                'deltaStart': start,
                'deltaEnd': end,
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
}

void _clipboard(
  WidgetTester tester, {
  required Future<String?> Function() read,
  void Function(String)? write,
}) {
  final messenger = tester.binding.defaultBinaryMessenger;
  final previous = messenger.allMessagesHandler;
  final channel = SystemChannels.platform;
  messenger.allMessagesHandler = (name, handler, message) {
    if (name == channel.name && message != null) {
      final call = channel.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.getData') {
        return read().then(
          (text) => channel.codec.encodeSuccessEnvelope(
            text == null ? null : {'text': text},
          ),
        );
      }
      if (call.method == 'Clipboard.setData') {
        write?.call((call.arguments as Map)['text'] as String);
        return Future.value(channel.codec.encodeSuccessEnvelope(null));
      }
    }
    if (previous != null) return previous(name, handler, message);
    return handler != null
        ? handler(message)
        : messenger.delegate.send(name, message);
  };
  addTearDown(() => messenger.allMessagesHandler = previous);
}
