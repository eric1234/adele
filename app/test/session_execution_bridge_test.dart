import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_ui/session_execution_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:bridge_probe/main.dart';

void main() {
  test('settlement stub grants no native access', () {
    expect(
      () => public_bridge.settleSessionOperation(Future<Object?>.value(null)),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.openSessionRunActivity('run'),
      throwsUnsupportedError,
    );
  });

  test(
    'structured data copies nested containers and rejects cycles and objects',
    () {
      final source = <String, Object?>{
        'list': [
          1,
          true,
          null,
          {'text': 'safe'},
        ],
      };
      final copied =
          copyStructuredBridgeData(wrapStructuredBridgeData(source))!
              as Map<String, Object?>;
      expect(copied, source);
      expect(() => copied['other'] = 1, throwsUnsupportedError);
      expect(() => (copied['list']! as List).add(2), throwsUnsupportedError);
      final cycle = <String, Object?>{};
      cycle['self'] = cycle;
      expect(() => copyStructuredBridgeData(cycle), throwsFormatException);
      final evalCycle = <$Value>[];
      evalCycle.add($List.wrap(evalCycle));
      expect(
        () => copyStructuredBridgeData($List.wrap(evalCycle)),
        throwsFormatException,
      );
      expect(
        () => copyStructuredBridgeData({'object': Object()}),
        throwsFormatException,
      );
      expect(
        () => copyStructuredBridgeData({1: 'bad key'}),
        throwsFormatException,
      );
      expect(() => copyStructuredBridgeData(double.nan), throwsFormatException);
    },
  );

  test(
    'owning backend allowlist and lifetime apply before and after settlement',
    () async {
      final channel = _Channel()..pending = Completer<Object?>();
      var active = true;
      final bridge = OwningBackendBridge(
        channels: {'allowed': channel},
        validateBinding: () {
          if (!active) throw StateError('Retired origin');
        },
      );
      await expectLater(bridge.request('forged', 'echo', {}), throwsStateError);
      expect(channel.calls, 0);
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      await expectLater(
        bridge.request('allowed', 'echo', {'cycle': cyclic}),
        throwsFormatException,
      );
      expect(channel.calls, 0);
      final result = bridge.request('allowed', 'echo', {
        'nested': [1, null],
      });
      expect(channel.calls, 1);
      active = false;
      channel.pending!.complete({'result': true});
      await expectLater(result, throwsStateError);
      bridge.invalidate();
      active = true;
      await expectLater(
        bridge.request('allowed', 'echo', {}),
        throwsStateError,
      );
      expect(channel.calls, 1);
    },
  );

  late Program program;
  setUpAll(() {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const SessionExecutionDeclarations())
      ..addPlugin(const OwningBackendDeclarations())
      ..entrypoints.add(_library);
    program = compiler.compile({
      'bridge_probe': {
        'main.dart': '''
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:flutter/widgets.dart';
int changes = 0;
final listener = () { changes++; };
void subscribe() { subscribeSessionExecution(listener); }
void unsubscribe() { unsubscribeSessionExecution(listener); }
int count() => changes;
Map<String, Object?> execution() => readSessionExecution();
String session() => currentSessionId();
Future<String> start() => startSessionRun();
String? open() => openSessionRunActivity('retained-run');
String? missing() => openSessionRunActivity('missing-run');
Map<String, Object?> activity() => readSessionRunActivity('run-handle');
bool inspect() => inspectSessionActivity('model-handle');
bool guess() => inspectSessionActivity('not-emitted');
Widget compact() => buildSessionActivity('model-handle');
Future<Object?> query() => OwningBackendRequestChannel('allowed').request('echo', {'nested': [1, true, null, {'text': 'safe'}]});
class Decoded {
  Decoded(this.value);
  final String value;
}
Future<Decoded> decode() async {
  await query();
  return Decoded('interpreted value');
}
Future<String> settleDecoded() async {
  final result = await settleSessionOperation(decode());
  if (result[0] != true) return 'rejected';
  return (result[1] as Decoded).value;
}
Future<void> nothing() async {}
Future<List<dynamic>> settleVoid() => settleSessionOperation(nothing());
Future<List<dynamic>> settleStart() => settleSessionOperation(startSessionRun());
Future<List<dynamic>> settleQuery() => settleSessionOperation(query());
Future<Object?> badDecode() async {
  await query();
  throw FormatException('private decoder failure');
}
Future<List<dynamic>> settleBadDecode() => settleSessionOperation(badDecode());
''',
      },
      'adele_ui': {
        for (final name in [
          'session_execution_bridge.dart',
          'owning_backend_bridge.dart',
        ])
          name: File(
            '${Directory.current.parent.path}/packages/ui/lib/$name',
          ).readAsStringSync(),
      },
      'adele_contract': {
        'adele_contract.dart': '''
abstract class AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload);
}
''',
      },
    });
  });

  test(
    'generic settlement preserves values and contains Future rejection',
    () async {
      final source = _Source();
      final channel = _Channel();
      final bridge = PreparedFrontendBridges([
        SessionExecutionBridge(source: source, isActive: () => source.active),
        OwningBackendBridge(
          channels: {'allowed': channel},
          validateBinding: () {},
        ),
      ]);
      addTearDown(() {
        bridge.invalidate();
        source.dispose();
      });
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      Future<Object?> invoke(String entry) async => copyStructuredBridgeData(
        await (runtime.executeLib(_library, entry) as Future<Object?>),
      );
      expect(await invoke('settleDecoded'), 'interpreted value');
      expect(await invoke('settleVoid'), [true, null]);
      expect(await invoke('settleStart'), [true, 'run-handle']);
      expect(await invoke('settleQuery'), [
        true,
        {
          'nested': [
            1,
            true,
            null,
            {'text': 'safe'},
          ],
        },
      ]);
      expect(await invoke('settleBadDecode'), [false, null]);

      channel.pending = Completer<Object?>();
      final rejected = invoke('settleDecoded');
      channel.pending!.completeError(StateError('private native failure'));
      expect(await rejected, 'rejected');

      source.pending = Completer<String>();
      final retired = invoke('settleStart');
      bridge.invalidate();
      source.pending!.complete('late-handle');
      expect(await retired, [false, null]);
    },
  );

  testWidgets(
    'retained activity handles use the same read and inspect authorization',
    (tester) async {
      final source = _Source();
      final bridge = SessionExecutionBridge(
        source: source,
        isActive: () => source.active,
      );
      addTearDown(() {
        bridge.invalidate();
        source.dispose();
      });
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      Object? invoke(String entry) =>
          copyStructuredBridgeData(runtime.executeLib(_library, entry));
      expect(invoke('missing'), isNull);
      expect(invoke('open'), 'run-handle');
      expect(source.starts, 0);
      expect(invoke('inspect'), isFalse);
      expect((invoke('activity') as Map)['state'], 'completed');
      expect(invoke('inspect'), isTrue);
      expect(invoke('guess'), isFalse);
      expect(invoke('open'), 'run-handle');
      bridge.retainPresentation();
      expect((invoke('activity') as Map)['state'], 'completed');
      expect(invoke('inspect'), isFalse);
      expect(() => invoke('open'), throwsA(anything));
      expect(source.starts, 0);
    },
  );

  testWidgets(
    'exit retention preserves display while revoking actions and late settlement',
    (tester) async {
      final source = _Source();
      final channel = _Channel();
      final bridge = PreparedFrontendBridges([
        SessionExecutionBridge(source: source, isActive: () => source.active),
        OwningBackendBridge(
          channels: {'allowed': channel},
          validateBinding: () {},
        ),
      ]);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
      Object? invoke(String entry) => runtime.executeLib(_library, entry);
      await (invoke('start') as Future<Object?>);
      final activity = copyStructuredBridgeData(invoke('activity'));
      final compact = (invoke('compact') as $Value).$reified;
      invoke('subscribe');
      source.notifyListeners();
      channel.pending = Completer<Object?>();
      final pending = invoke('settleQuery') as Future<Object?>;
      bridge.retainPresentation();
      expect(source.observing, isFalse);
      source.revision++;
      source.runState = 'failed';
      await tester.pump();
      expect(copyStructuredBridgeData(invoke('count')), 0);
      expect(copyStructuredBridgeData(invoke('session')), 'session-data');
      expect(copyStructuredBridgeData(invoke('execution')), {
        ...source.readExecution(),
        'canStart': false,
        'revision': 1,
      });
      expect(copyStructuredBridgeData(invoke('activity')), activity);
      expect((invoke('compact') as $Value).$reified, same(compact));
      expect(copyStructuredBridgeData(invoke('inspect')), isFalse);
      expect(
        copyStructuredBridgeData(
          await (invoke('settleStart') as Future<Object?>),
        ),
        [false, null],
      );
      channel.pending!.complete({'late': true});
      expect(copyStructuredBridgeData(await pending), [false, null]);
      bridge.invalidate();
      expect(() => invoke('execution'), throwsA(anything));
      expect(() => invoke('activity'), throwsA(anything));
      expect(copyStructuredBridgeData(invoke('inspect')), isFalse);
      source.dispose();
    },
  );

  testWidgets(
    'both public ABIs compose with coalesced and removable observation',
    (tester) async {
      final source = _Source();
      final channel = _Channel();
      final bridge = PreparedFrontendBridges([
        SessionExecutionBridge(source: source, isActive: () => source.active),
        OwningBackendBridge(
          channels: {'allowed': channel},
          validateBinding: () {},
        ),
      ]);
      final runtime = Runtime(program.write().buffer.asByteData())
        ..addPlugin(bridge);
      Object? invoke(String entry) => runtime.executeLib(_library, entry);
      expect(copyStructuredBridgeData(invoke('session')), 'session-data');
      expect(
        copyStructuredBridgeData(invoke('execution')),
        source.readExecution(),
      );
      expect(
        copyStructuredBridgeData(await (invoke('start') as Future<Object?>)),
        'run-handle',
      );
      expect(copyStructuredBridgeData(invoke('inspect')), isFalse);
      invoke('activity');
      expect(copyStructuredBridgeData(invoke('inspect')), isTrue);
      expect(copyStructuredBridgeData(invoke('guess')), isFalse);
      expect(
        copyStructuredBridgeData(await (invoke('query') as Future<Object?>)),
        {
          'nested': [
            1,
            true,
            null,
            {'text': 'safe'},
          ],
        },
      );
      invoke('subscribe');
      source.notifyListeners();
      source.notifyListeners();
      expect(copyStructuredBridgeData(invoke('count')), 0);
      await tester.pump();
      expect(copyStructuredBridgeData(invoke('count')), 1);
      source.notifyListeners();
      invoke('unsubscribe');
      await tester.pump();
      expect(copyStructuredBridgeData(invoke('count')), 1);
      invoke('subscribe');
      source.notifyListeners();
      bridge.invalidate();
      await tester.pump();
      expect(source.active, isFalse);
      expect(source.observing, isFalse);
      expect(copyStructuredBridgeData(invoke('inspect')), isFalse);
      expect(copyStructuredBridgeData(invoke('count')), 1);
      source.dispose();
    },
  );
}

