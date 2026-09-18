/// Transport snapshots for exact-generation remote model tools.
library;

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/adele_model_tool.dart' as local;

part 'remote_model_tool.g.dart';

enum RemoteToolEffect {
  resourceInspection,
  sourceRead,
  sourceMutation,
  processExecution,
}

enum RemoteEffectUncertainty { none, uncertain }

enum RemoteToolOutcomeDisposition {
  success,
  userRejected,
  policyDenied,
  failure,
  cancelled,
  indeterminate,
}

enum RemoteToolFailureKind { domain, infrastructure, staleBinding }

enum RemoteEffectCertainty { knownNotOccurred, knownOccurred, uncertain }

enum RemoteToolProgressKind { status, stdout, stderr }

enum RemoteToolExecutionEventKind { progress, terminal }

@AdeleValue('modelTool.descriptor')
final class RemoteToolDescriptor {
  RemoteToolDescriptor({
    required this.toolId,
    required this.toolDescription,
    required this.modelAlias,
    required this.modelDescription,
    required Map<String, Object?> argumentsSchema,
    required this.routeId,
    required List<String> executionHostServices,
  }) : argumentsSchema = adeleSnapshotJsonMap(argumentsSchema),
       executionHostServices = List<String>.unmodifiable(
         executionHostServices,
       ) {
    _requireNonBlank(toolId, 'Tool ID');
    _requireNonBlank(toolDescription, 'Tool description');
    _requireNonBlank(modelAlias, 'Model tool alias');
    _requireNonBlank(modelDescription, 'Model tool description');
    _requireNonBlank(routeId, 'Tool route ID');
  }

  final String toolId;
  final String toolDescription;
  final String modelAlias;
  final String modelDescription;
  final Map<String, Object?> argumentsSchema;

  /// Opaque route to the exact materialized executable, never a tool alias.
  final String routeId;

  /// Requested execution services, not an authority grant or selector.
  final List<String> executionHostServices;

  static RemoteToolDescriptor fromLocal(
    local.ToolRegistration registration, {
    required String routeId,
    required List<String> executionHostServices,
  }) => RemoteToolDescriptor(
    toolId: registration.definition.id.value,
    toolDescription: registration.definition.description,
    modelAlias: registration.modelDefinition.alias,
    modelDescription: registration.modelDefinition.description,
    argumentsSchema: registration.modelDefinition.argumentsSchema,
    routeId: routeId,
    executionHostServices: executionHostServices,
  );

  local.ToolDefinition toToolDefinition() => local.ToolDefinition(
    id: local.ToolId(toolId),
    description: toolDescription,
  );

  local.ModelToolDefinition toModelDefinition() => local.ModelToolDefinition(
    alias: modelAlias,
    description: modelDescription,
    argumentsSchema: argumentsSchema,
  );
}

@AdeleValue('modelTool.canonicalArguments')
final class RemoteCanonicalToolArguments {
  RemoteCanonicalToolArguments({required Map<String, Object?> snapshot})
    : snapshot = adeleSnapshotJsonMap(snapshot);

  final Map<String, Object?> snapshot;

  static RemoteCanonicalToolArguments fromLocal(
    local.CanonicalToolArguments arguments,
  ) => RemoteCanonicalToolArguments(snapshot: arguments.snapshot);

  local.CanonicalToolArguments toLocal() =>
      local.CanonicalToolArguments(snapshot);
}

@AdeleValue('modelTool.effectDescription')
final class RemoteEffectDescription {
  RemoteEffectDescription({
    required List<RemoteToolEffect> effects,
    required List<Uri> targetUris,
    required this.summary,
    required this.uncertainty,
  }) : effects = List<RemoteToolEffect>.unmodifiable(effects),
       targetUris = List<Uri>.unmodifiable(targetUris) {
    _requireNonBlank(summary, 'Effect summary');
    if (this.effects.toSet().length != this.effects.length) {
      throw const FormatException('Tool effects must not contain duplicates.');
    }
    for (final uri in this.targetUris) {
      if (!uri.hasScheme) {
        throw const FormatException('Effect target URIs must be absolute.');
      }
    }
  }

  final List<RemoteToolEffect> effects;
  final List<Uri> targetUris;
  final String summary;
  final RemoteEffectUncertainty uncertainty;

  static RemoteEffectDescription fromLocal(local.EffectDescription value) =>
      RemoteEffectDescription(
        effects: [
          for (final effect in value.effects)
            RemoteToolEffect.values.byName(effect.name),
        ],
        targetUris: [for (final target in value.targets) target.uri],
        summary: value.summary,
        uncertainty: RemoteEffectUncertainty.values.byName(
          value.uncertainty.name,
        ),
      );

  local.EffectDescription toLocal() => local.EffectDescription(
    effects: [
      for (final effect in effects) local.ToolEffect.values.byName(effect.name),
    ],
    targets: [for (final uri in targetUris) local.EffectTarget(uri: uri)],
    summary: summary,
    uncertainty: local.EffectUncertainty.values.byName(uncertainty.name),
  );
}

