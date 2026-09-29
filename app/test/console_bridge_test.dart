import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/console_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/frontend/terminal_projection_bridge.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/console_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:console_probe/main.dart';

void main() {
  late Program program;
  setUpAll(() async {
    program =
        (Compiler()
              ..addPlugin(const ConsoleDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'adele_ui': {
                'console_bridge.dart': await File(
                  '../packages/ui/lib/console_bridge.dart',
                ).readAsString(),
              },
              'console_probe': {
                'main.dart':
                    '''
import 'package:adele_ui/console_bridge.dart';
Future<List<dynamic>> open() => openPreparedConsole('test.output', 'run/invocation', 'Output', {'identity': 'opaque'});
Map<String, dynamic> data() => readConsoleContentData();
Map<String, dynamic> state() => readConsoleContentState();
bool remember() => writeConsoleContentState({'following': false, 'offset': 42});
bool oversized() => writeConsoleContentState({'text': '${'x' * 8193}'});
Future<List<dynamic>> badKey() => openPreparedConsole('test.output', '', 'Output', {});
final captured = <int>[0];
final notifications = <int>[0];
void Function() listener = () { notifications[0] = notifications[0] + 1; };
int interaction() => readConsoleInteraction();
int capture() => captured[0] = readConsoleInteraction();
bool capturedActive() => isConsoleInteractionActive(captured[0]);
void subscribe() => subscribeConsoleInteraction(listener);
void unsubscribe() => unsubscribeConsoleInteraction(listener);
int changes() => notifications[0];
''',
              },
            });
  });

  Runtime runtime(ConsoleBridge bridge) =>
      Runtime(ByteData.sublistView(program.write()))..addPlugin(bridge);

  ConsoleContentState content() => ConsoleContentState(
    ConsoleContentDescriptor(
      key: 'run/invocation',
      metadata: ConsoleMetadata(title: 'Output'),
      data: {'identity': 'opaque'},
    ),
  );

  test('public stubs grant no native admission or state', () {
    expect(
      () =>
          public_bridge.openPreparedConsole('test.output', 'key', 'Title', {}),
      throwsUnsupportedError,
    );
    expect(public_bridge.readConsoleContentData, throwsUnsupportedError);
    expect(public_bridge.readConsoleContentState, throwsUnsupportedError);
    expect(
      () => public_bridge.writeConsoleContentState({}),
      throwsUnsupportedError,
    );
    expect(public_bridge.readConsoleInteraction, throwsUnsupportedError);
    expect(
      () => public_bridge.isConsoleInteractionActive(1),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.subscribeConsoleInteraction(() {}),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.unsubscribeConsoleInteraction(() {}),
      throwsUnsupportedError,
    );
  });

  testWidgets(
    'EVC interaction epochs never revive while resident state stays usable',
    (tester) async {
      final presentation = _Presentation();
      final retained = content();
      final bridge = ConsoleBridge(
        isActive: () => true,
        presentation: presentation,
        content: retained,
      );
      final eval = runtime(bridge);
      Object? call(String name) =>
          copyStructuredBridgeData(eval.executeLib(_library, name));
      final first = call('capture') as int;
      expect(first, greaterThan(0));
      expect(call('capturedActive'), isTrue);
      expect(bridge.isInteractionActive(0), isFalse);
      call('subscribe');
      expect(presentation.hasSubscribers, isTrue);
      presentation.select(false);
      expect(call('capturedActive'), isFalse);
      expect(call('interaction'), 0);
      expect(call('remember'), isTrue);
      expect(call('data'), {'identity': 'opaque'});
      presentation.select(true);
      expect(call('capturedActive'), isFalse);
      expect(call('interaction'), greaterThan(first));
      expect(call('changes'), 0);
      await tester.pump();
      expect(
        call('changes'),
        1,
        reason: 'Multiple changes coalesce outside build.',
      );
      expect(call('capture'), greaterThan(first));
      expect(call('capturedActive'), isTrue);

      presentation.select(false);
      call('unsubscribe');
      await tester.pump();
      expect(
        call('changes'),
        1,
        reason: 'Unsubscribe fences queued callbacks.',
      );
      call('subscribe');
      presentation.select(true);
      presentation.retire();
      expect(presentation.hasSubscribers, isFalse);
      expect(call('interaction'), 0);
      expect(call('remember'), isFalse);
      expect(call('data'), isEmpty);
      await tester.pump();
      expect(call('changes'), 1, reason: 'Retirement fences queued callbacks.');
      bridge.invalidate();
      presentation.dispose();
    },
  );

  test('absent presentation grants no interaction', () {
    var active = true;
    final bridge = ConsoleBridge(isActive: () => active);
    final eval = runtime(bridge);
    expect(copyStructuredBridgeData(eval.executeLib(_library, 'capture')), 0);
    expect(
      copyStructuredBridgeData(eval.executeLib(_library, 'capturedActive')),
      isFalse,
    );
    active = false;
    expect(
      copyStructuredBridgeData(eval.executeLib(_library, 'capturedActive')),
      isFalse,
    );
    expect(
      copyStructuredBridgeData(eval.executeLib(_library, 'interaction')),
      0,
    );
    bridge.invalidate();
    active = true;
    expect(
      copyStructuredBridgeData(eval.executeLib(_library, 'interaction')),
      0,
    );
  });

  test('content release permanently retires its native checkpoint owner', () {
    final state = content();
    final oldView = TerminalProjectionBridge(
      isActive: () => true,
      retention: state.projection,
    );
    state.write({'following': false});
    state.clear();
    oldView.invalidate();
    expect(state.state, isEmpty);
    expect(state.projection.snapshot, isEmpty);
    expect(
      () => TerminalProjectionBridge(
        isActive: () => true,
        retention: state.projection,
      ),
      throwsStateError,
    );
  });

  test('actual EVC copies admission data and settles safe failures', () async {
    final admitted = <ConsoleContentDescriptor>[];
    final bridge = ConsoleBridge(
      isActive: () => true,
      open: (id, descriptor) async {
        expect(id, 'test.output');
        admitted.add(descriptor);
      },
    );
    final eval = runtime(bridge);
    expect(copyStructuredBridgeData(await eval.executeLib(_library, 'open')), [
      true,
      null,
    ]);
    expect(admitted.single.key, 'run/invocation');
    expect(admitted.single.metadata.title, 'Output');
    expect(admitted.single.data, {'identity': 'opaque'});
    expect(
      copyStructuredBridgeData(await eval.executeLib(_library, 'badKey')),
      [false, 'Console content is unavailable.'],
    );
    bridge.invalidate();
    expect(copyStructuredBridgeData(await eval.executeLib(_library, 'open')), [
      false,
      'Console content is unavailable.',
    ]);
    expect(admitted, hasLength(1));
    final denied = runtime(
      ConsoleBridge(
        isActive: () => true,
        open: (_, _) async => throw StateError('PRIVATE'),
      ),
    );
    expect(
      copyStructuredBridgeData(await denied.executeLib(_library, 'open')),
      [false, 'Console content is unavailable.'],
    );
  });

  test(
    'requesting view retirement does not retract admitted asynchronous opening',
    () async {
      final gate = Completer<void>();
      var calls = 0;
      final bridge = ConsoleBridge(
        isActive: () => true,
        open: (_, _) {
          calls++;
          return gate.future;
        },
      );
      final pending = runtime(bridge).executeLib(_library, 'open');
      expect(calls, 1);
      bridge.invalidate();
      gate.complete();
      expect(copyStructuredBridgeData(await pending), [true, null]);
      expect(await bridge.open('test.output', content().descriptor), [
        false,
        'Console content is unavailable.',
      ]);
    },
  );

  test(
    'fresh EVC sees only bounded retained state; obsolete runtime is fenced',
    () {
      final retained = content();
      var active = true;
      final bridge = ConsoleBridge(isActive: () => active, content: retained);
      final old = runtime(bridge);
      expect(copyStructuredBridgeData(old.executeLib(_library, 'data')), {
        'identity': 'opaque',
      });
      expect(
        copyStructuredBridgeData(old.executeLib(_library, 'remember')),
        isTrue,
      );
      expect(
        copyStructuredBridgeData(old.executeLib(_library, 'oversized')),
        isFalse,
      );
      expect(retained.state, {'following': false, 'offset': 42});
      active = false;
      expect(
        copyStructuredBridgeData(old.executeLib(_library, 'remember')),
        isFalse,
      );
      expect(
        copyStructuredBridgeData(old.executeLib(_library, 'data')),
        isEmpty,
      );
      final fresh = runtime(
        ConsoleBridge(isActive: () => true, content: retained),
      );
      expect(copyStructuredBridgeData(fresh.executeLib(_library, 'state')), {
        'following': false,
        'offset': 42,
      });
      retained.clear();
      expect(retained.state, isEmpty);
    },
  );
}

final class _Presentation extends ChangeNotifier
    implements ConsolePresentationAccess {
  @override
  bool isActive = true;
  @override
  Listenable get changes => this;
  bool get hasSubscribers => hasListeners;
  @override
  _Interaction? interaction = _Interaction();

  void select(bool selected) {
    interaction?.isActive = false;
    interaction = selected && isActive ? _Interaction() : null;
    notifyListeners();
  }

  void retire() {
    isActive = false;
    select(false);
  }
}

final class _Interaction implements ConsoleInteractionAccess {
  @override
  bool isActive = true;
}
