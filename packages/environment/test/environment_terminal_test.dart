import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  final dimensions = EnvironmentTerminalDimensions(columns: 80, rows: 24);
  EnvironmentTerminalRequest request({String program = '/bin/sh'}) =>
      EnvironmentTerminalRequest(
        program: program,
        arguments: ['-c', 'literal | argument'],
        relativeWorkingDirectory: 'nested',
        dimensions: dimensions,
      );

  test('terminal DTOs validate geometry, Unicode, and payload evidence', () {
    for (final pair in [(0, 24), (1001, 24), (80, 0), (80, 2001)]) {
      expect(
        () => EnvironmentTerminalDimensions(columns: pair.$1, rows: pair.$2),
        throwsFormatException,
      );
    }
    for (final program in ['', 'bad\x00name', '\ud800']) {
      expect(() => request(program: program), throwsFormatException);
    }
    final arguments = ['-i'];
    final immutable = EnvironmentTerminalRequest(
      program: '/bin/sh',
      arguments: arguments,
      relativeWorkingDirectory: '',
      dimensions: dimensions,
    );
    arguments.clear();
    expect(immutable.arguments, ['-i']);
    expect(() => immutable.arguments.add('x'), throwsUnsupportedError);
    for (final text in ['', 'x' * 8193, '\ud800', '\udc00']) {
      expect(
        () => validateEnvironmentTerminalText(text),
        throwsFormatException,
      );
    }
    validateEnvironmentTerminalText('\x00\x1b[31m\r\n\u{1f642}');
    expect(
      () => EnvironmentTerminalCompleted(
        termination: EnvironmentTerminalTermination.exited,
        exitCode: null,
      ),
      throwsFormatException,
    );
    expect(
      () => EnvironmentTerminalEvent(
        kind: EnvironmentTerminalEventKind.opened,
        opened: null,
        output: 'not opened',
        completed: null,
      ),
      throwsFormatException,
    );
    expect(
      () => EnvironmentTerminalOpened(handle: '', dimensions: dimensions),
      throwsFormatException,
    );
  });

  test(
    'generated terminal transport is lazy, ordered, and single use',
    () async {
      final provider = _Terminals();
      final dispatcher = EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final host = GeneratedEnvironmentProvider(
        providerId: provider.providerId,
        service: EnvironmentProviderServiceClient(channel),
      );
      final environment = EnvironmentId('environment-one');
      final stream = host.openTerminal(environment, request());
      expect(provider.opens, 0);
      final events = await stream.toList();
      expect(provider.opens, 1);
      expect(provider.request!.arguments, ['-c', 'literal | argument']);
      expect(provider.request!.relativeWorkingDirectory, 'nested');
      expect(events.map((event) => event.kind), [
        EnvironmentTerminalEventKind.opened,
        EnvironmentTerminalEventKind.output,
        EnvironmentTerminalEventKind.completed,
      ]);
      expect(events.first.opened!.handle, 'opaque');
      expect(events.first.opened!.dimensions.columns, 80);
      expect(events[1].output, '\x1b[32mline\r\n\u{1f642}');
      expect(events.last.completed!.exitCode, 7);
      expect(() => stream.listen((_) {}), throwsStateError);
      await host.writeTerminal(environment, 'opaque', '\x03');
      await host.resizeTerminal(environment, 'opaque', dimensions);
      await host.closeTerminal(environment, 'opaque');
      expect(provider.controls, [
        ['write', 'environment-one', 'opaque', '\x03'],
        ['resize', 'environment-one', 'opaque', 80, 24],
        ['close', 'environment-one', 'opaque'],
      ]);
    },
  );

  test('cancelling the opening cancels the resource producer', () async {
    final provider = _Terminals();
    final dispatcher = EnvironmentProviderServiceDispatcher(
      EnvironmentProviderServiceAdapter(provider),
    );
    addTearDown(dispatcher.close);
    final client = EnvironmentProviderServiceClient(_Channel(dispatcher));
    await client.openTerminal('environment-one', request()).first;
    expect(provider.settled, 1);
  });

  test(
    'generated opening rejects invalid dimensions and extra authority',
    () async {
      final provider = _Terminals();
      final dispatcher = EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final encoded = <String, Object?>{
        'program': '/bin/sh',
        'arguments': <String>[],
        'relativeWorkingDirectory': '',
        'dimensions': {'columns': 80, 'rows': 24},
      };
      for (final payload in <Map<String, Object?>>[
        {
          'environmentId': 'environment-one',
          'request': {
            ...encoded,
            'dimensions': {'columns': 0, 'rows': 24},
          },
        },
        {
          'environmentId': 'environment-one',
          'request': {...encoded, 'program': ''},
        },
        {
          'environmentId': 'environment-one',
          'request': {...encoded, 'timeoutSeconds': 600},
        },
        for (final name in [
          'sessionId',
          'runId',
          'providerId',
          'hostInvocationContext',
        ])
          {
            'environmentId': 'environment-one',
            'request': encoded,
            name: 'forged',
          },
      ]) {
        await expectLater(
          channel
              .stream(environmentProviderServiceOpenTerminalId, payload)
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
      expect(provider.opens, 0);
    },
  );

  test(
    'unsupported facet is an explicit declared Environment failure',
    () async {
      final dispatcher = EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(_NoTerminals()),
      );
      addTearDown(dispatcher.close);
      final client = EnvironmentProviderServiceClient(_Channel(dispatcher));
      final unavailable = isA<EnvironmentFailure>().having(
        (error) => error.code,
        'code',
        environmentTerminalUnavailableCode,
      );
      await expectLater(
        client.openTerminal('environment-one', request()).toList(),
        throwsA(unavailable),
      );
      await expectLater(
        client.closeTerminal('environment-one', 'opaque'),
        throwsA(unavailable),
      );
      await expectLater(
        client.writeTerminal('environment-one', 'opaque', 'x'),
        throwsA(unavailable),
      );
      await expectLater(
        client.resizeTerminal('environment-one', 'opaque', dimensions),
        throwsA(unavailable),
      );
    },
  );
}