@AdeleValue('modelTool.progress')
final class RemoteToolProgress {
  RemoteToolProgress({required this.kind, required this.content}) {
    if (content.isEmpty) {
      throw const FormatException('Tool progress content must not be empty.');
    }
  }

  final RemoteToolProgressKind kind;
  final String content;

  static RemoteToolProgress fromLocal(local.ToolProgress value) =>
      RemoteToolProgress(
        kind: RemoteToolProgressKind.values.byName(value.kind.name),
        content: value.content,
      );

  local.ToolProgress toLocal() => local.ToolProgress(
    kind: local.ToolProgressKind.values.byName(kind.name),
    content: content,
  );
}

@AdeleValue('modelTool.outcome')
final class RemoteToolOutcome {
  RemoteToolOutcome({
    required this.disposition,
    required this.failureKind,
    required this.effectCertainty,
    required this.modelContent,
    required Map<String, Object?> hostData,
    required this.hostDiagnostic,
  }) : hostData = adeleSnapshotJsonMap(hostData) {
    _requireNonBlank(modelContent, 'Tool model content');
    if ((disposition == RemoteToolOutcomeDisposition.failure) !=
        (failureKind != null)) {
      throw const FormatException(
        'Only failure outcomes require a failure kind.',
      );
    }
  }

  final RemoteToolOutcomeDisposition disposition;
  final RemoteToolFailureKind? failureKind;
  final RemoteEffectCertainty effectCertainty;
  final String modelContent;
  final Map<String, Object?> hostData;
  final String? hostDiagnostic;

  /// Exception objects are deliberately not transported.
  static RemoteToolOutcome fromLocal(local.ToolOutcome value) =>
      RemoteToolOutcome(
        disposition: RemoteToolOutcomeDisposition.values.byName(
          value.disposition.name,
        ),
        failureKind: value.failureKind == null
            ? null
            : RemoteToolFailureKind.values.byName(value.failureKind!.name),
        effectCertainty: RemoteEffectCertainty.values.byName(
          value.effectCertainty.name,
        ),
        modelContent: value.modelContent,
        hostData: value.hostData,
        hostDiagnostic: value.hostDiagnostic,
      );

  local.ToolOutcome toLocal() => local.ToolOutcome(
    disposition: local.ToolOutcomeDisposition.values.byName(disposition.name),
    failureKind: failureKind == null
        ? null
        : local.ToolFailureKind.values.byName(failureKind!.name),
    effectCertainty: local.EffectCertainty.values.byName(effectCertainty.name),
    modelContent: modelContent,
    hostData: hostData,
    hostDiagnostic: hostDiagnostic,
  );
}

@AdeleValue('modelTool.executionEvent')
final class RemoteToolExecutionEvent {
  RemoteToolExecutionEvent({
    required this.kind,
    required this.progress,
    required this.outcome,
  }) {
    if ((kind == RemoteToolExecutionEventKind.progress) != (progress != null) ||
        (kind == RemoteToolExecutionEventKind.terminal) != (outcome != null)) {
      throw const FormatException(
        'Tool event kind must match exactly one event payload.',
      );
    }
  }

  final RemoteToolExecutionEventKind kind;
  final RemoteToolProgress? progress;
  final RemoteToolOutcome? outcome;

  static RemoteToolExecutionEvent fromLocal(local.ToolExecutionEvent event) =>
      switch (event) {
        local.ToolExecutionProgress(:final progress) =>
          RemoteToolExecutionEvent(
            kind: RemoteToolExecutionEventKind.progress,
            progress: RemoteToolProgress.fromLocal(progress),
            outcome: null,
          ),
        local.ToolExecutionTerminal(:final outcome) => RemoteToolExecutionEvent(
          kind: RemoteToolExecutionEventKind.terminal,
          progress: null,
          outcome: RemoteToolOutcome.fromLocal(outcome),
        ),
      };

  local.ToolExecutionEvent toLocal() => switch (kind) {
    RemoteToolExecutionEventKind.progress => local.ToolExecutionProgress(
      progress!.toLocal(),
    ),
    RemoteToolExecutionEventKind.terminal => local.ToolExecutionTerminal(
      outcome!.toLocal(),
    ),
  };
}

/// Semantic IDs describe the invocation; only the execution context grants
/// authority. Materialization, validation, and description receive no authority.
@AdeleService('modelTool')
abstract interface class RemoteModelToolService {
  @AdeleMethod('materialize')
  Future<List<RemoteToolDescriptor>> materialize(String sessionId);

  @AdeleMethod('validateAndNormalize')
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  );

  @AdeleMethod('describe')
  Future<RemoteEffectDescription> describe(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? environmentId,
  );

  @AdeleMethod('execute')
  Stream<RemoteToolExecutionEvent> execute(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? environmentId,
    String? hostInvocationContext,
  );
}

/// Only semantic argument validation may be translated into this failure.
/// Other backend and transport failures must not become invalid arguments.
@AdeleFailure('modelTool.argumentValidationFailure')
final class RemoteToolArgumentValidationFailure implements Exception {
  const RemoteToolArgumentValidationFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'RemoteToolArgumentValidationFailure($code): $message';
}

void _requireNonBlank(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
}
