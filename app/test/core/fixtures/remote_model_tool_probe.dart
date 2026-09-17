import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final configuration = bootstrap['defaultConfigurationContext'] as String;
  final options = Map<String, Object?>.from(jsonDecode(arguments[1]) as Map);
  final probe = _Probe(responses, options);
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: configuration,
    serviceId: remoteModelToolServiceId,
    dispatcher: RemoteModelToolServiceDispatcher(probe),
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'extensionExposures': [
      AdeleExtensionExposure(
        extensionPointId: modelToolContributions.value,
        extensionId: arguments.first,
        serviceId: options['serviceId'] as String? ?? remoteModelToolServiceId,
        configurationContext: configuration,
        metadata: options.containsKey('metadata')
            ? Map<String, Object?>.from(options['metadata'] as Map)
            : {
                'hostServices': [
                  if (options['read'] != false)
                    authorizedEnvironmentReadServiceId,
                ],
              },
      ).toMap(),
    ],
  });
  try {
    await for (final Object? message in commands) {
      if (message is! Map) continue;
      if (message['kind'] == 'hostResponse') {
        probe.pending
            .remove(message['requestId'])
            ?.complete(Map<String, Object?>.from(message));
        continue;
      }
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        probe.close();
        await router.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      // Independent controls remain callable while a generated operation is held.
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        if (message['method'] == 'terminate') Isolate.exit();
        unawaited(probe.control(message));
        continue;
      }
      unawaited(
        router.handle(message, (response) {
          // Corrupt only generated payloads, preserving the real transport envelope.
          // Stream credits omit the method; execute is this probe's sole stream.
          final operation = response['kind'] == 'streamItem'
              ? 'execute'
              : switch (message['method']) {
                  remoteModelToolServiceMaterializeId => 'materialize',
                  remoteModelToolServiceValidateAndNormalizeId => 'validate',
                  remoteModelToolServiceDescribeId => 'describe',
                  remoteModelToolServiceExecuteId => 'execute',
                  _ => null,
                };
          if (operation != null &&
              operation == probe.malformed &&
              (response['ok'] == true || response['kind'] == 'streamItem')) {
            final payload = response['payload'];
            response['payload'] = switch (operation) {
              'materialize' => [
                {
                  ...Map<String, Object?>.from((payload! as List).first as Map),
                  'routeId': '',
                },
              ],
              'validate' => {'snapshot': <Object?>[]},
              'describe' => {
                ...Map<String, Object?>.from(payload! as Map),
                'uncertainty': 'invented',
              },
              _ => {
                ...Map<String, Object?>.from(payload! as Map),
                'kind': 'terminal',
              },
            };
          }
          responses.send(response);
        }),
      );
    }
  } finally {
    probe.close();
    commands.close();
    await router.close();
  }
}

final class _Probe implements RemoteModelToolService {
  _Probe(this.responses, this.options);

  final SendPort responses;
  final Map<String, Object?> options;
  final records = <Map<String, Object?>>[];
  final pending = <int, Completer<Map<String, Object?>>>{};
  final ready = <String, Completer<void>>{};
  final releases = <String, Completer<void>>{};
  final routes = <String>{};
  int nextRequest = 0;
  int nextMaterialization = 0;
  String? malformed;

  Future<Map<String, Object?>> call(
    String token, {
    String service = authorizedEnvironmentReadServiceId,
    String method = authorizedEnvironmentReadServiceReadFileId,
    Map<String, Object?> payload = const {'relativePath': 'probe.txt'},
  }) {
    final id = nextRequest++;
    final result = Completer<Map<String, Object?>>();
    pending[id] = result;
    responses.send({
      'kind': 'hostRequest',
      'requestId': id,
      'hostInvocationContext': token,
      'serviceId': service,
      'method': method,
      'payload': payload,
    });
    return result.future;
  }

  Future<void> control(Map<Object?, Object?> request) async {
    final payload = Map<String, Object?>.from(request['payload'] as Map);
    final Object? result = switch (request['method']) {
      'records' => records,
      'ready' =>
        await (ready[payload['operation']! as String] ??= Completer<void>())
            .future
            .then((_) => true),
      'release' => (() {
        final release = releases[payload['operation']! as String] ??=
            Completer<void>();
        if (!release.isCompleted) release.complete();
        return true;
      })(),
      'malform' => (() {
        malformed = payload['operation'] as String?;
        return true;
      })(),
      'replay' => await call(
        payload['token']! as String,
        service:
            payload['service'] as String? ?? authorizedEnvironmentReadServiceId,
        method:
            payload['method'] as String? ??
            authorizedEnvironmentReadServiceReadFileId,
        payload: payload.containsKey('payload')
            ? Map<String, Object?>.from(payload['payload'] as Map)
            : const {'relativePath': 'probe.txt'},
      ),
      _ => throw StateError('Unknown probe command ${request['method']}'),
    };
    responses.send({
      'kind': 'response',
      'requestId': request['requestId'],
      'ok': true,
      // Contract snapshots may contain views that spawnUri ports cannot send.
      'payload': jsonDecode(jsonEncode(result)),
    });
  }

