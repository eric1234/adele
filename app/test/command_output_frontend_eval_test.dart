import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/console_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/terminal_projection_bridge.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import '../tool/tool_inspection_frontend_compiler.dart';

// The backend is a deterministic test fixture, but both codecs, the stock reader
// EVC, native bridge admission, and terminal parsing/rendering are production.
void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend frontend;
  late _Output output;
  late _Channel channel;
  late ConsoleContentState content;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('command-output-evc-');
    artifact = File('${temporary.path}/command.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
      frontend: ToolInspectionFrontend.command,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    frontend = await PreparedFrontend.load(artifact);
    output = _Output();
    channel = _Channel(output);
    content = ConsoleContentState(
      ConsoleContentDescriptor(
        key: 'run/invocation',
        metadata: ConsoleMetadata(title: 'Command output fixture'),
        data: const {
          'sessionId': 'session',
          'runId': 'run',
          'toolInvocationId': 'invocation',
          'title': 'Command output fixture',
        },
      ),
    );
  });
  tearDown(() async {
    frontend.invalidate();
    if (output.readGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    await channel.dispatcher.close();
    await output.close();
  });

  Widget presentation({bool preview = false}) {
    final source = preview ? _InspectionSource() : null;
    if (source != null) addTearDown(source.dispose);
    return frontend.createPresentation(
      library: preview
          ? 'package:command_tools_frontend/command_tools_frontend.dart'
          : 'package:command_tools_frontend/command_output_view.dart',
      entrypoint: preview
          ? 'buildRunCommandInspection'
          : 'buildRunCommandOutput',
      createBridge: () => PreparedFrontendBridges([
        if (source != null)
          ToolActivityInspectionBridge(source: source, isActive: () => true),
        OwningBackendBridge(
          channels: {commandOutputServiceId: channel},
          validateBinding: () {},
        ),
        ConsoleBridge(isActive: () => true, content: content),
        TerminalProjectionBridge(isActive: () => true, maxLines: 32),
      ]),
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    bool preview = false,
    bool both = false,
  }) {
    // Failed assertions must still detach generated watches before dispatcher
    // teardown; otherwise a useful failure can wait on an unrelated subscription.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: preview ? 320 : 360,
            child: both
                ? Row(
                    children: [
                      Expanded(
                        key: const ValueKey('preview'),
                        child: SingleChildScrollView(
                          child: presentation(preview: true),
                        ),
                      ),
                      Expanded(
                        key: const ValueKey('expanded'),
                        child: presentation(),
                      ),
                    ],
                  )
                : preview
                ? SingleChildScrollView(child: presentation(preview: true))
                : presentation(),
          ),
        ),
      ),
    );
  }

  Future<void> caughtUp(WidgetTester tester) => _until(
    tester,
    () =>
        content.state['codeUnits'] == output.units &&
        find.text('Following output').evaluate().isNotEmpty,
    'reader caught up with committed output',
  );

  Future<void> history(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await _until(
      tester,
      () => find.text('Reading history').evaluate().isNotEmpty,
      '$label prefix replay',
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _until(tester, () => output.observers.isEmpty, 'watch cancellation');
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'generated watch admits after absence and renders split controls',
    (tester) async {
      await mount(tester);
      await _until(
        tester,
        () => output.watches == 1,
        'generated service watch opens',
      );
      await _until(
        tester,
        () => channel.items == 1,
        'generated state crosses dispatcher',
      );
      await _until(
        tester,
        () => find
            .text('No output capture has been admitted.')
            .evaluate()
            .isNotEmpty,
        'initial absent header',
      );
      expect(find.byType(TerminalView), findsNothing);
      expect(output.cursors, isEmpty);
      expect(output.watches, 1);

      output.publish('capturing');
      await caughtUp(tester);
      expect(find.text('Capture: capturing'), findsOneWidget);
      final view = _view(tester);
      expect(view.readOnly, isTrue);
      expect(view.autoResize, isFalse);
      expect((view.terminal.viewWidth, view.terminal.viewHeight), (80, 20));

      output.append('waiting');
      await caughtUp(tester);
      expect(_text(_view(tester).terminal), startsWith('waiting\n'));
      output.append('\rOK\x1b[K\n\x1b[3');
      await caughtUp(tester);
      output.append(
        '1;1mred\x1b[0m \u03bb\u754c \u{1f600}\nnext',
        stderr: true,
      );
      await caughtUp(tester);
      final terminal = _view(tester).terminal;
      expect(terminal.buffer.lines[0].getText().trimRight(), 'OK');
      expect(
        terminal.buffer.lines[1].getText().trimRight(),
        'red \u03bb\u754c \u{1f600}',
      );
      expect(terminal.buffer.lines[2].getText().trimRight(), 'next');
      expect(
        terminal.buffer.lines[1].getForeground(0) & CellColor.valueMask,
        1,
      );
      expect(
        terminal.buffer.lines[1].getAttributes(0) & CellAttr.bold,
        isNonZero,
      );
      final before = _text(terminal);
      final reads = output.cursors.length;
      output.publish('complete', exitCode: 23);
      await _until(
        tester,
        () => find.textContaining('Exit: 23').evaluate().isNotEmpty,
        'state-only nonzero completion',
      );
      expect(_text(_view(tester).terminal), before);
      expect(output.cursors.length, reads);
      expect(output.watches, 1);
      expect(channel.methods.toSet(), {
        commandOutputServiceWatchId,
        commandOutputServiceReadAfterId,
      });
      await unmount(tester);
    },
  );

  testWidgets('long unbroken lines page through bounded prefix row windows', (
    tester,
  ) async {
    final text = List.generate(
      120,
      (i) => 'row${i.toString().padLeft(3, '0')}:'.padRight(80, '.'),
    ).join();
    output.publish('capturing');
    output.append(text);
    await mount(tester);
    await caughtUp(tester);
    expect(_text(_view(tester).terminal), contains('row119:'));
    expect(_text(_view(tester).terminal), isNot(contains('row000:')));
    expect(_view(tester).terminal.buffer.height, lessThanOrEqualTo(32));

    void expectPrefix() {
      final consumed = content.state['codeUnits']! as int;
      final reference = Terminal(maxLines: 32)..resize(80, 20);
      reference.write(text.substring(0, consumed));
      expect(_text(_view(tester).terminal), _text(reference));
      expect(_view(tester).terminal.buffer.height, lessThanOrEqualTo(32));
    }

    await history(tester, 'Beginning');
    final beginning = content.state['codeUnits']! as int;
    expect(beginning, inInclusiveRange(800, 880));
    expect(beginning, lessThan(4096)); // Stops inside a stored chunk.
    expectPrefix();
    expect(_text(_view(tester).terminal), contains('row000:'));
    await history(tester, 'Later');
    expect(content.state['codeUnits'], beginning + 800);
    expectPrefix();
    await history(tester, 'Earlier');
    expect(content.state['codeUnits'], beginning);
    expectPrefix();
    await history(tester, 'Middle');
    expect(content.state['codeUnits']! as int, greaterThan(beginning + 800));
    expectPrefix();
    await tester.tap(find.byTooltip('Follow output'));
    await caughtUp(tester);
    expectPrefix();
    expect(
      output.cursors.where((cursor) => cursor == 0).length,
      greaterThanOrEqualTo(5),
    );
    expect(output.maximumReads, 1);
    expect(output.maximumPageChunks, lessThanOrEqualTo(4));
    expect(output.maximumPageUnits, lessThanOrEqualTo(16384));
    expect(content.state.keys.toSet(), {
      'following',
      'liveTail',
      'codeUnits',
      'knownLines',
      'scrollOffset',
    });
    expect(
      content.state.values.every((value) => value is bool || value is num),
      isTrue,
    );
    expect(jsonEncode(content.state).length, lessThan(256));
    await unmount(tester);
  });

  testWidgets(
    'watch bursts share one read chain and preserve newer terminal state',
    (tester) async {
      output.publish('capturing');
      output.append('x' * (4096 * 5));
      output.readGate = Completer<void>();
      await mount(tester);
      await _until(
        tester,
        () => output.activeReads == 1,
        'held generated page read',
      );
      for (var i = 0; i < 20; i++) {
        output.publish('capturing');
      }
      output.publish('complete', exitCode: 7);
      await _until(
        tester,
        () => find.textContaining('Exit: 7').evaluate().isNotEmpty,
        'newer terminal notification while page is held',
      );
      expect(output.cursors, [0]);
      expect(output.maximumReads, 1);
      output.readGate!.complete();
      await caughtUp(tester);
      expect(find.textContaining('Capture: complete'), findsOneWidget);
      expect(output.cursors, [0, 4]);
      expect(output.maximumReads, 1);
      expect(output.maximumPageChunks, 4);
      expect(output.maximumPageUnits, 16384);
      expect(_view(tester).terminal.buffer.height, lessThanOrEqualTo(32));
      expect(
        content.state.values.every((value) => value is bool || value is num),
        isTrue,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'native scroll freezes pending reads and scalar state survives remount',
    (tester) async {
      String lines(String prefix, int count) =>
          List.generate(count, (i) => '$prefix-$i\r\n').join();
      output.publish('capturing');
      output.append(lines('original', 100));
      await mount(tester);
      await caughtUp(tester);
      final original = _text(_view(tester).terminal);
      final originalUnits = output.units;
      output.readGate = Completer<void>();
      output.append(lines('during-read', 80));
      await _until(
        tester,
        () => output.activeReads == 1,
        'read before user scroll',
      );
      expect(
        _view(tester).scrollController!.position.maxScrollExtent,
        greaterThan(0),
      );
      await tester.drag(find.byType(TerminalView), const Offset(0, 100));
      await _until(
        tester,
        () => content.state['following'] == false,
        'native scroll freeze',
      );
      expect(
        _view(tester).scrollController!.offset,
        lessThan(_view(tester).scrollController!.position.maxScrollExtent),
      );
      output.append(lines('hidden-later', 80));
      output.readGate!.complete();
      await _until(
        tester,
        () => output.activeReads == 0,
        'late page settlement',
      );
      expect(_text(_view(tester).terminal), original);
      expect(content.state['codeUnits'], originalUnits);
      final retained = Map<String, Object?>.from(content.state);
      final oldTerminal = _view(tester).terminal;
      await unmount(tester);
      output.append(lines('while-hidden', 30));
      await mount(tester);
      await _until(
        tester,
        () => find.text('Reading history').evaluate().isNotEmpty,
        'reconstruction of frozen prefix on remount',
      );
      expect(_view(tester).terminal, isNot(same(oldTerminal)));
      expect(_text(_view(tester).terminal), original);
      expect(content.state['codeUnits'], retained['codeUnits']);
      expect(content.state['following'], false);
      expect(content.state['liveTail'], true);
      expect(
        _view(tester).scrollController!.offset,
        closeTo((retained['scrollOffset']! as num).toDouble(), 1),
      );
      expect(output.watches, 2);
      final scroll = _view(tester).scrollController!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(content.state['following'], false);
      expect(content.state['codeUnits'], retained['codeUnits']);
      scroll.jumpTo((retained['scrollOffset']! as num).toDouble());
      await tester.pump();
      await _userToEnd(tester, find.byType(TerminalView));
      await caughtUp(tester);
      expect(_text(_view(tester).terminal), contains('while-hidden-29'));
      expect(_text(_view(tester).terminal), isNot(contains('original-')));
      expect(output.maximumReads, 1);
      await unmount(tester);
    },
  );

  for (final (mode, message) in [
    ('empty', 'Committed output is unavailable.'),
    ('gap', 'Stored output continuity is unavailable.'),
    ('foreign', 'Output association is unavailable.'),
    (
      'error',
      'Stored output could not be read. Close and reopen to try fresh access.',
    ),
  ]) {
    testWidgets('generated page $mode fails explicitly without retry', (
      tester,
    ) async {
      output.publish('capturing');
      output.append('not silently skipped');
      output.readMode = mode;
      await mount(tester);
      await _until(
        tester,
        () => find.text(message).evaluate().isNotEmpty,
        '$mode failure',
      );
      expect(output.cursors, [0]);
      expect(
        _text(_view(tester).terminal),
        isNot(contains('not silently skipped')),
      );
      output.publish('complete', exitCode: 0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(output.cursors, [0]);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.text('Frontend unavailable.'), findsNothing);
      await unmount(tester);
    });
  }

  for (final terminal in ['failed', 'interrupted']) {
    testWidgets('$terminal capture preserves readable committed prefix', (
      tester,
    ) async {
      output.publish('capturing');
      output.append('known prefix');
      output.publish(terminal);
      await mount(tester);
      await caughtUp(tester);
      expect(
        find.textContaining('Capture incomplete ($terminal)'),
        findsOneWidget,
      );
      expect(_text(_view(tester).terminal), startsWith('known prefix\n'));
      unawaited(output.observers.single.close());
      await _until(
        tester,
        () => output.observers.isEmpty,
        'terminal watch close',
      );
      expect(
        find.textContaining('Live output observation ended.'),
        findsNothing,
      );
      expect(
        find.textContaining('Capture incomplete ($terminal)'),
        findsOneWidget,
      );
      expect(output.watches, 1);
      await unmount(tester);
    });
  }

  testWidgets('watch failure retains rendered output and does not reconnect', (
    tester,
  ) async {
    output.publish('capturing');
    output.append('committed before failure');
    await mount(tester);
    await caughtUp(tester);
    final before = _text(_view(tester).terminal);
    output.observers.single.addError(StateError('SECRET native failure'));
    await _until(
      tester,
      () => find
          .textContaining('Output reader unavailable.')
          .evaluate()
          .isNotEmpty,
      'stream failure',
    );
    expect(_text(_view(tester).terminal), before);
    expect(output.watches, 1);
    expect(find.textContaining('SECRET'), findsNothing);
    expect(find.text('Frontend unavailable.'), findsNothing);
    await unmount(tester);
  });

  testWidgets('empty completion is not absence or a reason to read output', (
    tester,
  ) async {
    output.publish('complete', exitCode: 17);
    await mount(tester);
    await caughtUp(tester);
    expect(find.textContaining('Capture complete: no output.'), findsOneWidget);
    expect(find.textContaining('Exit: 17'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(output.cursors, isEmpty);
    unawaited(output.observers.single.close());
    await _until(
      tester,
      () => output.observers.isEmpty,
      'complete watch close',
    );
    expect(find.textContaining('Live output observation ended.'), findsNothing);
    expect(find.textContaining('Capture complete: no output.'), findsOneWidget);
    expect(output.watches, 1);
    await unmount(tester);
  });

  testWidgets('same-version live failure is not overwritten by an older page', (
    tester,
  ) async {
    output.publish('capturing');
    output.append('committed before uncertain failure');
    output.readGate = Completer<void>();
    await mount(tester);
    await _until(
      tester,
      () => output.activeReads == 1,
      'held capturing snapshot',
    );
    output.publish('failed', advanceVersion: false);
    await _until(
      tester,
      () => find
          .textContaining('Capture incomplete (failed)')
          .evaluate()
          .isNotEmpty,
      'same-version live failure overlay',
    );
    output.readGate!.complete();
    await caughtUp(tester);
    expect(find.textContaining('Capture incomplete (failed)'), findsOneWidget);
    expect(
      _text(_view(tester).terminal),
      startsWith('committed before uncertain failure\n'),
    );
    expect(output.cursors, [0]);
    await unmount(tester);
  });

  testWidgets('stream close during capture is not fabricated completion', (
    tester,
  ) async {
    output.publish('capturing');
    output.append('still partial');
    await mount(tester);
    await caughtUp(tester);
    unawaited(output.observers.single.close());
    await _until(
      tester,
      () => find
          .textContaining('Live output observation ended.')
          .evaluate()
          .isNotEmpty,
      'live observation ended',
    );
    expect(find.text('Capture: capturing'), findsOneWidget);
    expect(_text(_view(tester).terminal), startsWith('still partial\n'));
    expect(output.watches, 1);
    await unmount(tester);
  });

  for (final initial in [false, true]) {
    testWidgets(
      'watch close ${initial ? 'after absence' : 'before initial state'} fails without retry',
      (tester) async {
        output.emitInitial = initial;
        await mount(tester);
        await _until(
          tester,
          () => initial
              ? find
                    .text('No output capture has been admitted.')
                    .evaluate()
                    .isNotEmpty
              : output.observers.isNotEmpty,
          'watch admitted',
        );
        if (!initial) {
          expect(find.text('Connecting to output...'), findsOneWidget);
        }
        unawaited(output.observers.single.close());
        await _until(
          tester,
          () => find
              .textContaining('Live output observation ended.')
              .evaluate()
              .isNotEmpty,
          'early observation close',
        );
        expect(find.text('Connecting to output...'), findsNothing);
        expect(
          find.text(
            initial
                ? 'No output capture has been admitted.'
                : 'Output state unavailable.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Capture complete'), findsNothing);
        expect(find.byType(TerminalView), findsNothing);
        output.publish('complete', exitCode: 0);
        await tester.pump(const Duration(milliseconds: 50));
        expect(output.watches, 1);
        expect(output.cursors, isEmpty);
        expect(find.textContaining('Capture complete'), findsNothing);
        await unmount(tester);
      },
    );
  }

  for (final selection in [false, true]) {
    testWidgets(
      'stock Inspection preview stays live after native ${selection ? 'selection' : 'scroll'}',
      (tester) async {
        output.publish('capturing');
        output.append(List.generate(100, (i) => 'preview-$i\r\n').join());
        await mount(tester, preview: true);
        await _until(
          tester,
          () =>
              find.text('Following output').evaluate().isNotEmpty &&
              find.byType(TerminalView).evaluate().isNotEmpty &&
              _text(_view(tester).terminal).contains('preview-99'),
          'stock preview catches up',
        );
        expect(find.text('Run Command'), findsOneWidget);
        expect(_view(tester).terminal.viewHeight, 6);
        expect(find.byTooltip('Follow output'), findsNothing);
        await tester.ensureVisible(find.byType(TerminalView));
        await tester.pump();
        final view = _view(tester);
        if (selection) {
          view.controller!.setSelection(
            view.terminal.buffer.createAnchor(0, 0),
            view.terminal.buffer.createAnchor(4, 0),
          );
        } else {
          final outer = tester
              .stateList<ScrollableState>(find.byType(Scrollable))
              .firstWhere((state) => state.position.axis == Axis.vertical);
          final before = outer.position.pixels;
          expect(before, greaterThan(0));
          await tester.dragFrom(
            tester.getTopLeft(find.byType(TerminalView)) + const Offset(80, 50),
            const Offset(0, 50),
          );
          expect(outer.position.pixels, lessThan(before));
        }
        output.append('preview-late\r\n');
        await _until(
          tester,
          () =>
              find.text('Following output').evaluate().isNotEmpty &&
              _text(_view(tester).terminal).contains('preview-late'),
          'preview remains live without a Follow action',
        );
        expect(find.byTooltip('Follow output'), findsNothing);
        expect(find.text('Show more'), findsOneWidget);
        expect(output.watches, 1);
        expect(output.maximumReads, 1);
        expect(content.state, isEmpty);
        await unmount(tester);
      },
    );
  }

  testWidgets('user live-end return resumes the actual expanded reader', (
    tester,
  ) async {
    output.publish('capturing');
    output.append(List.generate(100, (i) => 'live-$i\r\n').join());
    await mount(tester);
    await caughtUp(tester);
    await tester.drag(find.byType(TerminalView), const Offset(0, 100));
    await _until(
      tester,
      () => content.state['following'] == false,
      'pause live tail',
    );
    final frozen = _text(_view(tester).terminal);
    final units = content.state['codeUnits'];
    final notifications = channel.items;
    output.append('manual-return-late\r\n');
    await _until(
      tester,
      () => channel.items > notifications,
      'paused extent advances',
    );
    expect(_text(_view(tester).terminal), frozen);
    expect(content.state['codeUnits'], units);
    output.readGate = Completer<void>();
    final reads = output.cursors.length;
    await _userToEnd(tester, find.byType(TerminalView));
    await _until(
      tester,
      () => output.activeReads == 1,
      'return begins one catch-up read',
    );
    await tester.pump();
    expect(find.text('Replaying output...'), findsOneWidget);
    expect(find.text('Following output'), findsNothing);
    expect(content.state['codeUnits'], units);
    output.readGate!.complete();
    await caughtUp(tester);
    expect(output.cursors.length, reads + 1);
    expect(_text(_view(tester).terminal), contains('manual-return-late'));
    output.append('subsequent-partial');
    await caughtUp(tester);
    expect(_text(_view(tester).terminal), contains('subsequent-partial'));
    expect(output.maximumReads, 1);
    await unmount(tester);
  });

  testWidgets(
    'explicit historical window stays chosen at its local end and on remount',
    (tester) async {
      output.publish('capturing');
      output.append(List.generate(100, (i) => 'window-$i\r\n').join());
      await mount(tester);
      await caughtUp(tester);
      await history(tester, 'Middle');
      expect(content.state['liveTail'], false);
      final frozen = _text(_view(tester).terminal);
      final units = content.state['codeUnits'];
      final notifications = channel.items;
      output.append('explicit-window-late\r\n');
      await _until(
        tester,
        () => channel.items > notifications,
        'historical observation',
      );
      await _userToEnd(tester, find.byType(TerminalView));
      await tester.pump();
      expect(content.state['following'], false);
      expect(content.state['codeUnits'], units);
      expect(_text(_view(tester).terminal), frozen);
      await unmount(tester);
      await mount(tester);
      await _until(
        tester,
        () => find.text('Reading history').evaluate().isNotEmpty,
        'history restoration',
      );
      expect(content.state['liveTail'], false);
      await _userToEnd(tester, find.byType(TerminalView));
      await tester.pump();
      expect(content.state['codeUnits'], units);
      expect(_text(_view(tester).terminal), frozen);
      await tester.tap(find.byTooltip('Follow output'));
      await caughtUp(tester);
      expect(content.state['liveTail'], true);
      expect(_text(_view(tester).terminal), contains('explicit-window-late'));
      await unmount(tester);
    },
  );

  testWidgets(
    'expanded selection protects its region while the independent preview follows',
    (tester) async {
      output.publish('capturing');
      output.append(List.generate(100, (i) => 'independent-$i\r\n').join());
      await mount(tester, both: true);
      await caughtUp(tester);
      final expanded = find.descendant(
        of: find.byKey(const ValueKey('expanded')),
        matching: find.byType(TerminalView),
      );
      final preview = find.descendant(
        of: find.byKey(const ValueKey('preview')),
        matching: find.byType(TerminalView),
      );
      await _until(
        tester,
        () =>
            preview.evaluate().isNotEmpty &&
            _text(
              tester.widget<TerminalView>(preview).terminal,
            ).contains('independent-99'),
        'independent preview',
      );
      final view = tester.widget<TerminalView>(expanded);
      view.controller!.setSelection(
        view.terminal.buffer.createAnchor(0, 0),
        view.terminal.buffer.createAnchor(4, 0),
      );
      await _until(
        tester,
        () => content.state['following'] == false,
        'selection freeze',
      );
      final frozen = _text(view.terminal);
      output.append('selection-protected-late\r\n');
      await _until(
        tester,
        () => _text(
          tester.widget<TerminalView>(preview).terminal,
        ).contains('selection-protected-late'),
        'preview remains live during expanded selection',
      );
      await _userToEnd(tester, expanded);
      await tester.pump();
      expect(content.state['following'], false);
      expect(_text(view.terminal), frozen);
      expect(view.controller!.selection, isNotNull);
      await tester.drag(
        find.descendant(
          of: find.byKey(const ValueKey('expanded')),
          matching: find.byType(ListView),
        ),
        const Offset(-300, 0),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Follow output'));
      await caughtUp(tester);
      expect(view.controller!.selection, isNull);
      expect(_text(view.terminal), contains('selection-protected-late'));
      await unmount(tester);
    },
  );

  testWidgets(
    'disposal during manual return leaves late read settlement inert',
    (tester) async {
      output.publish('capturing');
      output.append(List.generate(100, (i) => 'disposed-$i\r\n').join());
      await mount(tester);
      await caughtUp(tester);
      await tester.drag(find.byType(TerminalView), const Offset(0, 100));
      await _until(
        tester,
        () => content.state['following'] == false,
        'paused projection',
      );
      output.readGate = Completer<void>();
      output.append('not-applied-after-disposal\r\n');
      await _userToEnd(tester, find.byType(TerminalView));
      await _until(
        tester,
        () => output.activeReads == 1,
        'manual catch-up held',
      );
      final retained = Map<String, Object?>.of(content.state);
      expect(retained['following'], true);
      expect(retained['liveTail'], true);
      await unmount(tester);
      output.readGate!.complete();
      await _until(
        tester,
        () => output.activeReads == 0,
        'obsolete read settles',
      );
      expect(content.state, retained);
      expect(find.byType(TerminalView), findsNothing);
      expect(output.observers, isEmpty);
      await mount(tester);
      await caughtUp(tester);
      expect(
        _text(_view(tester).terminal),
        contains('not-applied-after-disposal'),
      );
      expect(output.watches, 2);
      await unmount(tester);
    },
  );
}

Future<void> _userToEnd(WidgetTester tester, Finder view) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getTopLeft(view) + const Offset(50, 30),
      scrollDelta: const Offset(0, 20000),
    ),
  );
}

final class _InspectionSource extends ChangeNotifier
    implements ToolActivityInspectionSource {
  @override
  final SessionId sessionId = SessionId('session');
  @override
  final RunId runId = RunId('run');
  @override
  final ToolInvocationActivity snapshot = ToolInvocationActivity(
    id: ToolInvocationId('invocation'),
    preparedSequence: 2,
    modelInvocationId: ModelInvocationId('model'),
    proposalSequence: 1,
    toolId: ToolId('dev.adele.plugin.command-tools.run-command'),
    alias: 'run_command',
    providerCallId: 'provider-call',
    canonicalArguments: const {
      'program': 'fixture',
      'arguments': <String>[],
      'workingDirectory': '',
      'timeoutSeconds': 30,
    },
    changes: const [
      ToolActivityChange(sequence: 3, kind: ToolActivityKind.executionStarted),
    ],
  );
}

TerminalView _view(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView));

String _text(Terminal terminal) => [
  for (var i = 0; i < terminal.buffer.lines.length; i++)
    terminal.buffer.lines[i].getText().trimRight(),
].join('\n');

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var frame = 0; frame < 1000; frame++) {
    await tester.pump(const Duration(milliseconds: 10));
    final error = tester.takeException();
    if (error != null) fail('$reason: $error');
    if (ready()) return;
    if (find.text('Frontend unavailable.').evaluate().isNotEmpty) {
      fail('$reason: prepared frontend failed');
    }
  }
  fail(
    'Timed out: $reason; text: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
  );
}

