/// Public canonical Chat snapshots and typed backend service.
library;

import 'package:adele_contract/adele_contract.dart';

export 'src/identities.dart';

part 'chat_strategy_contract.g.dart';

/// An immutable canonical occurrence, not a model/tool activity item.
/// [id] is the wire form of ChatEntryId, scoped to its Session.
@AdeleValue('chat.entry')
final class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.role,
    required this.content,
    required this.runId,
    required this.feedback,
  });

  final String id;
  final String role;
  final String content;

  /// The Run associated with this user occurrence, or null before scheduling.
  /// Assistant entries never carry a Run association.
  final String? runId;

  /// Authoritative accepted-feedback relationship, never inferred from content.
  final ChatEntryFeedback? feedback;
}

enum ChatFeedbackKind { codeReview }

enum ChatFeedbackComparisonLayer { unstaged, staged, committed }

enum ChatFeedbackComparisonSide { oldSide, newSide }

@AdeleValue('chat.entryFeedback')
final class ChatEntryFeedback {
  const ChatEntryFeedback({
    required this.kind,
    required this.submissionId,
    required this.commentCount,
  });

  final ChatFeedbackKind kind;
  final String submissionId;
  final int commentCount;
}

/// Read-only transport projection of the public Session feedback semantics.
/// The public codec remains the source of canonical storage validation.
@AdeleValue('chat.acceptedFeedback')
final class ChatAcceptedFeedback {
  ChatAcceptedFeedback({
    required this.sessionId,
    required this.occurrenceId,
    required this.submissionId,
    required this.kind,
    required List<ChatFeedbackComment> comments,
    required this.runId,
  }) : comments = List<ChatFeedbackComment>.unmodifiable(comments);

  final String sessionId;
  final String occurrenceId;
  final String submissionId;
  final ChatFeedbackKind kind;
  final List<ChatFeedbackComment> comments;
  final String? runId;
}

@AdeleValue('chat.feedbackComment')
final class ChatFeedbackComment {
  const ChatFeedbackComment({
    required this.id,
    required this.anchor,
    required this.text,
    required this.version,
    required this.sequence,
  });

  final String id;
  final ChatFeedbackAnchor anchor;
  final String text;
  final int version;
  final int sequence;
}

@AdeleValue('chat.feedbackAnchor')
final class ChatFeedbackAnchor {
  const ChatFeedbackAnchor({
    required this.environmentId,
    required this.relativePath,
    required this.layer,
    required this.side,
    required this.startLine,
    required this.endLine,
    required this.comparisonIdentity,
    required this.sourceExcerpt,
    required this.hunkIndex,
    required this.lineIndex,
  });

  final String environmentId;
  final String relativePath;
  final ChatFeedbackComparisonLayer layer;
  final ChatFeedbackComparisonSide side;
  final int startLine;
  final int endLine;
  final String comparisonIdentity;
  final String sourceExcerpt;
  final int hunkIndex;
  final int lineIndex;
}

/// Deliberately separate from the mutation-capable Chat and feedback services.
@AdeleService('chat.feedbackInspection')
abstract interface class ChatFeedbackInspectionService {
  @AdeleMethod('readAcceptedFeedback')
  Future<ChatAcceptedFeedback> readAcceptedFeedback(
    String sessionId,
    String occurrenceId,
  );
}

/// Declared codes: invalid_request, not_found, unavailable, corrupt.
@AdeleFailure('chat.feedbackInspectionFailure')
final class ChatFeedbackInspectionFailure implements Exception {
  const ChatFeedbackInspectionFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ChatFeedbackInspectionFailure($code): $message';
}

@AdeleValue('chat.sessionSnapshot')
final class ChatSessionSnapshot {
  ChatSessionSnapshot({
    required List<ChatEntry> entries,
    required this.instructions,
    required this.draftRequest,
  }) : entries = List<ChatEntry>.unmodifiable(entries);

  final List<ChatEntry> entries;
  final String instructions;
  final String draftRequest;
}

@AdeleService('chat.session')
abstract interface class ChatSessionService {
  @AdeleMethod('snapshot')
  Future<ChatSessionSnapshot> snapshot(String sessionId);

  /// Returns the accepted occurrence without changing the Draft Request.
  /// Blank content is rejected, not normalized.
  @AdeleMethod('appendUserMessage')
  Future<ChatEntry> appendUserMessage(String sessionId, String content);

  /// Replaces the current plain-text draft exactly, including empty/blank text.
  @AdeleMethod('setDraftRequest')
  Future<void> setDraftRequest(String sessionId, String content);

  /// Atomically accepts the exact nonblank draft as a user entry and clears it.
  @AdeleMethod('submitDraftRequest')
  Future<ChatEntry> submitDraftRequest(String sessionId);

  /// Replaces the Session's instructions without changing its draft or history.
  @AdeleMethod('configureSession')
  Future<void> configureSession(String sessionId, String instructions);
}

/// Declared codes: session_busy, invalid_session, invalid_content.
/// A busy Session remains readable.
@AdeleFailure('chat.sessionFailure')
final class ChatSessionFailure implements Exception {
  const ChatSessionFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ChatSessionFailure($code): $message';
}
