import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

List<String> reviewModelMessages(Map<String, Object?> request) => [
  for (final item in (request['input']! as List).cast<Map<String, Object?>>())
    if (item['kind'] == 'message')
      for (final content
          in ((item['message']! as Map)['content']! as List)
              .cast<Map<String, Object?>>())
        content['text']! as String,
];

/// Deterministic public model/tool adapters. Stock Chat still owns sequencing,
/// input projection and Run association across its actual AOT boundary.
final class ReviewExecutionFixture
    implements AdeleStreamChannel, ModelToolContribution, ToolExecutable {
  static final providerId = ProviderId('test.review.model');
  static const model = 'review-deterministic';
  static const answer = 'Reviewed the complete immutable batch.';
  final requests = <Map<String, Object?>>[];
  final executedSessions = <String>[];
  final entered = Completer<void>();
  Completer<void>? modelGate;
  bool requiresApproval = false;
  late final CapabilityRegistration _provider;
  late final ExtensionRegistration _tools;

  void register(AdeleRuntime runtime) {
    _provider = runtime.registry.register(
      provider: ProviderDescriptor(
        id: providerId,
        capability: modelProviderCapability,
        pluginId: 'test.review.model',
        displayName: 'Deterministic review model',
        serviceId: modelProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: this,
        serviceId: modelProviderServiceId,
        isAvailable: () => true,
      ),
    );
    _tools = runtime.extensions.register(
      point: modelToolContributions,
      id: ExtensionId('test.review.tools'),
      value: this,
    );
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('The model only supports streaming invocation.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    expect(method, modelProviderServiceInvokeId);
    final request = Map<String, Object?>.from(payload['request']! as Map);
    expect(request['model'], model);
    requests.add(request);
    if (!entered.isCompleted) entered.complete();
    await modelGate?.future;
    final input = (request['input']! as List).cast<Map<String, Object?>>();
    final hasOutcome = input.any((item) => item['kind'] == 'toolOutcome');
    yield {
      'kind': 'output',
      'observation': null,
      'terminal': null,
      'output': {
        'kind': hasOutcome ? 'text' : 'toolProposal',
        'text': hasOutcome ? answer : null,
        'toolProposal': hasOutcome
            ? null
            : {
                'callId': 'review-probe',
                'name': 'review_probe',
                'arguments': <String, Object?>{},
              },
        'itemId': hasOutcome ? 'review-answer' : 'review-probe',
        'nativeMetadata': null,
        'nativePresentation': null,
      },
    };
    yield {
      'kind': 'terminal',
      'observation': null,
      'output': null,
      'terminal': {
        'settlement': 'completed',
        'incompleteReason': null,
        'failure': null,
        'providerStopReason': 'stop',
        'usage': null,
        'effectiveModel': model,
        'responseId': 'review-response-${requests.length}',
        'requestId': null,
        'nativeState': null,
        'affinityState': null,
      },
    };
  }

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async => [
    ToolRegistration(
      definition: ToolDefinition(
        id: ToolId('test.review.probe'),
        description: 'Observe the deterministic review fixture.',
      ),
      modelDefinition: ModelToolDefinition(
        alias: 'review_probe',
        description: 'Observe the deterministic review fixture.',
        argumentsSchema: const {
          'type': 'object',
          'additionalProperties': false,
        },
      ),
      executable: this,
    ),
  ];

  @override
  void validateBinding() {}

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) {
    expect(arguments, isEmpty);
    return CanonicalToolArguments(arguments);
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: [
      requiresApproval ? ToolEffect.sourceMutation : ToolEffect.sourceRead,
    ],
    targets: const [],
    summary: 'Observe the deterministic review fixture without changing files.',
  );

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executedSessions.add(context.sessionId.value);
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Review fixture observed; no file or index writes.',
      ),
    );
  }

  void release() {
    if (modelGate case final gate? when !gate.isCompleted) gate.complete();
  }

  Future<void> close() async {
    release();
    await _tools.close();
    await _provider.close();
  }
}
