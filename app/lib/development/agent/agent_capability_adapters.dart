import 'dart:async';
import 'dart:collection';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

final ToolId resourceInspectionToolId = ToolId(
  'dev.adele.tool.resource-inspection',
);

final class ModelProviderCapabilityAdapter implements ModelPort {
  ModelProviderCapabilityAdapter(
    this._binding, {
    required String selectedModel,
    this.maxOutputTokens,
    this.toolChoice = ModelProviderToolChoice.auto,
    Map<String, Object?> providerOptions = const <String, Object?>{},
  }) : selectedModel = _requireNonEmpty(selectedModel, 'Selected model'),
       providerOptions = _freezeJsonMap(providerOptions);

  final ProviderBinding _binding;
  final String selectedModel;
  final int? maxOutputTokens;
  final ModelProviderToolChoice toolChoice;
  final Map<String, Object?> providerOptions;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _binding.provider;
  int get invocationCount => _invocationCount;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) {
    late final StreamController<ModelEvent> controller;
    StreamSubscription<ModelProviderEvent>? subscription;
    Completer<void>? pendingConsumerCancellation;
    bool semanticTerminal = false;
    bool settled = false;

    void cancelSettledTransport() {
      final StreamSubscription<ModelProviderEvent>? current = subscription;
      if (current == null) return;
      unawaited(() async {
        try {
          await current.cancel();
        } on Object {
          // Semantic terminal is authoritative; cleanup cannot replace it.
        }
      }());
    }

    void fail(Object error, StackTrace stackTrace) {
      if (settled) return;
      settled = true;
      controller.add(
        ModelInvocationFailedEvent(
          invocationId: request.invocationId,
          error: error,
          stackTrace: stackTrace,
        ),
      );
      unawaited(controller.close());
    }

    controller = StreamController<ModelEvent>(
      sync: true,
      onListen: () {
        try {
          final ModelProviderService client = ModelProviderServiceClient(
            _binding.streamChannel,
          );
          _invocationCount++;
          final StreamSubscription<ModelProviderEvent> created = client
              .invoke(_toProviderRequest(request, this))
              .listen(
                (ModelProviderEvent event) {
                  if (settled || semanticTerminal) return;
                  try {
                    switch (event.kind) {
                      case ModelProviderEventKind.observation:
                        controller.add(
                          ModelObservationEvent(
                            invocationId: request.invocationId,
                            observation: _toModelObservation(
                              event.observation!,
                            ),
                          ),
                        );
                      case ModelProviderEventKind.output:
                        controller.add(
                          ModelOutputItemCompleted(
                            invocationId: request.invocationId,
                            item: _toModelOutput(event.output!),
                          ),
                        );
                      case ModelProviderEventKind.terminal:
                        final ModelTerminalEvent terminal = _toModelTerminal(
                          request.invocationId,
                          event.terminal!,
                        );
                        semanticTerminal = true;
                        settled = true;
                        controller.add(terminal);
                        unawaited(controller.close());
                        cancelSettledTransport();
                    }
                  } on Object catch (error, stackTrace) {
                    unawaited(subscription?.cancel());
                    fail(error, stackTrace);
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (semanticTerminal) {
                    settled = true;
                    unawaited(controller.close());
                  } else {
                    fail(error, stackTrace);
                  }
                },
                onDone: () {
                  if (settled) return;
                  if (!semanticTerminal) {
                    fail(
                      const ModelInvocationContractException(
                        'The provider stream ended without semantic terminal.',
                      ),
                      StackTrace.current,
                    );
                    return;
                  }
                  settled = true;
                  unawaited(controller.close());
                },
              );
          subscription = created;
          final Completer<void>? pending = pendingConsumerCancellation;
          if (pending != null) {
            created.cancel().then(
              pending.complete,
              onError: pending.completeError,
            );
          } else if (settled) {
            cancelSettledTransport();
          }
        } on Object catch (error, stackTrace) {
          final Completer<void>? pending = pendingConsumerCancellation;
          if (pending != null && !pending.isCompleted) {
            pending.completeError(error, stackTrace);
          }
          fail(error, stackTrace);
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        if (settled) return;
        settled = true;
        final StreamSubscription<ModelProviderEvent>? current = subscription;
        if (current != null) {
          await current.cancel();
          return;
        }
        final Completer<void> pending = pendingConsumerCancellation ??=
            Completer<void>();
        await pending.future;
      },
    );
    return controller.stream;
  }
}

ModelProviderRequest _toProviderRequest(
  SemanticModelRequest request,
  ModelProviderCapabilityAdapter adapter,
) => ModelProviderRequest(
  model: adapter.selectedModel,
  instructions: request.instructions,
  input: request.input.map(_toProviderInput).toList(growable: false),
  tools: request.tools.tools
      .map(
        (MaterializedTool tool) => ModelProviderTool(
          name: tool.modelDefinition.alias,
          description: tool.modelDefinition.description,
          argumentsSchema: tool.modelDefinition.argumentsSchema,
        ),
      )
      .toList(growable: false),
  toolChoice: adapter.toolChoice,
  maxOutputTokens: adapter.maxOutputTokens,
  providerOptions: adapter.providerOptions,
  // Invocation-native reuse needs explicit Session/Run ownership and
  // compatibility policy; canonical semantic replay remains authoritative.
  nativeState: null,
);

ModelProviderInput _toProviderInput(SemanticModelInputItem item) =>
    switch (item) {
      SemanticMessageInput(
        :final role,
        :final content,
        :final providerItemId,
        :final providerNativeMetadata,
      ) =>
        ModelProviderInput(
          kind: ModelProviderInputKind.message,
          itemId: providerItemId,
          message: ModelProviderMessage(
            role: switch (role) {
              SemanticMessageRole.user => ModelProviderMessageRole.user,
              SemanticMessageRole.assistant =>
                ModelProviderMessageRole.assistant,
            },
            content: <ModelProviderContent>[
              ModelProviderContent(
                kind: ModelProviderContentKind.text,
                text: content,
              ),
            ],
          ),
          toolProposal: null,
          toolOutcome: null,
          nativeMetadata: _toProviderNativeEnvelope(providerNativeMetadata),
        ),
      SemanticToolProposalInput(
        :final proposal,
        :final providerItemId,
        :final providerNativeMetadata,
      ) =>
        ModelProviderInput(
          kind: ModelProviderInputKind.toolProposal,
          itemId: providerItemId,
          message: null,
          toolProposal: ModelProviderToolProposal(
            callId: proposal.providerCallId,
            name: proposal.alias,
            arguments: proposal.arguments,
          ),
          toolOutcome: null,
          nativeMetadata: _toProviderNativeEnvelope(providerNativeMetadata),
        ),
      SemanticToolOutcomeInput(:final providerCallId, :final outcome) =>
        ModelProviderInput(
          kind: ModelProviderInputKind.toolOutcome,
          itemId: null,
          message: null,
          toolProposal: null,
          toolOutcome: ModelProviderToolOutcome(
            callId: providerCallId,
            status: switch (outcome.disposition) {
              ToolOutcomeDisposition.success =>
                ModelProviderToolOutcomeStatus.success,
              ToolOutcomeDisposition.userRejected ||
              ToolOutcomeDisposition.policyDenied =>
                ModelProviderToolOutcomeStatus.rejected,
              ToolOutcomeDisposition.failure =>
                ModelProviderToolOutcomeStatus.failed,
              ToolOutcomeDisposition.cancelled =>
                ModelProviderToolOutcomeStatus.cancelled,
              ToolOutcomeDisposition.indeterminate =>
                ModelProviderToolOutcomeStatus.indeterminate,
            },
            content: outcome.modelContent,
          ),
          nativeMetadata: null,
        ),
      SemanticToolProposalFailureInput(:final failure) => ModelProviderInput(
        kind: ModelProviderInputKind.toolOutcome,
        itemId: null,
        message: null,
        toolProposal: null,
        toolOutcome: ModelProviderToolOutcome(
          callId: failure.providerCallId,
          status: ModelProviderToolOutcomeStatus.failed,
          content: failure.message,
        ),
        nativeMetadata: null,
      ),
    };

ModelProviderNativeEnvelope? _toProviderNativeEnvelope(
  ModelNativeEnvelope? envelope,
) => envelope == null
    ? null
    : ModelProviderNativeEnvelope(
        kind: envelope.kind,
        compatibility: envelope.compatibility,
        data: envelope.data,
      );

ModelNativeEnvelope? _toKernelNativeEnvelope(
  ModelProviderNativeEnvelope? envelope,
) => envelope == null
    ? null
    : ModelNativeEnvelope(
        kind: envelope.kind,
        compatibility: envelope.compatibility,
        data: envelope.data,
      );

ModelObservation _toModelObservation(ModelProviderObservation observation) =>
    ModelTextDeltaObservation(
      observation.textDelta,
      providerItemId: observation.itemId,
    );

ModelOutputItem _toModelOutput(ModelProviderOutput output) =>
    switch (output.kind) {
      ModelProviderOutputKind.text => ModelTextOutput(
        output.text!,
        providerItemId: output.itemId,
        providerNativeMetadata: _toKernelNativeEnvelope(output.nativeMetadata),
      ),
      ModelProviderOutputKind.toolProposal => ModelToolProposalOutput(
        _toProviderToolProposal(output.toolProposal!),
        providerItemId: output.itemId,
        providerNativeMetadata: _toKernelNativeEnvelope(output.nativeMetadata),
      ),
    };

ProviderToolProposal _toProviderToolProposal(ModelProviderToolProposal call) =>
    ProviderToolProposal(
      providerCallId: call.callId,
      alias: call.name,
      arguments: call.arguments,
    );

ModelTerminalEvent _toModelTerminal(
  ModelInvocationId invocationId,
  ModelProviderTerminal terminal,
) {
  if (terminal.settlement == ModelProviderSettlement.failed) {
    final ModelProviderFailure failure = terminal.failure!;
    return ModelInvocationFailedEvent(
      invocationId: invocationId,
      error: ModelFailure(
        kind: _toModelFailureKind(failure.kind),
        providerCode: failure.providerCode,
        providerMessage: failure.providerMessage,
        providerDetails: failure.providerDetails,
      ),
      semanticTerminalMetadata: _toTerminalMetadata(terminal),
    );
  }
  return ModelInvocationSettledEvent(
    invocationId: invocationId,
    settlement: switch (terminal.settlement) {
      ModelProviderSettlement.completed => ModelSettlement.completed,
      ModelProviderSettlement.incomplete => ModelSettlement.incomplete,
      ModelProviderSettlement.refused => ModelSettlement.refused,
      ModelProviderSettlement.failed => throw StateError('Handled above.'),
    },
    incompleteReason: terminal.incompleteReason == null
        ? null
        : _toModelIncompleteReason(terminal.incompleteReason!),
    metadata: _toTerminalMetadata(terminal),
  );
}

ModelTerminalMetadata _toTerminalMetadata(ModelProviderTerminal terminal) =>
    ModelTerminalMetadata(
      effectiveModel: terminal.effectiveModel,
      providerResponseId: terminal.responseId,
      providerRequestId: terminal.requestId,
      providerStopReason: terminal.providerStopReason,
      usage: terminal.usage == null
          ? null
          : ModelUsage(
              inputTokens: terminal.usage!.inputTokens,
              outputTokens: terminal.usage!.outputTokens,
              cacheReadTokens: terminal.usage!.cacheReadTokens,
              cacheWriteTokens: terminal.usage!.cacheWriteTokens,
              providerDetails: terminal.usage!.providerDetails,
            ),
      providerNativeState: _toKernelNativeEnvelope(terminal.nativeState),
    );

ModelFailureKind _toModelFailureKind(
  ModelProviderFailureKind kind,
) => switch (kind) {
  ModelProviderFailureKind.invalidRequest => ModelFailureKind.invalidRequest,
  ModelProviderFailureKind.unsupportedRequest =>
    ModelFailureKind.unsupportedRequest,
  ModelProviderFailureKind.authentication => ModelFailureKind.authentication,
  ModelProviderFailureKind.permission => ModelFailureKind.permission,
  ModelProviderFailureKind.rateLimited => ModelFailureKind.rateLimited,
  ModelProviderFailureKind.unavailable => ModelFailureKind.unavailable,
  ModelProviderFailureKind.capacity => ModelFailureKind.capacity,
  ModelProviderFailureKind.transport => ModelFailureKind.transport,
  ModelProviderFailureKind.malformedResponse =>
    ModelFailureKind.malformedResponse,
  ModelProviderFailureKind.providerFailure => ModelFailureKind.providerFailure,
  ModelProviderFailureKind.unknown => ModelFailureKind.unknown,
};

ModelIncompleteReason _toModelIncompleteReason(
  ModelProviderIncompleteReason reason,
) => switch (reason) {
  ModelProviderIncompleteReason.outputLimit =>
    ModelIncompleteReason.outputLimit,
  ModelProviderIncompleteReason.contextLimit =>
    ModelIncompleteReason.contextLimit,
  ModelProviderIncompleteReason.other => ModelIncompleteReason.other,
};

final class ResourceInspectorToolExecutable implements ToolExecutable {
  ResourceInspectorToolExecutable(this._binding);

  final ProviderBinding _binding;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _binding.provider;
  int get invocationCount => _invocationCount;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: resourceInspectionToolId,
      description: 'Inspect one resource.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'inspect_resource',
      description: 'Inspect one resource identified by an absolute URI.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['uri'],
        'properties': <String, Object?>{
          'uri': <String, Object?>{'type': 'string', 'format': 'uri'},
        },
        'additionalProperties': false,
      },
    ),
    executable: this,
  );

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    final Uri uri = _resourceUri(arguments);
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.resourceInspection],
      targets: <EffectTarget>[EffectTarget(uri: uri)],
      summary: 'Inspect $uri.',
    );
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final Uri uri = _resourceUri(arguments);
    try {
      final ResourceInspectorService client = ResourceInspectorServiceClient(
        _binding.requestChannel,
      );
      _invocationCount++;
      final ResourceInspection inspection = await client.inspect(
        ResourceRef(uri: uri),
      );
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: inspection.summary,
          hostData: <String, Object?>{
            'resource': <String, Object?>{
              'uri': inspection.resource.uri.toString(),
              'mediaType': inspection.resource.mediaType,
            },
            'providerLabel': inspection.providerLabel,
            'summary': inspection.summary,
          },
        ),
      );
    } on ProviderUnavailable catch (error) {
      yield ToolExecutionTerminal(_bindingFailureOutcome(error));
    } on ProviderEndpointUnavailable catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.infrastructure,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent:
              'The resource-inspection provider endpoint is unavailable.',
          hostDiagnostic: error.toString(),
          cause: error,
        ),
      );
    } on ResourceInspectorFailure catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.uncertain,
          modelContent: 'Resource inspection failed: ${error.message}',
          hostData: <String, Object?>{
            'resource': <String, Object?>{'uri': uri.toString()},
            'code': error.code,
            'details': error.details,
          },
          hostDiagnostic: error.message,
          cause: error,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _infrastructureOutcome('Resource inspection transport failed.', error),
      );
    }
  }

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (proposedArguments.length != 1 || proposedArguments['uri'] is! String) {
      throw const ToolArgumentValidationException(
        'inspect_resource requires exactly one string argument named uri.',
      );
    }
    final Uri uri;
    try {
      uri = Uri.parse(proposedArguments['uri']! as String);
    } on FormatException catch (error) {
      throw ToolArgumentValidationException(
        'inspect_resource uri is invalid: ${error.message}',
      );
    }
    if (!uri.isAbsolute) {
      throw const ToolArgumentValidationException(
        'inspect_resource uri must be absolute.',
      );
    }
    return CanonicalToolArguments(<String, Object?>{'uri': uri.toString()});
  }

  @override
  void validateBinding() {
    try {
      _binding.requestChannel;
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw StaleToolBindingException(
          'The materialized ResourceInspector provider is stale.',
          cause: error,
        );
      }
      throw ToolBindingUnavailableException(
        'The materialized ResourceInspector provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw ToolBindingUnavailableException(
        'The materialized ResourceInspector endpoint is unavailable.',
        cause: error,
      );
    }
  }
}