final class _Output implements CommandOutputService {
  final chunks = <CommandOutputChunk>[];
  final observers = <StreamController<CommandCaptureState>>{};
  final cursors = <int>[];
  String status = 'absent';
  int version = 0;
  int units = 0;
  int? exit;
  int watches = 0;
  int activeReads = 0;
  int maximumReads = 0;
  int maximumPageChunks = 0;
  int maximumPageUnits = 0;
  String readMode = '';
  bool emitInitial = true;
  Completer<void>? readGate;

  CommandCaptureState get state => captureState('session');

  CommandCaptureState captureState(String sessionId) => CommandCaptureState(
    sessionId: sessionId,
    runId: 'run',
    toolInvocationId: 'invocation',
    state: status,
    version: version,
    highWater: chunks.length,
    totalCodeUnits: units,
    program: status == 'absent' ? null : 'fixture',
    argumentsJson: status == 'absent' ? null : '[]',
    workingDirectory: status == 'absent' ? null : '',
    environmentId: status == 'absent' ? null : 'environment',
    timeoutSeconds: status == 'absent' ? null : 30,
    termination: exit == null ? null : 'exited',
    exitCode: exit,
    failure: status == 'failed' ? 'capture unavailable' : null,
  );

  void publish(String next, {int? exitCode, bool advanceVersion = true}) {
    status = next;
    exit = exitCode;
    if (advanceVersion) version++;
    for (final observer in observers.toList()) {
      observer.add(state);
    }
  }

