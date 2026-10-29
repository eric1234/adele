import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';

import '../core/product_lifecycle.dart';
import '../core/session_feedback_host.dart';
import '../ui/execution/session_execution_controller.dart';

/// One window's finite admissions survive pane replacement. This is not a queue:
/// it retains only the current delivery and scheduling attempt per Session.
final class SessionFeedbackAdmissions {
  final Map<Session, _DeliveryAttempt> _deliveries = Map.identity();
  final Map<Session, _SchedulingAttempt> _scheduling = Map.identity();
}

final class SessionFeedbackPresentationSource {
  SessionFeedbackPresentationSource({
    required this.session,
    required this.lifecycle,
    required this.admissions,
    required this.controllerForSession,
    required this.lookupControllerForSession,
    required this.validateAttachment,
  });

  final Session session;
  final ProductLifecycleCoordinator lifecycle;
  final SessionFeedbackAdmissions admissions;
  final SessionExecutionController Function() controllerForSession;
  final SessionExecutionController? Function() lookupControllerForSession;
  final void Function() validateAttachment;
  CapturedSessionFeedbackTarget? _target;
  bool _active = true;

  bool get isActive {
    try {
      _validate();
      return true;
    } on Object {
      return false;
    }
  }

  void invalidate() => _active = false;

  void _validate() {
    if (!_active) throw StateError('Feedback presentation is retired.');
    validateAttachment();
    lifecycle.validateSessionInput(session);
  }

  CapturedSessionFeedbackTarget _capture({bool reconcile = false}) {
    _validate();
    if (lifecycle.databaseForSession(session.id) == null) {
      throw const SessionFeedbackFailure(
        code: 'durable_storage_required',
        message: 'Open a durable Project to submit a review.',
      );
    }
    // Only a new explicit reconciliation may discover a replacement. An admitted
    // operation holds its local target through every asynchronous boundary.
    if (_target == null || reconcile) {
      _target = CapturedSessionFeedbackTarget.capture(
        lifecycle: lifecycle,
        session: session,
        validateAttachment: _validate,
      );
    }
    _target!.validate();
    return _target!;
  }

  SessionExecutionController _controller() {
    final owner = controllerForSession();
    if (!identical(owner.session, session)) {
      throw StateError('Execution belongs to another canonical Session.');
    }
    return owner;
  }

  Map<String, Object?> readAvailability() {
    try {
      _capture();
      final controller = _controller();
      final busy =
          controller.isRunning ||
          controller.isAdvancing ||
          lifecycle.hasSessionExecution(session);
      return {
        'available': true,
        'canStart': !busy && controller.canStart,
        'reason': busy
            ? 'The Session already has an active or waiting Run.'
            : controller.unavailableReason,
      };
    } on SessionFeedbackFailure catch (error) {
      return {'available': false, 'canStart': false, 'reason': error.message};
    } on Object {
      return const {
        'available': false,
        'canStart': false,
        'reason': 'Session feedback is unavailable. Reopen Diff to reconnect.',
      };
    }
  }

  SessionFeedbackSubmission _decode(String payload) {
    final submission = decodeSessionFeedbackSubmission(payload);
    if (encodeSessionFeedbackSubmission(submission) != payload) {
      throw const SessionFeedbackFailure(
        code: 'invalid_submission',
        message: 'The prepared review payload is not canonical.',
      );
    }
    return submission;
  }

  void _changed() => lookupControllerForSession()?.notifySessionStateChanged();

  Map<String, Object?> _accepted(SessionFeedbackRecord record) => {
    'status': 'accepted',
    'sessionId': record.receipt.sessionId,
    'submissionId': record.receipt.submissionId,
    'occurrenceId': record.receipt.occurrenceId,
    'runId': record.runId,
  };

  Future<SessionFeedbackRecord?> _lookup(
    CapturedSessionFeedbackTarget target,
    SessionFeedbackSubmission submission,
  ) async {
    final record = await target.lookup(submission.submissionId);
    if (record != null &&
        encodeSessionFeedbackSubmission(record.submission) !=
            encodeSessionFeedbackSubmission(submission)) {
      throw const SessionFeedbackFailure(
        code: 'submission_conflict',
        message: 'The accepted review differs from the frozen submission.',
      );
    }
    return record;
  }

