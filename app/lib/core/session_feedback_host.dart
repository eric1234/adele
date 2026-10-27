import 'package:adele_orchestration/adele_orchestration.dart';

import 'product_lifecycle.dart';

/// A native request target bound synchronously to one canonical Session and exact
/// strategy registration. It never materializes execution or selects a replacement.
final class CapturedSessionFeedbackTarget implements SessionFeedbackTarget {
  factory CapturedSessionFeedbackTarget.capture({
    required ProductLifecycleCoordinator lifecycle,
    required Session session,
    void Function()? validateAttachment,
  }) {
    _validateSession(lifecycle, session, validateAttachment);
    final ResolvedOrchestrationStrategy strategy;
    try {
      strategy = lifecycle.resolveSessionStrategy(session.id);
    } on OrchestrationStrategyUnavailable {
      throw const SessionFeedbackFailure(
        code: 'missing_target',
        message: 'The Session feedback strategy is unavailable.',
      );
    } on AmbiguousOrchestrationStrategy {
      throw const SessionFeedbackFailure(
        code: 'ambiguous_target',
        message: 'The Session feedback strategy is ambiguous.',
      );
    }
    final factory = strategy.contribution.feedbackTarget;
    if (factory == null) {
      throw const SessionFeedbackFailure(
        code: 'unsupported_strategy',
        message: 'The Session strategy does not accept feedback.',
      );
    }
    final captured = CapturedSessionFeedbackTarget._(
      lifecycle,
      session,
      strategy,
      factory(session),
      validateAttachment,
    );
    // A native factory may synchronously retire its registration or attachment.
    captured._validate();
    return captured;
  }

  CapturedSessionFeedbackTarget._(
    this._lifecycle,
    this._session,
    this._strategy,
    this._target,
    this._validateAttachment,
  );

  final ProductLifecycleCoordinator _lifecycle;
  final Session _session;
  final ResolvedOrchestrationStrategy _strategy;
  final SessionFeedbackTarget _target;

  /// Trusted caller fence, not plugin-supplied authority or a target selector.
  final void Function()? _validateAttachment;

  static void _validateSession(
    ProductLifecycleCoordinator lifecycle,
    Session session,
    void Function()? validateAttachment,
  ) {
    try {
      validateAttachment?.call();
      lifecycle.validateSessionInput(session);
    } on SessionFeedbackFailure {
      rethrow;
    } on Object {
      throw _staleTarget;
    }
  }

  void _validate() {
    _validateSession(_lifecycle, _session, _validateAttachment);
    try {
      _lifecycle.validateResolvedStrategy(_session.strategyId, _strategy);
    } on Object {
      throw _staleTarget;
    }
  }

  @override
  Future<SessionFeedbackReceipt> accept(
    SessionFeedbackSubmission submission,
  ) async {
    _validate();
    if (_lifecycle.hasSessionExecution(_session)) {
      // Backend replacement loses its local claim, not the host Run's ownership.
      // Reconciliation remains read-only even when that Run is still waiting.
      final accepted = await lookup(submission.submissionId);
      if (accepted == null) {
        throw const SessionFeedbackFailure(
          code: 'session_busy',
          message: 'The Session still owns an execution.',
        );
      }
      if (encodeSessionFeedbackSubmission(accepted.submission) !=
          encodeSessionFeedbackSubmission(submission)) {
        throw const SessionFeedbackFailure(
          code: 'submission_conflict',
          message: 'This submission identity already has different feedback.',
        );
      }
      return accepted.receipt;
    }
    final SessionFeedbackReceipt receipt;
    try {
      receipt = await _target.accept(submission);
    } on SessionFeedbackFailure catch (error) {
      if (_knownFailures.contains(error.code)) rethrow;
      throw _outcomeUncertain;
    } on Object {
      // Dispatch may already have committed. Never replay or claim rejection.
      throw _outcomeUncertain;
    }
    try {
      _validate();
    } on Object {
      throw _outcomeUncertain;
    }
    if (receipt.sessionId != _session.id.value ||
        receipt.submissionId != submission.submissionId) {
      throw _outcomeUncertain;
    }
    return receipt;
  }

  @override
  Future<SessionFeedbackRecord?> lookup(String submissionId) async {
    _validate();
    validateSessionFeedbackIdentity(submissionId);
    final SessionFeedbackRecord? record;
    try {
      record = await _target.lookup(submissionId);
    } on SessionFeedbackFailure catch (error) {
      _validate();
      if (_knownFailures.contains(error.code)) rethrow;
      throw _storageFailure;
    } on Object {
      _validate();
      throw _storageFailure;
    }
    _validate();
    if (record != null &&
        (record.receipt.sessionId != _session.id.value ||
            record.receipt.submissionId != submissionId ||
            record.submission.submissionId != submissionId)) {
      throw _storageFailure;
    }
    return record;
  }
}

const _staleTarget = SessionFeedbackFailure(
  code: 'stale_target',
  message: 'The captured Session feedback target is no longer available.',
);
const _outcomeUncertain = SessionFeedbackFailure(
  code: 'outcome_uncertain',
  message:
      'Session feedback may have been accepted. Look up its submission ID.',
);
const _storageFailure = SessionFeedbackFailure(
  code: 'storage_failure',
  message: 'The accepted Session feedback record could not be read.',
);
const _knownFailures = {
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
};
