import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';
import 'package:test/test.dart';

void main() {
  const exact = '  Org/Model.Mixed@v1+fine:tuned  ';
  const provider = 'dev.adele.test.account';

  test(
    'generated capture transports only identities and three exact semantic fields',
    () async {
      final source = _Source();
      final dispatcher = RemoteRunModelPreferenceServiceDispatcher(source);
      addTearDown(dispatcher.close);
      final channel = _Channel((method, args) async {
        expect(method, 'runModelPreference.captureRun');
        expect(args, {'sessionId': 'session', 'runId': 'run'});
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': method,
          'payload': args,
        });
        expect(response, {
          'kind': 'response',
          'requestId': 1,
          'ok': true,
          'payload': source.value == null
              ? null
              : {
                  'providerId': provider,
                  'modelId': exact,
                  'reasoningEffort': source.value!.reasoningEffort,
                },
        });
        return response['payload'];
      });
      final client = RemoteRunModelPreferenceServiceClient(channel);
      expect(remoteRunModelPreferenceServiceId, 'runModelPreference');
      expect(await client.captureRun('session', 'run'), isNull);
      for (final effort in [null, ...ModelReasoningEffort.values]) {
        source.value = RemoteRunModelPreference(
          providerId: provider,
          modelId: exact,
          reasoningEffort: effort?.name,
        );
        final remote = (await client.captureRun('session', 'run'))!;
        expect(remote, isNot(same(source.value)));
        final value = remote.toLocal();
        expect(value.providerId, ProviderId(provider));
        expect(value.modelId, exact);
        expect(value.reasoningEffort, effort);
        expect(source.invocation, ('session', 'run'));
      }
    },
  );

  test('malformed wire results never decode as no opinion', () async {
    const valid = {
      'providerId': provider,
      'modelId': exact,
      'reasoningEffort': null,
    };
    for (final invalid in <Object>[
      false,
      [],
      {},
      {'providerId': provider, 'modelId': exact},
      {...valid, 'route': 'unexpected'},
      {...valid, 'providerId': '/private/owner'},
      {...valid, 'providerId': null},
      {
        ...valid,
        'providerId': 'dev.${'a' * RunModelPreference.maxProviderIdLength}',
      },
      {...valid, 'modelId': '  '},
      {...valid, 'modelId': 'x' * 1025},
      {...valid, 'modelId': 'ok\rprivate'},
      {...valid, 'reasoningEffort': 'None'},
      {...valid, 'reasoningEffort': ''},
      {...valid, 'reasoningEffort': 1},
    ]) {
      final client = RemoteRunModelPreferenceServiceClient(
        _Channel((_, _) async => invalid),
      );
      await expectLater(
        client.captureRun('session', 'run'),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });

  test(
    'dispatcher rejects extra authority and reports opaque source failures',
    () async {
      final source = _Source()..failure = StateError('/private/config');
      final dispatcher = RemoteRunModelPreferenceServiceDispatcher(source);
      addTearDown(dispatcher.close);
      Future<Map<String, Object?>> dispatch(Map<String, Object?> args) =>
          dispatcher.dispatch({
            'kind': 'request',
            'requestId': 2,
            'method': remoteRunModelPreferenceServiceCaptureRunId,
            'payload': args,
          });
      for (final invalid in [
        {'sessionId': 'session'},
        {'sessionId': 'session', 'runId': 7},
        {
          'sessionId': 'session',
          'runId': 'run',
          'hostInvocationContext': 'grant',
        },
      ]) {
        final response = await dispatch(invalid);
        expect(response['ok'], false);
        expect((response['error'] as Map)['code'], 'invalid_request');
        expect(source.invocation, isNull);
      }
      final response = await dispatch({'sessionId': 'session', 'runId': 'run'});
      expect(source.invocation, ('session', 'run'));
      expect(response['ok'], false);
      expect((response['error'] as Map)['code'], 'internal_error');
      expect(response.toString(), isNot(contains('/private/config')));
      expect(response, isNot(contains('payload')));
    },
  );
}

final class _Source implements RemoteRunModelPreferenceService {
  (String, String)? invocation;
  RemoteRunModelPreference? value;
  Object? failure;

  @override
  Future<RemoteRunModelPreference?> captureRun(
    String sessionId,
    String runId,
  ) async {
    invocation = (sessionId, runId);
    if (failure case final error?) throw error;
    return value;
  }
}

final class _Channel implements AdeleRequestChannel {
  const _Channel(this.send);

  final Future<Object?> Function(String, Map<String, Object?>) send;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      send(method, payload);
}
