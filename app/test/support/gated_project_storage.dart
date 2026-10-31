import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gates the real host dispatcher, not a replacement storage implementation.
final class GatedProjectStorage implements AdeleBackendDispatcher {
  GatedProjectStorage(this.delegate);

  final AdeleBackendDispatcher delegate;
  final calls = <String>[];
  StorageTransactionGate? _next;
  final _gates = <StorageTransactionGate>[];
  StorageQueryResponseGate? _nextQuery;
  final _queryGates = <StorageQueryResponseGate>[];

  StorageTransactionGate holdTransaction({
    bool afterCommit = false,
    String? sqlContains,
    Map<String, Object?> parameters = const {},
  }) {
    expect(_next, isNull);
    final gate = StorageTransactionGate._(afterCommit, sqlContains, parameters);
    _gates.add(gate);
    return _next = gate;
  }

  StorageQueryResponseGate holdQueryResponse({
    required String sqlContains,
    required Map<String, Object?> parameters,
  }) {
    expect(_nextQuery, isNull);
    final gate = StorageQueryResponseGate._(sqlContains, parameters);
    _queryGates.add(gate);
    return _nextQuery = gate;
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final method = request['method']! as String;
    calls.add(method);
    final payload = request['payload']! as Map;
    final query = _nextQuery;
    if (query != null &&
        method == projectStorageServiceQueryForSessionId &&
        (payload['sql']! as String).contains(query.sqlContains) &&
        query.parameters.entries.every(
          (entry) => (payload['parameters']! as Map)[entry.key] == entry.value,
        )) {
      _nextQuery = null;
      try {
        final response = await delegate.dispatch(request);
        expect(response['ok'], isTrue);
        query.entered.complete(response);
        await query._release.future;
        return response;
      } finally {
        query.settled.complete();
      }
    }
    final next = _next;
    final statements = payload['statements'] as List?;
    final matches =
        next != null &&
        method == projectStorageServiceTransactionForSessionId &&
        statements!.any((value) {
          final statement = value as Map;
          final values = statement['parameters']! as Map;
          return (next.sqlContains == null ||
                  (statement['sql']! as String).contains(next.sqlContains!)) &&
              next.parameters.entries.every(
                (entry) => values[entry.key] == entry.value,
              );
        });
    if (!matches) return delegate.dispatch(request);
    final gate = next;
    _next = null;
    try {
      if (!gate.afterCommit) {
        gate.entered.complete();
        await gate._release.future;
      }
      final response = await delegate.dispatch(request);
      if (gate.afterCommit) {
        expect(response['ok'], isTrue);
        gate.entered.complete();
        await gate._release.future;
      }
      return response;
    } finally {
      gate.settled.complete();
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async => send(await dispatch(command));

  @override
  Future<void> close() async {
    for (final gate in _gates) {
      gate.release();
    }
    for (final gate in _queryGates) {
      gate.release();
    }
    await delegate.close();
  }
}

/// Holds only a successful response after the selected real SQL query completes.
final class StorageQueryResponseGate {
  StorageQueryResponseGate._(this.sqlContains, this.parameters);

  final String sqlContains;
  final Map<String, Object?> parameters;
  final entered = Completer<Map<String, Object?>>();
  final settled = Completer<void>();
  final _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

final class StorageTransactionGate {
  StorageTransactionGate._(this.afterCommit, this.sqlContains, this.parameters);

  final bool afterCommit;
  final String? sqlContains;
  final Map<String, Object?> parameters;
  final entered = Completer<void>();
  final settled = Completer<void>();
  final _release = Completer<void>();
  void release() {
    if (_release.isCompleted) return;
    _release.complete();
  }
}
