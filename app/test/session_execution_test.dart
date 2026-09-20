import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/session_execution_source.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart' show $Value;
import 'package:dart_eval/stdlib/core.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

final _strategyId = OrchestrationStrategyId('dev.adele.test.execution');
final _providerId = ProviderId('dev.adele.test.execution-model');

Iterable<ExecutionEvent> _events(AgentRun run) =>
    run.journal.records.map((record) => record.event);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create();
    addTearDown(fixture.close);
  });

  testWidgets(
    'public EVC bridge emits exact view-local activity and revokes queued listeners',
    (tester) => tester.runAsync(() async {
      const library = 'package:execution_probe/main.dart';
      final compiler = Compiler()
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const SessionExecutionDeclarations())
        ..entrypoints.add(library);
      final program = compiler.compile({
        'execution_probe': {
          'main.dart': '''
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:flutter/widgets.dart';
int notifications = 0;
void changed() { notifications++; }
final void Function() listener = () => changed();
void subscribe() { subscribeSessionExecution(listener); }
void unsubscribe() { unsubscribeSessionExecution(listener); }
int count() => notifications;
String session() => currentSessionId();
Map<String, Object?> execution() => readSessionExecution();
Future<String> start() => startSessionRun();
Map<String, Object?> activity(String handle) => readSessionRunActivity(handle);
bool inspect(String handle) => inspectSessionActivity(handle);
Widget build(String handle) => buildSessionActivity(handle);
''',
        },
        'adele_ui': {
          'session_execution_bridge.dart': await File(
            '${Directory.current.parent.path}/packages/ui/lib/session_execution_bridge.dart',
          ).readAsString(),
        },
      });
      final controller = fixture.controller();
      var inspections = 0;
      var active = true;
      final source = SessionExecutionPresentationSource(
        controller: controller,
        extensions: fixture.runtime.extensions,
        isActive: () => active,
        inspect: (session, target) {
          expect(session, same(fixture.session));
          expect(target.sessionId, session.id);
          inspections++;
          return true;
        },
      );
      final bridge = SessionExecutionBridge(
        source: source,
        isActive: () => active,
      );
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
      addTearDown(bridge.invalidate);
      Object? execute(String name) => runtime.executeLib(library, name);
      expect(
        copyStructuredBridgeData(execute('session')),
        fixture.session.id.value,
      );
      final initial = copyStructuredBridgeData(execute('execution'))! as Map;
      expect(initial['canStart'], isTrue);
      expect(initial, isNot(contains('messages')));
      execute('subscribe');
      execute('subscribe');
      final handle =
          (await (execute('start') as $Future).$value as $String).$value;
      final advancing = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      call.propose(
        'view-owned',
        arguments: {
          'nested': [1, true, null],
        },
      );
      call.native();
      call.settle();
      await advancing;
      await tester.pumpAndSettle();
      final evidence =
          copyStructuredBridgeData(
                runtime.executeLib(library, 'activity', [$String(handle)]),
              )!
              as Map;
      final model = (evidence['models']! as List).single as Map;
      final outputs = model['outputs']! as List;
      expect(outputs.map((item) => (item as Map)['kind']), ['tool', 'native']);
      expect(evidence.toString(), isNot(contains('private-replay-data')));
      expect((outputs.last as Map)['compactText'], 'Safe native summary');
      final proposal = outputs.first as Map;
      expect(proposal['arguments'], {
        'nested': [1, true, null],
      });
      final tool = proposal['tool']! as Map;
      expect(tool['canonicalArguments'], proposal['arguments']);
      expect(tool['lifecycle'], 'approvalRequested');
      expect(tool['outcome'], isNull);
      expect((tool['effects']! as Map)['effects'], ['sourceMutation']);
      expect(
        (tool['changes']! as List).map((change) => (change as Map)['kind']),
        ['prepared', 'policyEvaluated', 'approvalRequested'],
      );
      expect(
        () => (proposal['arguments']! as Map).clear(),
        throwsUnsupportedError,
      );
      final activity = (outputs.first as Map)['handle']! as String;
      expect(
        copyStructuredBridgeData(
          runtime.executeLib(library, 'inspect', [$String(activity)]),
        ),
        isTrue,
      );
      expect(inspections, 1);
      final built =
          (runtime.executeLib(library, 'build', [$String(activity)]) as $Value)
                  .$reified
              as Widget;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: built)));
      await tester.pumpAndSettle();
      expect(find.text('Tool: test_effect'), findsOneWidget);
      final retainedAction = tester
          .widget<TextButton>(find.byType(TextButton))
          .onPressed!;
      final otherView = SessionExecutionPresentationSource(
        controller: controller,
        extensions: fixture.runtime.extensions,
        isActive: () => true,
        inspect: (_, _) => throw StateError('Foreign view authority'),
      );
      expect(() => otherView.readRunActivity(handle), throwsStateError);
      expect(otherView.inspectActivity(activity), isFalse);
      expect(
        source.inspectActivity(controller.currentRun!.run.id.value),
        isFalse,
      );
      final repeated = source.readRunActivity(handle);
      expect(((repeated['models']! as List).single as Map)['outputs'], outputs);

      execute('unsubscribe');
      final before = copyStructuredBridgeData(execute('count'));
      controller.refresh();
      await tester.pumpAndSettle();
      expect(copyStructuredBridgeData(execute('count')), before);
      execute('subscribe');
      controller.refresh();
      active = false;
      bridge.invalidate();
      await tester.pumpAndSettle();
      expect(copyStructuredBridgeData(execute('count')), before);
      expect(
        copyStructuredBridgeData(
          runtime.executeLib(library, 'inspect', [$String(activity)]),
        ),
        isFalse,
      );
      expect(source.readExecution, throwsStateError);
      expect(() => source.readRunActivity(handle), throwsStateError);
      expect(source.buildActivity(activity), isA<SizedBox>());
      retainedAction();
      expect(inspections, 1);
      expect(controller.currentRun!.run.state, RunState.waiting);
      expect(fixture.tool.executions, 0);
      otherView.invalidate();
      await tester.pumpWidget(const SizedBox.shrink());
    }),
  );

  testWidgets(
    'common approval UI preserves proposal order and single-use decisions',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = fixture.controller();
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Scaffold(
              body: SingleChildScrollView(
                child: RunExecutionStatus(
                  pendingApproval: controller.pendingApproval,
                  enabled: !controller.isAdvancing && !controller.isClosed,
                  isAdvancing: controller.isAdvancing,
                  failureMessage: controller.failureMessage,
                  unavailableReason: controller.unavailableReason,
                  onDecision: (approval, approved) =>
                      controller.resolveApproval(approval, approved: approved),
                ),
              ),
            ),
          ),
        ),
      );
      final firstId = await controller.startRun();
      final starting = controller.activeRunFuture!;
      await expectLater(controller.startRun(), throwsStateError);
      final call = await fixture.model.callAt(0);
      call.propose('first');
      call.propose('second');
      call.settle();
      await starting;
      await tester.pumpAndSettle();
      final run = controller.currentRun!.run;
      final first = controller.pendingApproval!;
      expect(run.id, firstId);
      expect(run.state, RunState.waiting);
      expect(fixture.tool.executions, 0);
      expect(fixture.model.calls, hasLength(1));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      final allow = find.widgetWithText(FilledButton, 'Allow once');
      final retainedAllow = tester.widget<FilledButton>(allow).onPressed!;
      await tester.ensureVisible(allow);
      await tester.tap(find.widgetWithText(FilledButton, 'Allow once'));
      final allowing = controller.activeRunFuture!;
      expect(controller.resolveApproval(first, approved: true), isFalse);
      await allowing;
      await tester.pumpAndSettle();
      final second = controller.pendingApproval!;
      expect(second, isNot(same(first)));
      expect(second.canonicalArgumentsJson, first.canonicalArgumentsJson);
      expect(fixture.tool.executions, 1);
      expect(fixture.model.calls, hasLength(1));
      expect(controller.resolveApproval(first, approved: false), isFalse);
      retainedAllow();
      expect(controller.pendingApproval, same(second));
      expect(controller.activeRunFuture, isNull);
      await tester.ensureVisible(find.text('Deny'));
      await tester.tap(find.text('Deny'));
      final denying = controller.activeRunFuture!;
      final continuation = await fixture.model.callAt(1);
      expect(
        continuation.outcomes.map((item) => (item['callId'], item['status'])),
        [('first', 'success'), ('second', 'rejected')],
      );
      continuation.settle();
      await denying;
      await tester.pumpAndSettle();
      expect(controller.currentRun!.run, same(run));
      expect(run.state, RunState.completed);
      expect(controller.pendingApproval, isNull);
      expect(controller.failure, isNull);
      expect(fixture.tool.executions, 1);
      expect(_events(run).whereType<RunInterrupted>(), hasLength(2));
      expect(_events(run).whereType<ToolExecutionStarted>(), hasLength(1));
      final activity = controller.activityForRun(firstId)!;
      expect(activity.tools.map((item) => item.outcome!.disposition), [
        ToolOutcomeDisposition.success,
        ToolOutcomeDisposition.userRejected,
      ]);
      expect(
        () => controller.activitySnapshots.clear(),
        throwsUnsupportedError,
      );

      final secondId = await controller.startRun();
      final next = controller.activeRunFuture!;
      (await fixture.model.callAt(2)).settle();
      await next;
      expect(secondId, isNot(firstId));
      expect(controller.activityForRun(firstId), same(activity));
      expect(controller.activitySnapshots.map((item) => item.runId), [
        firstId,
        secondId,
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }),
  );

  testWidgets(
    'progress capture coalesces per frame and a queued capture cannot publish after close',
    (tester) => tester.runAsync(() async {
      var notifications = 0;
      var activityNotifications = 0;
      final controller = fixture.controller(onChanged: () => notifications++);
      controller.activityChanges.addListener(() => activityNotifications++);
      fixture.tool.gate = Completer<void>();
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      call.propose('progress');
      call.settle();
      await starting;
      expect(
        controller.resolveApproval(controller.pendingApproval!, approved: true),
        isTrue,
      );
      await fixture.tool.entered.future;
      await tester.pumpAndSettle();
      final run = controller.currentRun!.run;
      final before = controller.activitySnapshots.single;
      final tool = before.tools.single.id;
      final beforeNotifications = notifications;
      final beforeActivity = activityNotifications;
      for (var i = 0; i < 1000; i++) {
        run.record(
          ToolProgressObserved(
            invocationId: tool,
            progress: ToolProgress(content: 'chunk $i'),
          ),
        );
        await Future<void>.value();
      }
      expect(controller.activitySnapshots.single, same(before));
      expect(notifications, beforeNotifications);
      expect(activityNotifications, beforeActivity);
      await tester.pump();
      final captured = controller.activitySnapshots.single;
      expect(captured.sequence, before.sequence + 1000);
      expect(
        captured.tools.single.changes.where(
          (change) => change.kind == ToolActivityKind.progress,
        ),
        hasLength(1000),
      );
      expect(notifications, beforeNotifications + 1);
      expect(activityNotifications, beforeActivity + 1);
      expect(controller.activityForRun(run.id), same(captured));
      await tester.pump();
      expect(activityNotifications, beforeActivity + 1);
      run.record(
        ToolProgressObserved(
          invocationId: tool,
          progress: ToolProgress(content: 'late'),
        ),
      );
      await Future<void>.value();
      final closing = controller.close();
      fixture.tool.gate!.complete();
      (await fixture.model.callAt(1)).settle();
      await closing;
      await tester.pumpAndSettle();
      expect(controller.activitySnapshots.single, same(captured));
      expect(notifications, beforeNotifications + 1);
      expect(activityNotifications, beforeActivity + 1);
      expect(controller.activityForRun(run.id), isNull);
      expect(run.state, RunState.completed);
      expect(tester.takeException(), isNull);
    }),
  );

  test('activity retains tool semantics on stable output handles', () async {
    final controller = fixture.controller();
    final source = SessionExecutionPresentationSource(
      controller: controller,
      extensions: fixture.runtime.extensions,
      isActive: () => true,
      inspect: (_, _) => true,
    );
    addTearDown(source.invalidate);
    final handle = await source.startRun();
    final starting = controller.activeRunFuture!;
    final call = await fixture.model.callAt(0);
    final arguments = <String, Object?>{
      'nested': [1, true, null],
    };
    call.propose('unknown', alias: 'missing_tool', arguments: arguments);
    call.propose('first', arguments: arguments);
    call.propose('second', arguments: arguments);
    call.settle();
    await starting;

    List<Map<String, Object?>> outputs() {
      final activity = source.readRunActivity(handle);
      final model = (activity['models']! as List).first as Map;
      return (model['outputs']! as List).cast<Map<String, Object?>>();
    }

    final waiting = outputs();
    expect(waiting[0]['tool'], isNull);
    expect((waiting[0]['rejection']! as Map)['kind'], 'unknownAlias');
    expect((waiting[0]['rejection']! as Map)['message'], isNotEmpty);
    expect(waiting[0]['arguments'], arguments);
    final first = waiting[1]['tool']! as Map;
    expect(first['toolId'], 'dev.adele.test.effect');
    expect(first['canonicalArguments'], arguments);
    expect(first['lifecycle'], 'approvalRequested');
    expect(first['outcome'], isNull);
    final changes = (first['changes']! as List).cast<Map<String, Object?>>();
    expect(changes.map((change) => change['kind']), [
      'prepared',
      'policyEvaluated',
      'approvalRequested',
    ]);
    expect(changes[1]['policyDecision'], 'ask');
    expect((first['effects']! as Map)['effects'], ['sourceMutation']);
    expect(waiting[2]['tool'], isNull);
    expect(waiting[2]['rejection'], isNull);
    expect(() => first['lifecycle'] = 'completed', throwsUnsupportedError);
    expect(() => changes.first['kind'] = 'completed', throwsUnsupportedError);

    expect(
      controller.resolveApproval(controller.pendingApproval!, approved: true),
      isTrue,
    );
    await controller.activeRunFuture!;
    final advanced = outputs();
    expect(
      advanced.map((output) => output['handle']),
      waiting.map((output) => output['handle']),
    );
    final completed = advanced[1]['tool']! as Map;
    expect(completed['invocationId'], first['invocationId']);
    expect(completed['lifecycle'], 'completed');
    expect(completed['outcome'], {
      'disposition': 'success',
      'failureKind': null,
      'effectCertainty': 'knownOccurred',
      'modelContent': 'Executed fixture effect',
      'hostData': {
        'nested': [1, true, null],
      },
    });
    final completedChanges = (completed['changes']! as List)
        .cast<Map<String, Object?>>();
    expect(completedChanges.map((change) => change['kind']), [
      'prepared',
      'policyEvaluated',
      'approvalRequested',
      'approvalResolved',
      'executionStarted',
      'progress',
      'completed',
    ]);
    expect(completedChanges[3]['approved'], isTrue);
    expect(completedChanges[5]['progress'], {
      'kind': 'stdout',
      'content': 'fixture progress',
    });
    expect(completedChanges.last['outcome'], completed['outcome']);
    expect((advanced[2]['tool']! as Map)['lifecycle'], 'approvalRequested');
    expect(first['lifecycle'], 'approvalRequested');
    expect(first['outcome'], isNull);
    expect(waiting[2]['tool'], isNull);
    expect(advanced.toString(), isNot(contains('private diagnostic')));
    expect(
      () =>
          (((completed['outcome']! as Map)['hostData']! as Map)['nested']!
                  as List)
              .clear(),
      throwsUnsupportedError,
    );

    expect(
      controller.resolveApproval(controller.pendingApproval!, approved: false),
      isTrue,
    );
    final denying = controller.activeRunFuture!;
    (await fixture.model.callAt(1)).settle();
    await denying;
    final terminal = outputs();
    final rejected = terminal[2]['tool']! as Map;
    expect(rejected['lifecycle'], 'completed');
    expect((rejected['outcome']! as Map)['disposition'], 'userRejected');
    expect(
      (rejected['outcome']! as Map)['effectCertainty'],
      'knownNotOccurred',
    );
    expect(
      terminal.map((output) => output['handle']),
      waiting.map((output) => output['handle']),
    );
    expect(fixture.tool.executions, 1);
  });

  for (final authority in ['summary', 'target']) {
    test(
      'unsafe authority $authority cannot be allowed but can be denied',
      () async {
        if (authority == 'summary') {
          fixture.tool.summary = 'Apply to file\u202E.dart';
        } else {
          fixture.tool.targets = [
            EffectTarget(
              uri: Uri.parse('adele-environment:/source/file%E2%80%AE.dart'),
            ),
          ];
        }
        final controller = fixture.controller();
        await controller.startRun();
        final starting = controller.activeRunFuture!;
        final call = await fixture.model.callAt(0);
        call.propose('unsafe');
        call.settle();
        await starting;
        final approval = controller.pendingApproval!;
        expect(approval.hasUnsafeAuthorityText, isTrue);
        if (authority == 'summary') {
          expect(approval.summary, contains(r'\u202E'));
        }
        final journal = controller.currentRun!.run.journal.records;
        expect(controller.resolveApproval(approval, approved: true), isFalse);
        expect(controller.activeRunFuture, isNull);
        expect(controller.currentRun!.run.journal.records, journal);
        expect(fixture.tool.executions, 0);
        expect(controller.resolveApproval(approval, approved: false), isTrue);
        final resuming = controller.activeRunFuture!;
        final continuation = await fixture.model.callAt(1);
        expect(continuation.outcomes.single['status'], 'rejected');
        continuation.settle();
        await resuming;
        expect(fixture.tool.executions, 0);
        expect(controller.failure, isNull);
      },
    );
  }

  test(
    'approval keeps the exact retired tool and never executes its replacement',
    () async {
      final controller = fixture.controller();
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      call.propose('retired');
      call.settle();
      await starting;
      await fixture.tools.close();
      final replacement = _Tool();
      fixture.tools = fixture.registerTool(replacement);
      expect(
        controller.resolveApproval(controller.pendingApproval!, approved: true),
        isTrue,
      );
      final resuming = controller.activeRunFuture!;
      final continuation = await fixture.model.callAt(1);
      expect(continuation.outcomes.single['status'], 'failed');
      continuation.settle();
      await resuming;
      expect(fixture.tool.executions, 0);
      expect(replacement.executions, 0);
      final result = _events(
        controller.currentRun!.run,
      ).whereType<ToolInvocationCompleted>().single.outcome;
      expect(result.failureKind, ToolFailureKind.staleBinding);
      expect(result.effectCertainty, EffectCertainty.knownNotOccurred);
    },
  );

  test(
    'activity observer failures cannot fail execution or skip settlement',
    () async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final controller = SessionExecutionController(
        runtime: fixture.runtime,
        session: fixture.session,
        providerId: _providerId,
        model: 'fixture-model',
        runIds: fixture.ids,
        onActivityChanged: () => throw StateError('Fixture observer failure'),
      );
      fixture.controllers.add(controller);
      await controller.startRun();
      final advancing = controller.activeRunFuture!;
      (await fixture.model.callAt(0)).settle();
      await advancing;
      expect(controller.currentRun!.run.state, RunState.completed);
      expect(controller.failure, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.activitySnapshots.single.state, RunState.completed);
      expect(errors, isNotEmpty);
      expect(
        errors.every(
          (error) =>
              error.exception.toString().contains('Fixture observer failure'),
        ),
        isTrue,
      );
    },
  );

  test(
    'pinned strategy retirement rejects replacement and allocates no Run',
    () async {
      final controller = fixture.controller();
      await fixture.strategy.close();
      fixture.strategy = fixture.registerStrategy();
      expect(controller.canStart, isFalse);
      expect(controller.unavailableReason, contains('strategy'));
      await expectLater(controller.startRun(), throwsStateError);
      expect(fixture.ids.values, isEmpty);
      expect(fixture.executions, isEmpty);
      expect(fixture.model.calls, isEmpty);
    },
  );

  test(
    'accepted preparation retains the retired model; only a fresh Run binds replacement',
    () async {
      fixture.tool.materializeGate = Completer<void>();
      final controller = fixture.controller();
      await controller.startRun();
      final preparing = controller.activeRunFuture!;
      await fixture.tool.materializing.future;
      await fixture.modelRegistration.close();
      final replacement = _ModelChannel();
      fixture.modelRegistration = fixture.registerModel(replacement);
      fixture.tool.materializeGate!.complete();
      await preparing;
      expect(controller.failure, isNotNull);
      expect(controller.isRunning, isFalse);
      expect(fixture.model.calls, isEmpty);
      expect(replacement.calls, isEmpty);
      await controller.startRun();
      final retry = controller.activeRunFuture!;
      (await replacement.callAt(0)).settle();
      await retry;
      expect(controller.failure, isNull);
      expect(controller.currentRun!.run.state, RunState.completed);
      expect(fixture.ids.values, hasLength(2));
    },
  );

  test(
    'selected model retirement does not fall back to another provider',
    () async {
      final controller = fixture.controller();
      await fixture.modelRegistration.close();
      final other = _ModelChannel();
      fixture.modelRegistration = fixture.registerModel(
        other,
        providerId: ProviderId('dev.adele.test.other-model'),
      );
      expect(controller.canStart, isFalse);
      await expectLater(controller.startRun(), throwsStateError);
      expect(fixture.ids.values, isEmpty);
      expect(other.calls, isEmpty);
    },
  );

  test(
    'Allow once does not authorize the same arguments in a later model turn',
    () async {
      final controller = fixture.controller();
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final first = await fixture.model.callAt(0);
      first.propose('first-turn');
      first.settle();
      await starting;
      final original = controller.pendingApproval!;
      expect(controller.resolveApproval(original, approved: true), isTrue);
      final allowing = controller.activeRunFuture!;
      final second = await fixture.model.callAt(1);
      second.propose('second-turn');
      second.settle();
      await allowing;
      final repeated = controller.pendingApproval!;
      expect(repeated.canonicalArgumentsJson, original.canonicalArgumentsJson);
      expect(repeated, isNot(same(original)));
      expect(controller.resolveApproval(original, approved: true), isFalse);
      expect(fixture.tool.executions, 1);
      expect(controller.resolveApproval(repeated, approved: false), isTrue);
      final denying = controller.activeRunFuture!;
      final finalTurn = await fixture.model.callAt(2);
      expect(
        finalTurn.outcomes.map((item) => (item['callId'], item['status'])),
        [('first-turn', 'success'), ('second-turn', 'rejected')],
      );
      finalTurn.settle();
      await denying;
      expect(fixture.tool.executions, 1);
      expect(
        _events(controller.currentRun!.run).whereType<RunInterrupted>(),
        hasLength(2),
      );
    },
  );

  for (final failure in ['revision changed', 'Environment retired']) {
    test(
      'approval cannot override $failure while a real patch is pending',
      () async {
        final filesystem = const FilesystemToolsPlugin().activate(
          fixture.runtime.extensions,
        );
        addTearDown(filesystem.close);
        final controller = fixture.controller();
        await controller.startRun();
        final starting = controller.activeRunFuture!;
        final call = await fixture.model.callAt(0);
        final arguments = <String, Object?>{
          'relativePath': _EnvironmentChannel.sourcePath,
          'expectedRevision': fixture.environment.revision,
          'edits': [
            {'search': 'before', 'replace': 'after'},
          ],
        };
        call.propose(
          'guarded-patch',
          alias: 'apply_patch',
          arguments: arguments,
        );
        call.settle();
        await starting;
        final approval = controller.pendingApproval!;
        expect(jsonDecode(approval.canonicalArgumentsJson), arguments);
        final replacement = _EnvironmentChannel();
        if (failure == 'revision changed') {
          fixture.environment.text =
              '// External change\n${fixture.environment.text}';
          fixture.environment.revision = 'external-revision';
        } else {
          await fixture.environmentRegistration.close();
          fixture.environmentRegistration = fixture.registerEnvironment(
            replacement,
          );
        }
        final before = fixture.environment.text;
        expect(controller.resolveApproval(approval, approved: true), isTrue);
        final resuming = controller.activeRunFuture!;
        final continuation = await fixture.model.callAt(1);
        expect(continuation.outcomes.single['status'], 'failed');
        final events = _events(controller.currentRun!.run);
        final result = failure == 'revision changed'
            ? events.whereType<ToolExecutionCompleted>().single.outcome
            : events.whereType<ToolInvocationCompleted>().single.outcome;
        expect(
          result.failureKind,
          failure == 'revision changed'
              ? ToolFailureKind.domain
              : ToolFailureKind.staleBinding,
        );
        expect(result.effectCertainty, EffectCertainty.knownNotOccurred);
        if (failure == 'revision changed') {
          expect(result.hostData['code'], environmentRevisionConflictCode);
        } else {
          expect(
            _events(
              controller.currentRun!.run,
            ).whereType<ToolExecutionStarted>(),
            isEmpty,
          );
        }
        expect(fixture.environment.writes, isEmpty);
        expect(fixture.environment.text, before);
        expect(replacement.reads, isEmpty);
        expect(replacement.writes, isEmpty);
        continuation.settle();
        await resuming;
        expect(controller.currentRun!.run.state, RunState.completed);
        expect(controller.failure, isNull);
      },
    );
  }

  test(
    'safe tool identity permits exact control-bearing patch payload',
    () async {
      final filesystem = const FilesystemToolsPlugin().activate(
        fixture.runtime.extensions,
      );
      addTearDown(filesystem.close);
      const replacement =
          'line one\nline two\r\n\t\u0000\u0085\u202E\u200D\u{E0020}';
      final controller = fixture.controller();
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      final arguments = <String, Object?>{
        'relativePath': _EnvironmentChannel.sourcePath,
        'expectedRevision': fixture.environment.revision,
        'edits': [
          {'search': 'before', 'replace': replacement},
        ],
      };
      call.propose('payload', alias: 'apply_patch', arguments: arguments);
      call.settle();
      await starting;
      final approval = controller.pendingApproval!;
      expect(approval.hasUnsafeAuthorityText, isFalse);
      expect(jsonDecode(approval.canonicalArgumentsJson), arguments);
      expect(approval.canonicalArgumentsJson, contains(r'\u202E'));
      expect(controller.resolveApproval(approval, approved: true), isTrue);
      final resuming = controller.activeRunFuture!;
      final continuation = await fixture.model.callAt(1);
      expect(continuation.outcomes.single['status'], 'success');
      expect(
        fixture.environment.writes.single['replacementText'],
        _EnvironmentChannel.initialText.replaceFirst('before', replacement),
      );
      continuation.settle();
      await resuming;
      expect(controller.failure, isNull);
    },
  );

  test(
    'model failure settles and allows a fresh Run without strategy history',
    () async {
      final controller = fixture.controller();
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      (await fixture.model.callAt(0)).settle(fails: true);
      await starting;
      expect(controller.currentRun!.run.state, RunState.failed);
      expect(controller.failureMessage, contains('rateLimited'));
      expect(controller.canStart, isTrue);
      final failed = controller.currentRun!.run.id;
      await controller.startRun();
      final retry = controller.activeRunFuture!;
      final next = await fixture.model.callAt(1);
      expect(next.request['input'], isEmpty);
      next.settle();
      await retry;
      expect(controller.currentRun!.run.id, isNot(failed));
      expect(controller.currentRun!.run.state, RunState.completed);
      expect(controller.failure, isNull);
    },
  );

  for (final model in <String?>[null, ' \t ']) {
    test('missing model rejects work before Run allocation ($model)', () async {
      final controller = fixture.controller(model: model);
      expect(controller.unavailableReason, contains('no model'));
      await expectLater(controller.startRun(), throwsStateError);
      expect(fixture.ids.values, isEmpty);
      expect(fixture.model.calls, isEmpty);
    });
  }

  test(
    'close abandons waiting approval without resolution or notifications',
    () async {
      var notifications = 0;
      final controller = fixture.controller(onChanged: () => notifications++);
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      call.propose('abandoned');
      call.settle();
      await starting;
      final run = controller.currentRun!.run;
      final approval = controller.pendingApproval!;
      final journal = run.journal.records;
      final evidence = controller.activitySnapshots;
      final beforeClose = notifications;
      final closing = controller.close();
      expect(controller.close(), same(closing));
      expect(controller.resolveApproval(approval, approved: true), isFalse);
      expect(controller.resolveApproval(approval, approved: false), isFalse);
      await expectLater(controller.startRun(), throwsStateError);
      await closing;
      expect(run.state, RunState.waiting);
      final interruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      await expectLater(
        controller.currentRun!.resolveApproval(
          ToolApprovalResolution(
            interruptionId: interruption.id,
            toolInvocationId: interruption.toolInvocationId,
            approved: true,
          ),
        ),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(run.journal.records, journal);
      expect(controller.activitySnapshots, evidence);
      expect(controller.activityForRun(run.id), isNull);
      expect(notifications, beforeClose);
      expect(fixture.tool.executions, 0);
      expect(fixture.executions.single.closeCalls, 1);
    },
  );

  test(
    'close drains accepted effects and model settlement without late UI updates',
    () async {
      fixture.tool.gate = Completer<void>();
      var notifications = 0;
      final controller = fixture.controller(onChanged: () => notifications++);
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      call.propose('draining');
      call.settle();
      await starting;
      expect(
        controller.resolveApproval(controller.pendingApproval!, approved: true),
        isTrue,
      );
      final active = controller.activeRunFuture!;
      await fixture.tool.entered.future;
      final beforeClose = notifications;
      final evidence = controller.activitySnapshots;
      var closed = false;
      final closing = controller.close();
      final observed = closing.then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      fixture.tool.gate!.complete();
      final continuation = await fixture.model.callAt(1);
      expect(closed, isFalse);
      continuation.settle();
      await active;
      await observed;
      expect(controller.currentRun!.run.state, RunState.completed);
      expect(controller.activitySnapshots, evidence);
      expect(notifications, beforeClose);
      expect(fixture.tool.executions, 1);
      expect(fixture.executions.single.closeCalls, 1);
    },
  );

  test(
    'close drains late materialization and releases the execution once',
    () async {
      fixture.materialization = Completer<void>();
      fixture.executionCloseGate = Completer<void>();
      var notifications = 0;
      final controller = fixture.controller(onChanged: () => notifications++);
      await controller.startRun();
      final active = controller.activeRunFuture!;
      await fixture.materializing.future;
      final beforeClose = notifications;
      final closing = controller.close();
      expect(controller.close(), same(closing));
      expect(controller.currentRun, isNull);
      fixture.materialization!.complete();
      (await fixture.model.callAt(0)).settle();
      await fixture.executions.single.closing.future;
      var closed = false;
      final observed = closing.then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(fixture.executions.single.closeCalls, 1);
      fixture.executionCloseGate!.complete();
      await active;
      await observed;
      expect(fixture.executions.single.closeCalls, 1);
      expect(controller.currentRun, isNull);
      expect(controller.activitySnapshots, isEmpty);
      expect(notifications, beforeClose);
    },
  );

  test(
    'close drains an accepted effect only to the next approval, without resolving it',
    () async {
      fixture.tool.gate = Completer<void>();
      final controller = fixture.controller();
      await controller.startRun();
      final starting = controller.activeRunFuture!;
      final call = await fixture.model.callAt(0);
      call.propose('accepted');
      call.propose('late-pending');
      call.settle();
      await starting;
      final first = controller.pendingApproval!;
      expect(controller.resolveApproval(first, approved: true), isTrue);
      await fixture.tool.entered.future;
      final evidence = controller.activitySnapshots;
      final closing = controller.close();
      fixture.tool.gate!.complete();
      await closing;
      final run = controller.currentRun!.run;
      expect(run.state, RunState.waiting);
      expect(
        (run.interruptions.values.single as ToolApprovalInterruption)
            .invocation
            .proposal
            .providerCallId,
        'late-pending',
      );
      expect(_events(run).whereType<RunInterruptionResolved>(), hasLength(1));
      expect(_events(run).whereType<ToolExecutionStarted>(), hasLength(1));
      expect(controller.activitySnapshots, evidence);
      expect(controller.pendingApproval, same(first));
      expect(controller.resolveApproval(first, approved: true), isFalse);
      expect(fixture.tool.executions, 1);
      expect(fixture.model.calls, hasLength(1));
    },
  );

  for (final preparing in [true, false]) {
    for (final fails in [true, false]) {
      test(
        'close freezes presentation during ${preparing ? 'preparation' : 'streaming'} and drains ${fails ? 'failure' : 'success'}',
        () async {
          if (preparing) fixture.materialization = Completer<void>();
          var notifications = 0;
          final controller = fixture.controller(
            onChanged: () => notifications++,
          );
          await controller.startRun();
          final active = controller.activeRunFuture!;
          if (preparing) {
            await fixture.materializing.future;
          } else {
            await fixture.model.callAt(0);
          }
          final execution = controller.currentRun;
          final evidence = controller.activitySnapshots;
          final beforeClose = notifications;
          var closed = false;
          final closing = controller.close();
          final observed = closing.then((_) => closed = true);
          await expectLater(controller.startRun(), throwsStateError);
          fixture.materialization?.complete();
          final call = await fixture.model.callAt(0);
          expect(closed, isFalse);
          call.settle(fails: fails);
          await active;
          await observed;
          expect(controller.currentRun, same(execution));
          expect(controller.activitySnapshots, evidence);
          expect(notifications, beforeClose);
          expect(controller.failure, isNull);
          expect(controller.activeRunFuture, isNull);
          expect(
            fixture.executions.single.host.state,
            fails ? RunState.failed : RunState.completed,
          );
          expect(fixture.executions.single.closeCalls, 1);
        },
      );
    }
  }
}

