import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_contract/openai_contract.dart';

/// Projects only supported, nonblank summary text from an owned reasoning item.
///
/// Declines input exceeding 1,024 parts or 262,144 total UTF-16 code units before
/// scanning text. Within that budget, every part is validated before projection.
/// Nonblank parts are trimmed and retain at most 32,768 Unicode code points
/// across 128 parts.
/// The `truncated` data field indicates full-text loss. The
/// compact first nonblank part is capped at 160 code points, including an
/// ellipsis when either compact or full text is truncated. Text is not escaped;
/// the presentation boundary owns escaping. Unknown fields are never copied.
ModelProviderNativePresentation? projectOpenAiReasoningSummary(
  ModelProviderNativeEnvelope envelope,
) {
  final Object? version = envelope.compatibility['version'];
  if (envelope.kind != openAiResponsesItemKind ||
      version is! int ||
      version != openAiResponsesItemVersion) {
    return null;
  }
  final Object? item = envelope.data['item'];
  if (item is! Map<String, Object?> || item['type'] != 'reasoning') return null;
  final Object? summary = item['summary'];
  const int maximumInputParts = 1024;
  const int maximumInputCodeUnits = 262144;
  if (summary is! List<Object?> || summary.length > maximumInputParts) {
    return null;
  }

  // Bound work before trimming or decoding Unicode, including discarded suffixes.
  final List<String> texts = <String>[];
  int inputCodeUnits = 0;
  for (final Object? part in summary) {
    if (part is! Map<String, Object?> || part['type'] != 'summary_text') {
      return null;
    }
    final Object? text = part['text'];
    if (text is! String) return null;
    inputCodeUnits += text.length;
    if (inputCodeUnits > maximumInputCodeUnits) return null;
    texts.add(text);
  }

  const int maximumCharacters = 32768;
  const int maximumParts = 128;
  final List<String> parts = <String>[];
  int remaining = maximumCharacters;
  bool truncated = false;
  for (final String text in texts) {
    final String nonblank = text.trim();
    if (nonblank.isEmpty) continue;
    if (remaining == 0 || parts.length == maximumParts) {
      truncated = true;
      continue;
    }
    final List<int> characters = nonblank.runes.take(remaining + 1).toList();
    if (characters.length > remaining) {
      parts.add(String.fromCharCodes(characters.take(remaining)));
      remaining = 0;
      truncated = true;
    } else {
      parts.add(nonblank);
      remaining -= characters.length;
    }
  }
  if (parts.isEmpty) return null;
  final List<int> compact = parts.first.trim().runes.take(161).toList();
  if (compact.isEmpty) return null;
  final String compactText = compact.length > 160 || truncated
      ? '${String.fromCharCodes(compact.take(159)).trimRight()}\u2026'
      : String.fromCharCodes(compact);
  return ModelProviderNativePresentation(
    kind: openAiReasoningSummaryPresentationKind,
    compactText: compactText,
    data: <String, Object?>{'summaryParts': parts, 'truncated': truncated},
  );
}
