import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:test/test.dart';

void main() {
  late _ProcessService service;
  late AuthorizedEnvironmentBufferedProcessServiceDispatcher dispatcher;
  late _Channel channel;
  late AuthorizedEnvironmentBufferedProcessServiceClient client;

  setUp(() {
    service = _ProcessService();
    dispatcher = AuthorizedEnvironmentBufferedProcessServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = AuthorizedEnvironmentBufferedProcessServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'generated service preserves bytes and nonzero exit without selectors',
    () async {
      final bytes = List<int>.generate(256, (index) => index);
      for (final input in ['', base64.encode(bytes)]) {
        final request = EnvironmentBufferedProcessRequest(
          program: 'tool',
          arguments: ['', 'literal | argument', 'line\nend'],
          relativeWorkingDirectory: 'relative dir',
          timeoutSeconds: 5,
          stdinBase64: input,
        );
        final result = await client.runBufferedProcess(request);
        expect(
          authorizedEnvironmentBufferedProcessServiceId,
          'authorizedEnvironmentBufferedProcess',
        );
        expect(
          channel.method,
          'authorizedEnvironmentBufferedProcess.runBufferedProcess',
        );
        expect(channel.payload, {
          'request': {
            'program': 'tool',
            'arguments': ['', 'literal | argument', 'line\nend'],
            'relativeWorkingDirectory': 'relative dir',
            'timeoutSeconds': 5,
            'stdinBase64': input,
          },
        });
        expect(service.request, isNot(same(request)));
        expect(service.request!.stdinBase64, input);
        expect(result.exitCode, 17);
        expect(result.stdoutBase64, input);
        expect(result.stderrBase64, 'AP8=');
        expect(
          base64.decode(result.stdoutBase64),
          input.isEmpty ? <int>[] : bytes,
        );
      }
    },
  );

  test(
    'rejects selectors, malformed binary and unrelated operations before work',
    () async {
      final request = <String, Object?>{
        'program': 'tool',
        'arguments': <String>[],
        'relativeWorkingDirectory': '',
        'timeoutSeconds': 1,
        'stdinBase64': '',
      };
      for (final payload in <Map<String, Object?>>[
        {},
        {'request': null},
        for (final field in [
          'sessionId',
          'environmentId',
          'providerId',
          'cwd',
          'hostInvocationContext',
        ]) ...[
          {'request': request, field: 'foreign'},
          {
            'request': {...request, field: 'foreign'},
          },
        ],
        for (final invalid in ['AA', 'AB==', 'AA-_', 'AA==\n'])
          {
            'request': {...request, 'stdinBase64': invalid},
          },
      ]) {
        final response = await dispatcher.dispatch(
          _envelope(
            authorizedEnvironmentBufferedProcessServiceRunBufferedProcessId,
            payload,
          ),
        );
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      for (final method in [
        authorizedEnvironmentReadServiceAuthorityId,
        authorizedEnvironmentReadServiceReadFileId,
        authorizedEnvironmentMutationServiceCreateTextFileId,
        authorizedEnvironmentProcessServiceRunForegroundProcessId,
        environmentProviderServiceRunBufferedProcessId,
        'authorizedEnvironmentBufferedProcess.openTerminal',
      ]) {
        final response = await dispatcher.dispatch(_envelope(method, {}));
        expect((response['error']! as Map)['code'], 'unknown_method');
      }
      expect(service.calls, 0);
    },
  );

  test(
    'preserves declared unavailable, timeout and size failures, never partial success',
    () async {
      final request = EnvironmentBufferedProcessRequest(
        program: 'tool',
        arguments: [],
        relativeWorkingDirectory: '',
        timeoutSeconds: 1,
        stdinBase64: '',
      );
      for (final code in [
        environmentBufferedProcessUnavailableCode,
        'process_timed_out',
        'process_output_overflow',
        'process_stdin_failed',
        'process_cleanup_failed',
      ]) {
        service.failure = EnvironmentFailure(
          code: code,
          message: 'Process failed.',
          details: const {'outputComplete': false},
        );
        await expectLater(
          client.runBufferedProcess(request),
          throwsA(
            isA<EnvironmentFailure>()
                .having((error) => error.code, 'code', code)
                .having((error) => error.details, 'details', {
                  'outputComplete': false,
                })
                .having(
                  (error) => identical(error, service.failure),
                  'copied',
                  isFalse,
                ),
          ),
        );
      }
      service.failure = StateError('private execution detail');
      await expectLater(
        client.runBufferedProcess(request),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private')),
              ),
        ),
      );
    },
  );
}

Map<Object?, Object?> _envelope(String method, Map<String, Object?> payload) =>
    {'kind': 'request', 'requestId': 1, 'method': method, 'payload': payload};

final class _ProcessService
    implements AuthorizedEnvironmentBufferedProcessService {
  EnvironmentBufferedProcessRequest? request;
  Object? failure;
  int calls = 0;

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    calls++;
    this.request = request;
    if (failure case final error?) throw error;
    return EnvironmentBufferedProcessResult(
      exitCode: 17,
      stdoutBase64: request.stdinBase64,
      stderrBase64: 'AP8=',
    );
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch(_envelope(method, payload));
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map<Object?, Object?>);
    }
    return response['payload'];
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  _RemoteFailure(this.error);
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