  void append(String text, {bool stderr = false}) {
    for (var offset = 0; offset < text.length;) {
      var end = math.min(offset + 4096, text.length);
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      chunks.add(
        CommandOutputChunk(
          cursor: chunks.length + 1,
          stream: stderr ? 'stderr' : 'stdout',
          text: text.substring(offset, end),
        ),
      );
      units += end - offset;
      offset = end;
    }
    publish(status, exitCode: exit);
  }

  void identity(String session, String run, String invocation) {
    expectSync((session, run, invocation), ('session', 'run', 'invocation'));
  }

  @override
  Future<CommandCaptureState> getState(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) async {
    identity(sessionId, runId, toolInvocationId);
    return state;
  }

  @override
  Future<CommandOutputPage> readAfter(
    String sessionId,
    String runId,
    String toolInvocationId,
    int afterCursor,
    int maxChunks,
    int maxCodeUnits,
  ) async {
    identity(sessionId, runId, toolInvocationId);
    expectSync((maxChunks, maxCodeUnits), (4, 16384));
    cursors.add(afterCursor);
    activeReads++;
    maximumReads = math.max(maximumReads, activeReads);
    final snapshot = captureState(
      readMode == 'foreign' ? 'foreign' : 'session',
    );
    final values = chunks.skip(afterCursor).take(maxChunks).toList();
    maximumPageChunks = math.max(maximumPageChunks, values.length);
    maximumPageUnits = math.max(
      maximumPageUnits,
      values.fold<int>(0, (sum, chunk) => sum + chunk.text.length),
    );
    try {
      await readGate?.future;
      if (readMode == 'error') throw StateError('SECRET storage path');
      return CommandOutputPage(
        state: snapshot,
        chunks: switch (readMode) {
          'empty' => [],
          'gap' => [
            CommandOutputChunk(
              cursor: afterCursor + 2,
              stream: 'stdout',
              text: 'gap',
            ),
          ],
          _ => values,
        },
      );
    } finally {
      activeReads--;
    }
  }

