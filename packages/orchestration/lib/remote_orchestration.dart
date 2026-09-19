/// Data-only transport for strategy execution and operation-scoped host calls.
library;

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/remote_model_tool.dart' as tool;
import 'package:adele_product/adele_product.dart' as product;

import 'adele_orchestration.dart' as local;

part 'remote_orchestration.g.dart';

enum RemoteRunState { created, running, waiting, completed, failed, cancelled }

enum RemoteRunTransition { start, complete, fail }

enum RemoteSemanticModelInputKind {
  providerNative,
  message,
  toolProposal,
  toolProposalFailure,
  toolOutcome,
}

enum RemoteModelOutputKind { providerNative, text, toolProposal }

enum RemoteModelSettlement { completed, incomplete, refused }

enum RemoteModelIncompleteReason { outputLimit, contextLimit, other }

enum RemoteStrategyToolResultKind { waiting, continuation }

@AdeleValue('orchestration.session')
final class RemoteOrchestrationSession {
  RemoteOrchestrationSession({
    required this.sessionId,
    required this.taskId,
    required this.strategyId,
  }) {
    toLocal();
  }

  final String sessionId;
  final String taskId;
  final String strategyId;

  static RemoteOrchestrationSession fromLocal(product.Session value) =>
      RemoteOrchestrationSession(
        sessionId: value.id.value,
        taskId: value.taskId.value,
        strategyId: value.strategyId.value,
      );

  product.Session toLocal() => product.Session(
    id: product.SessionId(sessionId),
    taskId: product.TaskId(taskId),
    strategyId: product.OrchestrationStrategyId(strategyId),
  );
}

/// Data from an intentional strategy failure or an already-collected model failure.
/// Failed orchestration calls stay exceptional at their operation boundary.
@AdeleValue('orchestration.failure')
final class RemoteOrchestrationFailure {
  RemoteOrchestrationFailure({required this.code, required this.message}) {
    if (code.trim().isEmpty || code.length > 128 || message.length > 4096) {
      throw const FormatException('Invalid bounded orchestration failure.');
    }
  }

  final String code;
  final String message;

  static RemoteOrchestrationFailure fromLocal(Object error) {
    if (error is RemoteStrategyFailure) {
      return RemoteOrchestrationFailure(
        code: error.code,
        message: error.message,
      );
    }
    return RemoteOrchestrationFailure(
      code: _bounded(error.runtimeType.toString(), 128),
      message: _bounded(error.toString(), 4096),
    );
  }

  RemoteStrategyFailure toLocal() => RemoteStrategyFailure._(code, message);
}

/// Generic reconstructed failure. No original exception or executable value survives.
final class RemoteStrategyFailure implements Exception {
  const RemoteStrategyFailure._(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RemoteStrategyFailure($code): $message';
}

@AdeleValue('orchestration.inferenceMaterial')
final class RemoteStrategyInferenceMaterial {
  RemoteStrategyInferenceMaterial({
    required this.instructions,
    required List<RemoteSemanticModelInput> input,
  }) : input = List<RemoteSemanticModelInput>.unmodifiable(input);

  final String instructions;
  final List<RemoteSemanticModelInput> input;

  static RemoteStrategyInferenceMaterial fromLocal(
    local.StrategyInferenceMaterial value,
  ) => RemoteStrategyInferenceMaterial(
    instructions: value.instructions,
    input: [
      for (final item in value.input) RemoteSemanticModelInput.fromLocal(item),
    ],
  );

  local.StrategyInferenceMaterial toLocal() => local.StrategyInferenceMaterial(
    instructions: instructions,
    input: input.map((item) => item.toLocal()),
  );
}

/// A strict tagged payload, including all provider replay data but no authority.
@AdeleValue('orchestration.semanticInput')
final class RemoteSemanticModelInput {
  RemoteSemanticModelInput({
    required this.kind,
    required Map<String, Object?> payload,
  }) : payload = adeleSnapshotJsonMap(payload) {
    toLocal();
  }

