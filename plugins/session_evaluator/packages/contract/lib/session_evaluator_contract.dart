/// Bounded retained Session evidence, independent of execution authority.
library;

import 'package:adele_contract/adele_contract.dart';

export 'src/identities.dart';
export 'src/read_session_evaluation_handoff.dart';
export 'src/read_session_evidence.dart';

part 'session_evaluator_contract.g.dart';

const String sessionEvidenceSchema = 'dev.adele.session-evidence.v2';
const int sessionEvidenceMaxBytes = 16 * 1024 * 1024;
const int sessionEvidenceChunkCodeUnits = 16 * 1024;
const int sessionEvidenceMaxRows = 100000;

@AdeleService('dev.adele.session-evaluator')
abstract interface class SessionEvaluatorService {
  /// Consecutive JSON text chunks of one fully collected, validated document.
  /// No chunks are emitted before successful collection. Each chunk is bounded
  /// by [sessionEvidenceChunkCodeUnits], without splitting surrogate pairs, and
  /// the complete UTF-8 document is bounded by [sessionEvidenceMaxBytes].
  @AdeleMethod('collectSession')
  Stream<String> collectSession(String sessionId);
}

@AdeleService('dev.adele.session-evaluation-handoff')
abstract interface class SessionEvaluationHandoffService {
  /// Prepares a private local handoff when listened to. Successful completion
  /// emits exactly one absolute README.md path, after all files are complete.
  /// Cancellation fences further work and joins incomplete-output cleanup.
  @AdeleMethod('prepareSession')
  Stream<String> prepareSession(String sessionId);
}

@AdeleFailure('dev.adele.session-evidence.failure')
final class SessionEvidenceFailure implements Exception {
  const SessionEvidenceFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'SessionEvidenceFailure($code): $message';
}
