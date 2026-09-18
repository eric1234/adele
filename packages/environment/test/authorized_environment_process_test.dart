import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:test/test.dart';

void main() {
  late _Process service;
  late AuthorizedEnvironmentProcessServiceDispatcher dispatcher;
  late _Channel channel;
  late AuthorizedEnvironmentProcessServiceClient client;
  final request = EnvironmentForegroundProcessRequest(
    program: 'git',
    arguments: ['diff', '--check', 'literal | argument'],
    relativeWorkingDirectory: 'src',
    timeoutSeconds: 17,
  );

  setUp(() {
    service = _Process();
    dispatcher = AuthorizedEnvironmentProcessServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = AuthorizedEnvironmentProcessServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test('lazy stream roundtrips existing request and ordered events', () async {
    expect(
      authorizedEnvironmentProcessServiceId,
      'authorizedEnvironmentProcess',
    );
    final stream = client.runForegroundProcess(request);
    expect(channel.payload, isNull);
    expect(service.requests, isEmpty);
    final events = await stream.toList();
    expect(
      channel.method,
      authorizedEnvironmentProcessServiceRunForegroundProcessId,
    );
    expect(channel.payload, {
      'request': {
        'program': 'git',
        'arguments': ['diff', '--check', 'literal | argument'],
        'relativeWorkingDirectory': 'src',
        'timeoutSeconds': 17,
      },
    });
    expect(service.requests.single, isNot(same(request)));
    expect(service.requests.single.arguments, request.arguments);
    expect(events.map((event) => event.kind), [
      EnvironmentProcessEventKind.output,
      EnvironmentProcessEventKind.output,
      EnvironmentProcessEventKind.completed,
    ]);
    expect(events[0].output!.stream, EnvironmentProcessOutputStream.stdout);
    expect(events[0].output!.text, 'out\n');
    expect(events[1].output!.stream, EnvironmentProcessOutputStream.stderr);
    expect(events[1].output!.text, 'err\n');
    expect(events.last.completed!.exitCode, 7);
    expect(events.last.completed!.stdoutTruncated, isTrue);
    expect(events.last.completed!.stderrTruncated, isFalse);
    expect(() => stream.listen((_) {}), throwsStateError);
  });

  test('consumer cancellation cancels the generated producer', () async {
    expect(
      (await client.runForegroundProcess(request).first).output!.text,
      'out\n',
    );
    expect(service.settled, 1);
    expect(channel.frames.last['kind'], 'streamCancelled');
  });

  test(
    'shared declared failures reconstruct; undeclared failures stay opaque',
    () async {
      for (final declared in [true, false]) {
        service.failure = declared
            ? const EnvironmentFailure(
                code: 'process_start_failed',
                message: 'Cannot start program.',
                details: {'program': 'git'},
              )
            : StateError('private provider detail');
        await expectLater(
          client.runForegroundProcess(request).toList(),
          throwsA(
            declared
                ? isA<EnvironmentFailure>()
                      .having(
                        (error) => error.code,
                        'code',
                        'process_start_failed',
                      )
                      .having(
                        (error) => error.message,
                        'message',
                        'Cannot start program.',
                      )
                      .having((error) => error.details, 'details', {
                        'program': 'git',
                      })
                      .having(
                        (error) => identical(error, service.failure),
                        'reconstructed',
                        isFalse,
                      )
                : isA<AdeleRemoteFailure>()
                      .having((error) => error.code, 'code', 'internal_error')
                      .having(
                        (error) => error.declaredFailureType,
                        'type',
                        isNull,
                      )
                      .having(
                        (error) => error.message,
                        'opaque',
                        isNot(contains('private')),
                      ),
          ),
        );
      }
    },
  );

  test(
    'process dispatch rejects malformed requests and authority selectors',
    () async {
      final encoded = <String, Object?>{
        'program': request.program,
        'arguments': request.arguments,
        'relativeWorkingDirectory': request.relativeWorkingDirectory,
        'timeoutSeconds': request.timeoutSeconds,
      };
      for (final payload in <Map<String, Object?>>[
        {},
        {'request': null},
        {
          'request': {...encoded, 'timeoutSeconds': 0},
        },
        {
          'request': {...encoded, 'program': ''},
        },
        for (final selector in [
          'sessionId',
          'taskId',
          'runId',
          'environmentId',
          'providerId',
          'hostInvocationContext',
        ]) ...[
          {'request': encoded, selector: 'forged'},
          {
            'request': {...encoded, selector: 'forged'},
          },
        ],
      ]) {
        await expectLater(
          channel
              .stream(
                authorizedEnvironmentProcessServiceRunForegroundProcessId,
                payload,
              )
              .toList(),
          throwsA(
            isA<AdeleRemoteFailure>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
      expect(service.requests, isEmpty);
    },
  );

  test(
    'process service has no authority, read, mutation or provider methods',
    () async {
      for (final method in [
        'authorizedEnvironmentProcess.authority',
        'authorizedEnvironmentProcess.readFile',
        'authorizedEnvironmentProcess.createTextFile',
        environmentProviderServiceRunForegroundProcessId,
      ]) {
        await expectLater(
          channel.stream(method, {}).toList(),
          throwsA(
            isA<AdeleRemoteFailure>().having(
              (error) => error.code,
              'code',
              'unknown_method',
            ),
          ),
        );
      }
      expect(service.requests, isEmpty);
    },
  );
}

final class _Process implements AuthorizedEnvironmentProcessService {
  final requests = <EnvironmentForegroundProcessRequest>[];
  Object? failure;
  int settled = 0;

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) async* {
    requests.add(request);
    try {
      if (failure case final error?) throw error;
      for (final stream in EnvironmentProcessOutputStream.values) {
        yield EnvironmentProcessEvent(
          kind: EnvironmentProcessEventKind.output,
          output: EnvironmentProcessOutput(
            stream: stream,
            text: stream == EnvironmentProcessOutputStream.stdout
                ? 'out\n'
                : 'err\n',
          ),
          completed: null,
        );
      }
      yield EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.completed,
        output: null,
        completed: EnvironmentProcessCompleted(
          termination: EnvironmentProcessTermination.exited,
          exitCode: 7,
          stdoutTruncated: true,
          stderrTruncated: false,
        ),
      );
    } finally {
      settled++;
    }
  }
}

final class _Channel implements AdeleStreamChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  final frames = <Map<String, Object?>>[];
  int nextId = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Process is streaming only.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    this.method = method;
    this.payload = payload;
    final id = nextId++;
    final responses = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(responses.stream);
    void send(Map<String, Object?> frame) {
      frames.add(frame);
      responses.add(frame);
    }

    try {
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': id,
        'method': method,
        'payload': payload,
      }, send);
      while (true) {
        await dispatcher.handle({
          'kind': 'streamCredit',
          'requestId': id,
          'credit': 1,
        }, send);
        if (!await iterator.moveNext()) break;
        final frame = iterator.current;
        if (frame['kind'] == 'streamDone') break;
        if (frame['kind'] == 'streamFailure') {
          throw _RemoteFailure(frame['error']! as Map);
        }
        yield frame['payload'];
      }
    } finally {
      await dispatcher.handle({'kind': 'streamCancel', 'requestId': id}, send);
      await iterator.cancel();
      await responses.close();
    }
  }
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
      Map<String, Object?>.from(error['details'] as Map? ?? {});
}