  Future<Map<String, Object?>> accept(String payload) async {
    _DeliveryAttempt? attempt;
    var dispatched = false;
    try {
      final submission = _decode(payload);
      _validate();
      final previous = admissions._deliveries[session];
      if (previous?.pending ?? false) return _uncertain('delivery_pending');
      if (previous != null &&
          previous.payload == payload &&
          !previous.retryable) {
        // A lost acknowledgement is recovered by lookup, never replayed by a
        // second click, remount, or another window-local callback.
        return _uncertain('reconciliation_required');
      }
      attempt = _DeliveryAttempt(payload);
      admissions._deliveries[session] = attempt;
      final target = _capture();
      final controller = lookupControllerForSession();
      if ((controller?.isRunning ?? false) ||
          (controller?.isAdvancing ?? false)) {
        throw const SessionFeedbackFailure(
          code: 'session_busy',
          message: 'The Session already has an active or waiting Run.',
        );
      }
      dispatched = true;
      final receipt = await target.accept(submission);
      _changed();
      return _accepted(
        SessionFeedbackRecord(
          receipt: receipt,
          submission: submission,
          runId: null,
        ),
      );
    } on SessionFeedbackFailure catch (error) {
      final retryable = !dispatched || _definiteRejections.contains(error.code);
      if (attempt != null) attempt.retryable = retryable;
      return {
        'status': retryable ? 'unavailable' : 'uncertain',
        'code': error.code,
        'message': error.message,
        'retryAllowed': retryable,
      };
    } on Object {
      if (attempt != null) attempt.retryable = !dispatched;
      return _uncertain('delivery_unconfirmed');
    } finally {
      if (attempt != null) attempt.pending = false;
    }
  }

  Future<Map<String, Object?>> lookup(String payload) async {
    try {
      final submission = _decode(payload);
      final target = _capture(reconcile: true);
      final record = await _lookup(target, submission);
      if (record != null) {
        _changed();
        return _accepted(record);
      }
      final attempt = admissions._deliveries[session];
      return {
        'status': 'absent',
        'sessionId': session.id.value,
        'submissionId': submission.submissionId,
        // Absence alone proves neither rollback nor draining. Only a retained
        // definite rejection from this exact payload permits another attempt.
        'retryAllowed':
            attempt != null &&
            attempt.payload == payload &&
            !attempt.pending &&
            attempt.retryable,
        'message':
            'Acceptance is not confirmed. The prepared review is retained.',
      };
    } on SessionFeedbackFailure catch (error) {
      return {
        'status': 'uncertain',
        'code': error.code,
        'message': error.message,
      };
    } on Object {
      return _uncertain('lookup_failed');
    }
  }

  Future<Map<String, Object?>> startRun(
    String payload,
    String occurrenceId,
    int schedulingAttempt,
  ) async {
    try {
      _validate();
      _decode(payload);
      validateSessionFeedbackIdentity(occurrenceId);
    } on Object {
      return _uncertain('scheduling_presentation_unavailable');
    }
    if (schedulingAttempt < 1 || schedulingAttempt > 2147483647) {
      return _uncertain('invalid_scheduling_attempt');
    }
    final previous = admissions._scheduling[session];
    if (previous != null && previous.payload == payload) {
      if (previous.occurrenceId != occurrenceId ||
          schedulingAttempt < previous.attempt) {
        return _uncertain('scheduling_conflict');
      }
      if (schedulingAttempt == previous.attempt) return previous.result.future;
      if (!previous.result.isCompleted || !previous.retryable) {
        return _uncertain('scheduling_reconciliation_required');
      }
    } else if (previous != null && !previous.result.isCompleted) {
      return _uncertain('another_scheduling_operation');
    }
    final admission = _SchedulingAttempt(
      payload,
      occurrenceId,
      schedulingAttempt,
    );
    admissions._scheduling[session] = admission;
    final result = await _schedule(payload, occurrenceId);
    admission.retryable = result['status'] == 'not_started';
    admission.result.complete(result);
    return result;
  }

