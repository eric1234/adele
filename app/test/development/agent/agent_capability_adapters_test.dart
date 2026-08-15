import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';

void main() {
  test(
    'ResourceInspector validates and normalizes its exact argument shape',
    () {
      final ResourceInspectorToolExecutable executable =
          ResourceInspectorToolExecutable(_binding());

      final CanonicalToolArguments valid = executable.validateAndNormalize(
        const <String, Object?>{'uri': 'file:///tmp/example.dart'},
      );
      expect(valid.snapshot, const <String, Object?>{
        'uri': 'file:///tmp/example.dart',
      });

      for (final Map<String, Object?> invalid in <Map<String, Object?>>[
        const <String, Object?>{},
        const <String, Object?>{'uri': 42},
        const <String, Object?>{'uri': 'relative/path.dart'},
        const <String, Object?>{
          'uri': 'file:///tmp/example.dart',
          'extra': true,
        },
      ]) {
        expect(
          () => executable.validateAndNormalize(invalid),
          throwsA(isA<ToolArgumentValidationException>()),
        );
      }
    },
  );

  test(
    'endpoint rejection before dispatch has known-no-effect certainty',
    () async {
      final _UnusedChannel channel = _UnusedChannel();
      bool available = true;
      final ResourceInspectorToolExecutable executable =
          ResourceInspectorToolExecutable(
            _binding(channel: channel, isAvailable: () => available),
          );
      final CanonicalToolArguments arguments = executable.validateAndNormalize(
        const <String, Object?>{'uri': 'file:///tmp/example.dart'},
      );
      available = false;

      final List<ToolExecutionEvent> events = await executable
          .execute(
            arguments,
            ToolExecutionContext(
              runId: RunId('run-1'),
              sessionId: SessionId('session-1'),
            ),
          )
          .toList();
      final ToolOutcome outcome =
          (events.single as ToolExecutionTerminal).outcome;

      expect(outcome.failureKind, ToolFailureKind.infrastructure);
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(channel.requestCount, 0);
    },
  );

  test('ScriptedModel maps streamed items and ignores probes', () async {
    final _ScriptedStreamChannel channel = _ScriptedStreamChannel(
      items: Stream<ScriptedModelStreamItem>.fromIterable(
        <ScriptedModelStreamItem>[
          const ScriptedModelStreamItem(
            kind: ScriptedModelStreamItemKind.probe,
            text: null,
            toolCall: null,
            sequence: 0,
          ),
          const ScriptedModelStreamItem(
            kind: ScriptedModelStreamItemKind.text,
            text: 'Inspecting.',
            toolCall: null,
            sequence: null,
          ),
          const ScriptedModelStreamItem(
            kind: ScriptedModelStreamItemKind.toolCall,
            text: null,
            toolCall: ScriptedToolCall(
              id: 'call-1',
              name: 'inspect_resource',
              arguments: <String, Object?>{'uri': 'file:///tmp/example.dart'},
            ),
            sequence: null,
          ),
        ],
      ),
    );
    final ModelInvocationId invocationId = ModelInvocationId('model-1');

    final List<ModelEvent> events = await ScriptedModelCapabilityAdapter(
      _scriptedBinding(channel),
    ).invoke(_modelRequest(invocationId)).toList();

    expect(channel.requestCount, 0);
    expect(channel.streamCount, 1);
    expect(events, <Matcher>[
      isA<ModelOutputItemCompleted>().having(
        (ModelOutputItemCompleted event) =>
            (event.item as ModelTextOutput).content,
        'text',
        'Inspecting.',
      ),
      isA<ModelOutputItemCompleted>().having(
        (ModelOutputItemCompleted event) =>
            (event.item as ModelToolProposalOutput).proposal.providerCallId,
        'provider call ID',
        'call-1',
      ),
      isA<ModelInvocationCompletedEvent>(),
    ]);
    expect(
      events.every((ModelEvent event) => event.invocationId == invocationId),
      isTrue,
    );
  });

  test(
    'ScriptedModel preserves partial output before stream failure',
    () async {
      final _ScriptedStreamChannel channel = _ScriptedStreamChannel(
        items: Stream<ScriptedModelStreamItem>.multi((controller) {
          controller.add(
            const ScriptedModelStreamItem(
              kind: ScriptedModelStreamItemKind.text,
              text: 'Partial.',
              toolCall: null,
              sequence: null,
            ),
          );
          controller.addError(StateError('provider failed'));
        }),
      );

      final List<ModelEvent> events = await ScriptedModelCapabilityAdapter(
        _scriptedBinding(channel),
      ).invoke(_modelRequest(ModelInvocationId('model-2'))).toList();

      expect(events, <Matcher>[
        isA<ModelOutputItemCompleted>(),
        isA<ModelInvocationFailedEvent>().having(
          (ModelInvocationFailedEvent event) => event.error,
          'error',
          isA<StateError>(),
        ),
      ]);
    },
  );

  test('ScriptedModel fails malformed stream items', () async {
    final _ScriptedStreamChannel channel = _ScriptedStreamChannel(
      items: Stream<ScriptedModelStreamItem>.value(
        const ScriptedModelStreamItem(
          kind: ScriptedModelStreamItemKind.text,
          text: null,
          toolCall: null,
          sequence: null,
        ),
      ),
    );

    final List<ModelEvent> events = await ScriptedModelCapabilityAdapter(
      _scriptedBinding(channel),
    ).invoke(_modelRequest(ModelInvocationId('model-3'))).toList();

    expect(events, hasLength(1));
    expect(
      events.single,
      isA<ModelInvocationFailedEvent>().having(
        (ModelInvocationFailedEvent event) => event.error,
        'error',
        isA<FormatException>(),
      ),
    );
  });
}

