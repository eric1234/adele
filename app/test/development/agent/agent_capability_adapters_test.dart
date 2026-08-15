import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

void main() {
  test(
    'common adapter lowers request and maps observations and output',
    () async {
      final _ProviderChannel channel = _ProviderChannel(
        events: Stream<ModelProviderEvent>.fromIterable(<ModelProviderEvent>[
          _delta('Inspecting '),
          _text('Inspecting.', 'text-1'),
          _proposal('call-1', 'item-1'),
          _terminal(),
        ]),
      );
      final ModelProviderCapabilityAdapter adapter =
          ModelProviderCapabilityAdapter(
            _binding(channel),
            selectedModel: 'scripted-v1',
            maxOutputTokens: 200,
            toolChoice: ModelProviderToolChoice.none,
            providerOptions: const <String, Object?>{'fixture': true},
          );

      final List<ModelEvent> events = await adapter.invoke(_request()).toList();

      expect(channel.requestCount, 0);
      expect(channel.streamCount, 1);
      expect(channel.lastPayload!['request'], isA<Map<Object?, Object?>>());
      expect(events, <Matcher>[
        isA<ModelObservationEvent>().having(
          (ModelObservationEvent event) =>
              (event.observation as ModelTextDeltaObservation).delta,
          'delta',
          'Inspecting ',
        ),
        isA<ModelOutputItemCompleted>(),
        isA<ModelOutputItemCompleted>().having(
          (ModelOutputItemCompleted event) =>
              (event.item as ModelToolProposalOutput).providerItemId,
          'item ID',
          'item-1',
        ),
        isA<ModelInvocationCompletedEvent>(),
      ]);
    },
  );

  test(
    'common adapter preserves partial output before semantic failure',
    () async {
      final _ProviderChannel channel = _ProviderChannel(
        events: Stream<ModelProviderEvent>.fromIterable(<ModelProviderEvent>[
          _text('Partial.', 'partial-1'),
          _failedTerminal(),
        ]),
      );
      final List<ModelEvent> events = await ModelProviderCapabilityAdapter(
        _binding(channel),
        selectedModel: 'scripted-v1',
      ).invoke(_request()).toList();

      expect(events, <Matcher>[
        isA<ModelOutputItemCompleted>(),
        isA<ModelInvocationFailedEvent>().having(
          (ModelInvocationFailedEvent event) => event.error,
          'structured failure',
          isA<ModelFailure>().having(
            (ModelFailure failure) => failure.kind,
            'kind',
            ModelFailureKind.rateLimited,
          ),
        ),
      ]);
    },
  );

  test('EOF before semantic terminal fails', () async {
    final List<ModelEvent> events = await ModelProviderCapabilityAdapter(
      _binding(
        _ProviderChannel(
          events: Stream<ModelProviderEvent>.value(_text('Partial.', 'p')),
        ),
      ),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList();
    expect(events.last, isA<ModelInvocationFailedEvent>());
  });

  test('transport error after terminal does not replace settlement', () async {
    final Stream<ModelProviderEvent> events = Stream<ModelProviderEvent>.multi((
      controller,
    ) {
      controller.add(_terminal());
      controller.addError(StateError('late teardown'));
    });
    final List<ModelEvent> mapped = await ModelProviderCapabilityAdapter(
      _binding(_ProviderChannel(events: events)),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList();
    expect(mapped, hasLength(1));
    expect(mapped.single, isA<ModelInvocationCompletedEvent>());
  });

  test('consumer cancellation reaches underlying stream', () async {
    final Completer<void> cancelled = Completer<void>();
    final StreamController<ModelProviderEvent> source =
        StreamController<ModelProviderEvent>(
          onCancel: () => cancelled.complete(),
        );
    final StreamSubscription<ModelEvent> subscription =
        ModelProviderCapabilityAdapter(
          _binding(_ProviderChannel(events: source.stream)),
          selectedModel: 'scripted-v1',
        ).invoke(_request()).listen((_) {});

    await subscription.cancel();
    await cancelled.future;
  });

  test('ResourceInspector validates its exact argument shape', () {
    final ResourceInspectorToolExecutable executable =
        ResourceInspectorToolExecutable(_resourceBinding());
    expect(
      executable.validateAndNormalize(const <String, Object?>{
        'uri': 'file:///tmp/example.dart',
      }).snapshot,
      const <String, Object?>{'uri': 'file:///tmp/example.dart'},
    );
    expect(
      () => executable.validateAndNormalize(const <String, Object?>{'uri': 42}),
      throwsA(isA<ToolArgumentValidationException>()),
    );
  });
}

SemanticModelRequest _request() => SemanticModelRequest(
  invocationId: ModelInvocationId('model-1'),
  instructions: 'Be concise.',
  input: <SemanticModelInputItem>[
    SemanticMessageInput(role: SemanticMessageRole.user, content: 'Inspect.'),
  ],
  tools: MaterializedToolSet(const <MaterializedTool>[]),
);

ModelProviderEvent _delta(String text) => ModelProviderEvent(
  kind: ModelProviderEventKind.observation,
  observation: ModelProviderObservation(
    kind: ModelProviderObservationKind.textDelta,
    textDelta: text,
    itemId: null,
  ),
  output: null,
  terminal: null,
);

ModelProviderEvent _text(String text, String itemId) => ModelProviderEvent(
  kind: ModelProviderEventKind.output,
  observation: null,
  output: ModelProviderOutput(
    kind: ModelProviderOutputKind.text,
    text: text,
    toolProposal: null,
    itemId: itemId,
    nativeMetadata: null,
  ),
  terminal: null,
);

ModelProviderEvent _proposal(String callId, String itemId) =>
    ModelProviderEvent(
      kind: ModelProviderEventKind.output,
      observation: null,
      output: ModelProviderOutput(
        kind: ModelProviderOutputKind.toolProposal,
        text: null,
        toolProposal: ModelProviderToolProposal(
          callId: callId,
          name: 'inspect_resource',
          arguments: const <String, Object?>{'uri': 'file:///tmp/example.dart'},
          itemId: itemId,
          nativeMetadata: ModelProviderNativeEnvelope(
            kind: 'fixture-v1',
            compatibility: const <String, Object?>{},
            data: const <String, Object?>{'signed': 'opaque'},
          ),
        ),
        itemId: itemId,
        nativeMetadata: null,
      ),
      terminal: null,
    );

ModelProviderEvent _terminal() => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.completed,
    incompleteReason: null,
    failure: null,
    providerStopReason: 'stop',
    usage: null,
    effectiveModel: 'scripted-v1',
    responseId: 'response-1',
    requestId: 'request-1',
    nativeState: null,
  ),
);

