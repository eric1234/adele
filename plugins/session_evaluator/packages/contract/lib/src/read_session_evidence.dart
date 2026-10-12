import 'dart:convert';

import '../session_evaluator_contract.dart';

/// Returns one bounded evidence document only after successful stream completion.
/// Collection and transport errors propagate without returning a partial map.
/// Accepts only [sessionEvidenceSchema]; v1 coverage did not include command
/// transcripts and must not be interpreted as v2 completeness.
Future<Map<String, Object?>> readSessionEvidence(
  SessionEvaluatorService service,
  String sessionId,
) async {
  final text = StringBuffer();
  var bytes = 0;
  await for (final chunk in service.collectSession(sessionId)) {
    if (chunk.length > sessionEvidenceChunkCodeUnits) {
      throw const FormatException('Session evidence chunk exceeds its bound.');
    }
    bytes += utf8.encode(chunk).length;
    if (bytes > sessionEvidenceMaxBytes) {
      throw const FormatException('Session evidence exceeds its byte bound.');
    }
    text.write(chunk);
  }
  final Object? document = jsonDecode(text.toString());
  if (document is! Map<String, Object?> ||
      document['schema'] != sessionEvidenceSchema) {
    throw const FormatException('Invalid Session evidence document schema.');
  }
  return document;
}