  Future<Map<String, Object?>> _schedule(
    String payload,
    String occurrenceId,
  ) async {
    SessionFeedbackRunAdmission? admission;
    SessionExecutionController? owner;
    SessionFeedbackReceipt? receipt;
    var calledStart = false;
    var confirmedUnassociated = false;
    try {
      final submission = _decode(payload);
      final target = _capture();
      final record = await _lookup(target, submission);
      if (record == null || record.receipt.occurrenceId != occurrenceId) {
        return _uncertain('acceptance_not_confirmed');
      }
      final controller = _controller();
      owner = controller;
      receipt = record.receipt;
      admission = controller.feedbackRunFor(record.receipt);
      final existing = _runResult(record, controller, admission);
      if (record.runId != null ||
          (admission != null &&
              admission.state !=
                  SessionFeedbackRunAdmissionState.failedBeforeAssociation)) {
        return existing;
      }
      confirmedUnassociated = true;
      _validate();
      target.validate();
      if (!controller.canStart || lifecycle.hasSessionExecution(session)) {
        return _notStarted(
          controller.unavailableReason ??
              'The Session already has an active or waiting Run.',
          receipt: record.receipt,
        );
      }
      calledStart = true;
      if (admission != null) {
        await controller.retryFeedbackRun(
          receipt: record.receipt,
          expectedStrategy: target.strategy,
        );
      } else {
        await controller.startRun(
          expectedStrategy: target.strategy,
          expectedFeedback: record.receipt,
        );
      }
      admission = controller.feedbackRunFor(record.receipt)!;
      await admission.preparationSettled;
      // The same target must confirm the association. A replacement is only
      // captured by an explicit later lookup, never this admitted continuation.
      final confirmed = await _lookup(target, submission);
      if (confirmed == null || confirmed.receipt.occurrenceId != occurrenceId) {
        return _uncertain('association_unconfirmed');
      }
      return _runResult(confirmed, controller, admission);
    } on Object {
      if (admission?.state ==
          SessionFeedbackRunAdmissionState.failedBeforeAssociation) {
        return _notStarted(
          'Run preparation failed before strategy materialization.',
          receipt: receipt,
        );
      }
      if (confirmedUnassociated &&
          (!calledStart ||
              (receipt != null && owner?.feedbackRunFor(receipt) == null))) {
        return _notStarted(
          'Review accepted. Run not started; retry when available.',
          receipt: receipt,
        );
      }
      return _uncertain('scheduling_unconfirmed');
    }
  }

  Future<Map<String, Object?>> lookupRun(
    String payload,
    String occurrenceId,
  ) async {
    try {
      final submission = _decode(payload);
      final target = _capture(reconcile: true);
      final record = await _lookup(target, submission);
      if (record == null || record.receipt.occurrenceId != occurrenceId) {
        return _uncertain('acceptance_not_confirmed');
      }
      final controller = lookupControllerForSession();
      final previous = admissions._scheduling[session];
      if (record.runId == null &&
          previous != null &&
          previous.payload == payload &&
          previous.occurrenceId == occurrenceId &&
          previous.retryable) {
        return previous.result.future;
      }
      return _runResult(
        record,
        controller,
        controller?.feedbackRunFor(record.receipt),
      );
    } on Object {
      return _uncertain('scheduling_lookup_failed');
    }
  }

  Map<String, Object?> _runResult(
    SessionFeedbackRecord record,
    SessionExecutionController? controller,
    SessionFeedbackRunAdmission? admission,
  ) {
    final runId = record.runId;
    if (runId != null) {
      if (admission != null &&
          admission.state !=
              SessionFeedbackRunAdmissionState.failedBeforeAssociation &&
          admission.runId.value != runId) {
        return _uncertain('run_association_conflict');
      }
      return {
        ..._accepted(record),
        'status': 'scheduled',
        'runId': runId,
        'runState':
            controller?.stateForRun(RunId(runId))?.name ??
            lifecycle.store.runRecord(RunId(runId))?.state.name ??
            'associated',
      };
    }
    if (admission?.state ==
        SessionFeedbackRunAdmissionState.failedBeforeAssociation) {
      return _notStarted(
        'Run preparation failed before strategy materialization.',
        receipt: record.receipt,
      );
    }
    return {
      ..._uncertain('association_unconfirmed'),
      'runId': admission?.runId.value,
      'runState': admission?.state.name,
    };
  }
}

final class _DeliveryAttempt {
  _DeliveryAttempt(this.payload);
  final String payload;
  bool pending = true;
  bool retryable = false;
}

final class _SchedulingAttempt {
  _SchedulingAttempt(this.payload, this.occurrenceId, this.attempt);
  final String payload;
  final String occurrenceId;
  final int attempt;
  final Completer<Map<String, Object?>> result = Completer();
  bool retryable = false;
}

const _definiteRejections = {
  'invalid_submission',
  'submission_too_large',
  'session_busy',
  'unsupported_strategy',
  'session_unavailable',
};

Map<String, Object?> _uncertain(String code) => {
  'status': 'uncertain',
  'code': code,
  'retryAllowed': false,
  'message':
      'Outcome unconfirmed. Reconcile the retained review before continuing.',
};

Map<String, Object?> _notStarted(
  String message, {
  SessionFeedbackReceipt? receipt,
}) => {
  'status': 'not_started',
  'retryAllowed': true,
  'message': message,
  if (receipt != null) ...{
    'sessionId': receipt.sessionId,
    'submissionId': receipt.submissionId,
    'occurrenceId': receipt.occurrenceId,
  },
};