  final RemoteSemanticModelInputKind kind;
  final Map<String, Object?> payload;

  static RemoteSemanticModelInput fromLocal(
    local.SemanticModelInputItem value,
  ) => switch (value) {
    local.SemanticNativeInput() => RemoteSemanticModelInput(
      kind: RemoteSemanticModelInputKind.providerNative,
      payload: _nativeFields(
        value.providerItemId,
        value.providerNativeMetadata,
      ),
    ),
    local.SemanticMessageInput() => RemoteSemanticModelInput(
      kind: RemoteSemanticModelInputKind.message,
      payload: {
        ..._nativeFields(value.providerItemId, value.providerNativeMetadata),
        'role': value.role.name,
        'content': value.content,
      },
    ),
    local.SemanticToolProposalInput() => RemoteSemanticModelInput(
      kind: RemoteSemanticModelInputKind.toolProposal,
      payload: {
        ..._nativeFields(value.providerItemId, value.providerNativeMetadata),
        'proposal': _proposalMap(value.proposal),
      },
    ),
    local.SemanticToolProposalFailureInput(:final failure) =>
      RemoteSemanticModelInput(
        kind: RemoteSemanticModelInputKind.toolProposalFailure,
        payload: {
          'kind': failure.kind.name,
          'providerCallId': failure.providerCallId,
          'alias': failure.alias,
          'message': failure.message,
        },
      ),
    local.SemanticToolOutcomeInput() => RemoteSemanticModelInput(
      kind: RemoteSemanticModelInputKind.toolOutcome,
      payload: {
        'providerCallId': value.providerCallId,
        'outcome': _outcomeMap(value.outcome),
      },
    ),
  };

  local.SemanticModelInputItem toLocal() {
    switch (kind) {
      case RemoteSemanticModelInputKind.providerNative:
        _fields(payload, {'providerItemId', 'providerNativeMetadata'});
        return local.SemanticNativeInput(
          providerItemId: _nullable<String>(payload, 'providerItemId'),
          providerNativeMetadata: _envelope(
            _read(payload, 'providerNativeMetadata'),
          ),
        );
      case RemoteSemanticModelInputKind.message:
        _fields(payload, {
          'providerItemId',
          'providerNativeMetadata',
          'role',
          'content',
        });
        return local.SemanticMessageInput(
          role: _enum(local.SemanticMessageRole.values, payload['role']),
          content: _read(payload, 'content'),
          providerItemId: _nullable<String>(payload, 'providerItemId'),
          providerNativeMetadata: _optionalEnvelope(
            payload['providerNativeMetadata'],
          ),
        );
      case RemoteSemanticModelInputKind.toolProposal:
        _fields(payload, {
          'providerItemId',
          'providerNativeMetadata',
          'proposal',
        });
        return local.SemanticToolProposalInput(
          proposal: _proposal(_read(payload, 'proposal')),
          providerItemId: _nullable<String>(payload, 'providerItemId'),
          providerNativeMetadata: _optionalEnvelope(
            payload['providerNativeMetadata'],
          ),
        );
      case RemoteSemanticModelInputKind.toolProposalFailure:
        _fields(payload, {'kind', 'providerCallId', 'alias', 'message'});
        return local.SemanticToolProposalFailureInput(
          failure: local.ToolProposalFailure(
            kind: _enum(local.ToolProposalFailureKind.values, payload['kind']),
            providerCallId: _read(payload, 'providerCallId'),
            alias: _read(payload, 'alias'),
            message: _read(payload, 'message'),
          ),
        );
      case RemoteSemanticModelInputKind.toolOutcome:
        _fields(payload, {'providerCallId', 'outcome'});
        return local.SemanticToolOutcomeInput(
          providerCallId: _read(payload, 'providerCallId'),
          outcome: _outcome(_read(payload, 'outcome')),
        );
    }
  }
}

@AdeleValue('orchestration.modelOutput')
final class RemoteModelOutput {
  RemoteModelOutput({
    required this.kind,
    required Map<String, Object?> payload,
    required this.proposalHandle,
  }) : payload = adeleSnapshotJsonMap(payload) {
    if (proposalHandle != null) {
      _nonBlank(proposalHandle!, 'Proposal handle');
      if (kind != RemoteModelOutputKind.toolProposal) {
        throw const FormatException(
          'Only proposal output may carry a proposal handle.',
        );
      }
    }
    toLocal();
  }