  @override
  Future<CommandOutputPage> readBefore(
    String sessionId,
    String runId,
    String toolInvocationId,
    int? beforeCursor,
    int maxChunks,
    int maxCodeUnits,
  ) =>
      throw StateError('Prefix reconstruction must not substitute a raw tail.');

  @override
  Stream<CommandCaptureState> watch(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) {
    identity(sessionId, runId, toolInvocationId);
    late final StreamController<CommandCaptureState> observer;
    observer = StreamController<CommandCaptureState>(
      onListen: () {
        watches++;
        observers.add(observer);
        if (emitInitial) observer.add(state);
      },
      onCancel: () => observers.remove(observer),
    );
    return observer.stream;
  }

  Future<void> close() async {
    for (final observer in observers.toList()) {
      await observer.close();
    }
  }
}

final class _Channel implements AdeleStreamChannel {
  _Channel(this.output);
  final _Output output;
  // Construct its serial Future chain in the widget test's current async zone.
  late final AdeleBackendDispatcher dispatcher = CommandOutputServiceDispatcher(
    output,
  );
  final methods = <String>[];
  int nextId = 0;
  int items = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    methods.add(method);
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': nextId++,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) throw StateError('Generated request failed.');
    return jsonDecode(jsonEncode(response['payload']));
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    methods.add(method);
    final id = nextId++;
    var closed = false;
    var paused = false;
    var credited = false;
    late final StreamController<Object?> controller;
    late final void Function(Map<String, Object?>) send;
    void credit() {
      if (closed || paused || credited) return;
      credited = true;
      unawaited(
        dispatcher.handle({
          'kind': 'streamCredit',
          'requestId': id,
          'credit': 1,
        }, send),
      );
    }

    send = (frame) {
      if (closed) return;
      if (frame['kind'] == 'streamItem') {
        items++;
        credited = false;
        controller.add(jsonDecode(jsonEncode(frame['payload'])));
        scheduleMicrotask(credit);
      } else {
        closed = true;
        if (frame['kind'] == 'streamFailure') {
          controller.addError(StateError('Generated observation failed.'));
        }
        unawaited(controller.close());
      }
    };
    controller = StreamController<Object?>(
      onListen: () async {
        await dispatcher.handle({
          'kind': 'streamOpen',
          'requestId': id,
          'method': method,
          'payload': payload,
        }, send);
        credit();
      },
      onPause: () => paused = true,
      onResume: () {
        paused = false;
        credit();
      },
      onCancel: () async {
        closed = true;
        await dispatcher.handle({
          'kind': 'streamCancel',
          'requestId': id,
        }, send);
      },
    );
    return controller.stream;
  }
}