class _NoTerminals implements EnvironmentProvider {
  @override
  ProviderId get providerId => ProviderId('dev.adele.environment.fixture');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Terminals extends _NoTerminals
    implements EnvironmentTerminalProvider {
  int opens = 0;
  int settled = 0;
  EnvironmentTerminalRequest? request;
  final controls = <List<Object>>[];

  @override
  Stream<EnvironmentTerminalEvent> openTerminal(
    EnvironmentId environmentId,
    EnvironmentTerminalRequest request,
  ) async* {
    opens++;
    this.request = request;
    try {
      yield EnvironmentTerminalEvent(
        kind: EnvironmentTerminalEventKind.opened,
        opened: EnvironmentTerminalOpened(
          handle: 'opaque',
          dimensions: request.dimensions,
        ),
        output: null,
        completed: null,
      );
      yield EnvironmentTerminalEvent(
        kind: EnvironmentTerminalEventKind.output,
        opened: null,
        output: '\x1b[32mline\r\n\u{1f642}',
        completed: null,
      );
      yield EnvironmentTerminalEvent(
        kind: EnvironmentTerminalEventKind.completed,
        opened: null,
        output: null,
        completed: EnvironmentTerminalCompleted(
          termination: EnvironmentTerminalTermination.exited,
          exitCode: 7,
        ),
      );
    } finally {
      settled++;
    }
  }

  @override
  Future<void> writeTerminal(
    EnvironmentId environmentId,
    String handle,
    String text,
  ) async {
    controls.add(['write', environmentId.value, handle, text]);
  }

  @override
  Future<void> resizeTerminal(
    EnvironmentId environmentId,
    String handle,
    EnvironmentTerminalDimensions dimensions,
  ) async {
    controls.add([
      'resize',
      environmentId.value,
      handle,
      dimensions.columns,
      dimensions.rows,
    ]);
  }

  @override
  Future<void> closeTerminal(EnvironmentId environmentId, String handle) async {
    controls.add(['close', environmentId.value, handle]);
  }
}

final class _Channel implements AdeleStreamChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  int nextId = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    Map<String, Object?>? response;
    await dispatcher.handle({
      'kind': 'request',
      'requestId': nextId++,
      'method': method,
      'payload': payload,
    }, (frame) => response = frame);
    if (response!['error'] case final Map<Object?, Object?> error) {
      throw _RemoteFailure(error);
    }
    return response!['result'];
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
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
  Map<String, Object?> get details => Map<String, Object?>.from(
    error['details'] as Map<Object?, Object?>? ?? {},
  );
}
