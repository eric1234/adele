import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';
import 'package:conservative_tool_policy_backend/conservative_tool_policy_backend.dart';
import 'package:test/test.dart';

import '../bin/conservative_tool_policy_backend.dart' as entrypoint;

void main() {
  const backend = ConservativeToolPolicyBackend();
  late _RecordingService service;
  late RemoteToolAuthorizationPolicyServiceDispatcher dispatcher;
  late _Channel channel;
  late RemoteToolAuthorizationPolicyServiceClient client;

  setUp(() {
    service = _RecordingService();
    dispatcher = RemoteToolAuthorizationPolicyServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = RemoteToolAuthorizationPolicyServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  const effects = [
    ToolEffect.resourceInspection,
    ToolEffect.sourceRead,
    ToolEffect.sourceMutation,
    ToolEffect.processExecution,
  ];
  test('decision matrix covers the complete public effect vocabulary', () {
    expect(effects, ToolEffect.values);
    expect(EffectUncertainty.values, [
      EffectUncertainty.none,
      EffectUncertainty.uncertain,
    ]);
  });

  for (var mask = 0; mask < 16; mask++) {
    for (final uncertainty in EffectUncertainty.values) {
      test('effect subset $mask with ${uncertainty.name}', () async {
        final selected = [
          for (var index = 0; index < effects.length; index++)
            if (mask & (1 << index) != 0) effects[index],
        ];
        final request = RemoteToolAuthorizationRequest.fromLocal(
          _localRequest(selected, uncertainty),
        );
        final expected = switch ((mask, uncertainty)) {
          (1 || 2, EffectUncertainty.none) =>
            RemoteToolAuthorizationDecision.allow,
          (4, EffectUncertainty.none) ||
          (8, _) => RemoteToolAuthorizationDecision.ask,
          _ => RemoteToolAuthorizationDecision.deny,
        };
        expect(
          await backend.evaluate(conservativeToolPolicyRouteId, request),
          expected,
        );
        expect(
          await client.evaluate(conservativeToolPolicyRouteId, request),
          expected,
        );
        expect(channel.response, {
          'kind': 'response',
          'requestId': 1,
          'ok': true,
          'payload': expected.name,
        });
        expect(
          service.request!.toLocal().effects.effects,
          unorderedEquals(selected),
        );
        expect(service.request!.toLocal().effects.uncertainty, uncertainty);
      });
    }
  }

  test(
    'generated dispatch and conversion retain exact canonical data',
    () async {
      final local = _localRequest([
        ToolEffect.sourceRead,
      ], EffectUncertainty.none);
      final request = RemoteToolAuthorizationRequest.fromLocal(local);
      expect(
        await client.evaluate(conservativeToolPolicyRouteId, request),
        RemoteToolAuthorizationDecision.allow,
      );
      expect(channel.method, remoteToolAuthorizationPolicyServiceEvaluateId);
      expect(channel.payload, {
        'routeId': 'conservative',
        'request': _wireRequest,
      });
      expect(service.routeId, 'conservative');
      expect(service.request, isNot(same(request)));
      for (final snapshot in [request, service.request!]) {
        final reconstructed = snapshot.toLocal();
        expect(reconstructed.toolId, local.toolId);
        expect(reconstructed.runId, local.runId);
        expect(reconstructed.sessionId, local.sessionId);
        expect(reconstructed.projectId, local.projectId);
        expect(reconstructed.toolInvocationId, local.toolInvocationId);
        expect(reconstructed.canonicalArguments, _arguments);
        final numbers = reconstructed.canonicalArguments['numbers']! as List;
        expect(numbers.take(3), everyElement(isA<int>()));
        expect(numbers.skip(3), everyElement(isA<double>()));
        expect((numbers.last as double).isNegative, isTrue);
        expect(reconstructed.effects.summary, _effects['summary']);
        expect(
          reconstructed.effects.targets.map((target) => target.uri.toString()),
          _effects['targetUris'],
        );
        expect(
          () => snapshot.canonicalArguments.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => (snapshot.canonicalArguments['numbers']! as List).clear(),
          throwsUnsupportedError,
        );
        expect(() => snapshot.effects.clear(), throwsUnsupportedError);
        expect(
          () => reconstructed.effects.effects.clear(),
          throwsUnsupportedError,
        );
      }
    },
  );

  for (final route in ['', 'Conservative', 'conservative ', 'other']) {
    test('unknown route "$route" is a failure, not a decision', () async {
      final request = RemoteToolAuthorizationRequest.fromLocal(
        _localRequest([ToolEffect.sourceRead], EffectUncertainty.none),
      );
      await expectLater(
        backend.evaluate(route, request),
        throwsA(
          isA<ArgumentError>()
              .having((error) => error.name, 'name', 'routeId')
              .having(
                (error) => error.message,
                'message',
                'Unknown policy route.',
              ),
        ),
      );
      final response = await dispatcher.dispatch(
        _envelope({'routeId': route, 'request': _wireRequest}),
      );
      expect(response['ok'], isFalse);
      expect(response.containsKey('payload'), isFalse);
      expect((response['error']! as Map)['code'], 'internal_error');
      expect(
        (response['error']! as Map)['message'],
        'The backend request failed unexpectedly.',
      );
    });
  }

  test(
    'malformed request shapes and identities fail before evaluation',
    () async {
      for (final payload in <Object?>[
        null,
        [],
        {},
        {'request': _wireRequest},
        {'routeId': 'conservative'},
        {'routeId': 1, 'request': _wireRequest},
        {'routeId': 'conservative', 'request': null},
        {
          'routeId': 'conservative',
          'request': _wireRequest,
          'hostInvocationContext': 'forged',
        },
        for (final key in _wireRequest.keys)
          {
            'routeId': 'conservative',
            'request': {..._wireRequest}..remove(key),
          },
        for (final key in _wireRequest.keys)
          {
            'routeId': 'conservative',
            'request': {..._wireRequest, key: 1},
          },
        for (final key in [
          'toolId',
          'runId',
          'sessionId',
          'projectId',
          'toolInvocationId',
        ])
          {
            'routeId': 'conservative',
            'request': {..._wireRequest, key: ' \t'},
          },
        {
          'routeId': 'conservative',
          'request': {..._wireRequest, 'authority': 'forged'},
        },
        for (final value in [Object(), double.nan, double.infinity])
          {
            'routeId': 'conservative',
            'request': {
              ..._wireRequest,
              'canonicalArguments': {'invalid': value},
            },
          },
      ]) {
        final response = await dispatcher.dispatch(_envelope(payload));
        expect(response['ok'], isFalse, reason: '$payload');
        expect((response['error']! as Map)['code'], 'invalid_request');
        expect(response.containsKey('payload'), isFalse);
      }
      expect(service.calls, 0);
    },
  );

  test(
    'shared effect validation rejects malformed effects, not Deny',
    () async {
      for (final effects in <Map<String, Object?>>[
        for (final key in _effects.keys) {..._effects}..remove(key),
        {..._effects, 'extra': true},
        {..._effects, 'effects': 'sourceRead'},
        {
          ..._effects,
          'effects': ['sourceRead', 'sourceRead'],
        },
        for (final effect in <Object?>['unknown', 'SourceRead', null, 1])
          {
            ..._effects,
            'effects': [effect],
          },
        for (final uri in <Object?>['relative/path', '', 'http://[', null, 1])
          {
            ..._effects,
            'targetUris': [uri],
          },
        {..._effects, 'summary': ' \n'},
        {..._effects, 'summary': null},
        for (final value in <Object?>['unknown', 'None', null, 1])
          {..._effects, 'uncertainty': value},
      ]) {
        final response = await dispatcher.dispatch(
          _envelope({
            'routeId': 'conservative',
            'request': {..._wireRequest, 'effects': effects},
          }),
        );
        expect(response['ok'], isFalse, reason: '$effects');
        expect((response['error']! as Map)['code'], 'invalid_request');
        expect(response.containsKey('payload'), isFalse);
      }
      expect(service.calls, 0);
    },
  );

  test('entrypoint is ready with one extension and no host services', () async {
    final running = await _RunningBackend.start();
    addTearDown(running.close);
    expect(running.ready, {
      'kind': 'ready',
      'commandPort': isA<SendPort>(),
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
      'extensionExposures': [
        {
          'extensionPointId': toolAuthorizationPolicies.value,
          'extensionId':
              'dev.adele.plugin.conservative-tool-policy.authorization',
          'serviceId': remoteToolAuthorizationPolicyServiceId,
          'configurationContext': 'configured-default',
          'metadata': {'routeId': 'conservative'},
        },
      ],
    });
    expect(AdeleCapabilityExposure.fromReady(running.ready), isEmpty);
    expect(AdeleExtensionExposure.fromReady(running.ready), hasLength(1));

    for (final (effect, uncertainty, decision) in [
      ('sourceRead', 'none', 'allow'),
      ('processExecution', 'uncertain', 'ask'),
      ('sourceMutation', 'uncertain', 'deny'),
    ]) {
      final response = await running.request({
        'payload': {
          'routeId': 'conservative',
          'request': {
            ..._wireRequest,
            'effects': {
              ..._effects,
              'effects': [effect],
              'uncertainty': uncertainty,
            },
          },
        },
      });
      // The first event must be the result, never a reverse host request.
      expect(response, {
        'kind': 'response',
        'requestId': 1,
        'ok': true,
        'payload': decision,
      });
    }
    await running.shutdown();
  });

  test(
    'entrypoint rejects wrong routing and malformed calls explicitly',
    () async {
      final running = await _RunningBackend.start();
      addTearDown(running.close);
      for (final (override, code) in <(Map<String, Object?>, String)>[
        ({'configurationContext': null}, 'invalid_configuration_context'),
        (
          {'configurationContext': 'other'},
          'configuration_context_unavailable',
        ),
        ({'serviceId': 'other'}, 'service_unavailable'),
        (
          {'hostInvocationContext': 'forged'},
          'host_invocation_context_unsupported',
        ),
        (
          {
            'payload': {'routeId': 'other', 'request': _wireRequest},
          },
          'internal_error',
        ),
        (
          {
            'payload': {'routeId': 'conservative'},
          },
          'invalid_request',
        ),
      ]) {
        final response = await running.request(override);
        expect(response['kind'], 'response');
        expect(response['requestId'], 1);
        expect(response['ok'], isFalse);
        expect((response['error']! as Map)['code'], code);
        expect(response.containsKey('payload'), isFalse);
      }
      expect((await running.request())['payload'], 'allow');
      await running.shutdown();
    },
  );
}

const _arguments = <String, Object?>{
  'structured': {
    'values': [
      null,
      true,
      false,
      ' exact\r\ntext ',
      {'path': 'lib/a b.dart'},
    ],
  },
  'numbers': [
    9007199254740993,
    9223372036854775807,
    -9223372036854775808,
    1.0,
    1.25,
    -0.0,
  ],
};

const _effects = <String, Object?>{
  'effects': ['sourceRead'],
  'targetUris': [
    'environment://captured/lib/a%20b.dart?rev=1#part',
    'file:///workspace/lib',
    'file:///workspace/lib',
  ],
  'summary': '  Exact effect summary\n',
  'uncertainty': 'none',
};

const _wireRequest = <String, Object?>{
  'toolId': ' exact tool ID ',
  'canonicalArguments': _arguments,
  'effects': _effects,
  'runId': 'run:captured/1',
  'sessionId': 'session:captured/2',
  'projectId': 'project:captured/3',
  'toolInvocationId': 'tool-invocation:captured/4',
};

ToolAuthorizationRequest _localRequest(
  Iterable<ToolEffect> effects,
  EffectUncertainty uncertainty,
) => ToolAuthorizationRequest(
  toolId: ToolId(' exact tool ID '),
  canonicalArguments: _arguments,
  effects: EffectDescription(
    effects: effects,
    targets: [
      for (final uri in _effects['targetUris']! as List<String>)
        EffectTarget(uri: Uri.parse(uri)),
    ],
    summary: '  Exact effect summary\n',
    uncertainty: uncertainty,
  ),
  runId: RunId('run:captured/1'),
  sessionId: SessionId('session:captured/2'),
  projectId: ProjectId('project:captured/3'),
  toolInvocationId: ToolInvocationId('tool-invocation:captured/4'),
);

Map<String, Object?> _envelope(Object? payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': remoteToolAuthorizationPolicyServiceEvaluateId,
  'payload': payload,
};

final class _RecordingService implements RemoteToolAuthorizationPolicyService {
  int calls = 0;
  String? routeId;
  RemoteToolAuthorizationRequest? request;

  @override
  Future<RemoteToolAuthorizationDecision> evaluate(
    String routeId,
    RemoteToolAuthorizationRequest request,
  ) {
    calls++;
    this.routeId = routeId;
    this.request = request;
    return const ConservativeToolPolicyBackend().evaluate(routeId, request);
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);

  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final wire =
        jsonDecode(jsonEncode({..._envelope(payload), 'method': method}))
            as Map<String, Object?>;
    final response =
        jsonDecode(jsonEncode(await dispatcher.dispatch(wire)))
            as Map<String, Object?>;
    this.response = response;
    expect(response['ok'], isTrue);
    return response['payload'];
  }
}

final class _RunningBackend {
  _RunningBackend(this.isolate, this.responses, this.messages, this.ready)
    : commands = ready['commandPort']! as SendPort;

  final Isolate isolate;
  final ReceivePort responses;
  final StreamIterator<Object?> messages;
  final Map<String, Object?> ready;
  final SendPort commands;

  static Future<_RunningBackend> start() async {
    final bootstrap = ReceivePort();
    final responses = ReceivePort();
    final messages = StreamIterator<Object?>(responses);
    final isolate = await Isolate.spawn(_runBackend, [
      bootstrap.sendPort,
      responses.sendPort,
    ]);
    try {
      final ready = await bootstrap.first.timeout(const Duration(seconds: 5));
      return _RunningBackend(
        isolate,
        responses,
        messages,
        Map<String, Object?>.from(ready! as Map),
      );
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      await messages.cancel();
      rethrow;
    } finally {
      bootstrap.close();
    }
  }

  Future<Map<String, Object?>> request([
    Map<String, Object?> overrides = const {},
  ]) {
    commands.send({
      ..._envelope({'routeId': 'conservative', 'request': _wireRequest}),
      'configurationContext': 'configured-default',
      'serviceId': remoteToolAuthorizationPolicyServiceId,
      ...overrides,
    });
    return next();
  }

  Future<Map<String, Object?>> next() async {
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    return Map<String, Object?>.from(messages.current! as Map);
  }

  Future<void> shutdown() async {
    commands.send({
      'kind': 'request',
      'requestId': 99,
      'method': 'shutdown',
      'payload': <String, Object?>{},
    });
    expect(await next(), {
      'kind': 'response',
      'requestId': 99,
      'ok': true,
      'payload': {'stopping': true},
    });
  }

  Future<void> close() async {
    isolate.kill(priority: Isolate.immediate);
    responses.close();
    await messages.cancel();
  }
}

Future<void> _runBackend(List<SendPort> ports) => entrypoint.main([], {
  'bootstrapPort': ports[0],
  'responsePort': ports[1],
  'defaultConfigurationContext': 'configured-default',
});
