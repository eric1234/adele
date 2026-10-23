import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:flutter/foundation.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Native developer diagnostics, never an interpreted exception channel.
/// Only semantic identifiers, declared codes and fixed classifications are logged.
final class EnvironmentCapabilityDiagnostics {
  EnvironmentCapabilityDiagnostics({
    required bool debugBuild,
    required Map<String, String> environment,
    required void Function(String) sink,
  }) : _enabled = debugBuild && environment[flag] == '1',
       _sink = sink;

  static const flag = 'ADELE_ENVIRONMENT_CAPABILITY_DIAGNOSTICS';
  static final native = EnvironmentCapabilityDiagnostics(
    debugBuild: kDebugMode,
    environment: Platform.environment,
    sink: stderr.writeln,
  );

  final bool _enabled;
  final void Function(String) _sink;
  int _sequence = 0;

  EnvironmentCapabilityDiagnostic? begin({
    required String service,
    required String method,
    required String provider,
    required String environmentProvider,
    required String grant,
  }) {
    if (!_enabled) return null;
    return EnvironmentCapabilityDiagnostic._(this, {
      'operation': ++_sequence,
      'service': _identifier(service),
      'method': _identifier(method),
      'provider': _identifier(provider),
      'environmentProvider': _identifier(environmentProvider),
      'grant': _identifier(grant),
    });
  }

  void _write(Map<String, Object> record) {
    try {
      _sink('[adele.environment-capability] ${jsonEncode(record)}');
    } on Object {
      // Observability must not change admission, settlement, or failure privacy.
    }
  }
}

/// One native request. A consumer can associate generated-client settlement only
/// with a handle used for exactly one request; concurrent/reused handles are not
/// guessed at. This observation retains no binding, payload, response or error.
final class EnvironmentCapabilityDiagnostic {
  EnvironmentCapabilityDiagnostic._(this._owner, this._context);

  final EnvironmentCapabilityDiagnostics _owner;
  final Map<String, Object> _context;
  final Stopwatch _watch = Stopwatch()..start();
  bool? _responseSucceeded;
  bool _settled = false;

  /// A later request makes a previously captured settlement association ambiguous.
  /// Native request outcomes remain observable, but client decoding is not guessed.
  void suppressSettlement() => _settled = true;

  void response() {
    _responseSucceeded = true;
    _report('response', 'success');
  }

  void failure(String phase, Object error) {
    _responseSucceeded = false;
    _report(phase, 'failure', error: error);
  }

  void settle(Object? error) {
    if (_settled) return;
    _settled = true;
    // The native request already recorded an invocation/admission failure.
    if (_responseSucceeded == false) return;
    _report(
      _responseSucceeded == true ? 'response-decoding' : 'client-settlement',
      error == null ? 'success' : 'failure',
      error: error,
    );
    _watch.stop();
  }

  void _report(String phase, String outcome, {Object? error}) {
    try {
      _owner._write({
        ..._context,
        'phase': phase,
        'outcome': outcome,
        'durationMs': _watch.elapsedMilliseconds.clamp(0, 600000),
        if (error != null) ...{
          'classification': _classification(error),
          if (error is AdeleRemoteFailure) 'code': _identifier(error.code),
        },
      });
    } on Object {
      // Even a foreign failure implementation with a throwing code getter must
      // leave the original operation and safe settlement untouched.
    }
  }
}

String _identifier(String value) =>
    value.length <= 128 && RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$').hasMatch(value)
    ? value
    : 'redacted';

String _classification(Object error) => switch (error) {
  AdeleRemoteFailure() => 'remote-failure',
  PluginConnectionClosed() => 'connection-closed',
  BackendHostProtocolException() => 'transport-protocol',
  TimeoutException() => 'timeout',
  FormatException() => 'invalid-format',
  StateError() => 'invalid-state',
  ArgumentError() => 'invalid-argument',
  _ => 'opaque-failure',
};
