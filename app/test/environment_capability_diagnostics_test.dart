import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/backend_invocation_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_diagnostics.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:diagnostic_probe/main.dart';
const _secret = 'PRIVATE /home/private/repository token:secret payload text';
const _context = {
  'service': 'test.snapshot',
  'method': 'test.snapshot.read',
  'provider': 'dev.adele.test.snapshot',
  'environmentProvider': 'dev.adele.test.environment',
  'grant': 'bufferedProcess',
};

void main() {
  late List<String> lines;
  late EnvironmentCapabilityDiagnostics diagnostics;
  late Program program;

  setUpAll(() {
    program =
        (Compiler()
              ..addPlugin(const EnvironmentCapabilityAccessDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'diagnostic_probe': {
                'main.dart': '''
import 'package:adele_ui/environment_capability_bridge.dart';
Future<String> value() async => 'safe-value';
Future<List<dynamic>> omitted() => settleEnvironmentCapabilityOperation(value());
Future<List<dynamic>> explicitNull() =>
    settleEnvironmentCapabilityOperation(value(), null);
Future<List<dynamic>> foreign() =>
    settleEnvironmentCapabilityOperation(value(), 'foreign-handle');
Future<List<dynamic>> denied() => settleEnvironmentCapabilityOperation(
    requestEnvironmentCapability('foreign-handle', 'test.read', {}),
    'foreign-handle');
''',
              },
              'adele_contract': {
                'adele_contract.dart': evalContractSupportSource,
              },
              'adele_ui': {
                'environment_capability_bridge.dart': File(
                  '../packages/ui/lib/environment_capability_bridge.dart',
                ).readAsStringSync(),
              },
            });
  });

  setUp(() {
    lines = [];
    diagnostics = EnvironmentCapabilityDiagnostics(
      debugBuild: true,
      environment: {EnvironmentCapabilityDiagnostics.flag: '1'},
      sink: lines.add,
    );
  });

  group('native diagnostics', () {
    for (final debugBuild in [false, true]) {
      for (final flag in <String?>[
        null,
        '',
        '0',
        'true',
        '01',
        ' 1',
        '1 ',
        '1',
      ]) {
        test('opt-in requires debug=$debugBuild and exact flag=$flag', () {
          diagnostics = EnvironmentCapabilityDiagnostics(
            debugBuild: debugBuild,
            environment: {EnvironmentCapabilityDiagnostics.flag: ?flag},
            sink: lines.add,
          );
          final operation = _begin(diagnostics);
          expect(operation != null, debugBuild && flag == '1');
          operation?.response();
          operation?.settle(null);
          expect(lines.length, debugBuild && flag == '1' ? 2 : 0);
        });
      }
    }

    test('records contain only bounded semantic metadata and duration', () {
      final first = _begin(diagnostics)!;
      expect(lines, isEmpty);
      first.response();
      first.settle(null);
      first.settle(_OpaqueFailure());
      _begin(diagnostics)!.failure('invocation', _RemoteFailure());

      final records = _records(lines);
      expect(records, hasLength(3));
      expect(records.map((record) => record['operation']), [1, 1, 2]);
      expect(records.map((record) => record['phase']), [
        'response',
        'response-decoding',
        'invocation',
      ]);
      expect(records.map((record) => record['outcome']), [
        'success',
        'success',
        'failure',
      ]);
      for (final record in records) {
        for (final entry in _context.entries) {
          expect(record[entry.key], entry.value);
        }
      }
      expect(records.last['classification'], 'remote-failure');
      expect(records.last['code'], 'snapshot_too_large');
    });

    test(
      'semantic identifiers and declared codes are bounded and sanitized',
      () {
        for (final value in [
          'a',
          'test.read_v1-2',
          List.filled(128, 'a').join(),
          '',
          '1bad',
          '/home/private/repository',
          'file:///home/private/repository',
          'token:secret',
          'two words',
          'injected\nline',
          List.filled(129, 'a').join(),
        ]) {
          final operation = diagnostics.begin(
            service: value,
            method: value,
            provider: value,
            environmentProvider: value,
            grant: value,
          )!;
          operation.failure('invocation', _RemoteFailure(code: value));
          final record = _records([lines.last]).single;
          final accepted = [
            'a',
            'test.read_v1-2',
            List.filled(128, 'a').join(),
          ];
          for (final key in [..._context.keys, 'code']) {
            expect(record[key], accepted.contains(value) ? value : 'redacted');
          }
        }
      },
    );

    for (final (error, classification) in <(Object, String)>[
      (_RemoteFailure(), 'remote-failure'),
      (const PluginConnectionClosed(_secret), 'connection-closed'),
      (const BackendHostProtocolException(_secret), 'transport-protocol'),
      (TimeoutException(_secret), 'timeout'),
      (const FormatException(_secret, _secret), 'invalid-format'),
      (StateError(_secret), 'invalid-state'),
      (ArgumentError.value(_secret, _secret, _secret), 'invalid-argument'),
      (_OpaqueFailure(), 'opaque-failure'),
    ]) {
      test(
        'failure uses fixed $classification without inspecting private data',
        () {
          final operation = _begin(diagnostics)!;
          operation.failure('invocation', error);
          operation.settle(error);
          expect(lines, hasLength(1));
          final record = _records(lines).single;
          expect(record['classification'], classification);
          expect(record.containsKey('code'), error is AdeleRemoteFailure);
          if (error is _OpaqueFailure) expect(error.stringReads, 0);
          if (error is _RemoteFailure) expect(error.privateReads, 0);
        },
      );
    }

    test(
      'decode failure is distinct from invocation failure and settles once',
      () {
        final error = _OpaqueFailure();
        final operation = _begin(diagnostics)!;
        operation.response();
        operation.settle(error);
        operation.settle(null);
        final records = _records(lines);
        expect(records, hasLength(2));
        expect(records.last['phase'], 'response-decoding');
        expect(records.last['outcome'], 'failure');
        expect(records.last['classification'], 'opaque-failure');
        expect(error.stringReads, 0);
      },
    );

    test('settlement without a native response does not claim decoding', () {
      _begin(diagnostics)!.settle(_OpaqueFailure());
      final record = _records(lines).single;
      expect(record['phase'], 'client-settlement');
      expect(record['outcome'], 'failure');
    });

    test('later handle reuse suppresses an already captured settlement', () {
      final first = _begin(diagnostics)!;
      final capturedForSettlement = first;
      first.suppressSettlement();
      first.response();
      capturedForSettlement.settle(_OpaqueFailure());
      expect(_records(lines).single['phase'], 'response');
    });
  });

  group('request and settlement behavior', () {
    late BackendInvocationBridge bridge;
    late _Channel channel;
    EnvironmentCapabilityDiagnostic? operation;
    Object? admissionError;
    Object? settlementError;
    late bool allowRoute;
    late int admissions;
    late int settlements;

    setUp(() {
      operation = null;
      admissionError = null;
      settlementError = null;
      allowRoute = true;
      admissions = 0;
      settlements = 0;
      channel = _Channel();
      bridge = BackendInvocationBridge(
        channelFor: (_) => allowRoute ? channel : null,
        validateAdmission: () {
          admissions++;
          if (admissionError != null) throw admissionError!;
        },
        validateSettlement: () {
          settlements++;
          if (settlementError != null) throw settlementError!;
        },
        isPresentationActive: () => true,
        beginDiagnostic: (method) =>
            operation = _begin(diagnostics, method: method),
      );
      addTearDown(bridge.invalidate);
    });

    test(
      'copies request and response without logging either or the handle',
      () async {
        final payload = <String, Object?>{'token': _secret};
        final response = <String, Object?>{
          'path': _secret,
          'details': [_secret],
        };
        channel.response = response;
        final result = await bridge.request(
          _secret,
          _context['method']!,
          payload,
        );
        expect(result, response);
        expect(identical(result, response), isFalse);
        expect(channel.payloads.single, payload);
        expect(identical(channel.payloads.single, payload), isFalse);
        expect(
          () => channel.payloads.single['token'] = 'changed',
          throwsUnsupportedError,
        );
        expect(
          () => (result as Map)['path'] = 'changed',
          throwsUnsupportedError,
        );
        expect(admissions, 1);
        expect(settlements, 1);
        final record = _records(lines).single;
        expect(record['phase'], 'response');
        expect(record['outcome'], 'success');
      },
    );

    for (final rejection in ['admission', 'route', 'method', 'payload']) {
      test('$rejection rejection stays before invocation', () async {
        final error = _OpaqueFailure();
        if (rejection == 'admission') admissionError = error;
        if (rejection == 'route') allowRoute = false;
        await expectLater(
          bridge.request(
            _secret,
            rejection == 'method' ? '' : _context['method']!,
            rejection == 'payload' ? [_secret] : {'token': _secret},
          ),
          rejection == 'admission' ? throwsA(same(error)) : throwsA(anything),
        );
        operation!.settle(error);
        expect(channel.payloads, isEmpty);
        expect(settlements, 0);
        final record = _records(lines).single;
        expect(record['phase'], 'admission');
        expect(record['outcome'], 'failure');
      });
    }

    test(
      'invocation error identity is preserved and not relabeled as decoding',
      () async {
        final error = _RemoteFailure();
        channel.error = error;
        await expectLater(
          bridge.request(_secret, 'test.read', {}),
          throwsA(same(error)),
        );
        operation!.settle(error);
        expect(channel.payloads, hasLength(1));
        expect(settlements, 0);
        expect(_records(lines).single['phase'], 'invocation');
        expect(error.privateReads, 0);
      },
    );

    test(
      'uncopyable response is not reported as successful or decoded',
      () async {
        channel.response = _OpaqueFailure();
        await expectLater(
          bridge.request(_secret, 'test.read', {}),
          throwsFormatException,
        );
        operation!.settle(_OpaqueFailure());
        final record = _records(lines).single;
        expect(record['phase'], 'response');
        expect(record['outcome'], 'failure');
        expect(record['classification'], 'invalid-format');
      },
    );

    for (final retire in [false, true]) {
      test(
        'late response obeys settlement validation retirement=$retire',
        () async {
          final pending = Completer<Object?>();
          channel.pending = pending.future;
          final request = bridge.request(_secret, 'test.read', {});
          final failure = expectLater(request, throwsA(anything));
          expect(channel.payloads, hasLength(1));
          expect(lines, isEmpty);
          if (retire) {
            bridge.invalidate();
          } else {
            settlementError = _OpaqueFailure();
          }
          pending.complete({'token': _secret});
          await failure;
          expect(channel.payloads, hasLength(1));
          expect(settlements, 1);
          final record = _records(lines).single;
          expect(record['phase'], 'response');
          expect(record['outcome'], 'failure');
        },
      );
    }

    for (final observer in ['disabled', 'release', 'throwing-sink']) {
      test('$observer cannot change successful or failed operations', () async {
        var sinkCalls = 0;
        diagnostics = EnvironmentCapabilityDiagnostics(
          debugBuild: observer != 'release',
          environment: {
            EnvironmentCapabilityDiagnostics.flag: observer == 'disabled'
                ? 'true'
                : '1',
          },
          sink: (_) {
            sinkCalls++;
            throw _OpaqueFailure();
          },
        );
        expect(await bridge.request(_secret, 'test.read', {}), {'ok': true});
        final runtime = Runtime.ofProgram(program);
        final value = $String('interpreted-value');
        final succeeded = await BackendInvocationBridge.settleOperation(
          runtime,
          [$Future.wrap(Future.value(value))],
          diagnostic: operation,
        ).$value;
        expect(copyStructuredBridgeData(succeeded), [
          true,
          'interpreted-value',
        ]);
        expect((succeeded as $List).$value[1], same(value));

        final error = _OpaqueFailure();
        channel.error = error;
        await expectLater(
          bridge.request(_secret, 'test.read', {}),
          throwsA(same(error)),
        );
        final failed = await BackendInvocationBridge.settleOperation(runtime, [
          $Future.wrap(Future<Object?>.error(error)),
        ], diagnostic: operation).$value;
        expect(copyStructuredBridgeData(failed), [false, null]);
        final decoding = _begin(diagnostics)?..response();
        final decodeFailed = await BackendInvocationBridge.settleOperation(
          runtime,
          [$Future.wrap(Future<Object?>.error(error))],
          diagnostic: decoding,
        ).$value;
        expect(copyStructuredBridgeData(decodeFailed), [false, null]);
        expect(error.stringReads, 0);
        expect(channel.payloads, hasLength(2));
        expect(admissions, 2);
        expect(settlements, 1);
        expect(sinkCalls, observer == 'throwing-sink' ? 5 : 0);
      });
    }

    test(
      'throwing failure code getter cannot replace failure or escape settlement',
      () async {
        final error = _RemoteFailure(throwCode: true);
        channel.error = error;
        await expectLater(
          bridge.request(_secret, 'test.read', {}),
          throwsA(same(error)),
        );
        expect(error.privateReads, 0);

        final decoded = _begin(diagnostics)!..response();
        final failed = await BackendInvocationBridge.settleOperation(
          Runtime.ofProgram(program),
          [$Future.wrap(Future<Object?>.error(error))],
          diagnostic: decoded,
        ).$value;
        expect(copyStructuredBridgeData(failed), [false, null]);
        expect(error.privateReads, 0);
        _records(lines);
      },
    );
  });

  for (final entrypoint in ['omitted', 'explicitNull', 'foreign', 'denied']) {
    test(
      'real optional settlement ABI $entrypoint grants no authority',
      () async {
        final bridge = EnvironmentCapabilityAccessBridge(
          session: null,
          environmentRuntime: null,
          backends: null,
          capabilities: const [],
          isActive: () => true,
        );
        addTearDown(bridge.invalidate);
        final runtime = Runtime.ofProgram(program)..addPlugin(bridge);
        expect(
          copyStructuredBridgeData(
            await runtime.executeLib(_library, entrypoint),
          ),
          entrypoint == 'denied' ? [false, null] : [true, 'safe-value'],
        );
        expect(
          await bridge.resolve(
            'dev.adele.test.snapshot',
            1,
            'test.snapshot',
            null,
          ),
          isNull,
        );
        expect(bridge.release('foreign-handle'), isFalse);
      },
    );
  }
}

