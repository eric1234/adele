/// Immutable Session feedback data, independent of execution or approval authority.
library;

import 'dart:convert' as convert;

import 'package:adele_contract/adele_contract.dart';

part 'session_feedback.g.dart';

/// String lengths use UTF-16 code units; aggregate limits use UTF-8 bytes.
abstract final class SessionFeedbackLimits {
  static const maxComments = 128;
  static const maxTextLength = 8192;
  static const maxExcerptLength = 4096;
  static const maxPathLength = 4096;
  static const maxComparisonIdentityLength = 256;
  static const maxIdentityLength = 256;
  static const maxLine = 2147483647;
  static const maxLineRange = 1000;
  static const maxHunkIndex = 8191;
  static const maxLineIndex = 65535;
  static const maxVersion = 2147483647;
  static const maxSequence = 2147483647;
  static const maxSubmissionBytes = 128 * 1024;

  /// Budget for a strategy-owned model projection, not a rendering policy.
  static const maxModelContentBytes = 144 * 1024;
}

enum SessionFeedbackKind { codeReview }

enum SessionFeedbackComparisonLayer { unstaged, staged, committed }

enum SessionFeedbackComparisonSide { oldSide, newSide }

/// Captured source coordinates and exact text, not live Environment authority.
@AdeleValue('dev.adele.session.feedback.anchor')
final class SessionFeedbackAnchor {
  SessionFeedbackAnchor({
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
  }) {
    validateSessionFeedbackIdentity(environmentId);
    _validateUnicode(relativePath);
    if (relativePath.isEmpty ||
        relativePath.length > SessionFeedbackLimits.maxPathLength ||
        relativePath.contains('\u0000') ||
        relativePath.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(relativePath) ||
        relativePath
            .split('/')
            .any(
              (part) =>
                  part.isEmpty || part == '.' || part == '..' || part == '.git',
            )) {
      throw _invalidSubmission;
    }
    if (comparisonIdentity.trim().isEmpty ||
        comparisonIdentity.length >
            SessionFeedbackLimits.maxComparisonIdentityLength ||
        comparisonIdentity.codeUnits.any(
          (unit) => unit < 0x20 || unit > 0x7e,
        )) {
      throw _invalidSubmission;
    }
    _validateUnicode(sourceExcerpt);
    if (sourceExcerpt.length > SessionFeedbackLimits.maxExcerptLength ||
        startLine < 1 ||
        endLine < startLine ||
        endLine > SessionFeedbackLimits.maxLine ||
        endLine - startLine + 1 > SessionFeedbackLimits.maxLineRange ||
        hunkIndex < 0 ||
        hunkIndex > SessionFeedbackLimits.maxHunkIndex ||
        lineIndex < 0 ||
        lineIndex > SessionFeedbackLimits.maxLineIndex) {
      throw _invalidSubmission;
    }
  }

  final String environmentId;

  /// Slash-separated relative path, without normalization or trimming.
  final String relativePath;
  final SessionFeedbackComparisonLayer layer;
  final SessionFeedbackComparisonSide side;

  /// Inclusive positive line range on [side] of the captured comparison.
  final int startLine;
  final int endLine;

  /// Opaque nonblank printable ASCII identity of the captured comparison.
  final String comparisonIdentity;

  /// Exact Unicode source, including whitespace, line endings and final newline.
  final String sourceExcerpt;

  /// Zero-based coordinates in the captured display.
  final int hunkIndex;
  final int lineIndex;
}

@AdeleValue('dev.adele.session.feedback.comment')
final class SessionFeedbackComment {
  SessionFeedbackComment({
    required this.id,
    required this.anchor,
    required this.text,
    required this.version,
    required this.sequence,
  }) {
    validateSessionFeedbackIdentity(id);
    _validateUnicode(text);
    if (text.trim().isEmpty ||
        text.length > SessionFeedbackLimits.maxTextLength ||
        version < 1 ||
        version > SessionFeedbackLimits.maxVersion ||
        sequence < 1 ||
        sequence > SessionFeedbackLimits.maxSequence) {
      throw _invalidSubmission;
    }
  }

