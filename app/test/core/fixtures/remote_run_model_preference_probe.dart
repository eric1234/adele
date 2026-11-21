import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';

// Each instance is either a preference source or a set of configured model
// providers. The source cannot observe inference or select a route by itself.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map;
  final requests = <Map<String, Object?>>[];
  final providers = (options['providers'] as List?)?.cast<String>();
  final source = _Source(options['hold'] == true);
  const sourceContext = 'preference-route';
  final router = AdeleConfigurationContextRouter(
    contexts: {
      if (providers == null)
        sourceContext: {
          remoteRunModelPreferenceServiceId:
              RemoteRunModelPreferenceServiceDispatcher(source),
        }
      else
        for (final id in providers)
          id: {
            modelProviderServiceId: ModelProviderServiceDispatcher(
              _ScriptedProvider(id, requests, options['toolProvider'] == id),
            ),
          },
    },
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    if (providers == null)
      'extensionExposures': [
        AdeleExtensionExposure(
          extensionPointId: runModelPreferencesExtensionPoint.value,
          extensionId: options['extensionId'] as String,
          serviceId: remoteRunModelPreferenceServiceId,
          configurationContext: sourceContext,
          metadata: const {},
        ).toMap(),
      ]
    else
      'capabilityExposures': [
        for (final id in providers)
          AdeleCapabilityExposure(
            providerId: id,
            capabilityId: modelProviderCapability.id.value,
            capabilityMajorVersion: modelProviderCapability.majorVersion,
            serviceId: modelProviderServiceId,
            displayName: 'Scripted $id',
            configurationContext: id,
          ).toMap(),
      ],
  });

  Future<void> control(Map<Object?, Object?> message) async {
    final payload = message['payload'] as Map;
    Object? result;
    switch (message['method']) {
      case 'setPreference':
        source.preference = payload.isEmpty
            ? null
            : RemoteRunModelPreference(
                providerId: payload['providerId'] as String,
                modelId: payload['modelId'] as String,
                reasoningEffort: payload['reasoningEffort'] as String?,
              );
      case 'entered':
        await source.entered.future;
      case 'release':
        source.release();
      case 'requests':
        result = requests;
      case 'terminate':
        Isolate.exit();
      default:
        throw StateError('Unknown control method.');
    }
    responses.send({
      'kind': 'response',
      'requestId': message['requestId'],
      'ok': true,
      'payload': result,
    });
  }

  try {
    await for (final Object? message in commands) {
      if (message is! Map) continue;
      if (message['method'] == 'shutdown' && message['serviceId'] == null) {
        source.release();
        await router.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': null,
        });
        break;
      }
      if (message['serviceId'] == 'probe') {
        unawaited(control(message));
        continue;
      }
      if (message['serviceId'] == remoteRunModelPreferenceServiceId) {
        // Record the actual wire payload, not just the decoded service arguments.
        requests.add({
          'configurationContext': message['configurationContext'],
          'method': message['method'],
          'payload': message['payload'],
          'hostInvocationContext': message['hostInvocationContext'],
        });
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    source.release();
    commands.close();
    await router.close();
  }
}

final class _Source implements RemoteRunModelPreferenceService {
  _Source(this.hold);
  final bool hold;
  final entered = Completer<void>();
  final _release = Completer<void>();
  RemoteRunModelPreference? preference;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<RemoteRunModelPreference?> captureRun(
    String sessionId,
    String runId,
  ) async {
    final captured = preference;
    if (!entered.isCompleted) entered.complete();
    if (hold) await _release.future;
    return captured;
  }
}

final class _ScriptedProvider implements ModelProviderService {
  _ScriptedProvider(this.id, this.requests, this.proposeTool);
  final String id;
  final List<Map<String, Object?>> requests;
  final bool proposeTool;

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) async* {
    final outcomes = [
      for (final item in request.input)
        if (item.toolOutcome case final outcome?) outcome.status.name,
    ];
    requests.add({
      'providerId': id,
      'modelId': request.model,
      'reasoningEffort': request.reasoningEffort?.name,
      if (proposeTool) 'toolOutcomes': outcomes,
    });
    if (proposeTool && outcomes.isEmpty) {
      yield ModelProviderEvent(
        kind: ModelProviderEventKind.output,
        observation: null,
        terminal: null,
        output: ModelProviderOutput(
          kind: ModelProviderOutputKind.toolProposal,
          text: null,
          toolProposal: ModelProviderToolProposal(
            callId: 'scripted-call',
            name: request.tools.single.name,
            arguments: const {},
          ),
          itemId: null,
          nativeMetadata: null,
          nativePresentation: null,
        ),
      );
    }
    yield ModelProviderEvent(
      kind: ModelProviderEventKind.terminal,
      observation: null,
      output: null,
      terminal: ModelProviderTerminal(
        settlement: ModelProviderSettlement.completed,
        incompleteReason: null,
        failure: null,
        providerStopReason: 'stop',
        usage: null,
        effectiveModel: request.model,
        responseId: null,
        requestId: null,
        nativeState: null,
        affinityState: null,
      ),
    );
  }
}