ModelProviderEvent _failedTerminal() => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.failed,
    incompleteReason: null,
    failure: ModelProviderFailure(
      kind: ModelProviderFailureKind.rateLimited,
      providerCode: '429',
      providerMessage: 'Slow down.',
      providerDetails: const <String, Object?>{},
    ),
    providerStopReason: 'error',
    usage: null,
    effectiveModel: null,
    responseId: null,
    requestId: null,
    nativeState: null,
  ),
);

ProviderBinding _binding(AdeleStreamChannel channel) {
  final CapabilityRegistry registry = CapabilityRegistry();
  registry.register(
    provider: ProviderDescriptor(
      id: ProviderId('dev.adele.fixture.common-model'),
      capability: modelProviderCapability,
      pluginId: 'dev.adele.fixture.common-model-plugin',
      displayName: 'Common Model Fixture',
      serviceId: modelProviderServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: modelProviderServiceId,
      isAvailable: () => true,
    ),
  );
  return registry.resolve(modelProviderCapability);
}

ProviderBinding _resourceBinding() {
  final CapabilityRegistry registry = CapabilityRegistry();
  registry.register(
    provider: ProviderDescriptor(
      id: basicResourceInspectorProviderId,
      capability: resourceInspectCapability,
      pluginId: 'dev.adele.resource-inspector.basic-plugin',
      displayName: 'Basic Inspector',
      serviceId: resourceInspectorServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: _UnusedChannel(),
      serviceId: resourceInspectorServiceId,
      isAvailable: () => true,
    ),
  );
  return registry.resolve(resourceInspectCapability);
}

final class _ProviderChannel implements AdeleStreamChannel {
  _ProviderChannel({required this.events});

  final Stream<ModelProviderEvent> events;
  int requestCount = 0;
  int streamCount = 0;
  Map<String, Object?>? lastPayload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requestCount++;
    throw StateError('The model adapter must not use unary transport.');
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    streamCount++;
    expect(method, modelProviderServiceInvokeId);
    lastPayload = payload;
    return events.map<Object?>(_encodeEvent);
  }
}

Map<String, Object?> _encodeEvent(
  ModelProviderEvent event,
) => <String, Object?>{
  'kind': event.kind.name,
  'observation': event.observation == null
      ? null
      : <String, Object?>{
          'kind': event.observation!.kind.name,
          'textDelta': event.observation!.textDelta,
          'itemId': event.observation!.itemId,
        },
  'output': event.output == null ? null : _encodeOutput(event.output!),
  'terminal': event.terminal == null ? null : _encodeTerminal(event.terminal!),
};

Map<String, Object?> _encodeOutput(ModelProviderOutput output) =>
    <String, Object?>{
      'kind': output.kind.name,
      'text': output.text,
      'toolProposal': output.toolProposal == null
          ? null
          : _encodeProposal(output.toolProposal!),
      'itemId': output.itemId,
      'nativeMetadata': output.nativeMetadata == null
          ? null
          : _encodeNative(output.nativeMetadata!),
    };

Map<String, Object?> _encodeProposal(ModelProviderToolProposal proposal) =>
    <String, Object?>{
      'callId': proposal.callId,
      'name': proposal.name,
      'arguments': proposal.arguments,
      'itemId': proposal.itemId,
      'nativeMetadata': proposal.nativeMetadata == null
          ? null
          : _encodeNative(proposal.nativeMetadata!),
    };

Map<String, Object?> _encodeTerminal(ModelProviderTerminal terminal) =>
    <String, Object?>{
      'settlement': terminal.settlement.name,
      'incompleteReason': terminal.incompleteReason?.name,
      'failure': terminal.failure == null
          ? null
          : <String, Object?>{
              'kind': terminal.failure!.kind.name,
              'providerCode': terminal.failure!.providerCode,
              'providerMessage': terminal.failure!.providerMessage,
              'providerDetails': terminal.failure!.providerDetails,
            },
      'providerStopReason': terminal.providerStopReason,
      'usage': terminal.usage == null
          ? null
          : <String, Object?>{
              'inputTokens': terminal.usage!.inputTokens,
              'outputTokens': terminal.usage!.outputTokens,
              'cacheReadTokens': terminal.usage!.cacheReadTokens,
              'cacheWriteTokens': terminal.usage!.cacheWriteTokens,
              'providerDetails': terminal.usage!.providerDetails,
            },
      'effectiveModel': terminal.effectiveModel,
      'responseId': terminal.responseId,
      'requestId': terminal.requestId,
      'nativeState': terminal.nativeState == null
          ? null
          : _encodeNative(terminal.nativeState!),
    };

Map<String, Object?> _encodeNative(ModelProviderNativeEnvelope native) =>
    <String, Object?>{
      'kind': native.kind,
      'compatibility': native.compatibility,
      'data': native.data,
    };

final class _UnusedChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Unused.');
}
