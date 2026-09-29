import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/console_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/frontend/terminal_projection_bridge.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/console_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
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