EnvironmentCapabilityDiagnostic? _begin(
  EnvironmentCapabilityDiagnostics diagnostics, {
  String method = 'test.snapshot.read',
}) => diagnostics.begin(
  service: _context['service']!,
  method: method,
  provider: _context['provider']!,
  environmentProvider: _context['environmentProvider']!,
  grant: _context['grant']!,
);

List<Map<String, dynamic>> _records(List<String> lines) => [
  for (final line in lines) _record(line),
];

Map<String, dynamic> _record(String line) {
  const prefix = '[adele.environment-capability] ';
  expect(line, startsWith(prefix));
  expect(line.length, lessThan(1200));
  expect(line, isNot(contains(_secret)));
  expect(line, isNot(contains('\n')));
  final record =
      jsonDecode(line.substring(prefix.length)) as Map<String, dynamic>;
  expect(record.keys.toSet(), {
    'operation',
    ..._context.keys,
    'phase',
    'outcome',
    'durationMs',
    if (record['outcome'] == 'failure') 'classification',
    if (record['classification'] == 'remote-failure') 'code',
  });
  expect(
    record['operation'],
    isA<int>().having((value) => value, 'positive', greaterThan(0)),
  );
  expect(
    record['durationMs'],
    isA<int>().having((value) => value, 'bounded', inInclusiveRange(0, 600000)),
  );
  for (final key in [
    ..._context.keys,
    if (record.containsKey('code')) 'code',
  ]) {
    expect(
      record[key],
      isA<String>().having(
        (value) => value.length,
        'bounded',
        lessThanOrEqualTo(128),
      ),
    );
  }
  return record;
}

final class _Channel implements AdeleRequestChannel {
  final List<Map<String, Object?>> payloads = [];
  Object? response = {'ok': true};
  Object? error;
  Future<Object?>? pending;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    payloads.add(payload);
    if (error != null) throw error!;
    return pending ?? response;
  }
}

final class _OpaqueFailure {
  int stringReads = 0;

  @override
  String toString() {
    stringReads++;
    throw StateError(_secret);
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  _RemoteFailure({String code = 'snapshot_too_large', this.throwCode = false})
    : _code = code;

  final String _code;
  final bool throwCode;
  int privateReads = 0;

  @override
  String get code => throwCode ? throw StateError(_secret) : _code;

  Never _private() {
    privateReads++;
    throw StateError(_secret);
  }

  @override
  String? get declaredFailureType => _private();
  @override
  String get message => _private();
  @override
  Map<String, Object?> get details => _private();
  @override
  String toString() => _private();
}
