import 'dart:collection' as collection;
import 'dart:convert' as convert;
import 'dart:typed_data' as typed_data;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  test('helpers preserve every byte including NUL and malformed UTF-8', () {
    final bytes = List<int>.generate(256, (index) => index);
    final encoded = encodeEnvironmentProcessBytes(bytes, maximumBytes: 256);
    expect(encoded, convert.base64.encode(bytes));
    expect(decodeEnvironmentProcessBytes(encoded, maximumBytes: 256), bytes);
    for (final length in [0, 1, 2, 3, 4, 5, 6, 7]) {
      final input = bytes.take(length).toList();
      final encoded = encodeEnvironmentProcessBytes(
        input,
        maximumBytes: length,
      );
      expect(
        decodeEnvironmentProcessBytes(encoded, maximumBytes: length),
        input,
      );
    }
    expect(encodeEnvironmentProcessBytes([], maximumBytes: 0), '');
    expect(decodeEnvironmentProcessBytes('', maximumBytes: 0), isEmpty);
    expect(
      decodeEnvironmentProcessBytes('AA==', maximumBytes: 0x7fffffffffffffff),
      [0],
    );
  });

  test(
    'helpers reject invalid limits and bytes before encoding allocation',
    () {
      expect(
        () => encodeEnvironmentProcessBytes([], maximumBytes: -1),
        throwsArgumentError,
      );
      expect(
        () => decodeEnvironmentProcessBytes('', maximumBytes: -1),
        throwsArgumentError,
      );
      for (final byte in [-1, 256, 65536]) {
        expect(
          () => encodeEnvironmentProcessBytes([byte], maximumBytes: 1),
          throwsFormatException,
        );
      }
      expect(
        () =>
            encodeEnvironmentProcessBytes(_UnreadableBytes(), maximumBytes: 1),
        throwsFormatException,
      );
      for (final pair in [('AA==', 0), ('AAA=', 1), ('AAAA', 2)]) {
        expect(
          () => decodeEnvironmentProcessBytes(pair.$1, maximumBytes: pair.$2),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'canonical base64 rejects alphabet, padding and all padding-bit aliases',
    () {
      for (final encoded in _malformedBase64) {
        expect(
          () => decodeEnvironmentProcessBytes(encoded, maximumBytes: 100),
          throwsFormatException,
          reason: encoded,
        );
        expect(
          () => _request(stdinBase64: encoded),
          throwsFormatException,
          reason: encoded,
        );
        for (final stdout in [true, false]) {
          expect(
            () => EnvironmentBufferedProcessResult(
              exitCode: 0,
              stdoutBase64: stdout ? encoded : '',
              stderrBase64: stdout ? '' : encoded,
            ),
            throwsFormatException,
            reason: encoded,
          );
        }
      }
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      for (int index = 0; index < alphabet.length; index++) {
        for (final padding in [1, 2]) {
          final encoded = padding == 1
              ? 'AA${alphabet[index]}='
              : 'A${alphabet[index]}==';
          if (index % (padding == 1 ? 4 : 16) == 0) {
            final decoded = decodeEnvironmentProcessBytes(
              encoded,
              maximumBytes: 2,
            );
            expect(
              encodeEnvironmentProcessBytes(decoded, maximumBytes: 2),
              encoded,
            );
          } else {
            expect(
              () => decodeEnvironmentProcessBytes(encoded, maximumBytes: 2),
              throwsFormatException,
              reason: encoded,
            );
          }
        }
      }
    },
  );

  test('all byte limits accept exact bounds and reject one byte more', () {
    expect(environmentBufferedProcessStdinLimit, 1024 * 1024);
    expect(environmentBufferedProcessStdoutLimit, 2 * 1024 * 1024);
    expect(environmentBufferedProcessStderrLimit, 256 * 1024);
    for (final limit in [
      environmentBufferedProcessStdinLimit,
      environmentBufferedProcessStdoutLimit,
      environmentBufferedProcessStderrLimit,
    ]) {
      final bytes = typed_data.Uint8List(limit);
      final encoded = encodeEnvironmentProcessBytes(bytes, maximumBytes: limit);
      expect(
        decodeEnvironmentProcessBytes(encoded, maximumBytes: limit).length,
        limit,
      );
      final overflow = typed_data.Uint8List(limit + 1);
      final oversized = convert.base64.encode(overflow);
      // All three limits can overflow within the same encoded-length bound.
      expect(oversized.length, encoded.length);
      expect(
        () => decodeEnvironmentProcessBytes(oversized, maximumBytes: limit),
        throwsFormatException,
      );
      expect(
        () => encodeEnvironmentProcessBytes(overflow, maximumBytes: limit),
        throwsFormatException,
      );
      if (limit == environmentBufferedProcessStdinLimit) {
        expect(_request(stdinBase64: encoded).stdinBase64, encoded);
        expect(() => _request(stdinBase64: oversized), throwsFormatException);
      } else {
        EnvironmentBufferedProcessResult result(String value) =>
            EnvironmentBufferedProcessResult(
              exitCode: 9,
              stdoutBase64: limit == environmentBufferedProcessStdoutLimit
                  ? value
                  : '',
              stderrBase64: limit == environmentBufferedProcessStderrLimit
                  ? value
                  : '',
            );
        expect(result(encoded).exitCode, 9);
        expect(() => result(oversized), throwsFormatException);
      }
    }
  });

  test(
    'request snapshots verbatim arguments and bounds metadata and timeout',
    () {
      final arguments = ['', 'a | b', 'line\nend', '\u{1f642}'];
      final request = _request(arguments: arguments);
      arguments.clear();
      expect(request.arguments, ['', 'a | b', 'line\nend', '\u{1f642}']);
      expect(() => request.arguments.add('extra'), throwsUnsupportedError);
      for (final invalid in ['bad\x00text', '\ud800', '\udc00']) {
        expect(() => _request(program: invalid), throwsFormatException);
        expect(() => _request(arguments: [invalid]), throwsFormatException);
        expect(
          () => _request(relativeWorkingDirectory: invalid),
          throwsFormatException,
        );
      }
      expect(() => _request(program: ''), throwsFormatException);
      for (final timeout in [0, -1, 601]) {
        expect(() => _request(timeoutSeconds: timeout), throwsFormatException);
      }
      for (final timeout in [1, 600]) {
        expect(_request(timeoutSeconds: timeout).timeoutSeconds, timeout);
      }
      expect(_request(arguments: List.filled(256, '')).arguments.length, 256);
      expect(
        () => _request(arguments: List.filled(257, '')),
        throwsFormatException,
      );
      expect(_request(program: 'p' * 65536).program.length, 65536);
      expect(() => _request(program: 'p' * 65537), throwsFormatException);
      expect(
        _request(
          program: 'p',
          arguments: ['a' * 65534],
          relativeWorkingDirectory: 'd',
        ).relativeWorkingDirectory,
        'd',
      );
      expect(
        () => _request(
          program: 'p',
          arguments: ['a' * 65535],
          relativeWorkingDirectory: 'd',
        ),
        throwsFormatException,
      );
      // Buffered-only metadata bounds must not tighten the existing foreground API.
      expect(
        EnvironmentForegroundProcessRequest(
          program: 'p' * 65537,
          arguments: List.filled(257, ''),
          relativeWorkingDirectory: '',
          timeoutSeconds: 1,
        ).arguments.length,
        257,
      );
    },
  );

  group('generated native buffered process transport', () {
    late _BufferedProvider provider;
    late EnvironmentProviderServiceDispatcher dispatcher;
    late _Channel channel;
    late EnvironmentProviderServiceClient client;
    late GeneratedEnvironmentProvider host;

    setUp(() {
      provider = _BufferedProvider();
      dispatcher = EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
      channel = _Channel(dispatcher);
      client = EnvironmentProviderServiceClient(channel);
      host = GeneratedEnvironmentProvider(
        providerId: provider.providerId,
        service: client,
      );
    });
    tearDown(() => dispatcher.close());

    test(
      'roundtrip retains exact binary data, metadata, identity and nonzero exit',
      () async {
        final bytes = List<int>.generate(256, (index) => index);
        final input = encodeEnvironmentProcessBytes(bytes, maximumBytes: 256);
        final stderr = encodeEnvironmentProcessBytes(
          bytes.reversed.toList(),
          maximumBytes: 256,
        );
        final request = _request(
          program: 'tools/bin',
          arguments: ['', 'literal | argument', 'line\nend', '\u{1f642}'],
          relativeWorkingDirectory: 'nested dir',
          timeoutSeconds: 37,
          stdinBase64: input,
        );
        provider.result = EnvironmentBufferedProcessResult(
          exitCode: 17,
          stdoutBase64: input,
          stderrBase64: stderr,
        );
        final result = await host.runBufferedProcess(
          EnvironmentId('environment-one'),
          request,
        );
        expect(host, isA<EnvironmentBufferedProcessProvider>());
        expect(
          environmentProviderServiceRunBufferedProcessId,
          'environment.runBufferedProcess',
        );
        expect(channel.method, environmentProviderServiceRunBufferedProcessId);
        expect(channel.payload, {
          'environmentId': 'environment-one',
          'request': {
            'program': request.program,
            'arguments': request.arguments,
            'relativeWorkingDirectory': request.relativeWorkingDirectory,
            'timeoutSeconds': request.timeoutSeconds,
            'stdinBase64': input,
          },
        });
        expect(provider.calls, 1);
        expect(provider.environmentId, EnvironmentId('environment-one'));
        expect(provider.request, isNot(same(request)));
        expect(provider.request!.program, request.program);
        expect(provider.request!.arguments, request.arguments);
        expect(
          () => provider.request!.arguments.clear(),
          throwsUnsupportedError,
        );
        expect(provider.request!.relativeWorkingDirectory, 'nested dir');
        expect(provider.request!.timeoutSeconds, 37);
        expect(provider.request!.stdinBase64, input);
        expect(result, isNot(same(provider.result)));
        expect(result.exitCode, 17);
        expect(result.stdoutBase64, input);
        expect(result.stderrBase64, stderr);
        expect(
          decodeEnvironmentProcessBytes(result.stdoutBase64, maximumBytes: 256),
          bytes,
        );
        expect(
          decodeEnvironmentProcessBytes(result.stderrBase64, maximumBytes: 256),
          bytes.reversed,
        );
        expect(channel.response!['payload'], {
          'exitCode': 17,
          'stdoutBase64': input,
          'stderrBase64': stderr,
        });
      },
    );

    test(
      'empty streams and all exact byte bounds survive both codecs',
      () async {
        for (final full in [false, true]) {
          String encoded(int limit) => encodeEnvironmentProcessBytes(
            typed_data.Uint8List(full ? limit : 0),
            maximumBytes: limit,
          );
          final input = encoded(environmentBufferedProcessStdinLimit);
          provider.result = EnvironmentBufferedProcessResult(
            exitCode: 0,
            stdoutBase64: encoded(environmentBufferedProcessStdoutLimit),
            stderrBase64: encoded(environmentBufferedProcessStderrLimit),
          );
          final result = await client.runBufferedProcess(
            'environment-one',
            _request(stdinBase64: input),
          );
          expect(provider.request!.stdinBase64, input);
          expect(result.stdoutBase64, provider.result.stdoutBase64);
          expect(result.stderrBase64, provider.result.stderrBase64);
        }
      },
    );

    test(
      'dispatcher rejects malformed requests before invoking provider',
      () async {
        final valid = _encodedRequest();
        for (final request in <Object?>[
          null,
          [],
          for (final key in valid.keys) {...valid}..remove(key),
          for (final key in valid.keys) {...valid, key: null},
          {...valid, 'program': 1},
          {...valid, 'program': ''},
          {...valid, 'program': 'bad\x00program'},
          {...valid, 'arguments': 'not a list'},
          {
            ...valid,
            'arguments': [1],
          },
          {
            ...valid,
            'arguments': ['\ud800'],
          },
          {...valid, 'arguments': List.filled(257, '')},
          {...valid, 'program': 'p' * 65537},
          {...valid, 'relativeWorkingDirectory': '\udc00'},
          {...valid, 'timeoutSeconds': 1.5},
          {...valid, 'timeoutSeconds': 0},
          {...valid, 'timeoutSeconds': 601},
          {...valid, 'stdinBase64': <Object?>[]},
          for (final encoded in _malformedBase64)
            {...valid, 'stdinBase64': encoded},
          {
            ...valid,
            'stdinBase64': convert.base64.encode(
              typed_data.Uint8List(environmentBufferedProcessStdinLimit + 1),
            ),
          },
          {
            ...valid,
            'stdinBase64':
                'A' *
                (((environmentBufferedProcessStdinLimit + 2) ~/ 3) * 4 + 4),
          },
          {
            ...valid,
            'environment': {'PATH': 'forged'},
          },
          {...valid, 'extra': true},
        ]) {
          final response = await dispatcher.dispatch(
            _envelope({'environmentId': 'environment-one', 'request': request}),
          );
          expect((response['error']! as Map)['code'], 'invalid_request');
        }
        expect(provider.calls, 0);
      },
    );

    test(
      'dispatcher rejects missing fields and injected authority selectors',
      () async {
        for (final payload in <Map<String, Object?>>[
          {},
          {'request': _encodedRequest()},
          {'environmentId': 'environment-one'},
          {'environmentId': 1, 'request': _encodedRequest()},
          for (final selector in [
            'sessionId',
            'taskId',
            'runId',
            'providerId',
            'hostInvocationContext',
          ]) ...[
            {
              'environmentId': 'environment-one',
              'request': _encodedRequest(),
              selector: 'forged',
            },
            {
              'environmentId': 'environment-one',
              'request': {..._encodedRequest(), selector: 'forged'},
            },
          ],
        ]) {
          final response = await dispatcher.dispatch(_envelope(payload));
          expect((response['error']! as Map)['code'], 'invalid_request');
        }
        expect(provider.calls, 0);
        await expectLater(
          client.runBufferedProcess('', _request()),
          throwsA(
            isA<EnvironmentFailure>().having(
              (error) => error.code,
              'code',
              'invalid_environment_id',
            ),
          ),
        );
        expect(provider.calls, 0);
      },
    );

    test('client rejects malformed and oversized result payloads', () async {
      final valid = <String, Object?>{
        'exitCode': 0,
        'stdoutBase64': '',
        'stderrBase64': '',
      };
      for (final response in <Object?>[
        null,
        [],
        for (final key in valid.keys) {...valid}..remove(key),
        for (final key in valid.keys) {...valid, key: null},
        {...valid, 'exitCode': '0'},
        {...valid, 'exitCode': 1.5},
        {...valid, 'stdoutBase64': <Object?>[]},
        {...valid, 'stderrBase64': <Object?>[]},
        {...valid, 'extra': true},
        {...valid, 'stdoutTruncated': true},
        for (final field in ['stdoutBase64', 'stderrBase64']) ...[
          for (final encoded in _malformedBase64) {...valid, field: encoded},
          {
            ...valid,
            field: convert.base64.encode(
              typed_data.Uint8List(
                (field == 'stdoutBase64'
                        ? environmentBufferedProcessStdoutLimit
                        : environmentBufferedProcessStderrLimit) +
                    1,
              ),
            ),
          },
        ],
      ]) {
        await expectLater(
          EnvironmentProviderServiceClient(
            _ResponseChannel(response),
          ).runBufferedProcess('environment-one', _request()),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    });

    test(
      'declared failures reconstruct while unexpected errors remain opaque',
      () async {
        for (final code in [
          'process_start_failed',
          'process_timed_out',
          'process_output_overflow',
          'process_stdin_failed',
          'process_cleanup_failed',
        ]) {
          provider.failure = EnvironmentFailure(
            code: code,
            message: 'Buffered process failed.',
            details: const {'exitCode': 17, 'outputComplete': false},
          );
          await expectLater(
            client.runBufferedProcess('environment-one', _request()),
            throwsA(
              isA<EnvironmentFailure>()
                  .having((error) => error.code, 'code', code)
                  .having(
                    (error) => error.message,
                    'message',
                    'Buffered process failed.',
                  )
                  .having((error) => error.details, 'details', {
                    'exitCode': 17,
                    'outputComplete': false,
                  })
                  .having(
                    (error) => identical(error, provider.failure),
                    'reconstructed',
                    isFalse,
                  ),
            ),
          );
          expect(
            (channel.response!['error']! as Map)['declaredFailureType'],
            environmentFailureTypeId,
          );
        }
        provider.failure = StateError('private process detail');
        await expectLater(
          client.runBufferedProcess('environment-one', _request()),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((error) => error.code, 'code', 'internal_error')
                .having((error) => error.declaredFailureType, 'type', isNull)
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('private')),
                ),
          ),
        );
      },
    );
  });

  test(
    'missing optional facet reports declared unavailability without fallback',
    () async {
      final provider = _Provider();
      final adapter = EnvironmentProviderServiceAdapter(provider);
      final dispatcher = EnvironmentProviderServiceDispatcher(adapter);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final host = GeneratedEnvironmentProvider(
        providerId: provider.providerId,
        service: EnvironmentProviderServiceClient(channel),
      );
      expect(provider, isNot(isA<EnvironmentBufferedProcessProvider>()));
      expect(
        environmentBufferedProcessUnavailableCode,
        'buffered_process_unavailable',
      );
      for (final invoke
          in <Future<EnvironmentBufferedProcessResult> Function()>[
            () => adapter.runBufferedProcess('environment-one', _request()),
            () => host.runBufferedProcess(
              EnvironmentId('environment-one'),
              _request(),
            ),
          ]) {
        await expectLater(
          invoke(),
          throwsA(
            isA<EnvironmentFailure>()
                .having(
                  (error) => error.code,
                  'code',
                  environmentBufferedProcessUnavailableCode,
                )
                .having((error) => error.details, 'details', isEmpty),
          ),
        );
      }
      expect(
        (channel.response!['error']! as Map)['declaredFailureType'],
        environmentFailureTypeId,
      );
      expect(provider.unexpectedCalls, 0);
    },
  );
}

const _malformedBase64 = [
  'A',
  'AA',
  'AAA',
  'AAAAA',
  'AA=',
  'AAA==',
  '====',
  'A===',
  '=AAA',
  'AA=A',
  'AA==AAAA',
  'AA==\n',
  ' AA==',
  'AA== ',
  'AA-_',
  'AA__',
  'AA--',
  'AA%3D%3D',
  '\u00e9AAA',
  '\ud800AAA',
  'AB==',
  'A/==',
  'AAB=',
  'AA/=',
];

EnvironmentBufferedProcessRequest _request({
  String program = 'tool',
  List<String> arguments = const [],
  String relativeWorkingDirectory = '',
  int timeoutSeconds = 1,
  String stdinBase64 = '',
}) => EnvironmentBufferedProcessRequest(
  program: program,
  arguments: arguments,
  relativeWorkingDirectory: relativeWorkingDirectory,
  timeoutSeconds: timeoutSeconds,
  stdinBase64: stdinBase64,
);

Map<String, Object?> _encodedRequest() => {
  'program': 'tool',
  'arguments': <String>[],
  'relativeWorkingDirectory': '',
  'timeoutSeconds': 1,
  'stdinBase64': '',
};

Map<Object?, Object?> _envelope(Map<String, Object?> payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': environmentProviderServiceRunBufferedProcessId,
  'payload': payload,
};

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

final class _BufferedProvider extends _Provider
    implements EnvironmentBufferedProcessProvider {
  int calls = 0;
  EnvironmentId? environmentId;
  EnvironmentBufferedProcessRequest? request;
  Object? failure;
  EnvironmentBufferedProcessResult result = EnvironmentBufferedProcessResult(
    exitCode: 0,
    stdoutBase64: '',
    stderrBase64: '',
  );

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentId environmentId,
    EnvironmentBufferedProcessRequest request,
  ) async {
    calls++;
    this.environmentId = environmentId;
    this.request = request;
    if (failure case final error?) throw error;
    return result;
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
    final response = await dispatcher.dispatch({
      ..._envelope(payload),
      'method': method,
    });
    this.response = response;
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map<Object?, Object?>);
    }
    return response['payload'];
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

/// A size rejection must not iterate bytes or invoke the encoder.
final class _UnreadableBytes extends collection.ListBase<int> {
  @override
  int get length => 2;
  @override
  set length(int value) => throw UnsupportedError('Unreachable');
  @override
  int operator [](int index) => throw StateError('Bytes must not be read.');
  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('Unreachable');
}
