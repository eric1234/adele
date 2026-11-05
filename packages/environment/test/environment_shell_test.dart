import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  test('profile identifiers are bounded tokens, not a dialect registry', () {
    for (final id in ['a', 'AZaz09._:-', 'p' * 256]) {
      expect(_profile(profileId: id).profileId, id);
      expect(_request(expectedProfileId: id).expectedProfileId, id);
    }
    for (final id in _invalidProfileIds) {
      expect(() => _profile(profileId: id), throwsFormatException);
      expect(() => _request(expectedProfileId: id), throwsFormatException);
    }
    for (final dialect in ['a', 'provider.custom-v1_2', 'd' * 64]) {
      expect(_profile(dialect: dialect).dialect, dialect);
    }
    for (final dialect in _invalidDialects) {
      expect(() => _profile(dialect: dialect), throwsFormatException);
    }
  });

  test(
    'interpreter is bounded well-formed text without control characters',
    () {
      for (final interpreter in [
        's',
        '/path with spaces/shell',
        'C:\\Program Files\\Shell\\shell.exe',
        '/shell/\u00e9\u{1f642}',
        '${'s' * 4094}\u{1f642}',
      ]) {
        expect(_profile(interpreter: interpreter).interpreter, interpreter);
      }
      for (final interpreter in _invalidInterpreters) {
        expect(() => _profile(interpreter: interpreter), throwsFormatException);
      }
    },
  );

  test('commands preserve raw text and count UTF-16 code units', () {
    for (final command in [
      'x',
      '  printf "%s\\n" "a | b" && echo \$HOME\r\n',
      'cat <<EOF\nfirst\nsecond\nEOF\n',
      'write \u00e9\u{1f642}\t\x01',
      '${'x' * 65534}\u{1f642}',
    ]) {
      expect(_request(command: command).command, command);
    }
    for (final command in _invalidCommands) {
      expect(() => _request(command: command), throwsFormatException);
    }
  });

  test(
    'cwd uses existing text validation and timeout uses foreground bounds',
    () {
      // Syntax and confinement checks belong to the selected provider, not the DTO.
      for (final cwd in [
        '',
        './nested//dir',
        '../outside',
        '/absolute',
        'a\nb',
      ]) {
        expect(
          _request(relativeWorkingDirectory: cwd).relativeWorkingDirectory,
          cwd,
        );
      }
      for (final cwd in ['bad\x00cwd', '\ud800', '\udc00']) {
        expect(
          () => _request(relativeWorkingDirectory: cwd),
          throwsFormatException,
        );
      }
      expect(environmentForegroundProcessTimeoutLimitSeconds, 1800);
      for (final timeout in [1, 600, 601, 1800]) {
        expect(_request(timeoutSeconds: timeout).timeoutSeconds, timeout);
      }
      for (final timeout in [-1, 0, 1801]) {
        expect(() => _request(timeoutSeconds: timeout), throwsFormatException);
      }
    },
  );

  for (final generated in [false, true]) {
    group(generated ? 'generated transport' : 'native adapters', () {
      late _Shells provider;
      late GeneratedEnvironmentProvider host;
      _Channel? channel;

      setUp(() {
        provider = _Shells();
        final adapter = EnvironmentProviderServiceAdapter(provider);
        EnvironmentProviderService service = adapter;
        if (generated) {
          final dispatcher = EnvironmentProviderServiceDispatcher(adapter);
          addTearDown(dispatcher.close);
          channel = _Channel(dispatcher);
          service = EnvironmentProviderServiceClient(channel!);
        }
        host = GeneratedEnvironmentProvider(
          providerId: provider.providerId,
          service: service,
        );
      });

      test(
        'description and lazy ordered command stream retain exact values',
        () async {
          final environment = EnvironmentId('environment-one');
          final profile = await host.describeShell(environment);
          expect(host, isA<EnvironmentShellProvider>());
          expect(provider.describeCalls, 1);
          expect(provider.environmentId, environment);
          expect(profile.profileId, provider.profile.profileId);
          expect(profile.interpreter, provider.profile.interpreter);
          expect(profile.dialect, provider.profile.dialect);
          expect(identical(profile, provider.profile), !generated);
          if (generated) {
            expect(channel!.method, environmentProviderServiceDescribeShellId);
            expect(channel!.payload, {'environmentId': environment.value});
          }
          final request = _request(
            command: '  printf "\u{1f642}" | other\r\n',
            expectedProfileId: profile.profileId,
            relativeWorkingDirectory: './nested dir//',
            timeoutSeconds: 1800,
          );
          final stream = host.runShellCommand(environment, request);
          expect(provider.runCalls, 0);
          final events = await stream.toList();
          expect(provider.runCalls, 1);
          expect(provider.executions, 1);
          expect(provider.environmentId, environment);
          expect(identical(provider.request, request), !generated);
          expect(provider.request!.command, request.command);
          expect(
            provider.request!.expectedProfileId,
            request.expectedProfileId,
          );
          expect(
            provider.request!.relativeWorkingDirectory,
            request.relativeWorkingDirectory,
          );
          expect(provider.request!.timeoutSeconds, request.timeoutSeconds);
          expect(events.map((event) => event.kind), [
            EnvironmentProcessEventKind.output,
            EnvironmentProcessEventKind.output,
            EnvironmentProcessEventKind.completed,
          ]);
          expect(
            events[0].output!.stream,
            EnvironmentProcessOutputStream.stdout,
          );
          expect(events[0].output!.text, '\x1b[32mfirst\r\n\x00\u{1f642}');
          expect(
            events[1].output!.stream,
            EnvironmentProcessOutputStream.stderr,
          );
          expect(events[1].output!.text, 'diagnostic');
          expect(
            events.last.completed!.termination,
            EnvironmentProcessTermination.exited,
          );
          expect(events.last.completed!.exitCode, 7);
          expect(events.last.completed!.stdoutTruncated, isFalse);
          expect(events.last.completed!.stderrTruncated, isTrue);
          expect(() => stream.listen((_) {}), throwsStateError);
          expect(provider.settled, 1);
          if (generated) {
            expect(
              channel!.method,
              environmentProviderServiceRunShellCommandId,
            );
            expect(channel!.payload, {
              'environmentId': environment.value,
              'request': {
                'command': request.command,
                'expectedProfileId': request.expectedProfileId,
                'relativeWorkingDirectory': request.relativeWorkingDirectory,
                'timeoutSeconds': request.timeoutSeconds,
              },
            });
          }
          expect(provider.unexpectedCalls, 0);
        },
      );

      test(
        'cancellation reaches the shell producer before completion',
        () async {
          final first = await host
              .runShellCommand(EnvironmentId('environment-one'), _request())
              .first;
          expect(first.kind, EnvironmentProcessEventKind.output);
          expect(provider.settled, 1);
          expect(provider.completed, 0);
        },
      );

      test(
        'changed selection and unavailable shell are explicit failures',
        () async {
          final environment = EnvironmentId('environment-one');
          expect(environmentShellProfileChangedCode, 'shell_profile_changed');
          expect(environmentShellUnavailableCode, 'shell_unavailable');
          await expectLater(
            host
                .runShellCommand(
                  environment,
                  _request(expectedProfileId: 'old-profile'),
                )
                .toList(),
            throwsA(_failure(environmentShellProfileChangedCode)),
          );
          expect(provider.executions, 0);
          provider.failure = const EnvironmentFailure(
            code: environmentShellUnavailableCode,
            message: 'The selected shell is unavailable.',
            details: {'reason': 'missing_interpreter'},
          );
          final unavailable = _failure(environmentShellUnavailableCode)
              .having(
                (error) => error.message,
                'message',
                'The selected shell is unavailable.',
              )
              .having((error) => error.details, 'details', {
                'reason': 'missing_interpreter',
              })
              .having(
                (error) => identical(error, provider.failure),
                'same failure',
                !generated,
              );
          await expectLater(
            host.describeShell(environment),
            throwsA(unavailable),
          );
          await expectLater(
            host.runShellCommand(environment, _request()).toList(),
            throwsA(unavailable),
          );
          expect(provider.executions, 0);
          expect(provider.unexpectedCalls, 0);
        },
      );

      test('invalid Environment IDs never reach the provider', () async {
        final service = generated
            ? EnvironmentProviderServiceClient(channel!)
            : EnvironmentProviderServiceAdapter(provider);
        await expectLater(
          service.describeShell(''),
          throwsA(_failure('invalid_environment_id')),
        );
        await expectLater(
          service.runShellCommand('', _request()).toList(),
          throwsA(_failure('invalid_environment_id')),
        );
        expect(provider.describeCalls, 0);
        expect(provider.runCalls, 0);
      });

      if (generated) {
        test(
          'exact descriptor and command bounds survive both codecs',
          () async {
            provider.profile = _profile(
              profileId: 'p' * 256,
              interpreter: '${'s' * 4094}\u{1f642}',
              dialect: 'd' * 64,
            );
            final profile = await host.describeShell(
              EnvironmentId('environment-one'),
            );
            expect(profile.profileId, provider.profile.profileId);
            expect(profile.interpreter, provider.profile.interpreter);
            expect(profile.dialect, provider.profile.dialect);
            final command = '${'x' * 65534}\u{1f642}';
            await host
                .runShellCommand(
                  EnvironmentId('environment-one'),
                  _request(
                    command: command,
                    expectedProfileId: profile.profileId,
                  ),
                )
                .toList();
            expect(provider.request!.command, command);
          },
        );

        test('unexpected failures remain opaque on both methods', () async {
          provider.failure = StateError('private shell detail');
          final opaque = isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having((error) => error.declaredFailureType, 'type', isNull)
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private')),
              );
          await expectLater(
            host.describeShell(EnvironmentId('environment-one')),
            throwsA(opaque),
          );
          await expectLater(
            host
                .runShellCommand(EnvironmentId('environment-one'), _request())
                .toList(),
            throwsA(opaque),
          );
        });
      }
    });
  }

  test(
    'generated dispatcher rejects malformed requests before provider calls',
    () async {
      final provider = _Shells();
      final dispatcher = EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final valid = _encodedRequest();
      for (final request in <Object?>[
        null,
        [],
        for (final key in valid.keys) {...valid}..remove(key),
        for (final key in valid.keys) {...valid, key: null},
        for (final key in [
          'command',
          'expectedProfileId',
          'relativeWorkingDirectory',
        ])
          {...valid, key: 1},
        for (final command in _invalidCommands) {...valid, 'command': command},
        for (final id in _invalidProfileIds)
          {...valid, 'expectedProfileId': id},
        for (final cwd in ['bad\x00cwd', '\ud800', '\udc00'])
          {...valid, 'relativeWorkingDirectory': cwd},
        for (final timeout in [0, 1801, 1.5, '1'])
          {...valid, 'timeoutSeconds': timeout},
        for (final extra in [
          'program',
          'arguments',
          'interpreter',
          'dialect',
          'environment',
          'extra',
        ])
          {...valid, extra: 'forged'},
      ]) {
        await expectLater(
          channel.stream(environmentProviderServiceRunShellCommandId, {
            'environmentId': 'environment-one',
            'request': request,
          }).toList(),
          throwsA(
            isA<AdeleRemoteFailure>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
      for (final method in [
        environmentProviderServiceDescribeShellId,
        environmentProviderServiceRunShellCommandId,
      ]) {
        final payload = <String, Object?>{
          'environmentId': 'environment-one',
          if (method == environmentProviderServiceRunShellCommandId)
            'request': valid,
        };
        for (final malformed in <Map<String, Object?>>[
          for (final key in payload.keys) {...payload}..remove(key),
          {...payload, 'environmentId': null},
          {...payload, 'environmentId': 1},
          for (final selector in [
            'sessionId',
            'taskId',
            'runId',
            'providerId',
            'hostInvocationContext',
          ]) ...[
            {...payload, selector: 'forged'},
            if (method == environmentProviderServiceRunShellCommandId)
              {
                ...payload,
                'request': {...valid, selector: 'forged'},
              },
          ],
        ]) {
          await expectLater(
            method == environmentProviderServiceDescribeShellId
                ? channel.request(method, malformed)
                : channel.stream(method, malformed).toList(),
            throwsA(
              isA<AdeleRemoteFailure>().having(
                (error) => error.code,
                'code',
                'invalid_request',
              ),
            ),
          );
        }
      }
      expect(provider.describeCalls, 0);
      expect(provider.runCalls, 0);
      expect(provider.unexpectedCalls, 0);
    },
  );

  test(
    'generated client strictly validates profile response shape and values',
    () async {
      final valid = <String, Object?>{
        'profileId': 'profile:one',
        'interpreter': '/bin/shell',
        'dialect': 'custom',
      };
      for (final response in <Object?>[
        null,
        [],
        for (final key in valid.keys) {...valid}..remove(key),
        for (final key in valid.keys) {...valid, key: null},
        for (final key in valid.keys) {...valid, key: 1},
        for (final id in _invalidProfileIds) {...valid, 'profileId': id},
        for (final interpreter in _invalidInterpreters)
          {...valid, 'interpreter': interpreter},
        for (final dialect in _invalidDialects) {...valid, 'dialect': dialect},
        {...valid, 'extra': true},
        {...valid, 'environmentId': 'environment-other'},
      ]) {
        await expectLater(
          EnvironmentProviderServiceClient(
            _ResponseChannel(response),
          ).describeShell('environment-one'),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'missing optional facet fails natively and remotely without fallback',
    () async {
      final provider = _Provider();
      final adapter = EnvironmentProviderServiceAdapter(provider);
      final dispatcher = EnvironmentProviderServiceDispatcher(adapter);
      addTearDown(dispatcher.close);
      final client = EnvironmentProviderServiceClient(_Channel(dispatcher));
      expect(provider, isNot(isA<EnvironmentShellProvider>()));
      for (final service in <EnvironmentProviderService>[adapter, client]) {
        final host = GeneratedEnvironmentProvider(
          providerId: provider.providerId,
          service: service,
        );
        final unavailable = _failure(
          environmentShellUnavailableCode,
        ).having((error) => error.details, 'details', isEmpty);
        await expectLater(
          host.describeShell(EnvironmentId('environment-one')),
          throwsA(unavailable),
        );
        await expectLater(
          host
              .runShellCommand(EnvironmentId('environment-one'), _request())
              .toList(),
          throwsA(unavailable),
        );
      }
      expect(provider.unexpectedCalls, 0);
    },
  );
}

final _invalidProfileIds = [
  '',
  'p' * 257,
  'with space',
  'p/id',
  'p\n',
  '\u00e9',
  '\x00',
  '\ud800',
  '\udc00',
];
final _invalidDialects = [
  '',
  'd' * 65,
  'Bash',
  '1sh',
  '-sh',
  'a:b',
  'a b',
  'a\n',
  '\u00e9',
  '\x00',
  '\ud800',
  '\udc00',
];
final _invalidInterpreters = [
  '',
  's' * 4097,
  '${'s' * 4095}\u{1f642}',
  '\ud800',
  '\udc00',
  '\ud800x',
  for (final code in [
    ...List.generate(32, (index) => index),
    ...List.generate(33, (index) => index + 0x7f),
  ])
    'shell${String.fromCharCode(code)}',
];
final _invalidCommands = [
  '',
  ' \t\r\n',
  '\u00a0\u2003',
  'x' * 65537,
  '${'x' * 65535}\u{1f642}',
  'echo\x00bad',
  '\ud800',
  '\udc00',
  '\ud800x',
];

EnvironmentShellProfile _profile({
  String profileId = 'profile:one',
  String interpreter = '/bin/shell',
  String dialect = 'provider.custom-v1',
}) => EnvironmentShellProfile(
  profileId: profileId,
  interpreter: interpreter,
  dialect: dialect,
);

EnvironmentShellCommandRequest _request({
  String command = 'echo ready',
  String expectedProfileId = 'profile:one',
  String relativeWorkingDirectory = '',
  int timeoutSeconds = 1,
}) => EnvironmentShellCommandRequest(
  command: command,
  expectedProfileId: expectedProfileId,
  relativeWorkingDirectory: relativeWorkingDirectory,
  timeoutSeconds: timeoutSeconds,
);

Map<String, Object?> _encodedRequest() => {
  'command': 'echo ready',
  'expectedProfileId': 'profile:one',
  'relativeWorkingDirectory': '',
  'timeoutSeconds': 1,
};

TypeMatcher<EnvironmentFailure> _failure(String code) =>
    isA<EnvironmentFailure>().having((error) => error.code, 'code', code);

class _Provider implements EnvironmentProvider {
  int unexpectedCalls = 0;

  @override
  ProviderId get providerId => ProviderId('dev.adele.environment.fixture');

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    throw UnsupportedError('No other provider operations may be called.');
  }
}

final class _Shells extends _Provider implements EnvironmentShellProvider {
  EnvironmentShellProfile profile = _profile();
  EnvironmentId? environmentId;
  EnvironmentShellCommandRequest? request;
  int describeCalls = 0;
  int runCalls = 0;
  int executions = 0;
  int settled = 0;
  int completed = 0;
  Object? failure;

  @override
  Future<EnvironmentShellProfile> describeShell(
    EnvironmentId environmentId,
  ) async {
    describeCalls++;
    this.environmentId = environmentId;
    if (failure case final error?) throw error;
    return profile;
  }

  @override
  Stream<EnvironmentProcessEvent> runShellCommand(
    EnvironmentId environmentId,
    EnvironmentShellCommandRequest request,
  ) async* {
    runCalls++;
    this.environmentId = environmentId;
    this.request = request;
    if (failure case final error?) throw error;
    if (request.expectedProfileId != profile.profileId) {
      throw const EnvironmentFailure(
        code: environmentShellProfileChangedCode,
        message: 'The shell selection changed.',
        details: {},
      );
    }
    executions++;
    try {
      yield EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.output,
        output: EnvironmentProcessOutput(
          stream: EnvironmentProcessOutputStream.stdout,
          text: '\x1b[32mfirst\r\n\x00\u{1f642}',
        ),
        completed: null,
      );
      yield EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.output,
        output: EnvironmentProcessOutput(
          stream: EnvironmentProcessOutputStream.stderr,
          text: 'diagnostic',
        ),
        completed: null,
      );
      completed++;
      yield EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.completed,
        output: null,
        completed: EnvironmentProcessCompleted(
          termination: EnvironmentProcessTermination.exited,
          exitCode: 7,
          stdoutTruncated: false,
          stderrTruncated: true,
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
  int nextId = 0;
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': nextId++,
      'method': method,
      'payload': payload,
    });
    if (response['error'] case final Map<Object?, Object?> error) {
      throw _RemoteFailure(error);
    }
    return response['payload'];
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    this.method = method;
    this.payload = payload;
    final id = nextId++;
    final responses = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(responses.stream);
    try {
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': id,
        'method': method,
        'payload': payload,
      }, responses.add);
      while (true) {
        await dispatcher.handle({
          'kind': 'streamCredit',
          'requestId': id,
          'credit': 1,
        }, responses.add);
        if (!await iterator.moveNext()) break;
        final frame = iterator.current;
        if (frame['kind'] == 'streamDone') break;
        if (frame['kind'] == 'streamFailure') {
          throw _RemoteFailure(frame['error']! as Map<Object?, Object?>);
        }
        yield frame['payload'];
      }
    } finally {
      await dispatcher.handle({
        'kind': 'streamCancel',
        'requestId': id,
      }, responses.add);
      await iterator.cancel();
      await responses.close();
    }
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
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
