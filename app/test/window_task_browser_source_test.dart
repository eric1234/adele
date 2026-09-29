import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/prepared_session_host.dart';
import 'package:adele_desktop/frontend/window_task_browser_source.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AdeleRuntime runtime;
  late Project project;
  late Task first;
  late Task second;
  late Task foreign;
  late Session retained;
  late Task? selected;
  late Session? activated;
  late PreparedSessionHost host;
  late WindowTaskBrowserSource source;
  late ExtensionRegistration browserRegistration;
  late ExtensionRegistration strategyRegistration;
  late ExtensionRegistration presentationRegistration;
  late Completer<TaskCreationResult> establishment;
  late bool windowBusy;
  late _ExecutionChanges executionChanges;
  late Map<SessionId, String> executionStatuses;
  late List<Session> statusReads;
  final strategyId = OrchestrationStrategyId('test.strategy');

  ExtensionRegistration registerStrategy() => runtime.extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId('test.strategy.extension'),
    value: OrchestrationStrategyContribution(
      strategyId: strategyId,
      materialize: (_) =>
          throw StateError('Browsing must not materialize a strategy.'),
    ),
  );

  ExtensionRegistration registerBrowser() => runtime.extensions.register(
    point: taskBrowserContributions,
    id: ExtensionId('test.browser'),
    value: TaskBrowserContribution(
      displayName: 'Browser',
      createPresentation: (_) => const SizedBox(),
    ),
  );

  setUp(() {
    runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'browser'));
    project = runtime.lifecycle.createProject(
      Uri.parse('file:///browser-project'),
    );
    final other = runtime.lifecycle.createProject(
      Uri.parse('file:///other-project'),
    );
    Task publish(String name, Project owner) {
      final task = Task(id: TaskId(name), projectId: owner.id, title: name);
      runtime.store.publishTaskWithPrimaryEnvironment(
        task,
        Environment(
          id: EnvironmentId('env-$name'),
          taskId: task.id,
          role: EnvironmentRole.primary,
          providerId: ProviderId('test.environment'),
          providerState: const {'secretProviderField': 'never exposed'},
        ),
      );
      return task;
    }

    first = publish('first', project);
    second = publish('second', project);
    foreign = publish('foreign', other);
    strategyRegistration = registerStrategy();
    retained = runtime.lifecycle.createSession(
      taskId: first.id,
      strategyId: strategyId,
    );
    runtime.lifecycle.createSession(taskId: second.id, strategyId: strategyId);
    presentationRegistration = runtime.extensions.register(
      point: sessionPresentationContributions,
      id: ExtensionId('test.presentation'),
      value: SessionPresentationContribution(
        strategyId: strategyId,
        displayName: 'Example',
        createPresentation: (_) => const SizedBox(),
      ),
    );
    browserRegistration = registerBrowser();
    host = PreparedSessionHost(
      extensions: runtime.extensions,
      backends: runtime.plugins,
      controllerForSession: (_) =>
          throw StateError('No presentation requested.'),
      inspectActivity: (_, _) => false,
    );
    selected = null;
    activated = null;
    establishment = Completer<TaskCreationResult>();
    windowBusy = false;
    executionChanges = _ExecutionChanges();
    executionStatuses = {};
    statusReads = [];
    source = WindowTaskBrowserSource(
      project: project,
      lifecycle: runtime.lifecycle,
      extensions: runtime.extensions,
      sessionHost: host,
      browser: TaskBrowserResolver(runtime.extensions).resolve(),
      isCurrent: () => activated == null,
      isBusy: () => windowBusy,
      selectedTask: () => selected,
      onSelectTask: (task) => selected = task,
      establishTask: (_) => establishment.future,
      activateSession: (session, selection) {
        selection.validate();
        activated = session;
      },
      onDispose: () {},
      executionStatusFor: (session) {
        statusReads.add(session);
        return executionStatuses[session.id] ?? 'idle';
      },
      executionChanges: executionChanges,
    );
    addTearDown(() async {
      source.dispose();
      executionChanges.dispose();
      await host.close();
      await runtime.close();
    });
  });

  String option() {
    final task = source.read()['selectedTask']! as Map;
    return ((task['sessionCreationOptions'] as List).single
            as Map)['opaqueHandle']
        as String;
  }

  test(
    'snapshot contains only canonical Project Tasks and generic details',
    () async {
      final snapshot = source.read();
      expect(snapshot['selectedTaskId'], isNull);
      expect(snapshot['selectedTask'], isNull);
      expect((snapshot['tasks'] as List).map((row) => (row as Map)['title']), [
        'first',
        'second',
      ]);
      await source.selectTask(first.id.value);
      final details = source.read()['selectedTask']! as Map;
      expect(details['primaryEnvironment'], {
        'id': 'env-first',
        'providerId': 'test.environment',
      });
      expect((details['sessions'] as List).single, {
        'id': retained.id.value,
        'strategyId': strategyId.value,
        'presentationName': 'Example',
        'available': true,
        'executionStatus': 'idle',
      });
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId('env-first'),
        ),
        isNull,
      );
    },
  );

  test(
    'execution counts are passive, Project-scoped Session status reads',
    () async {
      final states = <SessionId, String>{retained.id: 'running'};
      for (final status in [
        'idle',
        'preparing',
        'waitingForApproval',
        'completed',
        'cancelled',
        'failed',
      ]) {
        final session = runtime.lifecycle.createSession(
          taskId: first.id,
          strategyId: strategyId,
        );
        states[session.id] = status;
      }
      final outside = runtime.lifecycle.createSession(
        taskId: foreign.id,
        strategyId: strategyId,
      );
      executionStatuses.addAll({...states, outside.id: 'running'});
      await source.selectTask(first.id.value);
      final snapshot = source.read();
      final tasks = snapshot['tasks'] as List;
      expect(tasks.first, {
        'id': first.id.value,
        'title': first.title,
        'sessionCount': 7,
        'executionCounts': {
          'preparing': 1,
          'running': 1,
          'waiting': 1,
          'terminal': 3,
          'completed': 1,
          'cancelled': 1,
          'failed': 1,
        },
      });
      expect(tasks.last['executionCounts'], {
        'preparing': 0,
        'running': 0,
        'waiting': 0,
        'terminal': 0,
        'completed': 0,
        'cancelled': 0,
        'failed': 0,
      });
      final details = snapshot['selectedTask']! as Map;
      expect(
        (details['sessions'] as List).map((row) => row['executionStatus']),
        states.values,
      );
      expect(statusReads, isNot(contains(outside)));
      for (final session in statusReads) {
        expect(runtime.store.session(session.id), same(session));
        expect(runtime.store.runsForSession(session.id), isEmpty);
        expect(
          runtime.lifecycle.environmentRuntime.currentMaterialization(
            runtime.store.requireSessionAuthority(session.id).environmentId,
          ),
          isNull,
        );
      }
      expect(activated, isNull);
    },
  );

  test('status changes notify only the source and unsubscribe on disposal', () {
    var notifications = 0;
    source.addListener(() => notifications++);
    expect(executionChanges.observed, isTrue);
    executionStatuses[retained.id] = 'preparing';
    executionChanges.notifyListeners();
    expect(notifications, 1);
    expect(statusReads, isEmpty);
    source.dispose();
    expect(executionChanges.observed, isFalse);
    executionChanges.notifyListeners();
    expect(notifications, 1);
    expect(source.read, throwsStateError);
  });

  test(
    'unknown execution status fails explicitly instead of inventing idle',
    () {
      executionStatuses[retained.id] = 'not-a-status';
      expect(source.read, throwsStateError);
    },
  );

  test('sessionsForTask is a detached immutable canonical snapshot', () {
    final snapshot = runtime.store.sessionsForTask(first.id);
    expect(snapshot.single, same(retained));
    expect(() => snapshot.clear(), throwsUnsupportedError);
    runtime.lifecycle.createSession(taskId: first.id, strategyId: strategyId);
    expect(snapshot, hasLength(1));
    expect(runtime.store.sessionsForTask(first.id), hasLength(2));
    expect(runtime.store.sessionsForTask(TaskId('missing')), isEmpty);
  });

  test('IDs cannot navigate across the selected Project or Task', () async {
    await expectLater(source.selectTask(foreign.id.value), throwsStateError);
    await expectLater(source.openSession(retained.id.value), throwsStateError);
    await source.selectTask(second.id.value);
    await expectLater(source.openSession(retained.id.value), throwsStateError);
    expect(activated, isNull);
  });

  test(
    'retained Session opens canonical object without replacement or Environment access',
    () async {
      await source.selectTask(first.id.value);
      await source.openSession(retained.id.value);
      expect(activated, same(retained));
      expect(runtime.store.sessionsForTask(first.id).single, same(retained));
      expect(
        runtime.store.requireSessionAuthority(retained.id).environmentId,
        EnvironmentId('env-first'),
      );
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId('env-first'),
        ),
        isNull,
      );
      expect(runtime.store.runsForSession(retained.id), isEmpty);
    },
  );

  test(
    'missing strategy leaves retained Session visible but unavailable',
    () async {
      await strategyRegistration.close();
      await source.selectTask(first.id.value);
      final details = source.read()['selectedTask']! as Map;
      expect((details['sessions'] as List).single['available'], false);
      expect(
        (details['sessions'] as List).single['presentationName'],
        'Example',
      );
      expect(details['sessionCreationOptions'], isEmpty);
      await expectLater(
        source.openSession(retained.id.value),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      expect(runtime.store.session(retained.id), same(retained));
    },
  );

  test(
    'opaque creation choice creates one Session with existing authority',
    () async {
      await source.selectTask(first.id.value);
      await source.createSession(option());
      expect(runtime.store.sessionsForTask(first.id), hasLength(2));
      expect(activated!.id, isNot(retained.id));
      expect(
        runtime.store.requireSessionAuthority(activated!.id).environmentId,
        EnvironmentId('env-first'),
      );
      expect(runtime.store.runsForSession(activated!.id), isEmpty);
    },
  );

  test(
    'missing presentation retains stored strategy identity in the list',
    () async {
      await presentationRegistration.close();
      executionStatuses[retained.id] = 'waitingForApproval';
      await source.selectTask(first.id.value);
      final details = source.read()['selectedTask']! as Map;
      expect((details['sessions'] as List).single, {
        'id': retained.id.value,
        'strategyId': strategyId.value,
        'presentationName': strategyId.value,
        'available': false,
        'executionStatus': 'waitingForApproval',
      });
      expect(details['sessionCreationOptions'], isEmpty);
      expect(runtime.store.session(retained.id), same(retained));
    },
  );

  test('new strategy ambiguity rejects a previously offered option', () async {
    await source.selectTask(first.id.value);
    final offered = option();
    final duplicate = runtime.extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('test.other.strategy'),
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (_) => throw StateError('Must not execute.'),
      ),
    );
    addTearDown(duplicate.close);
    await expectLater(
      source.createSession(offered),
      throwsA(isA<AmbiguousOrchestrationStrategy>()),
    );
    expect(runtime.store.sessionsForTask(first.id), hasLength(1));
    final details = source.read()['selectedTask']! as Map;
    expect(details['sessionCreationOptions'], isEmpty);
    expect((details['sessions'] as List).single['available'], false);
  });

  test(
    'browser ambiguity revokes an already captured navigation source',
    () async {
      final duplicate = runtime.extensions.register(
        point: taskBrowserContributions,
        id: ExtensionId('test.other.browser'),
        value: TaskBrowserContribution(
          displayName: 'Other',
          createPresentation: (_) => const SizedBox(),
        ),
      );
      addTearDown(duplicate.close);
      await expectLater(
        source.selectTask(first.id.value),
        throwsA(isA<AmbiguousTaskBrowser>()),
      );
      expect(selected, isNull);
    },
  );

  test(
    'pending Task creation rejects duplicate and navigation callbacks',
    () async {
      final creating = source.createTask('pending');
      await expectLater(source.createTask('duplicate'), throwsStateError);
      await expectLater(source.selectTask(second.id.value), throwsStateError);
      establishment.complete(
        TaskCreationResult(
          task: first,
          environment: runtime.store.primaryEnvironmentFor(first.id)!,
        ),
      );
      await creating;
      expect(selected, same(first));
      expect(activated, isNull);
    },
  );

  test(
    'a replacement browser cannot create Sessions while window work is pending',
    () async {
      await source.selectTask(first.id.value);
      final offered = option();
      windowBusy = true;
      await expectLater(source.createSession(offered), throwsStateError);
      await expectLater(
        source.openSession(retained.id.value),
        throwsStateError,
      );
      expect(source.read()['selectedTaskId'], first.id.value);
      expect(runtime.store.sessionsForTask(first.id), [retained]);
      expect(activated, isNull);
    },
  );

  test('retired creation choice never retargets a replacement', () async {
    await source.selectTask(first.id.value);
    final old = option();
    await strategyRegistration.close();
    strategyRegistration = registerStrategy();
    await expectLater(
      source.createSession(old),
      throwsA(isA<StaleExtensionBinding>()),
    );
    expect(option(), isNot(old));
    await expectLater(source.createSession(old), throwsStateError);
    expect(runtime.store.sessionsForTask(first.id), hasLength(1));
  });

  test(
    'retired presentation and foreign Task options fail before publication',
    () async {
      await source.selectTask(first.id.value);
      final old = option();
      await source.selectTask(second.id.value);
      await expectLater(source.createSession(old), throwsStateError);
      await source.selectTask(first.id.value);
      await presentationRegistration.close();
      await expectLater(
        source.createSession(old),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(activated, isNull);
    },
  );

  test(
    'retiring the browser revokes reads/actions even after same-ID replacement',
    () async {
      await browserRegistration.close();
      browserRegistration = registerBrowser();
      expect(source.read, throwsA(isA<StaleExtensionBinding>()));
      await expectLater(
        source.selectTask(first.id.value),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(selected, isNull);
    },
  );

  test(
    'retirement during Task establishment preserves graph but rejects late navigation',
    () async {
      final creating = source.createTask('new title');
      final failure = expectLater(
        creating,
        throwsA(isA<StaleExtensionBinding>()),
      );
      await browserRegistration.close();
      establishment.complete(
        TaskCreationResult(
          task: first,
          environment: runtime.store.primaryEnvironmentFor(first.id)!,
        ),
      );
      await failure;
      expect(selected, isNull);
      expect(runtime.store.task(first.id), same(first));
    },
  );

  test(
    'bridge retirement during change delivery revokes before notifier cleanup',
    () async {
      source.addListener(source.dispose);
      expect(source.refresh, returnsNormally);
      expect(source.read, throwsStateError);
      await expectLater(source.selectTask(first.id.value), throwsStateError);
      expect(selected, isNull);
    },
  );
}

final class _ExecutionChanges extends ChangeNotifier {
  bool get observed => hasListeners;
}
