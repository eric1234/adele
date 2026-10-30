import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/session_feedback_bridge.dart';
import 'package:adele_desktop/frontend/session_feedback_source.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:feedback_probe/main.dart';
final _strategyId = OrchestrationStrategyId('test.feedback.strategy');
final _modelId = ProviderId('test.feedback.model');
final _projectId = ProviderId('test.feedback.project');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Program program;
  late _Fixture fixture;

  setUpAll(() async {
    program =
        (Compiler()
              ..addPlugin(const SessionFeedbackDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'feedback_probe': {'main.dart': _source},
              'adele_ui': {
                'session_feedback_bridge.dart': await File(
                  '../packages/ui/lib/session_feedback_bridge.dart',
                ).readAsString(),
              },
            });
  });
  setUp(() async {
    fixture = await _Fixture.create();
    addTearDown(fixture.close);
  });

  _BridgeProbe bridge([SessionFeedbackPresentationSource? source]) =>
      _BridgeProbe(program, SessionFeedbackBridge(source: source));

  testWidgets(
    'mounted opt-in grants canonical feedback and frontend retirement fences late results',
    (tester) async {
      final generation = (await tester.runAsync(() async {
        final compiled =
            (Compiler()
                  ..addPlugin(flutterEvalPlugin)
                  ..addPlugin(const MainContentDeclarations())
                  ..addPlugin(const SessionFeedbackDeclarations())
                  ..entrypoints.add(_library))
                .compile({
                  'feedback_probe': {'main.dart': _paneSource},
                  'adele_ui': {
                    for (final library in [
                      'main_content_bridge',
                      'session_feedback_bridge',
                    ])
                      '$library.dart': await File(
                        '../packages/ui/lib/$library.dart',
                      ).readAsString(),
                  },
                });
        final artifact = await File(
          '${fixture.directory.path}/pane.evc',
        ).writeAsBytes(compiled.write());
        return PreparedFrontend.load(artifact);
      }))!;
      addTearDown(generation.invalidate);
      final capture = _RuntimeCapture();
      final prepared = PreparedMainContentHost(
        createBinding:
            ({
              required installation,
              required descriptor,
              required session,
              required paneId,
            }) => PreparedMainContentPaneBinding(createBridge: (_) => capture),
      );
      addTearDown(prepared.close);
      final descriptor = PreparedMainContentPresentation(
        extensionId: ExtensionId('test.feedback.real-pane'),
        order: 100,
        library: _library,
        initialize: 'initialize',
        entrypoint: 'build',
        sessionFeedback: true,
      );
      final contribution = prepared.createContribution(
        extensions: fixture.runtime.extensions,
        installation: PreparedPluginInstallation(
          metadata: PluginMetadata(
            id: PluginId('test.feedback.frontend'),
            version: '1',
            displayName: 'Feedback',
          ),
          installationDirectory: fixture.directory,
          backendArtifactUri: null,
        ),
        generation: generation,
        descriptor: descriptor,
        services: fixture.services(),
        isActive: () => true,
      );
      fixture.runtime.extensions.register(
        point: mainContentContributions,
        id: descriptor.extensionId,
        value: contribution,
      );
      expect(fixture.capturedSessions, isEmpty);
      expect(fixture.owner, isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              session: fixture.session,
              extensions: fixture.runtime.extensions,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Canonical feedback available'), findsOneWidget);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(fixture.capturedSessions, [same(fixture.session)]);
      fixture.expectNoExecution();
      final entered = Completer<void>();
      final gate = Completer<SessionFeedbackReceipt>();
      fixture.target.onAccept = (_) {
        entered.complete();
        return gate.future;
      };
      final pending =
          (capture.runtime.executeLib(_library, 'deliver', [
                    $String(_payload()),
                  ])
                  as $Future)
              .$value;
      await entered.future;
      generation.invalidate();
      gate.complete(fixture.target.store(_submission()).receipt);
      final result = copyStructuredBridgeData(await pending) as Map;
      expect(result['code'], 'presentation_unavailable');
      expect(fixture.target.accepted, hasLength(1));
      expect(fixture.target.records['submission'], isNotNull);
      fixture.expectNoExecution();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test('declarations and unbound bridges grant no native authority', () async {
    expect(
      () => const SessionFeedbackDeclarations().configureForRuntime(
        Runtime.ofProgram(program),
      ),
      throwsUnsupportedError,
    );
    final probe = bridge();
    expect(probe.availability()['available'], isFalse);
    for (final operation in ['accept', 'lookup', 'start', 'lookupRun']) {
      expect((await probe.call(operation))['code'], 'presentation_unavailable');
    }
    fixture.expectNoExecution();
    expect(fixture.target.accepted, isEmpty);
    expect(fixture.target.lookedUp, isEmpty);
  });

  test(
    'descriptor denial and missing lifecycle never create an owner',
    () async {
      final denied = fixture.bind(program, feedback: false);
      expect(denied.probe.availability, throwsA(anything));
      final noLifecycle = fixture.bind(program, withLifecycle: false);
      expect(noLifecycle.probe.availability()['available'], isFalse);
      expect((await noLifecycle.probe.call('accept'))['status'], 'uncertain');
      expect(fixture.owner, isNull);
      expect(fixture.capturedSessions, isEmpty);
      expect(fixture.target.accepted, isEmpty);
    },
  );

  test(
    'availability, acceptance and lookup never execute a model or Run',
    () async {
      final source = fixture.source();
      expect(source.readAvailability()['available'], isTrue);
      expect(source.readAvailability()['canStart'], isTrue);
      expect(fixture.capturedSessions, [same(fixture.session)]);
      final owner = fixture.owner!;
      final before = owner.sessionStateRevision;
      var notifications = 0;
      owner.addListener(() => notifications++);
      expect((await source.accept(_payload()))['status'], 'accepted');
      expect(owner.sessionStateRevision, greaterThan(before));
      expect(notifications, greaterThan(0));
      final acceptedRevision = owner.sessionStateRevision;
      expect((await source.lookup(_payload()))['status'], 'accepted');
      expect(owner.sessionStateRevision, greaterThan(acceptedRevision));
      expect(
        (await source.lookupRun(_payload(), 'entry-submission'))['status'],
        'uncertain',
      );
      fixture.expectNoExecution();
      expect(fixture.target.accepted, hasLength(1));
      expect(
        fixture.runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId('environment'),
        ),
        isNull,
      );
    },
  );

  for (final mode in ['missing', 'ambiguous', 'unsupported']) {
    test(
      '$mode feedback target is an unavailable service, not failed binding',
      () async {
        await fixture.strategy.close();
        if (mode != 'missing') {
          fixture.registerStrategy(supportsFeedback: mode != 'unsupported');
        }
        if (mode == 'ambiguous') {
          fixture.registerStrategy(id: 'test.feedback.duplicate');
        }
        final bound = fixture.bind(program);
        expect(bound.probe.availability()['available'], isFalse);
        expect((await bound.probe.call('accept'))['status'], 'unavailable');
        expect(bound.registration.isClosed, isFalse);
        expect(fixture.owner, isNull);
        fixture.expectNoExecution();
      },
    );
  }

  test(
    'a lookalike Session cannot obtain a target through prepared services',
    () async {
      final fake = Session(
        id: fixture.session.id,
        taskId: fixture.session.taskId,
        strategyId: fixture.session.strategyId,
      );
      final services = fixture.services(isCurrent: (_) => true);
      final bound = fixture.bind(program, services: services, session: fake);
      expect(bound.probe.availability()['available'], isFalse);
      for (final operation in ['accept', 'lookup', 'start', 'lookupRun']) {
        expect((await bound.probe.call(operation))['status'], 'uncertain');
      }
      expect(fixture.capturedSessions, isEmpty);
      expect(fixture.owner, isNull);
      fixture.expectNoExecution();
    },
  );

  test(
    'volatile canonical Session cannot bypass the durable Project check',
    () async {
      final runtime = AdeleRuntime();
      addTearDown(runtime.close);
      runtime.store.publishRestoredProject(
        project: fixture.project,
        tasks: [fixture.runtime.store.task(fixture.session.taskId)!],
        environments: [
          fixture.runtime.store.environment(EnvironmentId('environment'))!,
        ],
        sessions: [fixture.session],
        authorities: [(fixture.session.id, EnvironmentId('environment'))],
        runRecords: [],
      );
      final source = SessionFeedbackPresentationSource(
        session: fixture.session,
        lifecycle: runtime.lifecycle,
        admissions: SessionFeedbackAdmissions(),
        controllerForSession: () =>
            throw StateError('Must not create an owner.'),
        lookupControllerForSession: () => null,
        validateAttachment: () {},
      );
      expect(source.readAvailability()['available'], isFalse);
      expect(
        (await source.accept(_payload()))['code'],
        'durable_storage_required',
      );
      expect(fixture.target.accepted, isEmpty);
    },
  );

  for (final fence in [
    'navigation',
    'noninteractive',
    'disposal',
    'frontend',
    'project',
  ]) {
    test(
      '$fence fences a late acceptance without cancelling its admitted effect',
      () async {
        final bound = fixture.bind(program);
        final entered = Completer<void>();
        final gate = Completer<SessionFeedbackReceipt>();
        fixture.target.onAccept = (_) {
          entered.complete();
          return gate.future;
        };
        final pending = bound.probe.call('accept');
        await entered.future;
        switch (fence) {
          case 'navigation':
            fixture.current = false;
          case 'noninteractive':
            fixture.interactive = false;
          case 'disposal':
            bound.probe.bridge.invalidate();
          case 'frontend':
            await bound.registration.close();
          case 'project':
            await fixture.runtime.lifecycle.close();
        }
        final record = fixture.target.store(_submission());
        gate.complete(record.receipt);
        expect((await pending)['code'], 'presentation_unavailable');
        expect(bound.probe.availability()['available'], isFalse);
        expect((await bound.probe.call('accept'))['status'], 'uncertain');
        expect(fixture.target.accepted, hasLength(1));
        expect(fixture.target.records['submission'], same(record));
        fixture.expectNoExecution();
      },
    );
  }

  test('retired exact view cannot borrow a same-ID replacement', () async {
    final services = fixture.services();
    final first = fixture.bind(program, services: services);
    expect(first.probe.availability()['available'], isTrue);
    await first.registration.close();
    final replacement = fixture.bind(program, services: services, id: first.id);
    expect(first.probe.availability()['available'], isFalse);
    expect((await first.probe.call('accept'))['status'], 'uncertain');
    expect(replacement.probe.availability()['available'], isTrue);
    expect((await replacement.probe.call('accept'))['status'], 'accepted');
    expect(fixture.target.accepted, hasLength(1));
  });

  test(
    'shared admissions suppress double acceptance across pane remounts',
    () async {
      final services = fixture.services();
      final first = fixture.bind(program, services: services);
      final entered = Completer<void>();
      final gate = Completer<SessionFeedbackReceipt>();
      fixture.target.onAccept = (_) {
        entered.complete();
        return gate.future;
      };
      final pending = first.probe.call('accept');
      await entered.future;
      expect((await first.probe.call('accept'))['code'], 'delivery_pending');
      first.probe.bridge.invalidate();
      final remounted = fixture.bind(program, services: services);
      expect(
        (await remounted.probe.call('accept'))['code'],
        'delivery_pending',
      );
      gate.complete(fixture.target.store(_submission()).receipt);
      expect((await pending)['status'], 'uncertain');
      expect(
        (await remounted.probe.call('accept'))['code'],
        'reconciliation_required',
      );
      expect((await remounted.probe.call('lookup'))['status'], 'accepted');
      expect(fixture.target.accepted, hasLength(1));
      fixture.expectNoExecution();
    },
  );

  test(
    'uncertain delivery plus absent lookup never authorizes replay',
    () async {
      final source = fixture.source();
      fixture.target.onAccept = (_) => throw StateError('Lost response.');
      expect((await source.accept(_payload()))['status'], 'uncertain');
      expect(
        await source.lookup(_payload()),
        containsPair('retryAllowed', false),
      );
      final remounted = fixture.source();
      expect(
        (await remounted.accept(_payload()))['code'],
        'reconciliation_required',
      );
      expect(fixture.target.accepted, hasLength(1));
      expect(
        (await remounted.lookupRun(_payload(), 'entry-submission'))['status'],
        'uncertain',
      );
      fixture.expectNoExecution();
    },
  );

  test(
    'only a retained definite rejection permits same-payload explicit retry',
    () async {
      final source = fixture.source();
      fixture.target.onAccept = (_) => throw const SessionFeedbackFailure(
        code: 'session_busy',
        message: 'Busy.',
      );
      expect((await source.accept(_payload()))['retryAllowed'], isTrue);
      expect((await source.lookup(_payload()))['retryAllowed'], isTrue);
      expect(
        (await source.lookup(_payload('different')))['retryAllowed'],
        isFalse,
      );
      fixture.target.onAccept = null;
      expect((await source.accept(_payload()))['status'], 'accepted');
      expect(
        (await source.accept(_payload()))['code'],
        'reconciliation_required',
      );
      expect(fixture.target.accepted, hasLength(2));
    },
  );

  for (final result in ['absent', 'failure', 'conflict']) {
    test(
      'read-only $result lookup never accepts, schedules, or grants retry',
      () async {
        if (result == 'failure') {
          fixture.target.onLookup = (_) =>
              throw StateError('Private storage failure.');
        } else if (result == 'conflict') {
          fixture.target.store(_submission(text: 'Different frozen content.'));
        }
        final source = fixture.source();
        final found = await source.lookup(_payload());
        expect(found['status'], result == 'absent' ? 'absent' : 'uncertain');
        expect(found['retryAllowed'], isNot(true));
        if (result == 'conflict') expect(found['code'], 'submission_conflict');
        expect(
          (await source.lookupRun(_payload(), 'entry-submission'))['status'],
          'uncertain',
        );
        expect(fixture.owner, isNull);
        expect(fixture.target.accepted, isEmpty);
        fixture.expectNoExecution();
      },
    );
  }

  test('noncanonical or malformed payloads cannot reach the target', () async {
    final source = fixture.source();
    for (final payload in ['{}', ' ${_payload()}']) {
      expect((await source.accept(payload))['status'], 'unavailable');
      expect((await source.lookup(payload))['status'], 'uncertain');
    }
    expect(fixture.target.accepted, isEmpty);
    expect(fixture.target.lookedUp, isEmpty);
    expect(fixture.capturedSessions, isEmpty);
  });

  test(
    'target retirement fences an admitted lookup without redirection',
    () async {
      final source = fixture.source();
      final original = fixture.target;
      final gate = Completer<SessionFeedbackRecord?>();
      original.onLookup = (_) => gate.future;
      final pending = source.startRun(_payload(), 'entry-submission', 1);
      expect(original.lookedUp, ['submission']);
      await fixture.strategy.close();
      final replacement = _Target(fixture.session)..store(_submission());
      fixture.registerStrategy(target: replacement);
      gate.complete(original.store(_submission()));
      expect((await pending)['status'], 'uncertain');
      expect(replacement.lookedUp, isEmpty);
      expect(replacement.accepted, isEmpty);
      expect(fixture.materializations, isEmpty);
      expect(
        (await source.startRun(_payload(), 'entry-submission', 1))['status'],
        'uncertain',
      );
      expect(replacement.lookedUp, isEmpty);
      expect((await source.lookup(_payload()))['status'], 'accepted');
      expect(replacement.lookedUp, ['submission']);
      expect(fixture.materializations, isEmpty);
    },
  );

  test(
    'captured availability cannot silently migrate to a replacement target',
    () async {
      final source = fixture.source();
      expect(source.readAvailability()['available'], isTrue);
      await fixture.strategy.close();
      final replacement = _Target(fixture.session);
      fixture.registerStrategy(target: replacement);
      expect(source.readAvailability()['available'], isFalse);
      expect((await source.accept(_payload()))['code'], 'stale_target');
      expect(replacement.accepted, isEmpty);
      expect((await source.lookup(_payload()))['status'], 'absent');
      expect(replacement.lookedUp, ['submission']);
      fixture.expectNoExecution();
    },
  );

  test(
    'unavailable model returns not_started without allocating a Run',
    () async {
      fixture.target.store(_submission());
      await fixture.modelRegistration.close();
      final source = fixture.source();
      final result = await source.startRun(_payload(), 'entry-submission', 1);
      expect(result['status'], 'not_started');
      expect(result['retryAllowed'], isTrue);
      expect(
        fixture.owner!.feedbackRunFor(
          fixture.target.records['submission']!.receipt,
        ),
        isNull,
      );
      expect(await source.lookupRun(_payload(), 'entry-submission'), result);
      fixture.expectNoExecution();
    },
  );

  test(
    'retained lifecycle occupancy blocks delivery and scheduling, not reconciliation',
    () async {
      fixture.target.store(_submission());
      final release = fixture.runtime.lifecycle.retainSessionExecution(
        fixture.session,
      );
      addTearDown(release);
      final source = fixture.source();
      expect(source.readAvailability()['available'], isTrue);
      expect(source.readAvailability()['canStart'], isFalse);
      expect((await source.accept(_payload('new')))['code'], 'session_busy');
      expect((await source.lookup(_payload()))['status'], 'accepted');
      expect(
        (await source.startRun(_payload(), 'entry-submission', 1))['status'],
        'not_started',
      );
      expect(fixture.target.accepted, isEmpty);
      expect(
        fixture.runtime.lifecycle.hasSessionExecution(fixture.session),
        isTrue,
      );
      fixture.expectNoExecution();
      release();
      expect(source.readAvailability()['canStart'], isTrue);
    },
  );

  test(
    'double start coalesces and retained completed admission cannot duplicate',
    () async {
      fixture.target.store(_submission());
      fixture.materializationGate = Completer<void>();
      final source = fixture.source();
      final first = source.startRun(_payload(), 'entry-submission', 1);
      final second = source.startRun(_payload(), 'entry-submission', 1);
      await fixture.materializing.future;
      final owner = fixture.owner!;
      final admission = owner.feedbackRunFor(
        fixture.target.records['submission']!.receipt,
      )!;
      expect(admission.state, SessionFeedbackRunAdmissionState.preparing);
      expect(
        (await source.startRun(_payload(), 'entry-submission', 2))['status'],
        'uncertain',
      );
      fixture.materializationGate!.complete();
      final result = await first;
      expect(result['status'], 'scheduled');
      expect(await second, result);
      expect(result['runId'], admission.runId.value);
      await owner.activeRunFuture;
      expect(
        await fixture.source().startRun(_payload(), 'entry-submission', 1),
        result,
      );
      expect(
        (await source.startRun(_payload(), 'entry-submission', 2))['status'],
        'uncertain',
      );
      expect(fixture.materializations, hasLength(1));
      expect(fixture.starts, 1);
    },
  );

  test(
    'scheduling attempt ABA cannot replay a prior not_started result',
    () async {
      fixture.target.store(_submission());
      await fixture.modelRegistration.close();
      final source = fixture.source();
      expect(
        (await source.startRun(_payload(), 'entry-submission', 1))['status'],
        'not_started',
      );
      fixture.registerModel();
      fixture.materializationGate = Completer<void>();
      final retry = source.startRun(_payload(), 'entry-submission', 2);
      await fixture.materializing.future;
      expect(
        (await source.startRun(_payload(), 'entry-submission', 1))['code'],
        'scheduling_conflict',
      );
      expect(
        (await source.startRun(_payload(), 'different-entry', 2))['code'],
        'scheduling_conflict',
      );
      fixture.materializationGate!.complete();
      expect((await retry)['status'], 'scheduled');
      expect(fixture.materializations, hasLength(1));
      for (final invalid in [0, -1, 2147483648]) {
        expect(
          (await source.startRun(
            _payload(),
            'entry-submission',
            invalid,
          ))['code'],
          'invalid_scheduling_attempt',
        );
      }
    },
  );

  test(
    'uncertain materialization and absent association never reschedule',
    () async {
      final record = fixture.target.store(_submission());
      fixture.materializationFailure = StateError(
        'Unknown materialization outcome.',
      );
      final source = fixture.source();
      expect(
        (await source.startRun(
          _payload(),
          record.receipt.occurrenceId,
          1,
        ))['status'],
        'uncertain',
      );
      final admission = fixture.owner!.feedbackRunFor(record.receipt)!;
      expect(admission.state, SessionFeedbackRunAdmissionState.uncertain);
      fixture.materializationFailure = null;
      expect(
        (await source.lookupRun(
          _payload(),
          record.receipt.occurrenceId,
        ))['status'],
        'uncertain',
      );
      expect(
        (await fixture.source().startRun(
          _payload(),
          record.receipt.occurrenceId,
          1,
        ))['status'],
        'uncertain',
      );
      expect(
        (await source.startRun(
          _payload(),
          record.receipt.occurrenceId,
          2,
        ))['status'],
        'uncertain',
      );
      final newAdmissions = fixture.source(
        admissions: SessionFeedbackAdmissions(),
      );
      expect(
        (await newAdmissions.startRun(
          _payload(),
          record.receipt.occurrenceId,
          1,
        ))['status'],
        'uncertain',
      );
      expect(fixture.owner!.feedbackRunFor(record.receipt), same(admission));
      expect(fixture.materializations, hasLength(1));
      expect(fixture.starts, 0);
    },
  );

  test(
    'durable association reconciles without terminal history or model availability',
    () async {
      fixture.target.store(_submission(), runId: 'previous-run');
      await fixture.modelRegistration.close();
      final source = fixture.source();
      final result = await source.lookupRun(_payload(), 'entry-submission');
      expect(result['status'], 'scheduled');
      expect(result['runId'], 'previous-run');
      expect(result['runState'], 'associated');
      expect(fixture.owner, isNull);
      expect(
        (await source.startRun(_payload(), 'entry-submission', 1))['runId'],
        'previous-run',
      );
      fixture.expectNoExecution();
    },
  );

  test(
    'conflicting Run association stays uncertain without another start',
    () async {
      fixture.target.store(_submission());
      final source = fixture.source();
      final scheduled = await source.startRun(
        _payload(),
        'entry-submission',
        1,
      );
      expect(scheduled['status'], 'scheduled');
      await fixture.owner!.activeRunFuture;
      fixture.target.store(_submission(), runId: 'conflicting-run');
      final lookup = await source.lookupRun(_payload(), 'entry-submission');
      expect(lookup['status'], 'uncertain');
      expect(lookup['code'], 'run_association_conflict');
      expect(lookup['retryAllowed'], isFalse);
      expect(fixture.materializations, hasLength(1));
      expect(fixture.starts, 1);
    },
  );

  test(
    'proven failed preparation cannot hide a later ordinary Run association',
    () async {
      fixture.target.store(_submission());
      final tools = fixture.runtime.extensions.register(
        point: modelToolContributions,
        id: ExtensionId('test.feedback.failing-tools'),
        value: _FailingTools(),
      );
      final source = fixture.source();
      expect(
        (await source.startRun(_payload(), 'entry-submission', 1))['status'],
        'not_started',
      );
      await fixture.owner!.activeRunFuture;
      await tools.close();
      fixture.target.store(_submission(), runId: 'ordinary-run');
      final reconciled = await source.lookupRun(_payload(), 'entry-submission');
      expect(reconciled['status'], 'scheduled');
      expect(reconciled['runId'], 'ordinary-run');
      expect(fixture.materializations, isEmpty);
      expect(fixture.starts, 0);
    },
  );

  test(
    'late scheduling completion is fenced, then explicitly reconciled after remount',
    () async {
      fixture.target.store(_submission());
      fixture.materializationGate = Completer<void>();
      final services = fixture.services();
      final first = fixture.bind(program, services: services);
      final pending = first.probe.call('start');
      await fixture.materializing.future;
      first.probe.bridge.invalidate();
      final remounted = fixture.bind(program, services: services);
      final duplicate = remounted.probe.call('start');
      fixture.materializationGate!.complete();
      expect((await pending)['code'], 'presentation_unavailable');
      expect((await duplicate)['status'], 'uncertain');
      final reconciled = await remounted.probe.call('lookupRun');
      expect(reconciled['status'], 'scheduled');
      expect(fixture.materializations, hasLength(1));
      expect(fixture.starts, 1);
    },
  );
}

final class _Fixture {
  final runtime = AdeleRuntime();
  final admissions = SessionFeedbackAdmissions();
  final capturedSessions = <Session>[];
  final materializations = <SessionFeedbackReceipt?>[];
  final materializing = Completer<void>();
  final model = _ModelChannel();
  late Directory directory;
  late Project project;
  late Session session;
  late _Target target;
  late ExtensionRegistration strategy;
  late CapabilityRegistration modelRegistration;
  SessionExecutionController? owner;
  Completer<void>? materializationGate;
  Object? materializationFailure;
  bool current = true;
  bool interactive = true;
  int starts = 0;
  int nextView = 0;

  static Future<_Fixture> create() async {
    final fixture = _Fixture();
    fixture.directory = await Directory.systemTemp.createTemp(
      'feedback-presentation-',
    );
    final database = ProjectDatabase.open(
      ProjectBacking(
        sourceLocation: fixture.directory.uri,
        databaseRelativePath: 'data.db',
      ),
    );
    final project = database.openProject(
      sourceLocation: fixture.directory.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final task = Task(
      id: TaskId('task'),
      projectId: project.id,
      title: 'Feedback',
    );
    final environment = Environment(
      id: EnvironmentId('environment'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: ProviderId('test.unavailable.environment'),
      providerState: const {},
    );
    final session = Session(
      id: SessionId('session'),
      taskId: task.id,
      strategyId: _strategyId,
    );
    database.insertTaskWithPrimaryEnvironment(task, environment);
    database.insertSessionWithAuthority(session, environment.id);
    database.close();
    fixture.runtime.registry.register(
      provider: ProviderDescriptor(
        id: _projectId,
        capability: projectProviderCapability,
        pluginId: 'test.feedback.project',
        displayName: 'Durable fixture',
        serviceId: projectProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _ProjectChannel(),
        serviceId: projectProviderServiceId,
        isAvailable: () => true,
      ),
    );
    fixture.project = await fixture.runtime.lifecycle.openProject(
      sourceLocation: fixture.directory.uri,
      provider: fixture.runtime.lifecycle.resolveProjectProvider(_projectId),
    );
    fixture.session = fixture.runtime.store.session(session.id)!;
    expect(fixture.runtime.lifecycle.databaseForSession(session.id), isNotNull);
    fixture.target = _Target(fixture.session);
    fixture.registerStrategy();
    fixture.registerModel();
    return fixture;
  }

  ExtensionRegistration registerStrategy({
    String id = 'test.feedback.registration',
    _Target? target,
    bool supportsFeedback = true,
  }) {
    final selected = target ?? this.target;
    return strategy = runtime.extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId(id),
      value: OrchestrationStrategyContribution(
        strategyId: _strategyId,
        feedbackTarget: supportsFeedback
            ? (canonical) {
                capturedSessions.add(canonical);
                return selected;
              }
            : null,
        materialize: (context) async {
          materializations.add(context.expectedFeedback);
          if (!materializing.isCompleted) materializing.complete();
          await materializationGate?.future;
          if (materializationFailure case final failure?) throw failure;
          final receipt = context.expectedFeedback!;
          final record = selected.records[receipt.submissionId]!;
          expect(receipt.sessionId, session.id.value);
          expect(receipt.occurrenceId, record.receipt.occurrenceId);
          selected.store(record.submission, runId: context.host.id.value);
          return _Execution(context.host, () => starts++);
        },
      ),
    );
  }

  void registerModel() {
    modelRegistration = runtime.registry.register(
      provider: ProviderDescriptor(
        id: _modelId,
        capability: modelProviderCapability,
        pluginId: 'test.feedback.model',
        displayName: 'Fixture model',
        serviceId: modelProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: model,
        serviceId: modelProviderServiceId,
        isAvailable: () => true,
      ),
    );
  }

  SessionExecutionController controller() =>
      owner ??= SessionExecutionController(
        runtime: runtime,
        session: session,
        providerId: _modelId,
        model: 'fixture',
      );

  SessionFeedbackPresentationSource source({
    SessionFeedbackAdmissions? admissions,
  }) => SessionFeedbackPresentationSource(
    session: session,
    lifecycle: runtime.lifecycle,
    admissions: admissions ?? this.admissions,
    controllerForSession: controller,
    lookupControllerForSession: () => owner,
    validateAttachment: () {
      if (!current || !interactive) throw StateError('Detached.');
    },
  );

  PreparedSessionServices services({
    bool withLifecycle = true,
    bool Function(Session)? isCurrent,
  }) => PreparedSessionServices(
    extensions: runtime.extensions,
    backends: runtime.plugins,
    lifecycle: withLifecycle ? runtime.lifecycle : null,
    controllerForSession: (canonical, strategy) {
      expect(canonical, same(session));
      expect(strategy, isNull);
      return controller();
    },
    lookupControllerForSession: (_) => owner,
    inspectActivity: (_, _) => false,
    isCurrent: isCurrent ?? (value) => current && identical(value, session),
    isInteractive: (_) => interactive,
  );

  ({_BridgeProbe probe, ExtensionRegistration registration, String id}) bind(
    Program program, {
    PreparedSessionServices? services,
    Session? session,
    bool feedback = true,
    bool withLifecycle = true,
    String? id,
  }) {
    id ??= 'test.feedback.view.v${nextView++}';
    final descriptor = PreparedMainContentPresentation(
      extensionId: ExtensionId(id),
      order: 100,
      library: _library,
      initialize: 'initialize',
      entrypoint: 'build',
      sessionFeedback: feedback,
    );
    final contribution = MainContentContribution(order: 100, attach: (_) {});
    final registration = runtime.extensions.register(
      point: mainContentContributions,
      id: descriptor.extensionId,
      value: contribution,
    );
    final binding = runtime.extensions
        .discover(mainContentContributions)
        .singleWhere((view) => view.id == descriptor.extensionId);
    services ??= this.services(withLifecycle: withLifecycle);
    services.registerMetadata(
      contribution,
      PreparedPluginInstallation(
        metadata: PluginMetadata(
          id: PluginId('test.feedback.frontend'),
          version: '1',
          displayName: 'Feedback',
        ),
        installationDirectory: directory,
        backendArtifactUri: null,
      ),
      descriptor,
    );
    final bridge = services.bind(
      binding,
      session: session ?? this.session,
      isActive: () => true,
    );
    addTearDown(bridge.invalidate);
    return (
      probe: _BridgeProbe(program, bridge),
      registration: registration,
      id: id,
    );
  }

  void expectNoExecution() {
    expect(materializations, isEmpty);
    expect(starts, 0);
    expect(model.calls, 0);
    expect(owner?.latestRunId, isNull);
    expect(runtime.store.runsForSession(session.id), isEmpty);
  }

  Future<void> close() async {
    if (materializationGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    await owner?.close();
    await runtime.close();
    await directory.delete(recursive: true);
  }
}

final class _BridgeProbe {
  _BridgeProbe(Program program, this.bridge)
    : runtime = Runtime.ofProgram(program) {
    runtime.addPlugin(bridge);
  }
  final PreparedFrontendBridge bridge;
  final Runtime runtime;
  Map<String, Object?> availability() =>
      copyStructuredBridgeData(runtime.executeLib(_library, 'availability'))
          as Map<String, Object?>;
  Future<Map<String, Object?>> call(String operation) async =>
      copyStructuredBridgeData(
            await (runtime.executeLib(_library, operation, [
                      $String(_payload()),
                      if (operation == 'start' || operation == 'lookupRun')
                        $String('entry-submission'),
                      if (operation == 'start') 1,
                    ])
                    as $Future)
                .$value,
          )
          as Map<String, Object?>;
}

final class _FailingTools implements ModelToolContribution {
  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async =>
      throw StateError('Tools unavailable before strategy materialization.');
}

final class _RuntimeCapture implements PreparedFrontendBridge {
  late Runtime runtime;
  @override
  String get identifier => 'test.feedback.runtime-capture';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) => this.runtime = runtime;
  @override
  void invalidate() {}
}

final class _Target implements SessionFeedbackTarget {
  _Target(this.session);
  final Session session;
  final records = <String, SessionFeedbackRecord>{};
  final accepted = <SessionFeedbackSubmission>[];
  final lookedUp = <String>[];
  Future<SessionFeedbackReceipt> Function(SessionFeedbackSubmission)? onAccept;
  Future<SessionFeedbackRecord?> Function(String)? onLookup;

  SessionFeedbackRecord store(
    SessionFeedbackSubmission submission, {
    String? runId,
  }) => records[submission.submissionId] = SessionFeedbackRecord(
    receipt: SessionFeedbackReceipt(
      sessionId: session.id.value,
      submissionId: submission.submissionId,
      occurrenceId: 'entry-${submission.submissionId}',
    ),
    submission: submission,
    runId: runId,
  );

  @override
  Future<SessionFeedbackReceipt> accept(SessionFeedbackSubmission submission) {
    accepted.add(submission);
    return onAccept?.call(submission) ??
        Future.value(store(submission).receipt);
  }

  @override
  Future<SessionFeedbackRecord?> lookup(String id) {
    lookedUp.add(id);
    return onLookup?.call(id) ?? Future.value(records[id]);
  }
}

final class _ProjectChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, projectProviderServicePrepareSourceId);
    return {
      'sourceLocation': payload['sourceLocation'],
      'databaseRelativePath': 'data.db',
    };
  }
}

