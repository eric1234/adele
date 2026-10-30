import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_content_inspection_bridge.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:inspection_probe/main.dart';

void main() {
  late Program program;
  late Directory temporary;
  late File artifact;
  late _Context context;
  late SessionContentInspectionBridge bridge;
  late Runtime runtime;
  var active = true;
  var failLiveness = false;
  var invalidations = 0;
  var failures = 0;

  setUpAll(() async {
    program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const SessionContentInspectionDeclarations())
              ..addPlugin(const OwningBackendDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'inspection_probe': {'main.dart': _probe},
              'adele_contract': {
                'adele_contract.dart': evalContractSupportSource,
              },
              'adele_ui': {
                for (final file in [
                  'session_content_inspection_bridge.dart',
                  'owning_backend_bridge.dart',
                ])
                  file: File('../packages/ui/lib/$file').readAsStringSync(),
              },
            });
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('session-inspection-bridge-');
    artifact = File('${temporary.path}/frontend.evc');
    await artifact.writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() {
    active = true;
    failLiveness = false;
    invalidations = 0;
    failures = 0;
    context = _Context();
    bridge = SessionContentInspectionBridge(
      context: context,
      isActive: () {
        if (failLiveness) throw StateError('PRIVATE-LIVENESS-SECRET');
        return active;
      },
      onInvalidate: () => invalidations++,
    )..onFailure = () => failures++;
    runtime = Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
  });
  tearDown(() {
    bridge.invalidate();
    context.dispose();
  });

  Object? invoke(String entrypoint, [Runtime? target]) {
    final result = (target ?? runtime).executeLib(_library, entrypoint);
    return result is $Value ? result.$reified : result;
  }

  test('compiled reads carry only frozen factual identity strings', () {
    expect(invoke('inspect'), {
      'sessionId': 'session',
      'taskId': 'task',
      'strategyId': 'test.strategy',
      'contentKind': 'test.content',
      'occurrenceId': 'occurrence-1',
    });
    expect(invoke('hasAuthority'), false);
    expect(context.observed, isTrue);
  });

  test('interpreted code cannot mutate the captured identity map', () {
    expect(() => invoke('mutate'), throwsA(anything));
    runtime = Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
    expect((invoke('inspect') as Map)['occurrenceId'], 'occurrence-1');
  });

  test('unrelated context notifications preserve the frozen snapshot', () {
    context.signalChange();
    expect(invalidations, 0);
    expect(failures, 0);
    expect((invoke('inspect') as Map)['sessionId'], 'session');
  });

  for (final mode in [
    'context',
    'presenter',
    'invalidate',
    'liveness failure',
    'context failure',
  ]) {
    test('$mode permanently revokes reads with bounded failure', () {
      switch (mode) {
        case 'context':
          context.retire();
        case 'presenter':
          active = false;
        case 'invalidate':
          bridge.invalidate();
        case 'liveness failure':
          failLiveness = true;
        case 'context failure':
          context.failLiveness = true;
      }
      expect(
        () => invoke('inspect'),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains(
                  'Session content Inspection is unavailable.',
                ) &&
                !error.toString().contains('PRIVATE-LIVENESS-SECRET'),
          ),
        ),
      );
      expect(invalidations, 1);
      expect(failures, 1);
      expect(context.observed, isFalse);
      active = true;
      failLiveness = false;
      context
        ..active = true
        ..failLiveness = false;
      runtime = Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
      expect(() => invoke('inspect'), throwsA(anything));
      expect(invalidations, 1);
      expect(failures, 1);
    });
  }

  test(
    'context retirement synchronously revokes before failure notification',
    () {
      final order = <String>[];
      final captured = SessionContentInspectionBridge(
        context: context,
        isActive: () => true,
        onInvalidate: () => order.add('backend'),
      )..onFailure = () => order.add('presentation');
      addTearDown(captured.invalidate);
      context.retire();
      expect(order, ['backend', 'presentation']);
      expect(invalidations, 1);
      expect(failures, 1);
      expect(context.observed, isFalse);
    },
  );

  test('same occurrence in a fresh context cannot revive an old bridge', () {
    context.retire();
    final replacement = _Context();
    final captured = SessionContentInspectionBridge(
      context: replacement,
      isActive: () => true,
    );
    addTearDown(() {
      captured.invalidate();
      replacement.dispose();
    });
    final newRuntime = Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(captured);
    expect((invoke('inspect', newRuntime) as Map)['sessionId'], 'session');
    expect(() => invoke('inspect'), throwsA(anything));
  });

  test(
    'optional backend absence preserves facts without granting a route',
    () async {
      final backend = OwningBackendBridge(
        channels: const {},
        validateBinding: bridge.validate,
      );
      addTearDown(backend.invalidate);
      await expectLater(
        backend.request('test.retrieval', 'read', {}),
        throwsStateError,
      );
      expect((invoke('inspect') as Map)['contentKind'], 'test.content');
      expect(invalidations, 0);
    },
  );

  test('declared retrieval route grants no undeclared service', () async {
    final channel = _Channel();
    final backend = OwningBackendBridge(
      channels: {'test.retrieval': channel},
      validateBinding: bridge.validate,
    );
    addTearDown(backend.invalidate);
    await expectLater(
      backend.request('test.undeclared', 'read', {}),
      throwsStateError,
    );
    expect(channel.requests, 0);
    expect((invoke('inspect') as Map)['contentKind'], 'test.content');
    channel.events.close().ignore();
  });

  test(
    'context retirement cancels observation and fences admitted results',
    () async {
      final channel = _Channel();
      late final OwningBackendBridge backend;
      final captured = SessionContentInspectionBridge(
        context: context,
        isActive: () => true,
        onInvalidate: () => backend.invalidate(),
      );
      backend = OwningBackendBridge(
        channels: {'test.retrieval': channel},
        validateBinding: captured.validate,
      );
      addTearDown(captured.invalidate);
      final seen = <Object?>[];
      final done = Completer<void>();
      backend
          .stream('test.retrieval', 'watch', {})
          .listen(seen.add, onDone: done.complete);
      final pending = backend.request('test.retrieval', 'read', {});
      final rejected = expectLater(pending, throwsStateError);
      expect(channel.requests, 1);
      expect(channel.cancels, 0);
      context.retire();
      expect(channel.cancels, 1);
      channel.events.add({'text': 'late stream result'});
      channel.read.complete({'text': 'late unary result'});
      await rejected;
      await done.future;
      expect(seen, isEmpty);
      await expectLater(
        backend.request('test.retrieval', 'read', {}),
        throwsStateError,
      );
      expect(channel.requests, 1);
      await channel.events.close();
    },
  );

  for (final retirement in ['context', 'presenter', 'frontend']) {
    testWidgets('$retirement retirement fences a late interpreted widget', (
      tester,
    ) async {
      final frontend = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      addTearDown(frontend.invalidate);
      final channel = _Channel();
      late final SessionContentInspectionBridge facts;
      await tester.pumpWidget(
        MaterialApp(
          home: frontend.createPresentation(
            library: _library,
            entrypoint: 'buildDelayedView',
            createBridge: () {
              late final OwningBackendBridge backend;
              facts = SessionContentInspectionBridge(
                context: context,
                isActive: () => active,
                onInvalidate: () => backend.invalidate(),
              );
              backend = OwningBackendBridge(
                channels: {'test.retrieval': channel},
                validateBinding: facts.validate,
              );
              return PreparedFrontendBridges([facts, backend]);
            },
          ),
        ),
      );
      expect(channel.requests, 1);
      switch (retirement) {
        case 'context':
          context.retire();
        case 'presenter':
          active = false;
          facts.invalidate();
        case 'frontend':
          frontend.invalidate();
      }
      channel.read.complete({'text': 'late private result'});
      await tester.pump();
      await tester.pump();
      expect(find.text('late interpreted widget'), findsNothing);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      channel.events.close().ignore();
    });
  }

  for (final mode in ['absent', 'failed']) {
    testWidgets('$mode retrieval keeps facts safely displayable', (
      tester,
    ) async {
      final frontend = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      addTearDown(frontend.invalidate);
      final channel = _Channel();
      await tester.pumpWidget(
        MaterialApp(
          home: frontend.createPresentation(
            library: _library,
            entrypoint: 'buildAvailableFacts',
            createBridge: () {
              late final OwningBackendBridge backend;
              final facts = SessionContentInspectionBridge(
                context: context,
                isActive: () => active,
                onInvalidate: () => backend.invalidate(),
              );
              backend = OwningBackendBridge(
                channels: mode == 'absent'
                    ? const {}
                    : {'test.retrieval': channel},
                validateBinding: facts.validate,
              );
              return PreparedFrontendBridges([facts, backend]);
            },
          ),
        ),
      );
      if (mode == 'failed') {
        expect(channel.requests, 1);
        channel.read.completeError(StateError('PRIVATE-BACKEND-SECRET'));
      }
      await tester.pump();
      await tester.pump();
      expect(find.text('occurrence-1:unavailable'), findsOneWidget);
      expect(find.textContaining('PRIVATE-BACKEND-SECRET'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      channel.events.close().ignore();
    });
  }
}

final class _Context extends ChangeNotifier
    implements SessionContentInspectionContext {
  @override
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.strategy'),
  );
  @override
  final kind = SessionContentKind('test.content');
  @override
  final occurrenceId = SessionContentOccurrenceId('occurrence-1');
  bool active = true;
  bool failLiveness = false;
  bool get observed => hasListeners;

  void signalChange() => notifyListeners();

  @override
  bool get isActive {
    if (failLiveness) throw StateError('PRIVATE-LIVENESS-SECRET');
    return active;
  }

  void retire() {
    active = false;
    notifyListeners();
  }
}

