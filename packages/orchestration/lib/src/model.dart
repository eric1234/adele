import 'dart:collection';

import 'package:adele_model_tool/adele_model_tool.dart';

import 'tool.dart';

enum SemanticMessageRole { user, assistant }

final class ModelNativeEnvelope {
  ModelNativeEnvelope({
    required String kind,
    required Map<String, Object?> compatibility,
    required Map<String, Object?> data,
  }) : kind = _requireNonEmpty(kind, 'Model native envelope kind'),
       compatibility = _freezeMap(compatibility),
       data = _freezeMap(data);

  final String kind;
  final Map<String, Object?> compatibility;
  final Map<String, Object?> data;
}

sealed class SemanticModelInputItem {
  const SemanticModelInputItem();
}

final class SemanticNativeInput extends SemanticModelInputItem {
  SemanticNativeInput({
    required this.providerNativeMetadata,
    this.providerItemId,
  }) {
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final String? providerItemId;
  final ModelNativeEnvelope providerNativeMetadata;
}

final class SemanticMessageInput extends SemanticModelInputItem {
  SemanticMessageInput({
    required this.role,
    required this.content,
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    if (content.isEmpty) {
      throw const FormatException(
        'Semantic message content must not be empty.',
      );
    }
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final SemanticMessageRole role;
  final String content;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

final class SemanticToolOutcomeInput extends SemanticModelInputItem {
  SemanticToolOutcomeInput({
    required this.providerCallId,
    required this.outcome,
  }) {
    if (providerCallId.trim().isEmpty) {
      throw const FormatException('Provider call ID must not be empty.');
    }
  }

  final String providerCallId;
  final ToolOutcome outcome;
}

final class SemanticToolProposalInput extends SemanticModelInputItem {
  SemanticToolProposalInput({
    required this.proposal,
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final ProviderToolProposal proposal;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

final class SemanticToolProposalFailureInput extends SemanticModelInputItem {
  SemanticToolProposalFailureInput({required this.failure});

  final ToolProposalFailure failure;
}

sealed class ModelOutputItem {
  const ModelOutputItem();
}

final class ModelNativeOutput extends ModelOutputItem {
  ModelNativeOutput({
    required this.providerNativeMetadata,
    this.providerItemId,
  }) {
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final String? providerItemId;
  final ModelNativeEnvelope providerNativeMetadata;
}

final class ModelTextOutput extends ModelOutputItem {
  ModelTextOutput(
    this.content, {
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    if (content.isEmpty) {
      throw const FormatException('Model text output must not be empty.');
    }
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final String content;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

final class ModelToolProposalOutput extends ModelOutputItem {
  ModelToolProposalOutput(
    this.proposal, {
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final ProviderToolProposal proposal;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

enum ModelSettlement { completed, incomplete, refused }

enum ModelIncompleteReason { outputLimit, contextLimit, other }

final class ModelUsage {
  ModelUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    Map<String, Object?> providerDetails = const <String, Object?>{},
  }) : providerDetails = _freezeMap(providerDetails) {
    for (final int? value in <int?>[
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
    ]) {
      if (value != null && value < 0) {
        throw const FormatException('Model usage counts must not be negative.');
      }
    }
  }

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final Map<String, Object?> providerDetails;
}

final class ModelTerminalMetadata {
  ModelTerminalMetadata({
    this.effectiveModel,
    this.providerResponseId,
    this.providerRequestId,
    this.providerStopReason,
    this.usage,
    this.providerNativeState,
  }) {
    _requireOptionalNonEmpty(effectiveModel, 'Effective model');
    _requireOptionalNonEmpty(providerResponseId, 'Provider response ID');
    _requireOptionalNonEmpty(providerRequestId, 'Provider request ID');
    _requireOptionalNonEmpty(providerStopReason, 'Provider stop reason');
  }

  final String? effectiveModel;
  final String? providerResponseId;
  final String? providerRequestId;
  final String? providerStopReason;
  final ModelUsage? usage;
  final ModelNativeEnvelope? providerNativeState;
}

void _requireOptionalNonEmpty(String? value, String label) {
  if (value != null && value.trim().isEmpty) {
    throw FormatException('$label must not be empty.');
  }
}

String _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
  return value;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    _freezeValue(source, 0, HashSet<Object>.identity())!
        as Map<String, Object?>;

const int _structuredMaxDepth = 64;

Object? _freezeValue(Object? value, int depth, Set<Object> active) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Structured values require finite doubles.');
    }
    return value;
  }
  if (depth >= _structuredMaxDepth) {
    throw const FormatException('Structured value exceeds maximum depth 64.');
  }
  if (value is List<Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic structured value.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((Object? item) => _freezeValue(item, depth + 1, active)),
      );
    } finally {
      active.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic structured value.');
    }
    try {
      return Map<String, Object?>.unmodifiable(
        value.map(
          (String key, Object? item) => MapEntry<String, Object?>(
            key,
            _freezeValue(item, depth + 1, active),
          ),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  throw FormatException('Unsupported structured value: ${value.runtimeType}.');
}