final class _Fixture {
  final runtime = AdeleRuntime(
    ids: MonotonicProductIdSource(seed: 'execution'),
  );
  final ids = _RunIds();
  final model = _ModelChannel();
  final models = <_ModelChannel>[];
  final environment = _EnvironmentChannel();
  final tool = _Tool();
  final executions = <_Execution>[];
  final controllers = <SessionExecutionController>[];
  final materializing = Completer<void>();
  Completer<void>? materialization;
  Completer<void>? executionCloseGate;
  late ExtensionRegistration strategy;
  late ExtensionRegistration tools;
  late CapabilityRegistration modelRegistration;
  late CapabilityRegistration environmentRegistration;
  late Session session;

  static Future<_Fixture> create() async {
    final fixture = _Fixture();
    fixture.strategy = fixture.registerStrategy();
    fixture.tools = fixture.registerTool(fixture.tool);
    fixture.modelRegistration = fixture.registerModel(fixture.model);
    fixture.environmentRegistration = fixture.registerEnvironment(
      fixture.environment,
    );
    final project = fixture.runtime.lifecycle.createProject(
      Uri.parse('file:///execution-test/'),
    );
    final created = await fixture.runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Generic execution',
    );
    fixture.session = fixture.runtime.lifecycle.createSession(
      taskId: created.task.id,
      strategyId: _strategyId,
    );
    return fixture;
  }

  CapabilityRegistration registerModel(
    _ModelChannel channel, {
    ProviderId? providerId,
  }) {
    models.add(channel);
    return runtime.registry.register(
      provider: ProviderDescriptor(
        id: providerId ?? _providerId,
        capability: modelProviderCapability,
        pluginId: 'dev.adele.test.model',
        displayName: 'Test model',
        serviceId: modelProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: channel,
        serviceId: modelProviderServiceId,
        isAvailable: () => true,
      ),
    );
  }

  CapabilityRegistration registerEnvironment(_EnvironmentChannel channel) =>
      runtime.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('dev.adele.test.environment'),
          capability: environmentProviderCapability,
          pluginId: 'dev.adele.test.environment',
          displayName: 'Test environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );

  ExtensionRegistration registerStrategy() => runtime.extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId('dev.adele.test.execution.strategy'),
    value: OrchestrationStrategyContribution(
      strategyId: _strategyId,
      materialize: (context) async {
        if (!materializing.isCompleted) materializing.complete();
        await materialization?.future;
        final execution = _Execution(context.host, executionCloseGate);
        executions.add(execution);
        return execution;
      },
    ),
  );

  ExtensionRegistration registerTool(_Tool tool) => runtime.extensions.register(
    point: modelToolContributions,
    id: ExtensionId('dev.adele.test.execution.tools'),
    value: tool,
  );

  SessionExecutionController controller({
    String? model = 'fixture-model',
    VoidCallback? onChanged,
  }) {
    final controller = SessionExecutionController(
      runtime: runtime,
      session: session,
      strategy: runtime.lifecycle.resolveSessionStrategy(session.id),
      providerId: _providerId,
      model: model,
      runIds: ids,
      onChanged: onChanged,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> close() async {
    if (materialization case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    if (tool.gate case final gate? when !gate.isCompleted) gate.complete();
    if (tool.materializeGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    if (executionCloseGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    for (final model in models) {
      for (final call in model.calls) {
        unawaited(call.events.close());
      }
    }
    for (final controller in controllers) {
      await controller.close();
    }
    await tools.close();
    await strategy.close();
    await modelRegistration.close();
    await environmentRegistration.close();
    await runtime.close();
  }
}

// Only the public host facade is used. This test strategy has no Chat history,
// instructions, frontend, or plugin implementation dependency.
final class _Execution implements OrchestrationExecution {
  _Execution(this.host, this.closeGate);
  final OrchestrationExecutionHost host;
  final Completer<void>? closeGate;
  final closing = Completer<void>();
  final outcomes = <SemanticModelInputItem>[];
  late StrategyModelTurn turn;
  final proposals = <ProviderToolProposal>[];
  int closeCalls = 0;

  @override
  Future<void> start() async {
    host.start();
    await nextTurn();
  }

  Future<void> nextTurn() async {
    turn = await host.invokeModel(StrategyInferenceMaterial(input: outcomes));
    if (turn.failure case final failure?) {
      host.fail(failure);
      return;
    }
    proposals.addAll(
      turn.output.whereType<ModelToolProposalOutput>().map(
        (item) => item.proposal,
      ),
    );
    if (proposals.isEmpty) {
      host.complete();
      return;
    }
    await advance();
  }

  Future<void> advance() async {
    while (proposals.isNotEmpty) {
      final result = await host.processProposal(
        tools: turn.tools,
        proposal: proposals.removeAt(0),
      );
      if (result is StrategyToolWaiting) return;
      outcomes.add((result as StrategyToolContinuation).item);
    }
    await nextTurn();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    outcomes.add(await host.resolveApproval(resolution));
    await advance();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (!closing.isCompleted) closing.complete();
    await closeGate?.future;
  }
}

final class _Tool implements ModelToolContribution, ToolExecutable {
  int executions = 0;
  String summary = 'Mutate fixture source';
  List<EffectTarget> targets = [];
  Completer<void>? gate;
  final entered = Completer<void>();
  Completer<void>? materializeGate;
  final materializing = Completer<void>();

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    if (!materializing.isCompleted) materializing.complete();
    await materializeGate?.future;
    return [
      ToolRegistration(
        definition: ToolDefinition(
          id: ToolId('dev.adele.test.effect'),
          description: 'Test effect',
        ),
        modelDefinition: ModelToolDefinition(
          alias: 'test_effect',
          description: 'Test effect',
          argumentsSchema: const {'type': 'object'},
        ),
        executable: this,
      ),
    ];
  }

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments(arguments);
  @override
  void validateBinding() {}
  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const [ToolEffect.sourceMutation],
    targets: targets,
    summary: summary,
  );
  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executions++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    yield ToolExecutionProgress(
      ToolProgress(kind: ToolProgressKind.stdout, content: 'fixture progress'),
    );
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Executed fixture effect',
        hostData: const {
          'nested': [1, true, null],
        },
        hostDiagnostic: 'private diagnostic',
        cause: StateError('private diagnostic'),
      ),
    );
  }
}