  final RemoteModelOutputKind kind;
  final Map<String, Object?> payload;

  final String? proposalHandle;

  static RemoteModelOutput fromLocal(
    local.ModelOutputItem value, {
    String? proposalHandle,
  }) {
    if (proposalHandle != null && value is! local.ModelToolProposalOutput) {
      throw const FormatException(
        'Only proposal output may carry a proposal handle.',
      );
    }
    return switch (value) {
      local.ModelNativeOutput() => RemoteModelOutput(
        kind: RemoteModelOutputKind.providerNative,
        proposalHandle: null,
        payload: {
          ..._nativeFields(value.providerItemId, value.providerNativeMetadata),
          'presentation': value.presentation == null
              ? null
              : {
                  'kind': value.presentation!.kind,
                  'compactText': value.presentation!.compactText,
                  'data': value.presentation!.data,
                },
        },
      ),
      local.ModelTextOutput() => RemoteModelOutput(
        kind: RemoteModelOutputKind.text,
        proposalHandle: null,
        payload: {
          ..._nativeFields(value.providerItemId, value.providerNativeMetadata),
          'content': value.content,
        },
      ),
      local.ModelToolProposalOutput() => RemoteModelOutput(
        kind: RemoteModelOutputKind.toolProposal,
        proposalHandle: proposalHandle,
        payload: {
          ..._nativeFields(value.providerItemId, value.providerNativeMetadata),
          'proposal': _proposalMap(value.proposal),
        },
      ),
    };
  }

  local.ModelOutputItem toLocal() {
    switch (kind) {
      case RemoteModelOutputKind.providerNative:
        _fields(payload, {
          'providerItemId',
          'providerNativeMetadata',
          'presentation',
        });
        return local.ModelNativeOutput(
          providerItemId: _nullable<String>(payload, 'providerItemId'),
          providerNativeMetadata: _envelope(
            _read(payload, 'providerNativeMetadata'),
          ),
          presentation: payload['presentation'] == null
              ? null
              : _presentation(_read(payload, 'presentation')),
        );
      case RemoteModelOutputKind.text:
        _fields(payload, {
          'providerItemId',
          'providerNativeMetadata',
          'content',
        });
        return local.ModelTextOutput(
          _read(payload, 'content'),
          providerItemId: _nullable<String>(payload, 'providerItemId'),
          providerNativeMetadata: _optionalEnvelope(
            payload['providerNativeMetadata'],
          ),
        );
      case RemoteModelOutputKind.toolProposal:
        _fields(payload, {
          'providerItemId',
          'providerNativeMetadata',
          'proposal',
        });
        return local.ModelToolProposalOutput(
          _proposal(_read(payload, 'proposal')),
          providerItemId: _nullable<String>(payload, 'providerItemId'),
          providerNativeMetadata: _optionalEnvelope(
            payload['providerNativeMetadata'],
          ),
        );
    }
  }
}

@AdeleValue('orchestration.modelMetadata')
final class RemoteModelTerminalMetadata {
  RemoteModelTerminalMetadata({required Map<String, Object?> payload})
    : payload = adeleSnapshotJsonMap(payload) {
    toLocal();
  }

  final Map<String, Object?> payload;

