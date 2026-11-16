import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/remote_model_tool.dart' as tool;
import 'package:adele_orchestration/adele_orchestration.dart' as local;
import 'package:adele_orchestration/remote_tool_authorization.dart';
import 'package:test/test.dart';

void main() {
  late _Service service;
  late RemoteToolAuthorizationPolicyServiceDispatcher dispatcher;
  late _Channel channel;
  late RemoteToolAuthorizationPolicyServiceClient client;

  setUp(() {
    service = _Service();
    dispatcher = RemoteToolAuthorizationPolicyServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = RemoteToolAuthorizationPolicyServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'generated roundtrip preserves every field and exact decision',
    () async {
      const decisions = {
        local.ToolAuthorizationDecision.allow:
            RemoteToolAuthorizationDecision.allow,
        local.ToolAuthorizationDecision.deny:
            RemoteToolAuthorizationDecision.deny,
        local.ToolAuthorizationDecision.ask:
            RemoteToolAuthorizationDecision.ask,
        local.ToolAuthorizationDecision.abstain:
            RemoteToolAuthorizationDecision.abstain,
      };
      expect(
        decisions.keys,
        unorderedEquals(local.ToolAuthorizationDecision.values),
      );
      expect(
        decisions.values,
        unorderedEquals(RemoteToolAuthorizationDecision.values),
      );
      for (final entry in decisions.entries) {
        expect(remoteToolAuthorizationDecision(entry.key), entry.value);
        expect(localToolAuthorizationDecision(entry.value), entry.key);
        service.decision = entry.value;
        for (final uncertainty in local.EffectUncertainty.values) {
          final original = _localRequest(uncertainty);
          final request = RemoteToolAuthorizationRequest.fromLocal(original);
          final expected = {
            ..._wireRequest,
            'effects': {..._effects, 'uncertainty': uncertainty.name},
          };
          expect(await client.evaluate('opaque/route:1', request), entry.value);
          expect(
            remoteToolAuthorizationPolicyServiceId,
            'toolAuthorizationPolicy',
          );
          expect(channel.method, 'toolAuthorizationPolicy.evaluate');
          expect(channel.payload, {
            'routeId': 'opaque/route:1',
            'request': expected,
          });
          expect(channel.response, {
            'kind': 'response',
            'requestId': 1,
            'ok': true,
            'payload': entry.value.name,
          });
          expect(service.routeId, 'opaque/route:1');
          expect(service.request, isNot(same(request)));
          for (final reconstructed in [
            request.toLocal(),
            service.request!.toLocal(),
          ]) {
            expect(reconstructed.toolId, original.toolId);
            expect(reconstructed.runId, original.runId);
            expect(reconstructed.sessionId, original.sessionId);
            expect(reconstructed.projectId, original.projectId);
            expect(reconstructed.toolInvocationId, original.toolInvocationId);
            expect(
              reconstructed.canonicalArguments,
              original.canonicalArguments,
            );
            final numbers =
                reconstructed.canonicalArguments['numbers']! as List;
            expect(numbers.take(4), everyElement(isA<int>()));
            expect(numbers.skip(4), everyElement(isA<double>()));
            expect((numbers.last as double).isNegative, isTrue);
            expect(
              reconstructed.effects.effects.toList(),
              original.effects.effects.toList(),
            );
            expect(
              reconstructed.effects.targets.map((target) => target.uri),
              original.effects.targets.map((target) => target.uri),
            );
            expect(reconstructed.effects.summary, original.effects.summary);
            expect(reconstructed.effects.uncertainty, uncertainty);
          }
        }
      }
    },
  );

  test(
    'constructor and conversions retain deeply immutable snapshots',
    () async {
      final nested = <String, Object?>{'value': 'captured'};
      final values = <Object?>[nested];
      final arguments = <String, Object?>{'values': values};
      final effectNames = List<Object?>.from(_effects['effects']! as List);
      final targetUris = List<Object?>.from(_effects['targetUris']! as List);
      final effects = {
        ..._effects,
        'effects': effectNames,
        'targetUris': targetUris,
      };
      final request = _remoteRequest({
        ..._wireRequest,
        'canonicalArguments': arguments,
        'effects': effects,
      });
      final roundtrip = RemoteToolAuthorizationRequest.fromLocal(
        request.toLocal(),
      );
      nested['value'] = 'changed';
      values.clear();
      arguments.clear();
      effectNames.clear();
      targetUris.clear();
      effects.clear();
      await client.evaluate('route', request);

      for (final snapshot in [request, roundtrip, service.request!]) {
        expect(snapshot.canonicalArguments, {
          'values': [
            {'value': 'captured'},
          ],
        });
        expect(snapshot.effects, _effects);
        expect(
          () => snapshot.canonicalArguments.clear(),
          throwsUnsupportedError,
        );
        final retainedValues = snapshot.canonicalArguments['values']! as List;
        expect(() => retainedValues.clear(), throwsUnsupportedError);
        expect(
          () => (retainedValues.single as Map).clear(),
          throwsUnsupportedError,
        );
        expect(() => snapshot.effects.clear(), throwsUnsupportedError);
        expect(
          () => (snapshot.effects['effects']! as List).clear(),
          throwsUnsupportedError,
        );
        expect(
          () => (snapshot.effects['targetUris']! as List).clear(),
          throwsUnsupportedError,
        );
        final semantic = snapshot.toLocal();
        expect(
          () => semantic.canonicalArguments.clear(),
          throwsUnsupportedError,
        );
        expect(() => semantic.effects.effects.clear(), throwsUnsupportedError);
        expect(() => semantic.effects.targets.clear(), throwsUnsupportedError);
      }
    },
  );

  test('semantic ID validation applies in constructors and dispatch', () async {
    for (final key in [
      'toolId',
      'runId',
      'sessionId',
      'projectId',
      'toolInvocationId',
    ]) {
      for (final value in [
        '',
        ' \t\n',
        if (key != 'toolId') ...[' leading', 'trailing '],
      ]) {
        final invalid = {..._wireRequest, key: value};
        expect(
          () => _remoteRequest(invalid),
          throwsFormatException,
          reason: key,
        );
        final response = await dispatcher.dispatch(
          _envelope({'routeId': 'route', 'request': invalid}),
        );
        expect(
          (response['error']! as Map)['code'],
          'invalid_request',
          reason: key,
        );
      }
    }
    expect(service.calls, 0);
    // ToolId permits outer whitespace; transport must not impose normalization.
    final exact = _remoteRequest({
      ..._wireRequest,
      'toolId': ' exact tool ID ',
    });
    await client.evaluate('route', exact);
    expect(service.request!.toLocal().toolId.value, ' exact tool ID ');
  });

  test(
    'malformed request fields and shapes fail before policy invocation',
    () async {
      for (final payload in <Object?>[
        null,
        [],
        {},
        {'request': _wireRequest},
        {'routeId': 'route'},
        {'routeId': 1, 'request': _wireRequest},
        {'routeId': null, 'request': _wireRequest},
        {'routeId': 'route', 'request': null},
        {'routeId': 'route', 'request': <Object?>[]},
        {
          'routeId': 'route',
          'request': _wireRequest,
          'hostInvocationContext': 'forged',
        },
        for (final key in _wireRequest.keys)
          {
            'routeId': 'route',
            'request': {..._wireRequest}..remove(key),
          },
        for (final key in _wireRequest.keys)
          for (final value in <Object?>[null, 1, []])
            {
              'routeId': 'route',
              'request': {..._wireRequest, key: value},
            },
        {
          'routeId': 'route',
          'request': {..._wireRequest, 'authority': 'forged'},
        },
        {
          'routeId': 'route',
          'request': {
            ..._wireRequest,
            'canonicalArguments': <Object?, Object?>{1: 'not a string key'},
          },
        },
      ]) {
        final response = await dispatcher.dispatch(_envelope(payload));
        expect(
          (response['error']! as Map)['code'],
          'invalid_request',
          reason: '$payload',
        );
      }
      expect(service.calls, 0);
    },
  );

  test(
    'strict shared effect projection rejects malformed fields and values',
    () async {
      for (final effects in <Map<String, Object?>>[
        for (final key in _effects.keys) {..._effects}..remove(key),
        {..._effects, 'extra': true},
        for (final key in _effects.keys)
          for (final value in <Object?>[null, 1, {}]) {..._effects, key: value},
        {..._effects, 'effects': 'sourceRead'},
        {
          ..._effects,
          'effects': ['unknown'],
        },
        {
          ..._effects,
          'effects': ['SourceRead'],
        },
        {
          ..._effects,
          'effects': [0],
        },
        {
          ..._effects,
          'effects': [null],
        },
        {
          ..._effects,
          'effects': ['sourceRead', 'sourceRead'],
        },
        {..._effects, 'targetUris': 'environment://target'},
        for (final uri in <Object?>[null, 1, '', 'relative/path', 'http://['])
          {
            ..._effects,
            'targetUris': [uri],
          },
        {..._effects, 'summary': ' \t'},
        {..._effects, 'summary': []},
        {..._effects, 'uncertainty': 'unknown'},
        {..._effects, 'uncertainty': 'None'},
        {..._effects, 'uncertainty': []},
      ]) {
        expect(
          () => tool.RemoteEffectDescription.fromJson(effects),
          throwsFormatException,
          reason: '$effects',
        );
        final invalid = {..._wireRequest, 'effects': effects};
        expect(() => _remoteRequest(invalid), throwsFormatException);
        final response = await dispatcher.dispatch(
          _envelope({'routeId': 'route', 'request': invalid}),
        );
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(service.calls, 0);
      final empty = _remoteRequest({
        ..._wireRequest,
        'effects': {
          ..._effects,
          'effects': <Object?>[],
          'targetUris': <Object?>[],
        },
      });
      await client.evaluate('route', empty);
      expect(service.request!.toLocal().effects.effects, isEmpty);
      expect(service.request!.toLocal().effects.targets, isEmpty);
    },
  );

  test(
    'non-JSON, cyclic, deep and nonfinite arguments fail rather than coerce',
    () async {
      final cycle = <Object?>[];
      cycle.add(cycle);
      Object? deep;
      for (var i = 0; i < 65; i++) {
        deep = [deep];
      }
      for (final value in [
        Object(),
        double.nan,
        double.infinity,
        double.negativeInfinity,
        cycle,
        deep,
      ]) {
        final invalid = {
          ..._wireRequest,
          'canonicalArguments': {'nested': value},
        };
        expect(() => _remoteRequest(invalid), throwsFormatException);
        final response = await dispatcher.dispatch(
          _envelope({'routeId': 'route', 'request': invalid}),
        );
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(service.calls, 0);
    },
  );

  test('malformed and unknown decisions remain protocol failures', () async {
    for (final response in <Object?>[
      null,
      0,
      true,
      [],
      {},
      {'decision': 'allow'},
      'Allow',
      ' allow',
      '',
      'unknown',
    ]) {
      await expectLater(
        RemoteToolAuthorizationPolicyServiceClient(
          _ResponseChannel(response),
        ).evaluate('route', _remoteRequest(_wireRequest)),
        throwsA(isA<AdeleProtocolException>()),
        reason: '$response',
      );
    }
  });

  test(
    'backend exceptions become opaque failures, never Deny or Abstain',
    () async {
      for (final failure in [
        StateError('private policy detail'),
        const FormatException('private format detail'),
      ]) {
        service.failure = failure;
        await expectLater(
          client.evaluate('route', _remoteRequest(_wireRequest)),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((error) => error.code, 'code', 'internal_error')
                .having(
                  (error) => error.declaredFailureType,
                  'declared type',
                  isNull,
                )
                .having(
                  (error) => error.message,
                  'message',
                  'The backend request failed unexpectedly.',
                )
                .having((error) => error.details, 'details', isEmpty),
          ),
        );
        expect(jsonEncode(channel.response), isNot(contains('private')));
      }
      service.failure = null;
      expect(
        await client.evaluate('route', _remoteRequest(_wireRequest)),
        RemoteToolAuthorizationDecision.allow,
      );
    },
  );
}

const _arguments = <String, Object?>{
  'structured': {
    'values': [
      null,
      true,
      false,
      ' exact\ntext ',
      {'path': 'lib/main.dart'},
    ],
  },
  'numbers': [
    0,
    9007199254740993,
    9223372036854775807,
    -9223372036854775808,
    1.0,
    1.25,
    double.maxFinite,
    double.minPositive,
    -0.0,
  ],
};

const _effects = <String, Object?>{
  'effects': [
    'processExecution',
    'sourceMutation',
    'sourceRead',
    'resourceInspection',
  ],
  'targetUris': [
    'environment://captured/lib/a%20b.dart?rev=1#part',
    'file:///workspace/lib',
    'file:///workspace/lib',
  ],
  'summary': '  Exact effect summary\n',
  'uncertainty': 'uncertain',
};

const _wireRequest = <String, Object?>{
  'toolId': 'dev.adele.tool.test',
  'canonicalArguments': _arguments,
  'effects': _effects,
  'runId': 'run:captured/1',
  'sessionId': 'session:captured/2',
  'projectId': 'project:captured/3',
  'toolInvocationId': 'tool-invocation:captured/4',
};

local.ToolAuthorizationRequest _localRequest(
  local.EffectUncertainty uncertainty,
) => local.ToolAuthorizationRequest(
  toolId: local.ToolId('dev.adele.tool.test'),
  canonicalArguments: _arguments,
  effects: local.EffectDescription(
    effects: local.ToolEffect.values.reversed,
    targets: [
      for (final uri in _effects['targetUris']! as List<String>)
        local.EffectTarget(uri: Uri.parse(uri)),
    ],
    summary: '  Exact effect summary\n',
    uncertainty: uncertainty,
  ),
  runId: local.RunId('run:captured/1'),
  sessionId: local.SessionId('session:captured/2'),
  projectId: local.ProjectId('project:captured/3'),
  toolInvocationId: local.ToolInvocationId('tool-invocation:captured/4'),
);

RemoteToolAuthorizationRequest _remoteRequest(Map<String, Object?> fields) =>
    RemoteToolAuthorizationRequest(
      toolId: fields['toolId']! as String,
      canonicalArguments: fields['canonicalArguments']! as Map<String, Object?>,
      effects: fields['effects']! as Map<String, Object?>,
      runId: fields['runId']! as String,
      sessionId: fields['sessionId']! as String,
      projectId: fields['projectId']! as String,
      toolInvocationId: fields['toolInvocationId']! as String,
    );

Map<String, Object?> _envelope(Object? payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': remoteToolAuthorizationPolicyServiceEvaluateId,
  'payload': payload,
};

final class _Service implements RemoteToolAuthorizationPolicyService {
  RemoteToolAuthorizationDecision decision =
      RemoteToolAuthorizationDecision.allow;
  String? routeId;
  RemoteToolAuthorizationRequest? request;
  Object? failure;
  int calls = 0;

  @override
  Future<RemoteToolAuthorizationDecision> evaluate(
    String routeId,
    RemoteToolAuthorizationRequest request,
  ) async {
    calls++;
    this.routeId = routeId;
    this.request = request;
    if (failure case final Object error) throw error;
    return decision;
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
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return response['payload'];
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;

  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}