ToolOutcome _bindingFailureOutcome(ProviderUnavailable error) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: error.stale
      ? ToolFailureKind.staleBinding
      : ToolFailureKind.infrastructure,
  effectCertainty: EffectCertainty.knownNotOccurred,
  modelContent: error.stale
      ? 'The approved resource-inspection binding is stale.'
      : 'The resource-inspection provider is unavailable.',
  hostDiagnostic: error.message,
  cause: error,
);

ToolOutcome _infrastructureOutcome(String content, Object cause) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: ToolFailureKind.infrastructure,
  effectCertainty: EffectCertainty.uncertain,
  modelContent: content,
  hostDiagnostic: cause.toString(),
  cause: cause,
);

Uri _resourceUri(CanonicalToolArguments arguments) =>
    Uri.parse(arguments.snapshot['uri']! as String);

String _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
  return value;
}

const int _jsonMaxDepth = 64;

Map<String, Object?> _freezeJsonMap(Map<String, Object?> source) =>
    _freezeJsonValue(source, 0, HashSet<Object>.identity())!
        as Map<String, Object?>;

Object? _freezeJsonValue(Object? value, int depth, Set<Object> active) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Structured values require finite doubles.');
    }
    return value;
  }
  if (depth >= _jsonMaxDepth) {
    throw const FormatException('Structured value exceeds maximum depth 64.');
  }
  if (value is List<Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic structured value.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((Object? item) => _freezeJsonValue(item, depth + 1, active)),
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
            _freezeJsonValue(item, depth + 1, active),
          ),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  throw FormatException('Unsupported structured value: ${value.runtimeType}.');
}
