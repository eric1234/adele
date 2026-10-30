import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/session_feedback_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host occupancy only reconciles and releases each owner once', () async {
    final fixture = _Fixture();
    final target = fixture.capture();
    final submission = _submission();
    final receipt = await target.accept(submission);
    final releaseA = fixture.lifecycle.retainSessionExecution(fixture.session);
    final releaseB = fixture.lifecycle.retainSessionExecution(fixture.session);
    expect((await target.accept(submission)), same(receipt));
    final comment = submission.comments.single;
    final conflicting = SessionFeedbackSubmission(
      submissionId: submission.submissionId,
      kind: submission.kind,
      comments: [
        SessionFeedbackComment(
          id: comment.id,
          anchor: comment.anchor,
          text: comment.text,
          version: comment.version + 1,
          sequence: comment.sequence,
        ),
      ],
    );
    await expectLater(
      target.accept(conflicting),
      throwsA(_failure('submission_conflict')),
    );
    await expectLater(
      target.accept(_submission('new')),
      throwsA(_failure('session_busy')),
    );
    expect(
      (await target.lookup(submission.submissionId))!.receipt,
      same(receipt),
    );
    expect(fixture.target.accepted, [same(submission)]);
    releaseA();
    releaseA();
    expect(fixture.lifecycle.hasSessionExecution(fixture.session), isTrue);
    releaseB();
    expect(fixture.lifecycle.hasSessionExecution(fixture.session), isFalse);
    await target.accept(_submission('new'));
    expect(fixture.target.accepted, hasLength(2));
  });

  test(
    'busy reconciliation failure never admits a mutation or claims absence',
    () async {
      final fixture = _Fixture();
      final release = fixture.lifecycle.retainSessionExecution(fixture.session);
      addTearDown(release);
      fixture.target.onLookup = (_) =>
          Future.error(StateError('private storage error'));
      await expectLater(
        fixture.capture().accept(_submission()),
        throwsA(_failure('storage_failure')),
      );
      expect(fixture.target.accepted, isEmpty);
      expect(fixture.target.lookedUp, ['submission']);
    },
  );

  test(
    'capture and lookup use canonical Session without any execution',
    () async {
      final fixture = _Fixture();
      final target = fixture.capture();
      expect(fixture.capturedSessions, [same(fixture.session)]);
      expect(fixture.target.accepted, isEmpty);
      expect(fixture.target.lookedUp, isEmpty);
      expect(fixture.materializations, 0);
      final submission = _submission();
      final receipt = await target.accept(submission);
      expect(receipt.sessionId, fixture.session.id.value);
      expect(receipt.submissionId, submission.submissionId);
      final record = await target.lookup(submission.submissionId);
      expect(record!.receipt, same(receipt));
      expect(record.submission, same(submission));
      expect(await target.lookup('not-accepted'), isNull);
      expect(fixture.capturedSessions, hasLength(1));
      expect(fixture.materializations, 0);
      expect(fixture.providerResolutions, 0);
      expect(
        fixture.lifecycle.environmentRuntime.currentMaterialization(
          fixture.environment.id,
        ),
        isNull,
      );
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      expect(
        fixture.lifecycle.runActivitiesForSession(fixture.session.id),
        isEmpty,
      );
    },
  );

  test('lookalike and unknown Sessions fail before the target factory', () {
    final fixture = _Fixture();
    for (final id in [fixture.session.id, SessionId('unknown')]) {
      final clone = Session(
        id: id,
        taskId: fixture.session.taskId,
        strategyId: fixture.session.strategyId,
      );
      expect(
        () => fixture.lifecycle.validateSessionInput(clone),
        throwsArgumentError,
      );
      expect(
        () => fixture.capture(session: clone),
        throwsA(_failure('stale_target')),
      );
    }
    expect(fixture.capturedSessions, isEmpty);
  });

  test('missing strategy does not use an unrelated opted-in target', () {
    final fixture = _Fixture(register: false);
    fixture.register(
      id: 'other',
      contribution: OrchestrationStrategyContribution(
        strategyId: OrchestrationStrategyId('test.other'),
        materialize: (_) => throw StateError('Must not materialize.'),
        feedbackTarget: (_) => throw StateError('Must not select.'),
      ),
    );
    expect(fixture.capture, throwsA(_failure('missing_target')));
    expect(fixture.capturedSessions, isEmpty);
  });

  test('a resolved strategy without opt-in is unsupported', () {
    final fixture = _Fixture(register: false);
    fixture.register(
      contribution: OrchestrationStrategyContribution(
        strategyId: fixture.session.strategyId,
        materialize: (_) => throw StateError('Must not materialize.'),
      ),
    );
    expect(fixture.capture, throwsA(_failure('unsupported_strategy')));
    expect(fixture.capturedSessions, isEmpty);
  });

  test('multiple matching strategies are ambiguous before checking opt-in', () {
    final fixture = _Fixture();
    fixture.register(
      id: 'duplicate',
      contribution: OrchestrationStrategyContribution(
        strategyId: fixture.session.strategyId,
        materialize: (_) => throw StateError('Must not materialize.'),
      ),
    );
    expect(fixture.capture, throwsA(_failure('ambiguous_target')));
    expect(fixture.capturedSessions, isEmpty);
  });

  test(
    'a later ambiguity fences the retained target without rediscovery',
    () async {
      final fixture = _Fixture();
      final target = fixture.capture();
      fixture.register(id: 'duplicate');
      await expectLater(
        target.accept(_submission()),
        throwsA(_failure('stale_target')),
      );
      await expectLater(
        target.lookup('submission'),
        throwsA(_failure('stale_target')),
      );
      expect(fixture.target.accepted, isEmpty);
      expect(fixture.target.lookedUp, isEmpty);
      expect(fixture.capturedSessions, hasLength(1));
    },
  );

  test(
    'same contribution re-registration cannot replace an exact capture',
    () async {
      final fixture = _Fixture();
      final target = fixture.capture();
      await fixture.registration!.close();
      fixture.register();
      await expectLater(
        target.accept(_submission()),
        throwsA(_failure('stale_target')),
      );
      await expectLater(
        target.lookup('submission'),
        throwsA(_failure('stale_target')),
      );
      expect(fixture.target.accepted, isEmpty);
      final fresh = fixture.capture();
      await fresh.accept(_submission());
      expect(fixture.capturedSessions, hasLength(2));
      expect(fixture.target.accepted, hasLength(1));
    },
  );

  test(
    'lifecycle close fences new captures and previously captured inputs',
    () async {
      final fixture = _Fixture();
      final target = fixture.capture();
      final closing = fixture.lifecycle.close();
      expect(
        () => fixture.lifecycle.validateSessionInput(fixture.session),
        throwsStateError,
      );
      expect(fixture.capture, throwsA(_failure('stale_target')));
      await expectLater(
        target.accept(_submission()),
        throwsA(_failure('stale_target')),
      );
      await expectLater(
        target.lookup('submission'),
        throwsA(_failure('stale_target')),
      );
      await closing;
      expect(fixture.store.session(fixture.session.id), same(fixture.session));
      expect(fixture.target.accepted, isEmpty);
    },
  );

  for (final revoke in ['lifecycle', 'registration', 'attachment']) {
    test('factory-side $revoke revocation rejects capture synchronously', () {
      final fixture = _Fixture(register: false);
      var attached = true;
      late ExtensionRegistration registration;
      registration = fixture.register(
        contribution: OrchestrationStrategyContribution(
          strategyId: fixture.session.strategyId,
          materialize: (_) => throw StateError('Must not materialize.'),
          feedbackTarget: (_) {
            switch (revoke) {
              case 'lifecycle':
                unawaited(fixture.lifecycle.close());
              case 'registration':
                unawaited(registration.close());
              case 'attachment':
                attached = false;
            }
            return fixture.target;
          },
        ),
      );
      expect(
        () => fixture.capture(
          validateAttachment: () {
            if (!attached) throw StateError('Detached.');
          },
        ),
        throwsA(_failure('stale_target')),
      );
      expect(fixture.target.accepted, isEmpty);
    });
  }

  test(
    'attachment revocation blocks initial capture and later dispatch',
    () async {
      final fixture = _Fixture();
      var attached = false;
      void validateAttachment() {
        if (!attached) throw StateError('Detached.');
      }

      expect(
        () => fixture.capture(validateAttachment: validateAttachment),
        throwsA(_failure('stale_target')),
      );
      expect(fixture.capturedSessions, isEmpty);
      attached = true;
      final target = fixture.capture(validateAttachment: validateAttachment);
      attached = false;
      await expectLater(
        target.accept(_submission()),
        throwsA(_failure('stale_target')),
      );
      await expectLater(
        target.lookup('submission'),
        throwsA(_failure('stale_target')),
      );
      expect(fixture.target.accepted, isEmpty);
      expect(fixture.target.lookedUp, isEmpty);
    },
  );

  test(
    'trusted typed admission rejection is preserved before dispatch',
    () async {
      final fixture = _Fixture();
      const busy = SessionFeedbackFailure(
        code: 'session_busy',
        message: 'Busy.',
      );
      var busyNow = false;
      final target = fixture.capture(
        validateAttachment: () {
          if (busyNow) throw busy;
        },
      );
      busyNow = true;
      await expectLater(target.accept(_submission()), throwsA(same(busy)));
      expect(fixture.target.accepted, isEmpty);
    },
  );

  for (final revoke in ['lifecycle', 'registration', 'attachment']) {
    test(
      '$revoke revocation during acceptance is uncertain without retry',
      () async {
        final fixture = _Fixture();
        var attached = true;
        final target = fixture.capture(
          validateAttachment: () {
            if (!attached) throw StateError('Detached.');
          },
        );
        final gate = Completer<SessionFeedbackReceipt>();
        fixture.target.onAccept = (_) => gate.future;
        final submission = _submission();
        final pending = expectLater(
          target.accept(submission),
          throwsA(_failure('outcome_uncertain')),
        );
        expect(fixture.target.accepted, hasLength(1));
        switch (revoke) {
          case 'lifecycle':
            await fixture.lifecycle.close();
          case 'registration':
            await fixture.registration!.close();
            fixture.register();
          case 'attachment':
            attached = false;
        }
        gate.complete(_receipt(fixture.session, submission));
        await pending;
        expect(fixture.target.accepted, hasLength(1));
        expect(fixture.capturedSessions, hasLength(1));
      },
    );
  }

  test(
    'accepted acknowledgement remains a value after later retirement',
    () async {
      final fixture = _Fixture();
      final receipt = await fixture.capture().accept(_submission());
      await fixture.registration!.close();
      expect(receipt.occurrenceId, 'entry');
      expect(receipt.sessionId, fixture.session.id.value);
    },
  );

  for (final code in [
    'invalid_submission',
    'unsupported_strategy',
    'missing_target',
    'ambiguous_target',
    'session_busy',
    'submission_conflict',
    'submission_too_large',
    'stale_target',
    'storage_failure',
    'outcome_uncertain',
    'session_unavailable',
  ]) {
    test(
      'known target failure $code is preserved even after retirement',
      () async {
        final fixture = _Fixture();
        final failure = SessionFeedbackFailure(
          code: code,
          message: 'Rejected.',
        );
        final target = fixture.capture();
        fixture.target.onAccept = (_) async {
          await fixture.registration!.close();
          throw failure;
        };
        await expectLater(target.accept(_submission()), throwsA(same(failure)));
        expect(fixture.target.accepted, hasLength(1));
      },
    );
  }

  for (final error in [
    StateError('Unknown transport outcome.'),
    const SessionFeedbackFailure(code: 'unknown_failure', message: 'Unknown.'),
  ]) {
    test(
      'unrecognized mutation failure is uncertain: ${error.runtimeType}',
      () async {
        final fixture = _Fixture();
        fixture.target.onAccept = (_) => throw error;
        await expectLater(
          fixture.capture().accept(_submission()),
          throwsA(_failure('outcome_uncertain')),
        );
        expect(fixture.target.accepted, hasLength(1));
      },
    );
  }

  for (final foreign in ['session', 'submission']) {
    test('foreign $foreign acknowledgement is uncertain', () async {
      final fixture = _Fixture();
      fixture.target.onAccept = (submission) async => SessionFeedbackReceipt(
        submissionId: foreign == 'submission'
            ? 'other'
            : submission.submissionId,
        sessionId: foreign == 'session' ? 'other' : fixture.session.id.value,
        occurrenceId: 'entry',
      );
      await expectLater(
        fixture.capture().accept(_submission()),
        throwsA(_failure('outcome_uncertain')),
      );
      expect(fixture.target.accepted, hasLength(1));
    });
  }

  test('lookup rejects invalid ID before consulting target', () async {
    final fixture = _Fixture();
    await expectLater(
      fixture.capture().lookup(' '),
      throwsA(_failure('invalid_submission')),
    );
    expect(fixture.target.lookedUp, isEmpty);
  });

  test(
    'lookup failure is storage failure, never authoritative absence',
    () async {
      final fixture = _Fixture();
      final target = fixture.capture();
      fixture.target.onLookup = (_) => throw StateError('Read failed.');
      await expectLater(
        target.lookup('submission'),
        throwsA(_failure('storage_failure')),
      );
      const failure = SessionFeedbackFailure(
        code: 'storage_failure',
        message: 'Corrupt.',
      );
      fixture.target.onLookup = (_) => throw failure;
      await expectLater(target.lookup('submission'), throwsA(same(failure)));
      expect(fixture.target.lookedUp, hasLength(2));
    },
  );

  for (final foreign in ['session', 'submission']) {
    test('lookup validates $foreign receipt identity', () async {
      final fixture = _Fixture();
      final submission = _submission(
        foreign == 'submission' ? 'other' : 'submission',
      );
      fixture.target.onLookup = (_) async => SessionFeedbackRecord(
        receipt: SessionFeedbackReceipt(
          submissionId: submission.submissionId,
          sessionId: foreign == 'session' ? 'other' : fixture.session.id.value,
          occurrenceId: 'entry',
        ),
        submission: submission,
        runId: null,
      );
      await expectLater(
        fixture.capture().lookup('submission'),
        throwsA(_failure('storage_failure')),
      );
    });
  }

  for (final result in ['absent', 'present', 'failure']) {
    test('retired lookup with $result result cannot report absence', () async {
      final fixture = _Fixture();
      final target = fixture.capture();
      final gate = Completer<SessionFeedbackRecord?>();
      fixture.target.onLookup = (_) => gate.future;
      final pending = expectLater(
        target.lookup('submission'),
        throwsA(_failure('stale_target')),
      );
      await fixture.registration!.close();
      fixture.register();
      switch (result) {
        case 'absent':
          gate.complete(null);
        case 'present':
          final submission = _submission();
          gate.complete(
            SessionFeedbackRecord(
              receipt: _receipt(fixture.session, submission),
              submission: submission,
              runId: null,
            ),
          );
        case 'failure':
          gate.completeError(StateError('Transport retired.'));
      }
      await pending;
      expect(fixture.target.lookedUp, ['submission']);
      expect(fixture.capturedSessions, hasLength(1));
    });
  }
}