  static RemoteModelTerminalMetadata fromLocal(
    local.ModelTerminalMetadata value,
  ) => RemoteModelTerminalMetadata(
    payload: {
      'effectiveModel': value.effectiveModel,
      'providerResponseId': value.providerResponseId,
      'providerRequestId': value.providerRequestId,
      'providerStopReason': value.providerStopReason,
      'providerNativeState': _envelopeMap(value.providerNativeState),
      'usage': value.usage == null
          ? null
          : {
              'inputTokens': value.usage!.inputTokens,
              'outputTokens': value.usage!.outputTokens,
              'cacheReadTokens': value.usage!.cacheReadTokens,
              'cacheWriteTokens': value.usage!.cacheWriteTokens,
              'providerDetails': value.usage!.providerDetails,
            },
    },
  );

  local.ModelTerminalMetadata toLocal() {
    _fields(payload, {
      'effectiveModel',
      'providerResponseId',
      'providerRequestId',
      'providerStopReason',
      'providerNativeState',
      'usage',
    });
    return local.ModelTerminalMetadata(
      effectiveModel: _nullable<String>(payload, 'effectiveModel'),
      providerResponseId: _nullable<String>(payload, 'providerResponseId'),
      providerRequestId: _nullable<String>(payload, 'providerRequestId'),
      providerStopReason: _nullable<String>(payload, 'providerStopReason'),
      providerNativeState: _optionalEnvelope(payload['providerNativeState']),
      usage: payload['usage'] == null ? null : _usage(_read(payload, 'usage')),
    );
  }
}

@AdeleValue('orchestration.modelTurn')
final class RemoteStrategyModelTurn {
  RemoteStrategyModelTurn({
    required this.toolSnapshotHandle,
    required List<RemoteModelOutput> output,
    required this.settlement,
    required this.incompleteReason,
    required this.metadata,
    required this.failure,
  }) : output = List<RemoteModelOutput>.unmodifiable(output) {
    _nonBlank(toolSnapshotHandle, 'Tool snapshot handle');
    if (failure != null
        ? settlement != null || incompleteReason != null || metadata != null
        : settlement == null ||
              metadata == null ||
              ((settlement == RemoteModelSettlement.incomplete) !=
                  (incompleteReason != null))) {
      throw const FormatException('Model turn settlement payload mismatch.');
    }
    final handles = <String>{};
    for (final item in output) {
      if (item.kind == RemoteModelOutputKind.toolProposal &&
          (item.proposalHandle == null || !handles.add(item.proposalHandle!))) {
        throw const FormatException(
          'Model turn proposals require unique handles.',
        );
      }
    }
  }

  final String toolSnapshotHandle;
  final List<RemoteModelOutput> output;
  final RemoteModelSettlement? settlement;
  final RemoteModelIncompleteReason? incompleteReason;
  final RemoteModelTerminalMetadata? metadata;
  final RemoteOrchestrationFailure? failure;

  static RemoteStrategyModelTurn fromLocal(
    local.StrategyModelTurn value, {
    required String toolSnapshotHandle,
    required String Function(local.ProviderToolProposal) proposalHandle,
  }) => RemoteStrategyModelTurn(
    toolSnapshotHandle: toolSnapshotHandle,
    output: [
      for (final item in value.output)
        RemoteModelOutput.fromLocal(
          item,
          proposalHandle: item is local.ModelToolProposalOutput
              ? proposalHandle(item.proposal)
              : null,
        ),
    ],
    settlement: value.settlement == null
        ? null
        : RemoteModelSettlement.values.byName(value.settlement!.name),
    incompleteReason: value.incompleteReason == null
        ? null
        : RemoteModelIncompleteReason.values.byName(
            value.incompleteReason!.name,
          ),
    metadata: value.metadata == null
        ? null
        : RemoteModelTerminalMetadata.fromLocal(value.metadata!),
    failure: value.failure == null
        ? null
        : RemoteOrchestrationFailure.fromLocal(value.failure!),
  );

