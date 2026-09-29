import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:flutter/foundation.dart';

import 'session_execution_controller.dart';

/// Window-owned executions, independent of which Session is presented.
/// Lookup is passive; only explicit Session activation creates an owner.
final class SessionExecutionOwners extends ChangeNotifier {
  SessionExecutionOwners({
    required AdeleRuntime runtime,
    required this.providerId,
    required this.model,
    this.configurationUnavailableReason,
    RunIdSource? runIds,
  }) : _runtime = runtime,
       _runIds = runIds ?? runtime.runIds;

  final AdeleRuntime _runtime;
  final ProviderId providerId;
  final String? model;
  final String? configurationUnavailableReason;
  final RunIdSource _runIds;
  final Map<SessionId, SessionExecutionController> _owners = {};
  final Map<SessionId, (String, String?)> _statuses = {};
  Future<void>? _closing;
  bool _closed = false;
  bool _notificationPending = false;

  int get length => _owners.length;
  bool get isClosed => _closed;

  SessionExecutionController? lookup(Session session) {
    if (!identical(_runtime.store.session(session.id), session)) {
      throw ArgumentError('Execution lookup requires a canonical Session.');
    }
    return _owners[session.id];
  }

  SessionExecutionController getOrCreate(
    Session session, {
    ResolvedOrchestrationStrategy? strategy,
  }) {
    if (_closed) throw StateError('Session execution ownership is closed.');
    final retained = lookup(session);
    if (retained != null) return retained;
    final controller = SessionExecutionController(
      runtime: _runtime,
      session: session,
      providerId: providerId,
      model: model,
      strategy: strategy,
      runIds: _runIds,
      configurationUnavailableReason: configurationUnavailableReason,
    );
    _owners[session.id] = controller;
    controller.addListener(() => _ownerChanged(controller));
    _ownerChanged(controller);
    return controller;
  }

  String statusFor(Session session) {
    final controller = lookup(session);
    if (controller == null) return 'idle';
    if (controller.pendingApproval != null && !controller.isAdvancing) {
      return 'waitingForApproval';
    }
    if (controller.isRunning || controller.isAdvancing) {
      return controller.currentRun == null ? 'preparing' : 'running';
    }
    if (controller.failure != null) return 'failed';
    final runId = controller.latestRunId;
    return switch (runId == null ? null : controller.stateForRun(runId)) {
      RunState.completed => 'completed',
      RunState.failed => 'failed',
      RunState.cancelled => 'cancelled',
      _ => 'idle',
    };
  }

  void _ownerChanged(SessionExecutionController controller) {
    if (_closed) return;
    final status = (
      statusFor(controller.session),
      controller.unavailableReason,
    );
    if (_statuses[controller.session.id] == status) return;
    _statuses[controller.session.id] = status;
    if (_notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_closed) notifyListeners();
    });
  }

  void refresh() {
    if (_closed) return;
    for (final controller in _owners.values) {
      controller.refresh();
    }
  }

  /// Fence every owner before awaiting any drain. A failed sibling cannot skip
  /// release of another, and backing runtime resources must outlive this future.
  Future<void> close() {
    _closed = true;
    return _closing ??= Future.wait<void>([
      for (final controller in _owners.values)
        Future<void>.sync(controller.close),
    ]).whenComplete(super.dispose).then((_) {});
  }
}
