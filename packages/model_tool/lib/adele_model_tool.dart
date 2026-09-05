/// Public ADELE model-tool contribution and execution API.
library;

import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

final ExtensionPoint<ModelToolContribution> modelToolContributions =
    ExtensionPoint<ModelToolContribution>('dev.adele.extension.model-tools');

final class ToolId {
  ToolId(String value) : value = _requireNonEmpty(value, 'Tool ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ToolId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ToolDefinition {
  ToolDefinition({required this.id, required String description})
    : description = _requireNonEmpty(description, 'Tool description');

  final ToolId id;
  final String description;
}

final class ModelToolDefinition {
  ModelToolDefinition({
    required String alias,
    required String description,
    required Map<String, Object?> argumentsSchema,
  }) : alias = _requireNonEmpty(alias, 'Model tool alias'),
       description = _requireNonEmpty(description, 'Model tool description'),
       argumentsSchema = _freezeMap(argumentsSchema);

  final String alias;
  final String description;
  final Map<String, Object?> argumentsSchema;
}

final class CanonicalToolArguments {
  CanonicalToolArguments(Map<String, Object?> snapshot)
    : snapshot = _freezeMap(snapshot);

  final Map<String, Object?> snapshot;
}

final class ToolExecutionContext {
  const ToolExecutionContext({required this.runId, required this.sessionId});

  final RunId runId;
  final SessionId sessionId;
}

abstract interface class ToolExecutable {
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  );

  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  );

  void validateBinding();

  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  );
}

final class ToolRegistration {
  const ToolRegistration({
    required this.definition,
    required this.modelDefinition,
    required this.executable,
  });

  final ToolDefinition definition;
  final ModelToolDefinition modelDefinition;
  final ToolExecutable executable;
}

abstract interface class ModelToolHostContext {
  SessionId get sessionId;

  /// Resolves an authority-safe host service for this Session.
  Future<T> requireHostService<T extends Object>();
}

abstract interface class ModelToolContribution {
  Future<Iterable<ToolRegistration>> materialize(ModelToolHostContext context);
}

final class ToolArgumentValidationException implements FormatException {
  const ToolArgumentValidationException(this.message);

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => 'ToolArgumentValidationException: $message';
}

enum ToolEffect { resourceInspection, sourceRead, sourceMutation }

enum EffectUncertainty { none, uncertain }

final class EffectTarget {
  const EffectTarget({required this.uri});

  final Uri uri;
}

final class EffectDescription {
  EffectDescription({
    required Iterable<ToolEffect> effects,
    required Iterable<EffectTarget> targets,
    required this.summary,
    this.uncertainty = EffectUncertainty.none,
  }) : effects = Set<ToolEffect>.unmodifiable(effects),
       targets = List<EffectTarget>.unmodifiable(targets) {
    if (summary.trim().isEmpty) {
      throw const FormatException('Effect summary must not be empty.');
    }
  }

  final Set<ToolEffect> effects;
  final List<EffectTarget> targets;
  final String summary;
  final EffectUncertainty uncertainty;
}

enum ToolOutcomeDisposition {
  success,
  userRejected,
  policyDenied,
  failure,
  cancelled,
  indeterminate,
}

enum ToolFailureKind { domain, infrastructure, staleBinding }

enum EffectCertainty { knownNotOccurred, knownOccurred, uncertain }

final class ToolOutcome {
  ToolOutcome({
    required this.disposition,
    required this.effectCertainty,
    required this.modelContent,
    Map<String, Object?> hostData = const <String, Object?>{},
    this.failureKind,
    this.hostDiagnostic,
    this.cause,
  }) : hostData = _freezeMap(hostData) {
    if (modelContent.trim().isEmpty) {
      throw const FormatException('Tool model content must not be empty.');
    }
    if (disposition == ToolOutcomeDisposition.failure && failureKind == null) {
      throw const FormatException('A failure outcome needs a failure kind.');
    }
    if (disposition != ToolOutcomeDisposition.failure && failureKind != null) {
      throw const FormatException(
        'Only a failure outcome may carry a failure kind.',
      );
    }
  }

  final ToolOutcomeDisposition disposition;
  final ToolFailureKind? failureKind;
  final EffectCertainty effectCertainty;
  final String modelContent;
  final Map<String, Object?> hostData;
  final String? hostDiagnostic;
  final Object? cause;
}

final class ToolProgress {
  ToolProgress({required String message})
    : message = _requireNonEmpty(message, 'Tool progress message');

  final String message;
}

sealed class ToolExecutionEvent {
  const ToolExecutionEvent();
}

final class ToolExecutionProgress extends ToolExecutionEvent {
  const ToolExecutionProgress(this.progress);

  final ToolProgress progress;
}

final class ToolExecutionTerminal extends ToolExecutionEvent {
  const ToolExecutionTerminal(this.outcome);

  final ToolOutcome outcome;
}

final class ToolExecutionObservation {
  ToolExecutionObservation({
    required Iterable<ToolProgress> progress,
    required this.outcome,
  }) : progress = List<ToolProgress>.unmodifiable(progress);

  final List<ToolProgress> progress;
  final ToolOutcome outcome;
}

Future<ToolExecutionObservation> collectToolExecution(
  Stream<ToolExecutionEvent> events, {
  void Function(ToolProgress progress)? onProgress,
}) async {
  final List<ToolProgress> progress = <ToolProgress>[];
  ToolOutcome? outcome;
  await for (final ToolExecutionEvent event in events) {
    switch (event) {
      case ToolExecutionProgress(progress: final ToolProgress progressItem):
        if (outcome != null) {
          throw const ToolExecutionContractException(
            'Tool progress followed the terminal outcome.',
          );
        }
        progress.add(progressItem);
        onProgress?.call(progressItem);
      case ToolExecutionTerminal(outcome: final ToolOutcome outcomeItem):
        if (outcome != null) {
          throw const ToolExecutionContractException(
            'Tool execution emitted more than one terminal outcome.',
          );
        }
        outcome = outcomeItem;
    }
  }
  if (outcome == null) {
    throw const ToolExecutionContractException(
      'Tool execution ended without a terminal outcome.',
    );
  }
  return ToolExecutionObservation(progress: progress, outcome: outcome);
}

final class ToolExecutionContractException implements Exception {
  const ToolExecutionContractException(this.message);

  final String message;

  @override
  String toString() => 'ToolExecutionContractException: $message';
}

sealed class ToolBindingException implements Exception {
  const ToolBindingException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

final class StaleToolBindingException extends ToolBindingException {
  const StaleToolBindingException(super.message, {super.cause});
}

final class ToolBindingUnavailableException extends ToolBindingException {
  const ToolBindingUnavailableException(super.message, {super.cause});
}

String _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
  return value;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      source.map(
        (String key, Object? value) =>
            MapEntry<String, Object?>(key, _freezeValue(value)),
      ),
    );

Object? _freezeValue(Object? value) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Structured values require finite doubles.');
    }
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Map<String, Object?>) return _freezeMap(value);
  throw FormatException('Unsupported structured value: ${value.runtimeType}.');
}