  local.StrategyModelTurn toLocal({required local.StrategyToolSnapshot tools}) {
    final items = [for (final item in output) item.toLocal()];
    if (failure != null) {
      return local.StrategyModelTurn.failed(
        tools: tools,
        output: items,
        error: failure!.toLocal(),
      );
    }
    return local.StrategyModelTurn.settled(
      tools: tools,
      output: items,
      settlement: local.ModelSettlement.values.byName(settlement!.name),
      incompleteReason: incompleteReason == null
          ? null
          : local.ModelIncompleteReason.values.byName(incompleteReason!.name),
      metadata: metadata!.toLocal(),
    );
  }
}

@AdeleValue('orchestration.toolResult')
final class RemoteStrategyToolResult {
  RemoteStrategyToolResult({required this.kind, required this.item}) {
    if ((kind == RemoteStrategyToolResultKind.continuation) != (item != null)) {
      throw const FormatException('Tool result kind and payload mismatch.');
    }
  }

  final RemoteStrategyToolResultKind kind;
  final RemoteSemanticModelInput? item;

  static RemoteStrategyToolResult fromLocal(local.StrategyToolResult value) =>
      switch (value) {
        local.StrategyToolWaiting() => RemoteStrategyToolResult(
          kind: RemoteStrategyToolResultKind.waiting,
          item: null,
        ),
        local.StrategyToolContinuation(:final item) => RemoteStrategyToolResult(
          kind: RemoteStrategyToolResultKind.continuation,
          item: RemoteSemanticModelInput.fromLocal(item),
        ),
      };

  local.StrategyToolResult toLocal() => switch (kind) {
    RemoteStrategyToolResultKind.waiting => const local.StrategyToolWaiting(),
    RemoteStrategyToolResultKind.continuation => local.StrategyToolContinuation(
      item!.toLocal(),
    ),
  };
}

@AdeleValue('orchestration.approvalResolution')
final class RemoteApprovalResolution {
  RemoteApprovalResolution({
    required this.interruptionId,
    required this.toolInvocationId,
    required this.approved,
  }) {
    toLocal();
  }

  final String interruptionId;
  final String toolInvocationId;
  final bool approved;

  static RemoteApprovalResolution fromLocal(
    local.ToolApprovalResolution value,
  ) => RemoteApprovalResolution(
    interruptionId: value.interruptionId.value,
    toolInvocationId: value.toolInvocationId.value,
    approved: value.approved,
  );

  local.ToolApprovalResolution toLocal() => local.ToolApprovalResolution(
    interruptionId: local.RunInterruptionId(interruptionId),
    toolInvocationId: local.ToolInvocationId(toolInvocationId),
    approved: approved,
  );
}

@AdeleService('orchestrationStrategy')
abstract interface class RemoteOrchestrationService {
  @AdeleMethod('materialize')
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  );

  @AdeleMethod('start')
  Future<RemoteRunState> start(
    String executionId,
    String hostInvocationContext,
  );

  @AdeleMethod('resolveApproval')
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String hostInvocationContext,
  );

  @AdeleMethod('release')
  Future<void> release(String executionId);
}

@AdeleService('orchestrationExecutionHost')
abstract interface class RemoteOrchestrationHostService {
  @AdeleMethod('transition')
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  );

  @AdeleMethod('invokeModel')
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  );

  @AdeleMethod('processProposal')
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  );

  @AdeleMethod('applyCurrentApproval')
  Future<RemoteSemanticModelInput> applyCurrentApproval();
}

Map<String, Object?> _nativeFields(
  String? id,
  local.ModelNativeEnvelope? metadata,
) => {'providerItemId': id, 'providerNativeMetadata': _envelopeMap(metadata)};

Map<String, Object?>? _envelopeMap(local.ModelNativeEnvelope? value) =>
    value == null
    ? null
    : {
        'kind': value.kind,
        'compatibility': value.compatibility,
        'data': value.data,
      };

local.ModelNativeEnvelope? _optionalEnvelope(Object? value) => value == null
    ? null
    : _envelope(_typed<Map<String, Object?>>(value, 'native envelope'));

