part of '../chat_strategy_backend.dart';

/// Exact-generation read access only: no Session hydration, schema creation,
/// acceptance, cache refresh, or execution authority is acquired by Inspection.
final class ChatFeedbackInspectionBackend
    implements ChatFeedbackInspectionService {
  ChatFeedbackInspectionBackend(this.storage);

  final ProjectStorageService? storage;

  @override
  Future<ChatAcceptedFeedback> readAcceptedFeedback(
    String sessionId,
    String occurrenceId,
  ) async {
    final SessionId id;
    try {
      validateSessionFeedbackIdentity(sessionId);
      validateSessionFeedbackIdentity(occurrenceId);
      id = SessionId(sessionId);
    } on Object {
      throw const ChatFeedbackInspectionFailure(
        code: 'invalid_request',
        message: 'The feedback Inspection request is invalid.',
        details: {},
      );
    }
    final SessionFeedbackRecord? record;
    try {
      final client = storage;
      if (client == null || !await client.isDurableSession(sessionId)) {
        throw StateError('Durable feedback storage is required.');
      }
      record = await _readAcceptedChatFeedback(
        client,
        id,
        occurrenceId: occurrenceId,
      );
    } on ChatStateCorruption {
      throw const ChatFeedbackInspectionFailure(
        code: 'corrupt',
        message: 'The accepted feedback is inconsistent or invalid.',
        details: {},
      );
    } on Object {
      throw const ChatFeedbackInspectionFailure(
        code: 'unavailable',
        message: 'Accepted feedback storage is unavailable.',
        details: {},
      );
    }
    if (record == null) {
      throw const ChatFeedbackInspectionFailure(
        code: 'not_found',
        message: 'No accepted feedback exists for this occurrence.',
        details: {},
      );
    }
    return ChatAcceptedFeedback(
      sessionId: record.receipt.sessionId,
      occurrenceId: record.receipt.occurrenceId,
      submissionId: record.submission.submissionId,
      kind: switch (record.submission.kind) {
        SessionFeedbackKind.codeReview => ChatFeedbackKind.codeReview,
      },
      comments: [
        for (final comment in record.submission.comments)
          ChatFeedbackComment(
            id: comment.id,
            anchor: ChatFeedbackAnchor(
              environmentId: comment.anchor.environmentId,
              relativePath: comment.anchor.relativePath,
              layer: switch (comment.anchor.layer) {
                SessionFeedbackComparisonLayer.unstaged =>
                  ChatFeedbackComparisonLayer.unstaged,
                SessionFeedbackComparisonLayer.staged =>
                  ChatFeedbackComparisonLayer.staged,
                SessionFeedbackComparisonLayer.committed =>
                  ChatFeedbackComparisonLayer.committed,
              },
              side: switch (comment.anchor.side) {
                SessionFeedbackComparisonSide.oldSide =>
                  ChatFeedbackComparisonSide.oldSide,
                SessionFeedbackComparisonSide.newSide =>
                  ChatFeedbackComparisonSide.newSide,
              },
              startLine: comment.anchor.startLine,
              endLine: comment.anchor.endLine,
              comparisonIdentity: comment.anchor.comparisonIdentity,
              sourceExcerpt: comment.anchor.sourceExcerpt,
              hunkIndex: comment.anchor.hunkIndex,
              lineIndex: comment.anchor.lineIndex,
            ),
            text: comment.text,
            version: comment.version,
            sequence: comment.sequence,
          ),
      ],
      runId: record.runId,
    );
  }
}

