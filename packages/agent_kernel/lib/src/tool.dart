import 'dart:async';

import 'identifiers.dart';

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
  /// Returns immutable canonical arguments or throws a [FormatException].
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  );

  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  );

  /// Validates the exact executable generation retained by a materialization.
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

final class ToolCatalog {
  final Map<ToolId, ToolRegistration> _registrations =
      <ToolId, ToolRegistration>{};

  void register(ToolRegistration registration) {
    _registrations[registration.definition.id] = registration;
  }

  bool remove(ToolId id) => _registrations.remove(id) != null;

  MaterializedToolSet materialize({Iterable<ToolId>? selected}) {
    final Iterable<ToolRegistration> registrations;
    if (selected == null) {
      registrations = _registrations.values;
    } else {
      registrations = selected.map((ToolId id) {
        final ToolRegistration? registration = _registrations[id];
        if (registration == null) {
          throw ToolMaterializationException('Tool $id is not registered.');
        }
        return registration;
      });
    }
    return MaterializedToolSet(
      registrations.map(
        (ToolRegistration registration) => MaterializedTool(
          definition: registration.definition,
          modelDefinition: registration.modelDefinition,
          executable: registration.executable,
        ),
      ),
    );
  }
}

final class MaterializedTool {
  const MaterializedTool({
    required this.definition,
    required this.modelDefinition,
    required this.executable,
  });

  final ToolDefinition definition;
  final ModelToolDefinition modelDefinition;
  final ToolExecutable executable;
}

final class MaterializedToolSet {
  MaterializedToolSet(Iterable<MaterializedTool> tools)
    : tools = List<MaterializedTool>.unmodifiable(tools) {
    final Map<String, MaterializedTool> byAlias = <String, MaterializedTool>{};
    for (final MaterializedTool tool in this.tools) {
      final String alias = tool.modelDefinition.alias;
      if (byAlias.containsKey(alias)) {
        throw ToolMaterializationException(
          'Model tool alias is not unique in this materialization: $alias.',
        );
      }
      byAlias[alias] = tool;
    }
    _byAlias = Map<String, MaterializedTool>.unmodifiable(byAlias);
  }

  final List<MaterializedTool> tools;
  late final Map<String, MaterializedTool> _byAlias;

  MaterializedTool? byAlias(String alias) => _byAlias[alias];
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

final class ToolInvocation {
  ToolInvocation._({
    required this.id,
    required this.proposal,
    required this.tool,
    required this.arguments,
    required this.context,
  }) : canonicalArguments = _freezeMap(arguments.snapshot);

  final ToolInvocationId id;
  final ProviderToolProposal proposal;
  final MaterializedTool tool;
  final CanonicalToolArguments arguments;
  final ToolExecutionContext context;
  final Map<String, Object?> canonicalArguments;

  ToolId get toolId => tool.definition.id;
}

enum ToolProposalFailureKind { unknownAlias, invalidArguments }

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

sealed class ToolProposalResolution {
  const ToolProposalResolution();
}

final class ResolvedToolProposal extends ToolProposalResolution {
  const ResolvedToolProposal(this.invocation);

  final ToolInvocation invocation;
}

final class RejectedToolProposal extends ToolProposalResolution {
  const RejectedToolProposal(this.failure);

  final ToolProposalFailure failure;
}

final class ToolInvocationResolver {
  const ToolInvocationResolver();

  ToolProposalResolution resolve({
    required ToolInvocationId invocationId,
    required ProviderToolProposal proposal,
    required MaterializedToolSet tools,
    required ToolExecutionContext context,
  }) {
    final MaterializedTool? tool = tools.byAlias(proposal.alias);
    if (tool == null) {
      return RejectedToolProposal(
        ToolProposalFailure(
          kind: ToolProposalFailureKind.unknownAlias,
          providerCallId: proposal.providerCallId,
          alias: proposal.alias,
          message: 'The proposed model tool alias is not available.',
        ),
      );
    }
    try {
      return ResolvedToolProposal(
        ToolInvocation._(
          id: invocationId,
          proposal: proposal,
          tool: tool,
          arguments: tool.executable.validateAndNormalize(proposal.arguments),
          context: context,
        ),
      );
    } on FormatException catch (error) {
      return RejectedToolProposal(
        ToolProposalFailure(
          kind: ToolProposalFailureKind.invalidArguments,
          providerCallId: proposal.providerCallId,
          alias: proposal.alias,
          message: error.message.trim().isEmpty
              ? 'The proposed tool arguments are invalid.'
              : error.message,
          cause: error,
        ),
      );
    }
  }
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

enum ToolEffect { resourceInspection, sourceRead }

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

final class ToolPolicyInput {
  const ToolPolicyInput({
    required this.invocation,
    required this.effects,
    required this.context,
  });

  final ToolInvocation invocation;
  final EffectDescription effects;
  final ToolExecutionContext context;
}

enum ToolPolicyDecision { allow, deny, ask }

abstract interface class ToolPolicy {
  ToolPolicyDecision evaluate(ToolPolicyInput input);
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

final class ToolExecutionAlreadyStarted implements Exception {
  const ToolExecutionAlreadyStarted(this.invocationId);

  final ToolInvocationId invocationId;

  @override
  String toString() =>
      'ToolExecutionAlreadyStarted: Tool invocation $invocationId already started.';
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

final class ToolMaterializationException implements Exception {
  const ToolMaterializationException(this.message);

  final String message;

  @override
  String toString() => 'ToolMaterializationException: $message';
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
