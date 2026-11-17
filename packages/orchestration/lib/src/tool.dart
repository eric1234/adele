import 'dart:async';
import 'dart:collection';

import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

import 'run.dart';

/// Independent, zero-or-many authorization participants, not selected providers.
final ExtensionPoint<ToolAuthorizationPolicyContribution>
toolAuthorizationPolicies = ExtensionPoint<ToolAuthorizationPolicyContribution>(
  'dev.adele.extension.tool-authorization-policies',
);

/// An immutable opinion, not an approval token or execution authority.
enum ToolAuthorizationDecision { allow, deny, ask, abstain }

/// Data for one normalized invocation after effect preflight.
///
/// The host supplies canonical Run/Session identity and validates the Session's
/// Project association through the product graph. IDs grant no host access.
final class ToolAuthorizationRequest {
  ToolAuthorizationRequest({
    required this.toolId,
    required Map<String, Object?> canonicalArguments,
    required this.effects,
    required this.runId,
    required this.sessionId,
    required this.projectId,
    required this.toolInvocationId,
  }) : canonicalArguments = _freezeMap(canonicalArguments);

  final ToolId toolId;
  final Map<String, Object?> canonicalArguments;
  final EffectDescription effects;
  final RunId runId;
  final SessionId sessionId;
  final ProjectId projectId;
  final ToolInvocationId toolInvocationId;
}

final class ToolAuthorizationPolicyContribution {
  const ToolAuthorizationPolicyContribution({required this.evaluate});

  /// Evaluates without executing the proposed tool. Throwing (including a failed
  /// Future) is an evaluation failure, never Deny or Abstain.
  ///
  /// The host captures registrations per request, evaluates sequentially by
  /// Extension ID, and validates exact bindings through completion. Deny wins
  /// over Ask, then Allow; Abstain has no effect. Zero policies yields Allow only
  /// after the host validates any applicable expected participation.
  /// Completed decisions are not re-evaluated on approval resume.
  final FutureOr<ToolAuthorizationDecision> Function(ToolAuthorizationRequest)
  evaluate;
}

final class ProviderToolProposal {
  ProviderToolProposal({
    required String providerCallId,
    required String alias,
    required Map<String, Object?> arguments,
  }) : providerCallId = _requireNonEmpty(providerCallId, 'Provider call ID'),
       alias = _requireNonEmpty(alias, 'Proposed model tool alias'),
       arguments = _freezeMap(arguments);

  final String providerCallId;
  final String alias;
  final Map<String, Object?> arguments;
}

enum ToolProposalFailureKind {
  unknownAlias,
  invalidArguments,
  staleBinding,
  bindingUnavailable,
}

final class ToolProposalFailure {
  ToolProposalFailure({
    required this.kind,
    required String providerCallId,
    required String alias,
    required String message,
    this.cause,
  }) : providerCallId = _requireNonEmpty(providerCallId, 'Provider call ID'),
       alias = _requireNonEmpty(alias, 'Proposed model tool alias'),
       message = _requireNonEmpty(message, 'Tool proposal failure message');

  final ToolProposalFailureKind kind;
  final String providerCallId;
  final String alias;
  final String message;
  final Object? cause;
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
