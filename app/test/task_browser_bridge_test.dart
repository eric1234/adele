import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/frontend/task_browser_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:browser_probe/main.dart';

void main() {
  late Program program;
  setUpAll(() {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const TaskBrowserDeclarations())
      ..entrypoints.add(_library);
    program = compiler.compile({
      'browser_probe': {
        'main.dart': '''
import 'package:adele_ui/task_browser_bridge.dart';
int changes = 0;
final listener = () { changes++; };
final failing = () { throw StateError('broken listener'); };
void subscribe() { subscribeTaskBrowser(listener); }
void subscribeFailing() { subscribeTaskBrowser(failing); }
void unsubscribe() { unsubscribeTaskBrowser(listener); }
int count() => changes;
Map<String, dynamic> read() => readTaskBrowser();
String executionStatus() => readTaskBrowser()['selectedTask']['sessions'][0]['executionStatus'] as String;
bool active() => isTaskBrowserActive();
String nested() {
  final entries = readTaskBrowser()['entries'] as List<dynamic>;
  String text = '';
  for (final entry in entries) {
    final data = entry as Map<String, dynamic>;
    text = data['title'] as String;
  }
  return text;
}
Future<List<dynamic>> select() => selectTask('task');
Future<List<dynamic>> clear() => selectTask(null);
Future<List<dynamic>> create() => createTask('title');
Future<List<dynamic>> session() => createSession('opaque');
Future<List<dynamic>> open() => openSession('session');
''',
      },
      'adele_ui': {
        'task_browser_bridge.dart': File(
          '${Directory.current.parent.path}/packages/ui/lib/task_browser_bridge.dart',
        ).readAsStringSync(),
      },
    });
  });

  test('all actions settle safely and never leak native exceptions', () async {
    final source = _Source();
    final bridge = TaskBrowserBridge(source: source, isActive: () => true);
    addTearDown(() {
      bridge.invalidate();
      source.dispose();
    });
    final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
    Future<Object?> invoke(String entry) async => copyStructuredBridgeData(
      await (runtime.executeLib(_library, entry) as Future<Object?>),
    );
    for (final name in ['select', 'clear', 'create', 'session', 'open']) {
      expect(await invoke(name), [true, null]);
    }
    source.entries = true;
    expect(
      copyStructuredBridgeData(runtime.executeLib(_library, 'nested')),
      'nested title',
    );
    expect(source.calls, [
      'select:task',
      'select:null',
      'create:title',
      'session:opaque',
      'open:session',
    ]);
    source.failure = StateError('private native diagnostic');
    for (final name in ['select', 'clear', 'create', 'session', 'open']) {
      expect(await invoke(name), [
        false,
        'Task Browser action could not be completed.',
      ]);
    }
    source.failure = null;
    source.pending = Completer<void>();
    final pending = invoke('create');
    bridge.invalidate();
    source.pending!.complete();
    expect(await pending, [
      false,
      'Task Browser action could not be completed.',
    ]);
    final count = source.calls.length;
    expect(await invoke('create'), [
      false,
      'Task Browser action could not be completed.',
    ]);
    expect(source.calls, hasLength(count));
  });

  test(
    'generation retirement is permanent before and after action settlement',
    () async {
      final source = _Source()..pending = Completer<void>();
      var active = true;
      var disposals = 0;
      final bridge = TaskBrowserBridge(
        source: source,
        isActive: () => active,
        onDispose: () {
          disposals++;
          source.dispose();
        },
      );
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      Future<Object?> invoke() async => copyStructuredBridgeData(
        await (runtime.executeLib(_library, 'create') as Future<Object?>),
      );
      final pending = invoke();
      active = false;
      source.pending!.completeError(StateError('late native failure'));
      expect((await pending as List).first, isFalse);
      expect((await invoke() as List).first, isFalse);
      expect(disposals, 1);
      active = true;
      expect((await invoke() as List).first, isFalse);
      expect(source.calls, ['create:title']);
      bridge.invalidate();
      expect(disposals, 1);
    },
  );

  for (final entry in ['session', 'open']) {
    for (final outcome in ['success', 'retired', 'failure']) {
      test(
        '$entry settles $outcome after navigation disposes its view',
        () async {
          final source = _Source()..pending = Completer<void>();
          var active = true;
          var disposals = 0;
          var failures = 0;
          final bridge = TaskBrowserBridge(
            source: source,
            isActive: () => active,
            onDispose: () {
              disposals++;
              source.dispose();
            },
          )..onFailure = () => failures++;
          final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
          Future<Object?> invoke() async => copyStructuredBridgeData(
            await (runtime.executeLib(_library, entry) as Future<Object?>),
          );
          final pending = invoke();
          bridge.invalidate();
          expect(disposals, 1);
          if (outcome == 'retired') active = false;
          if (outcome == 'failure') {
            source.pending!.completeError(
              StateError('private navigation failure'),
            );
          } else {
            source.pending!.complete();
          }
          expect(
            await pending,
            outcome == 'success'
                ? [true, null]
                : [false, 'Task Browser action could not be completed.'],
          );
          expect(failures, 0);
          expect(await invoke(), [
            false,
            'Task Browser action could not be completed.',
          ]);
          expect(source.calls, hasLength(1));
          bridge.invalidate();
          expect(disposals, 1);
        },
      );
    }
  }

  testWidgets(
    'subscriptions coalesce and cancelled queued callbacks stay cancelled',
    (tester) async {
      final source = _Source();
      final bridge = TaskBrowserBridge(source: source, isActive: () => true);
      addTearDown(() {
        bridge.invalidate();
        source.dispose();
      });
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      Object? invoke(String entry) =>
          copyStructuredBridgeData(runtime.executeLib(_library, entry));
      expect(invoke('read'), {
        'title': 'safe',
        'nested': [1, null],
      });
      invoke('subscribe');
      invoke('subscribe');
      source.notifyListeners();
      source.notifyListeners();
      await tester.pump();
      expect(invoke('count'), 1);
      source.notifyListeners();
      invoke('unsubscribe');
      invoke('subscribe');
      await tester.pump();
      expect(invoke('count'), 1);
      source.notifyListeners();
      await tester.pump();
      expect(invoke('count'), 2);
      source.notifyListeners();
      bridge.invalidate();
      await tester.pump();
      expect(invoke('count'), 2);
      expect(source.listening, isFalse);
    },
  );

  testWidgets(
    'execution status is read-only, frame-coalesced, and revoked with the view',
    (tester) async {
      final counts = {
        'preparing': 0,
        'running': 1,
        'waiting': 0,
        'terminal': 0,
        'completed': 0,
        'cancelled': 0,
        'failed': 0,
      };
      final session = <String, Object?>{'executionStatus': 'running'};
      final source = _Source()
        ..snapshot = {
          'tasks': [
            {'executionCounts': counts},
          ],
          'selectedTask': {
            'sessions': [session],
          },
        };
      final bridge = TaskBrowserBridge(source: source, isActive: () => true);
      addTearDown(() {
        bridge.invalidate();
        source.dispose();
      });
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      Object? invoke(String entry) =>
          copyStructuredBridgeData(runtime.executeLib(_library, entry));
      invoke('subscribe');
      expect(invoke('executionStatus'), 'running');
      session['executionStatus'] = 'waitingForApproval';
      counts['running'] = 0;
      counts['waiting'] = 1;
      for (var i = 0; i < 20; i++) {
        source.notifyListeners();
      }
      expect(invoke('count'), 0);
      await tester.pump();
      expect(invoke('count'), 1);
      expect(invoke('executionStatus'), 'waitingForApproval');
      expect(invoke('read'), source.snapshot);
      expect(source.calls, isEmpty);
      bridge.retainPresentation();
      session['executionStatus'] = 'completed';
      counts['waiting'] = 0;
      counts['terminal'] = 1;
      counts['completed'] = 1;
      source.notifyListeners();
      await tester.pump();
      expect(invoke('active'), false);
      expect(invoke('count'), 1);
      expect(invoke('executionStatus'), 'waitingForApproval');
      expect(source.listening, isFalse);
      expect(source.calls, isEmpty);
    },
  );

  testWidgets(
    'listener failure revokes the bridge and reports view failure once',
    (tester) async {
      final source = _Source();
      final bridge = TaskBrowserBridge(source: source, isActive: () => true);
      addTearDown(() {
        bridge.invalidate();
        source.dispose();
      });
      var failures = 0;
      bridge.onFailure = () => failures++;
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      runtime.executeLib(_library, 'subscribeFailing');
      source.notifyListeners();
      await tester.pump();
      expect(failures, 1);
      expect(source.listening, isFalse);
      source.notifyListeners();
      await tester.pump();
      expect(failures, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exit retains immutable display but revokes actions and observation',
    (tester) async {
      final source = _Source();
      final bridge = TaskBrowserBridge(
        source: source,
        isActive: () => true,
        onDispose: source.dispose,
      );
      final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
      expect(runtime.executeLib(_library, 'active'), true);
      runtime.executeLib(_library, 'subscribe');
      bridge.retainPresentation();
      expect(runtime.executeLib(_library, 'active'), false);
      expect(copyStructuredBridgeData(runtime.executeLib(_library, 'read')), {
        'title': 'safe',
        'nested': [1, null],
      });
      expect(
        copyStructuredBridgeData(
          await (runtime.executeLib(_library, 'create') as Future<Object?>),
        ),
        [false, 'Task Browser action could not be completed.'],
      );
      expect(source.calls, isEmpty);
      bridge.invalidate();
      expect(runtime.executeLib(_library, 'active'), false);
    },
  );
}

class _Source extends ChangeNotifier implements TaskBrowserSource {
  bool get listening => hasListeners;
  bool entries = false;
  final List<String> calls = [];
  Object? failure;
  Completer<void>? pending;
  Map<String, Object?>? snapshot;

  @override
  Map<String, Object?> read() =>
      snapshot ??
      {
        if (entries)
          'entries': [
            {'title': 'nested title'},
          ],
        'title': 'safe',
        'nested': [1, null],
      };
  Future<void> _act(String value) {
    calls.add(value);
    if (failure case final error?) throw error;
    return pending?.future ?? Future<void>.value();
  }

  @override
  Future<void> selectTask(String? taskId) => _act('select:$taskId');
  @override
  Future<void> createTask(String title) => _act('create:$title');
  @override
  Future<void> createSession(String optionHandle) =>
      _act('session:$optionHandle');
  @override
  Future<void> openSession(String sessionId) => _act('open:$sessionId');
}