final class _Channel implements AdeleRequestChannel {
  int calls = 0;
  Completer<Object?>? pending;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls++;
    return pending == null ? payload : await pending!.future;
  }
}

final class _Source extends ChangeNotifier implements SessionExecutionSource {
  bool active = true;
  int revision = 1;
  int starts = 0;
  String runState = 'completed';
  Completer<String>? pending;
  bool get observing => hasListeners;
  @override
  String currentSessionId() => 'session-data';
  @override
  Map<String, Object?> readExecution() => {
    'canStart': true,
    'running': false,
    'advancing': false,
    'failure': null,
    'unavailableReason': null,
    'revision': revision,
  };
  @override
  Future<String> startRun() async {
    starts++;
    return pending == null ? 'run-handle' : await pending!.future;
  }

  @override
  String? openRunActivity(String runId) =>
      runId == 'retained-run' ? 'run-handle' : null;
  @override
  Map<String, Object?> readRunActivity(String handle) => {
    'runHandle': handle,
    'state': runState,
    'models': [
      {'handle': 'model-handle', 'outputs': <Object?>[]},
    ],
  };
  @override
  bool inspectActivity(String handle) => true;
  @override
  Widget buildActivity(String handle) => const SizedBox.shrink();
  @override
  void invalidate() => active = false;
}
