import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

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

final class _UnusedChannel implements AdeleRequestChannel {
  int requestCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requestCount++;
    throw StateError('The unavailable endpoint must not dispatch a request.');
  }
}