  Future<void> operation(Map<String, Object?> record) async {
    records.add(record);
    final token = record['token'] as String?;
    if (token != null) {
      final read = AuthorizedEnvironmentReadServiceClient(
        _HostChannel(this, token),
      );
      final authority = await read.authority();
      record['authority'] = {
        'sessionId': authority.sessionId,
        'environmentId': authority.environmentId,
      };
      final directory = await read.readDirectory('');
      record['entries'] = directory.entries
          .map((entry) => entry.relativePath)
          .toList();
      record['text'] = (await read.readFile('probe.txt')).text;
    }
    await hold(record['operation']! as String);
  }

  Future<void> hold(String name) async {
    final entered = ready[name] ??= Completer<void>();
    if (!entered.isCompleted) entered.complete();
    if (options['hold'] == name) {
      await (releases[name] ??= Completer<void>()).future;
    }
  }

  @override
  Future<List<RemoteToolDescriptor>> materialize(
    String sessionId,
    String? hostInvocationContext,
  ) async {
    final generation = nextMaterialization++;
    final descriptors = [
      for (var index = 0; index < (options['count'] as int? ?? 1); index++)
        RemoteToolDescriptor(
          toolId: 'probe-tool-${options['collision'] == 'id' ? 0 : index}',
          toolDescription: 'Host probe tool $index',
          modelAlias: 'probe_${options['collision'] == 'alias' ? 0 : index}',
          modelDescription: 'Model probe tool $index',
          argumentsSchema: const {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
            'required': ['value'],
            'additionalProperties': false,
          },
          routeId: 'route-$generation-$index',
        ),
    ];
    routes.addAll(descriptors.map((descriptor) => descriptor.routeId));
    await operation({
      'operation': 'materialize',
      'sessionId': sessionId,
      'token': hostInvocationContext,
      'routes': descriptors.map((descriptor) => descriptor.routeId).toList(),
    });
    return descriptors;
  }

  @override
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  ) async {
    if (!routes.contains(routeId)) throw StateError('Unknown route $routeId.');
    final record = <String, Object?>{
      'operation': 'validate',
      'routeId': routeId,
      'arguments': proposedArguments,
    };
    final token =
        records.lastWhere((record) => record.containsKey('token'))['token']
            as String?;
    records.add(record);
    if (token != null) record['replay'] = await call(token);
    if (proposedArguments['value'] == 'invalid') {
      throw const RemoteToolArgumentValidationFailure(
        code: 'invalid_arguments',
        message: 'The probe rejects this value.',
        details: {},
      );
    }
    if (proposedArguments['value'] == 'crash') {
      throw StateError('Backend defect, not invalid arguments.');
    }
    return RemoteCanonicalToolArguments(
      snapshot: {'value': (proposedArguments['value']! as String).trim()},
    );
  }

  @override
  Future<RemoteEffectDescription> describe(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? hostInvocationContext,
  ) async {
    if (!routes.contains(routeId)) throw StateError('Unknown route $routeId.');
    await operation({
      'operation': 'describe',
      'routeId': routeId,
      'arguments': arguments.snapshot,
      'sessionId': sessionId,
      'runId': runId,
      'token': hostInvocationContext,
    });
    return RemoteEffectDescription.fromLocal(
      EffectDescription(
        effects: [ToolEffect.resourceInspection, ToolEffect.sourceRead],
        targets: [
          EffectTarget(
            uri: Uri.parse('adele-environment://tool-environment/probe.txt'),
          ),
        ],
        summary: 'Inspect the captured probe authority',
        uncertainty: EffectUncertainty.uncertain,
      ),
    );
  }

  @override
  Stream<RemoteToolExecutionEvent> execute(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? hostInvocationContext,
  ) async* {
    if (!routes.contains(routeId)) throw StateError('Unknown route $routeId.');
    await operation({
      'operation': 'execute',
      'routeId': routeId,
      'arguments': arguments.snapshot,
      'sessionId': sessionId,
      'runId': runId,
      'token': hostInvocationContext,
    });
    for (final progress in [
      ToolProgress(content: 'Working'),
      ToolProgress(kind: ToolProgressKind.stdout, content: 'out\n'),
      ToolProgress(kind: ToolProgressKind.stderr, content: 'err\n'),
    ]) {
      yield RemoteToolExecutionEvent.fromLocal(ToolExecutionProgress(progress));
    }
    yield RemoteToolExecutionEvent.fromLocal(
      ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: 'Probe result',
          hostData: const {
            'nested': {
              'values': [1, true, null],
            },
          },
          hostDiagnostic: 'Probe diagnostic',
          cause: StateError('This diagnostic must never cross the transport.'),
        ),
      ),
    );
    await hold('done');
  }

  void close() {
    for (final release in releases.values) {
      if (!release.isCompleted) release.complete();
    }
    for (final request in pending.values) {
      request.complete({
        'kind': 'hostResponse',
        'ok': false,
        'error': {'code': 'probe_closed', 'message': 'Probe shutdown.'},
      });
    }
    pending.clear();
  }
}

// Test framing shares raw replay correlation with generated read clients. Domain
// requests/results still use the generated contracts, not handwritten codecs.
final class _HostChannel implements AdeleRequestChannel {
  const _HostChannel(this.probe, this.token);

  final _Probe probe;
  final String token;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await probe.call(token, method: method, payload: payload);
    if (response['ok'] != true) {
      throw StateError('Host call rejected: ${response['error']}');
    }
    return response['payload'];
  }
}