  final String id;
  final SessionFeedbackAnchor anchor;
  final String text;
  final int version;

  /// Original creation order, retained across updates and deletion gaps.
  final int sequence;
}

/// Caller-owned identity and exact ordered content, with no target selectors.
@AdeleValue('dev.adele.session.feedback.submission')
final class SessionFeedbackSubmission {
  SessionFeedbackSubmission({
    required this.submissionId,
    required this.kind,
    required List<SessionFeedbackComment> comments,
  }) : comments = List<SessionFeedbackComment>.unmodifiable(comments) {
    validateSessionFeedbackIdentity(submissionId);
    if (this.comments.isEmpty ||
        this.comments.length > SessionFeedbackLimits.maxComments) {
      throw _invalidSubmission;
    }
    final ids = <String>{};
    var previousSequence = 0;
    for (final comment in this.comments) {
      if (!ids.add(comment.id) || comment.sequence <= previousSequence) {
        throw _invalidSubmission;
      }
      previousSequence = comment.sequence;
    }
    if (convert.utf8.encode(encodeSessionFeedbackSubmission(this)).length >
        SessionFeedbackLimits.maxSubmissionBytes) {
      throw _submissionTooLarge;
    }
  }

  final String submissionId;
  final SessionFeedbackKind kind;
  final List<SessionFeedbackComment> comments;
}

/// Stable receipt returned unchanged for an identical accepted submission.
@AdeleValue('dev.adele.session.feedback.receipt')
final class SessionFeedbackReceipt {
  SessionFeedbackReceipt({
    required this.submissionId,
    required this.sessionId,
    required this.occurrenceId,
  }) {
    validateSessionFeedbackIdentity(submissionId);
    validateSessionFeedbackIdentity(sessionId);
    validateSessionFeedbackIdentity(occurrenceId);
  }

  final String submissionId;
  final String sessionId;
  final String occurrenceId;
}

@AdeleValue('dev.adele.session.feedback.record')
final class SessionFeedbackRecord {
  SessionFeedbackRecord({required this.receipt, required this.submission}) {
    if (receipt.submissionId != submission.submissionId) {
      throw _invalidSubmission;
    }
  }

  final SessionFeedbackReceipt receipt;
  final SessionFeedbackSubmission submission;
}

/// An already-bound Session target. Accepting feedback does not start a Run.
abstract interface class SessionFeedbackTarget {
  Future<SessionFeedbackReceipt> accept(SessionFeedbackSubmission submission);

  /// Reads retained accepted data; absence does not establish mutation rollback.
  Future<SessionFeedbackRecord?> lookup(String submissionId);
}

/// Route and Session selectors belong to the internal exact-binding adapter,
/// never to the public submission or native caller-facing target.
@AdeleService('dev.adele.session.feedback')
abstract interface class RemoteSessionFeedbackService {
  @AdeleMethod('accept')
  Future<SessionFeedbackReceipt> accept(
    String routeId,
    String sessionId,
    SessionFeedbackSubmission submission,
  );

  @AdeleMethod('lookup')
  Future<SessionFeedbackRecord?> lookup(
    String routeId,
    String sessionId,
    String submissionId,
  );
}

/// Validation uses `invalid_submission` or `submission_too_large`. Targets may
/// report availability, conflict, storage or uncertain-outcome failures without
/// including submitted text, paths, excerpts or identities in their messages.
@AdeleFailure('dev.adele.session.feedback.failure')
final class SessionFeedbackFailure implements Exception {
  const SessionFeedbackFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'SessionFeedbackFailure($code): $message';
}