ProviderBinding _binding({
  AdeleRequestChannel? channel,
  bool Function()? isAvailable,
}) {
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
      channel: channel ?? _UnusedChannel(),
      serviceId: resourceInspectorServiceId,
      isAvailable: isAvailable ?? () => true,
    ),
  );
  return registry.resolve(resourceInspectCapability);
}

ProviderBinding _scriptedBinding(AdeleStreamChannel channel) {
  final CapabilityRegistry registry = CapabilityRegistry();
  registry.register(
    provider: ProviderDescriptor(
      id: scriptedModelFixtureProviderId,
      capability: scriptedModelFixtureCapability,
      pluginId: 'dev.adele.scripted-model-fixture-plugin',
      displayName: 'Scripted Model Fixture',
      serviceId: scriptedModelFixtureServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: scriptedModelFixtureServiceId,
      isAvailable: () => true,
    ),
  );
  return registry.resolve(scriptedModelFixtureCapability);
}

SemanticModelRequest _modelRequest(ModelInvocationId invocationId) =>
    SemanticModelRequest(
      invocationId: invocationId,
      input: <SemanticModelInputItem>[
        SemanticMessageInput(
          role: SemanticMessageRole.user,
          content: 'Inspect the resource.',
        ),
      ],
      tools: MaterializedToolSet(const <MaterializedTool>[]),
    );

final class _UnusedChannel implements AdeleRequestChannel {
  int requestCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requestCount++;
    throw StateError('The unavailable endpoint must not dispatch a request.');
  }
}

final class _ScriptedStreamChannel implements AdeleStreamChannel {
  _ScriptedStreamChannel({required this.items});

  final Stream<ScriptedModelStreamItem> items;
  int requestCount = 0;
  int streamCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requestCount++;
    throw StateError(
      'The scripted-model adapter must not use unary transport.',
    );
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    streamCount++;
    expect(method, scriptedModelFixtureServiceInvokeStreamId);
    return items.map<Object?>(_encodeStreamItem);
  }
}

Map<String, Object?> _encodeStreamItem(ScriptedModelStreamItem item) =>
    <String, Object?>{
      'kind': item.kind.name,
      'text': item.text,
      'toolCall': switch (item.toolCall) {
        final ScriptedToolCall call => <String, Object?>{
          'id': call.id,
          'name': call.name,
          'arguments': call.arguments,
        },
        null => null,
      },
      'sequence': item.sequence,
    };