/// One read observes the immutable relationship and its current Run association
/// together. Both receipt lookup and Inspection validate the public canonical
/// payload and the actual user projection, never parse model-facing prose.
Future<SessionFeedbackRecord?> _readAcceptedChatFeedback(
  ProjectStorageService storage,
  SessionId id, {
  String? submissionId,
  String? occurrenceId,
}) async {
  assert((submissionId == null) != (occurrenceId == null));
  final rows = await storage.queryForSession(
    id.value,
    'SELECT f.session_id, f.submission_id, f.canonical_payload, f.entry_id, '
    'e.session_id AS entry_session_id, e.entry_id AS canonical_entry_id, '
    'e.sequence, e.role, e.content, e.run_id, '
    's.session_id AS chat_session_id, s.next_entry '
    'FROM adele_chat_feedback_submissions f '
    'LEFT JOIN adele_chat_entries e '
    'ON e.session_id = f.session_id AND e.entry_id = f.entry_id '
    'LEFT JOIN adele_chat_sessions s ON s.session_id = f.session_id '
    'WHERE f.session_id = :session AND '
    '${submissionId != null ? 'f.submission_id = :identity' : 'f.entry_id = :identity'} '
    'LIMIT 2',
    {':session': id.value, ':identity': submissionId ?? occurrenceId},
    ProjectStorageAccessMode.durable,
  );
  if (rows.isEmpty) return null;
  try {
    if (rows.length != 1) throw const FormatException();
    final row = rows.single.values;
    _requireReadableRow(row);
    final payload = row['canonical_payload'];
    final entryId = row['entry_id'];
    final sequence = row['sequence'];
    final counter = row['next_entry'];
    final runId = row['run_id'];
    if (row['session_id'] != id.value ||
        row['entry_session_id'] != id.value ||
        row['chat_session_id'] != id.value ||
        payload is! String ||
        entryId is! String ||
        row['canonical_entry_id'] != entryId ||
        (occurrenceId != null && occurrenceId != entryId) ||
        (submissionId != null && row['submission_id'] != submissionId) ||
        sequence is! int ||
        sequence < 0 ||
        counter is! int ||
        counter <= sequence ||
        entryId != 'entry-$sequence' ||
        row['role'] != 'user' ||
        (runId != null && runId is! String)) {
      throw const FormatException();
    }
    final submission = decodeSessionFeedbackSubmission(payload);
    if (submission.submissionId != row['submission_id'] ||
        encodeSessionFeedbackSubmission(submission) != payload ||
        row['content'] != renderChatSessionFeedback(submission)) {
      throw const FormatException();
    }
    if (runId is String) RunId(runId);
    return SessionFeedbackRecord(
      receipt: SessionFeedbackReceipt(
        submissionId: submission.submissionId,
        sessionId: id.value,
        occurrenceId: entryId,
      ),
      submission: submission,
      runId: runId as String?,
    );
  } on Object {
    throw ChatStateCorruption(id, 'Invalid accepted feedback relationship.');
  }
}

Future<ChatEntryFeedback?> _readChatEntryFeedback(
  ProjectStorageService storage,
  SessionId id,
  String entryId,
  String role,
) async {
  // Keep this narrow query separate from the canonical content row so metadata
  // cannot make an already accepted maximum-size ordinary entry unreadable.
  // CASE guards every JSON operation, including malformed retained JSON.
  final rows = await storage.queryForSession(
    id.value,
    'SELECT session_id, entry_id, submission_id, '
    'CASE WHEN json_valid(canonical_payload) THEN '
    r"CASE WHEN json_type(canonical_payload, '$.submissionId') = 'text' "
    r"THEN json_extract(canonical_payload, '$.submissionId') END END AS payload_id, "
    'CASE WHEN json_valid(canonical_payload) THEN '
    r"CASE WHEN json_type(canonical_payload, '$.kind') = 'text' "
    r"THEN json_extract(canonical_payload, '$.kind') END END AS kind, "
    'CASE WHEN json_valid(canonical_payload) THEN '
    r"CASE WHEN json_type(canonical_payload, '$.comments') = 'array' "
    r"THEN json_array_length(canonical_payload, '$.comments') END END AS comment_count "
    'FROM adele_chat_feedback_submissions '
    'WHERE session_id = :session AND entry_id = :entry LIMIT 2',
    {':session': id.value, ':entry': entryId},
    ProjectStorageAccessMode.durable,
  );
  if (rows.isEmpty) return null;
  try {
    if (rows.length != 1) throw const FormatException();
    final row = rows.single.values;
    final submissionId = row['submission_id'];
    final count = row['comment_count'];
    if (role != 'user' ||
        row['session_id'] != id.value ||
        row['entry_id'] != entryId ||
        submissionId is! String ||
        row['payload_id'] != submissionId ||
        row['kind'] != SessionFeedbackKind.codeReview.name ||
        count is! int ||
        count < 1 ||
        count > SessionFeedbackLimits.maxComments) {
      throw const FormatException();
    }
    validateSessionFeedbackIdentity(submissionId);
    return ChatEntryFeedback(
      kind: ChatFeedbackKind.codeReview,
      submissionId: submissionId,
      commentCount: count,
    );
  } on Object {
    throw ChatStateCorruption(id, 'Invalid accepted feedback metadata.');
  }
}