Matcher _failure(String code) =>
    isA<SessionFeedbackFailure>().having((error) => error.code, 'code', code);

SessionFeedbackSubmission _submission([String id = 'submission']) =>
    SessionFeedbackSubmission(
      submissionId: id,
      kind: SessionFeedbackKind.codeReview,
      comments: [
        SessionFeedbackComment(
          id: 'comment',
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
          text: 'Review this line.',
          version: 1,
          sequence: 1,
        ),
      ],
    );

SessionFeedbackReceipt _receipt(
  Session session,
  SessionFeedbackSubmission submission,
) => SessionFeedbackReceipt(
  submissionId: submission.submissionId,
  sessionId: session.id.value,
  occurrenceId: 'entry',
);

final class _Fixture {
  _Fixture({bool register = true}) {
    store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [environment],
      sessions: [session],
      authorities: [(session.id, environment.id)],
      runRecords: const [],
    );
    lifecycle = ProductLifecycleCoordinator(
      store: store,
      registry: CapabilityRegistry(),
      extensions: extensions,
      ids: MonotonicProductIdSource(seed: 'feedback'),
      providerForBinding: (_) {
        providerResolutions++;
        throw StateError('Feedback must not resolve an Environment provider.');
      },
    );
    addTearDown(lifecycle.close);
    target = _Target(session);
    contribution = OrchestrationStrategyContribution(
      strategyId: session.strategyId,
      materialize: (_) {
        materializations++;
        throw StateError('Feedback must not materialize a Run.');
      },
      feedbackTarget: (canonical) {
        capturedSessions.add(canonical);
        return target;
      },
    );
    if (register) registration = this.register();
  }

  final store = InMemoryProductStore();
  final extensions = ExtensionRegistry();
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///fixture'),
  );
  final task = Task(
    id: TaskId('task'),
    projectId: ProjectId('project'),
    title: 'Feedback',
  );
  final environment = Environment(
    id: EnvironmentId('environment'),
    taskId: TaskId('task'),
    role: EnvironmentRole.primary,
    providerId: ProviderId('test.environment'),
    providerState: const {},
  );
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.strategy'),
  );
  final capturedSessions = <Session>[];
  late final ProductLifecycleCoordinator lifecycle;
  late final OrchestrationStrategyContribution contribution;
  late final _Target target;
  ExtensionRegistration? registration;
  int materializations = 0;
  int providerResolutions = 0;

  ExtensionRegistration register({
    String id = 'strategy',
    OrchestrationStrategyContribution? contribution,
  }) {
    final registration = extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('test.feedback.$id'),
      value: contribution ?? this.contribution,
    );
    addTearDown(registration.close);
    return registration;
  }

  CapturedSessionFeedbackTarget capture({
    Session? session,
    void Function()? validateAttachment,
  }) => CapturedSessionFeedbackTarget.capture(
    lifecycle: lifecycle,
    session: session ?? this.session,
    validateAttachment: validateAttachment,
  );
}

final class _Target implements SessionFeedbackTarget {
  _Target(this.session);

  final Session session;
  final accepted = <SessionFeedbackSubmission>[];
  final lookedUp = <String>[];
  final records = <String, SessionFeedbackRecord>{};
  Future<SessionFeedbackReceipt> Function(SessionFeedbackSubmission)? onAccept;
  Future<SessionFeedbackRecord?> Function(String)? onLookup;

  @override
  Future<SessionFeedbackReceipt> accept(SessionFeedbackSubmission submission) {
    accepted.add(submission);
    if (onAccept case final callback?) return callback(submission);
    final record = SessionFeedbackRecord(
      receipt: _receipt(session, submission),
      submission: submission,
      runId: null,
    );
    records[submission.submissionId] = record;
    return Future.value(record.receipt);
  }

  @override
  Future<SessionFeedbackRecord?> lookup(String submissionId) {
    lookedUp.add(submissionId);
    return onLookup?.call(submissionId) ?? Future.value(records[submissionId]);
  }
}