final class _ModelChannel implements AdeleStreamChannel {
  int calls = 0;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls++;
    throw StateError('Feedback reads must not call a model.');
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    calls++;
    throw StateError('Feedback reads must not call a model.');
  }
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host, this.onStart);
  final OrchestrationExecutionHost host;
  final void Function() onStart;
  @override
  Future<void> start() async {
    onStart();
    host.start();
    host.complete();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      throw StateError('No approval.');
  @override
  Future<void> close() async {}
}

String _payload([String id = 'submission']) =>
    encodeSessionFeedbackSubmission(_submission(id: id));

SessionFeedbackSubmission _submission({
  String id = 'submission',
  String text = 'Review this line.',
}) => SessionFeedbackSubmission(
  submissionId: id,
  kind: SessionFeedbackKind.codeReview,
  comments: [
    SessionFeedbackComment(
      id: 'comment',
      text: text,
      version: 1,
      sequence: 1,
      anchor: SessionFeedbackAnchor(
        environmentId: 'environment',
        relativePath: 'lib/example.dart',
        layer: SessionFeedbackComparisonLayer.unstaged,
        side: SessionFeedbackComparisonSide.newSide,
        startLine: 1,
        endLine: 1,
        comparisonIdentity: 'comparison',
        sourceExcerpt: 'example\n',
        hunkIndex: 0,
        lineIndex: 0,
      ),
    ),
  ],
);

const _source = '''
import 'package:adele_ui/session_feedback_bridge.dart';
Map<String, Object?> availability() => readSessionFeedbackAvailability();
Future<Map<String, Object?>> accept(String payload) => acceptSessionFeedback(payload);
Future<Map<String, Object?>> lookup(String payload) => lookupSessionFeedback(payload);
Future<Map<String, Object?>> start(String payload, String occurrence, int attempt) =>
    startSessionFeedbackRun(payload, occurrence, attempt);
Future<Map<String, Object?>> lookupRun(String payload, String occurrence) =>
    lookupSessionFeedbackRun(payload, occurrence);
''';

const _paneSource = '''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/session_feedback_bridge.dart';
void initialize() { openMainContentPane('review', 'Review', false); }
Future<Map<String, Object?>> deliver(String payload) => acceptSessionFeedback(payload);
Widget build() {
  final availability = readSessionFeedbackAvailability();
  return Text(availability['available'] == true
      ? 'Canonical feedback available' : 'Feedback unavailable');
}
''';