final class _EnvironmentChannel implements AdeleStreamChannel {
  static const sourcePath = 'lib/example.dart';
  static const initialText = 'final value = "before";\n';
  String text = initialText;
  String revision = 'source-revision';
  final reads = <Map<String, Object?>>[];
  final writes = <Map<String, Object?>>[];
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    switch (method) {
      case environmentProviderServiceEstablishId:
        return {'providerState': <String, Object?>{}};
      case environmentProviderServiceReadFileId:
        expect(payload['relativePath'], sourcePath);
        reads.add(payload);
        return {
          'relativePath': sourcePath,
          'text': text,
          'sizeBytes': utf8.encode(text).length,
          'revision': revision,
        };
      case environmentProviderServiceReplaceExistingTextFileId:
        expect(payload['relativePath'], sourcePath);
        expect(payload['expectedRevision'], revision);
        writes.add(payload);
        text = payload['replacementText']! as String;
        revision = 'written-${writes.length}';
        return {'revision': revision};
      default:
        throw StateError('Unexpected Environment request $method');
    }
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      throw UnimplementedError();
}

final class _RunIds implements RunIdSource {
  final values = <RunId>[];
  @override
  RunId nextRunId() {
    final id = RunId('execution-${values.length + 1}');
    values.add(id);
    return id;
  }
}