final class _Channel implements AdeleStreamChannel {
  _Channel() {
    events = StreamController<Object?>(
      onCancel: () {
        cancels++;
      },
    );
  }

  final read = Completer<Object?>();
  late final StreamController<Object?> events;
  var requests = 0;
  var cancels = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    requests++;
    return read.future;
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      events.stream;
}

const _probe = r'''
import 'package:adele_ui/session_content_inspection_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:flutter/material.dart';

Map<String, dynamic> inspect() => readSessionContentInspectionContext();
void mutate() {
  readSessionContentInspectionContext()['occurrenceId'] = 'changed';
}
bool hasAuthority() {
  final Map<String, dynamic> facts = readSessionContentInspectionContext();
  return facts.containsKey('session') || facts.containsKey('runId') ||
      facts.containsKey('environment') || facts.containsKey('channel') ||
      facts.containsKey('approval') || facts.containsKey('startRun') ||
      facts.containsKey('console') || facts.containsKey('capabilities');
}
Future<Widget> buildDelayedView() async {
  final facts = readSessionContentInspectionContext();
  await settleOwningBackendOperation(
    requestOwningBackend('test.retrieval', 'read', facts),
  );
  return const Text('late interpreted widget');
}
Future<Widget> buildAvailableFacts() async {
  final facts = readSessionContentInspectionContext();
  final result = await settleOwningBackendOperation(
    requestOwningBackend('test.retrieval', 'read', facts),
  );
  final status = result[0] == true ? 'available' : 'unavailable';
  return Text(facts['occurrenceId'] + ':' + status);
}
''';