/// Canonical complete JSON: fixed field order, exact strings, original comment
/// order, and submission identity. This is durable data, not model rendering.
String encodeSessionFeedbackSubmission(SessionFeedbackSubmission submission) =>
    convert.jsonEncode(<String, Object?>{
      'submissionId': submission.submissionId,
      'kind': submission.kind.name,
      'comments': <Object?>[
        for (final comment in submission.comments)
          <String, Object?>{
            'id': comment.id,
            'anchor': <String, Object?>{
              'environmentId': comment.anchor.environmentId,
              'relativePath': comment.anchor.relativePath,
              'layer': comment.anchor.layer.name,
              'side': comment.anchor.side.name,
              'startLine': comment.anchor.startLine,
              'endLine': comment.anchor.endLine,
              'comparisonIdentity': comment.anchor.comparisonIdentity,
              'sourceExcerpt': comment.anchor.sourceExcerpt,
              'hunkIndex': comment.anchor.hunkIndex,
              'lineIndex': comment.anchor.lineIndex,
            },
            'text': comment.text,
            'version': comment.version,
            'sequence': comment.sequence,
          },
      ],
    });

/// Reloads structured durable data with exact fields, types and value validation.
/// Encoded input is bounded as well as the reconstructed canonical payload.
SessionFeedbackSubmission decodeSessionFeedbackSubmission(String encoded) {
  _validateUnicode(encoded);
  if (encoded.length > SessionFeedbackLimits.maxSubmissionBytes ||
      convert.utf8.encode(encoded).length >
          SessionFeedbackLimits.maxSubmissionBytes) {
    throw _submissionTooLarge;
  }
  try {
    final data = _fields(convert.jsonDecode(encoded), const [
      'submissionId',
      'kind',
      'comments',
    ]);
    return SessionFeedbackSubmission(
      submissionId: data['submissionId'] as String,
      kind: SessionFeedbackKind.values.byName(data['kind'] as String),
      comments: [
        for (final value in data['comments'] as List<Object?>)
          _decodeComment(value),
      ],
    );
  } on FormatException {
    throw _invalidSubmission;
  } on TypeError {
    throw _invalidSubmission;
  } on ArgumentError {
    throw _invalidSubmission;
  }
}

SessionFeedbackComment _decodeComment(Object? value) {
  final data = _fields(value, const [
    'id',
    'anchor',
    'text',
    'version',
    'sequence',
  ]);
  final anchor = _fields(data['anchor'], const [
    'environmentId',
    'relativePath',
    'layer',
    'side',
    'startLine',
    'endLine',
    'comparisonIdentity',
    'sourceExcerpt',
    'hunkIndex',
    'lineIndex',
  ]);
  return SessionFeedbackComment(
    id: data['id'] as String,
    anchor: SessionFeedbackAnchor(
      environmentId: anchor['environmentId'] as String,
      relativePath: anchor['relativePath'] as String,
      layer: SessionFeedbackComparisonLayer.values.byName(
        anchor['layer'] as String,
      ),
      side: SessionFeedbackComparisonSide.values.byName(
        anchor['side'] as String,
      ),
      startLine: anchor['startLine'] as int,
      endLine: anchor['endLine'] as int,
      comparisonIdentity: anchor['comparisonIdentity'] as String,
      sourceExcerpt: anchor['sourceExcerpt'] as String,
      hunkIndex: anchor['hunkIndex'] as int,
      lineIndex: anchor['lineIndex'] as int,
    ),
    text: data['text'] as String,
    version: data['version'] as int,
    sequence: data['sequence'] as int,
  );
}

Map<String, Object?> _fields(Object? value, List<String> keys) {
  if (value is! Map<String, Object?> ||
      value.length != keys.length ||
      keys.any((key) => !value.containsKey(key))) {
    throw _invalidSubmission;
  }
  return value;
}

/// Validates an exact feedback identity, including IDs supplied to lookup.
void validateSessionFeedbackIdentity(String value) {
  _validateUnicode(value);
  if (value.isEmpty ||
      value.length > SessionFeedbackLimits.maxIdentityLength ||
      value.trim() != value ||
      value.codeUnits.any(
        (unit) => unit < 0x20 || (unit >= 0x7f && unit <= 0x9f),
      )) {
    throw _invalidSubmission;
  }
}

void _validateUnicode(String value) {
  if (value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    throw _invalidSubmission;
  }
}

const _invalidSubmission = SessionFeedbackFailure(
  code: 'invalid_submission',
  message: 'Invalid Session feedback data.',
);

const _submissionTooLarge = SessionFeedbackFailure(
  code: 'submission_too_large',
  message: 'Session feedback exceeds its payload limit.',
);
