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
  late Directory temporary;
  late File artifact;
  late Program program;
  late PreparedFrontend generation;

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
    generation = await PreparedFrontend.load(artifact);
    expect(generation.failure, isNull);
  });
  tearDown(() => generation.invalidate());

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
    'rebuilding and native unmount retain the same content and undo',
    (tester) async {
      await tester.pumpWidget(_host(presentation()));
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
      expect(_snapshotText(tester), contains('ab!'));
      _press(tester, 'Toggle');
      await _frames(tester);
      expect(await _select(tester, 'ab!'), same(state));
      await _control(tester, LogicalKeyboardKey.keyZ);
      expect(state.document.root.children.single.delta!.toPlainText(), 'ab');
      _press(tester, 'Snapshot');
      await _frames(tester);
      expect(_snapshotText(tester).trim(), 'ab');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

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
      ]) {
        for (final invalid in ['', 'fabricated', '$handle ', foreign]) {
          expect(
            () => _invoke(runtime, method, [
              $String(invalid),
              if (method.endsWith('observeHandle')) listener,
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

  testWidgets(
    'independent handles retain owners and release only their own editor',
    (tester) async {
      final bridge = RichDocumentEditorBridge(isActive: () => true);
      final runtime = bind(bridge);
      final first = _create(runtime, 'first');
      final second = _create(runtime, 'second');
      final notices = [0, 0];
      for (final (index, handle) in [first, second].indexed) {
        _invoke(runtime, 'observeHandle', [
          $String(handle),
          $Function((_, _, _) {
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
        contains('first!'),
      );
      expect(
        (_invoke(runtime, 'snapshotHandle', [$String(second)])
            as Map)['markdown'],
        'second',
      );
      expect(oldSnapshot['markdown'], 'first');
      _invoke(runtime, 'releaseHandle', [$String(first)]);
      expect(firstState.isDisposed, isTrue);
      expect(secondState.isDisposed, isFalse);
      await _append(tester, '?');
      expect(notices, [1, 1]);
      expect(
        (_invoke(runtime, 'snapshotHandle', [$String(second)])
            as Map)['markdown'],
        contains('second?'),
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

  testWidgets(
    'exit retention synchronously stops already-mounted native input',
    (tester) async {
      await tester.pumpWidget(_host(presentation()));
      final state = await _select(tester, 'ab');
      await _append(tester, '!');
      final element = tester.element(find.byType(AppFlowyEditor));
      final before = state.document.root.toJson();
      final client = tester.testTextInput.log.lastWhere(
        (call) => call.method == 'TextInput.setClient',
      );
      generation.retainPresentations();
      expect(element.mounted, isTrue);
      expect(state.editable, isFalse);
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

  testWidgets(
    'unsupported post-edit serialization has an explicit safe result',
    (tester) async {
      await tester.pumpWidget(_host(presentation()));
      final state = await _select(tester, 'ab');
      final node = state.document.root.children.single;
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
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

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
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '${value.text}$text',
      selection: TextSelection.collapsed(
        offset: value.text.length + text.length,
      ),
    ),
  );
  await _frames(tester);
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