final class _ModelChannel implements AdeleStreamChannel {
  final calls = <_ModelCall>[];
  Completer<void> changed = Completer<void>();
  Future<_ModelCall> callAt(int index) async {
    while (calls.length <= index) {
      await changed.future;
    }
    return calls[index];
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw UnimplementedError();
  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    expect(method, modelProviderServiceInvokeId);
    final call = _ModelCall(payload['request']! as Map<String, Object?>);
    calls.add(call);
    changed.complete();
    changed = Completer<void>();
    return call.events.stream;
  }
}

final class _ModelCall {
  _ModelCall(this.request);
  final Map<String, Object?> request;
  final events = StreamController<Object?>();
  void native() => events.add({
    'kind': 'output',
    'observation': null,
    'terminal': null,
    'output': {
      'kind': 'nativeItem',
      'text': null,
      'toolProposal': null,
      'itemId': 'native-fixture',
      'nativeMetadata': {
        'kind': 'dev.adele.test.native',
        'compatibility': <String, Object?>{},
        'data': {'private': 'private-replay-data'},
      },
      'nativePresentation': {
        'kind': 'dev.adele.test.summary',
        'compactText': 'Safe native summary',
        'data': {'text': 'Safe native summary'},
      },
    },
  });
  Iterable<Map<String, Object?>> get outcomes =>
      (request['input']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((item) => item['kind'] == 'toolOutcome')
          .map((item) => item['toolOutcome']! as Map<String, Object?>);
  void propose(
    String callId, {
    String alias = 'test_effect',
    Map<String, Object?> arguments = const {},
  }) => events.add({
    'kind': 'output',
    'observation': null,
    'terminal': null,
    'output': {
      'kind': 'toolProposal',
      'text': null,
      'toolProposal': {'callId': callId, 'name': alias, 'arguments': arguments},
      'itemId': callId,
      'nativeMetadata': null,
      'nativePresentation': null,
    },
  });
  void settle({bool fails = false}) => events.add({
    'kind': 'terminal',
    'observation': null,
    'output': null,
    'terminal': {
      'settlement': fails ? 'failed' : 'completed',
      'incompleteReason': null,
      'failure': fails
          ? {
              'kind': 'rateLimited',
              'providerCode': '429',
              'providerMessage': 'Fixture failure',
              'providerDetails': <String, Object?>{},
            }
          : null,
      'providerStopReason': 'stop',
      'usage': null,
      'effectiveModel': 'fixture-model',
      'responseId': 'fixture-response',
      'requestId': null,
      'nativeState': null,
    },
  });
}