local.ModelNativeEnvelope _envelope(Map<String, Object?> value) {
  _fields(value, {'kind', 'compatibility', 'data'});
  return local.ModelNativeEnvelope(
    kind: _read(value, 'kind'),
    compatibility: _read(value, 'compatibility'),
    data: _read(value, 'data'),
  );
}

local.ModelNativePresentation _presentation(Map<String, Object?> value) {
  _fields(value, {'kind', 'compactText', 'data'});
  return local.ModelNativePresentation(
    kind: _read(value, 'kind'),
    compactText: _read(value, 'compactText'),
    data: _read(value, 'data'),
  );
}

Map<String, Object?> _proposalMap(local.ProviderToolProposal value) => {
  'providerCallId': value.providerCallId,
  'alias': value.alias,
  'arguments': value.arguments,
};

local.ProviderToolProposal _proposal(Map<String, Object?> value) {
  _fields(value, {'providerCallId', 'alias', 'arguments'});
  return local.ProviderToolProposal(
    providerCallId: _read(value, 'providerCallId'),
    alias: _read(value, 'alias'),
    arguments: _read(value, 'arguments'),
  );
}

// Codegen is deliberately library-local. Reuse the model-tool conversion boundary
// while carrying its strict data-only outcome shape inside our tagged payload.
Map<String, Object?> _outcomeMap(local.ToolOutcome value) {
  final remote = tool.RemoteToolOutcome.fromLocal(value);
  return {
    'disposition': remote.disposition.name,
    'failureKind': remote.failureKind?.name,
    'effectCertainty': remote.effectCertainty.name,
    'modelContent': remote.modelContent,
    'hostData': remote.hostData,
    'hostDiagnostic': remote.hostDiagnostic,
  };
}

local.ToolOutcome _outcome(Map<String, Object?> value) {
  _fields(value, {
    'disposition',
    'failureKind',
    'effectCertainty',
    'modelContent',
    'hostData',
    'hostDiagnostic',
  });
  return tool.RemoteToolOutcome(
    disposition: _enum(
      tool.RemoteToolOutcomeDisposition.values,
      value['disposition'],
    ),
    failureKind: value['failureKind'] == null
        ? null
        : _enum(tool.RemoteToolFailureKind.values, value['failureKind']),
    effectCertainty: _enum(
      tool.RemoteEffectCertainty.values,
      value['effectCertainty'],
    ),
    modelContent: _read(value, 'modelContent'),
    hostData: _read(value, 'hostData'),
    hostDiagnostic: _nullable<String>(value, 'hostDiagnostic'),
  ).toLocal();
}

local.ModelUsage _usage(Map<String, Object?> value) {
  _fields(value, {
    'inputTokens',
    'outputTokens',
    'cacheReadTokens',
    'cacheWriteTokens',
    'providerDetails',
  });
  return local.ModelUsage(
    inputTokens: _nullable<int>(value, 'inputTokens'),
    outputTokens: _nullable<int>(value, 'outputTokens'),
    cacheReadTokens: _nullable<int>(value, 'cacheReadTokens'),
    cacheWriteTokens: _nullable<int>(value, 'cacheWriteTokens'),
    providerDetails: _read(value, 'providerDetails'),
  );
}

void _fields(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !keys.every(value.containsKey)) {
    throw const FormatException(
      'Unexpected or missing semantic payload fields.',
    );
  }
}

T _read<T>(Map<String, Object?> value, String key) =>
    _typed<T>(value[key], key);

T? _nullable<T>(Map<String, Object?> value, String key) =>
    value[key] == null ? null : _read<T>(value, key);

T _typed<T>(Object? value, String label) {
  if (value is! T) throw FormatException('Invalid $label payload type.');
  return value;
}

T _enum<T extends Enum>(List<T> values, Object? value) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  throw const FormatException('Unknown semantic enum value.');
}

void _nonBlank(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be blank.');
}

String _bounded(String value, int limit) =>
    value.length <= limit ? value : value.substring(0, limit);
