import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/model_provider_host.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/resource_cleanup.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart' show RunTerminalState;
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'pending_tool_approval.dart';

/// Window-local execution and evidence, without strategy-owned Session state.
final class SessionExecutionController extends ChangeNotifier {
  SessionExecutionController({
    required AdeleRuntime runtime,
    required this.session,
    required this.providerId,
    required this.model,
    this.strategy,
    RunIdSource? runIds,
    this.configurationUnavailableReason,
    this.onChanged,
    this.onActivityChanged,
  }) : _runtime = runtime,
       _runIds = runIds ?? runtime.runIds {
    if (!identical(runtime.store.session(session.id), session)) {
      throw ArgumentError('Execution requires a canonical Session.');
    }
    if (strategy case final binding?) {
      runtime.lifecycle.validateResolvedStrategy(session.strategyId, binding);
    }
  }

  final AdeleRuntime _runtime;
  final Session session;
  final ProviderId providerId;
  final String? model;
  final ResolvedOrchestrationStrategy? strategy;
  final RunIdSource _runIds;
  final String? configurationUnavailableReason;
  final VoidCallback? onChanged;
  final VoidCallback? onActivityChanged;
  final ValueNotifier<int> _activityChanges = ValueNotifier(0);
  final Map<RunId, RunActivitySnapshot> _activity = {};
  // Scheduling/startup can fail before a materialized Run actually starts.
  final Map<RunId, RunState> _preparationStates = {};
  RunActivitySource? _activitySource;
  StreamSubscription<void>? _activitySubscription;
  bool _activityUpdateScheduled = false;
  SessionOrchestrationRun? _currentRun;
  SessionOrchestrationRun? _ownedExecution;
  Future<void>? _activeRunFuture;
  Future<void>? _closing;
  bool _closed = false;
  bool _running = false;
  bool _advancing = false;
  int _revision = 0;
  int _sessionStateRevision = 0;
  RunId? _latestRunId;
  ResolvedOrchestrationStrategy? _capturedStrategy;
  ProviderBinding? _capturedProvider;
  PendingToolApproval? _pendingApproval;
  ToolApprovalInterruption? _pendingInterruption;
  Object? _failure;
  Object? _releaseFailure;

  Listenable get activityChanges => _activityChanges;
  SessionOrchestrationRun? get currentRun => _currentRun;
  List<RunActivitySnapshot> get activitySnapshots => List.unmodifiable(
    {
      for (final activity in _runtime.lifecycle.runActivitiesForSession(
        session.id,
      ))
        activity.runId: ?retainedActivityForRun(activity.runId),
      ..._activity,
    }.values,
  );
  RunActivitySnapshot? activityForRun(RunId runId) =>
      _closed ? null : _activity[runId] ?? retainedActivityForRun(runId);

  /// Historical evidence never creates an execution or subscribes to one.
  RunActivitySnapshot? retainedActivityForRun(RunId runId) {
    if (_closed) return null;
    final state = _terminalStateForRun(runId);
    final activity = _runtime.lifecycle.runActivity(runId);
    return state != null &&
            activity?.runId == runId &&
            activity?.sessionId == session.id &&
            activity?.state == state
        ? activity
        : null;
  }

  RunState? _terminalStateForRun(RunId runId) {
    final record = _runtime.store.runRecord(runId);
    if (record == null || record.sessionId != session.id) return null;
    return switch (record.state) {
      RunTerminalState.completed => RunState.completed,
      RunTerminalState.failed => RunState.failed,
      RunTerminalState.cancelled => RunState.cancelled,
    };
  }

  RunState? stateForRun(RunId runId) => _closed
      ? null
      : _preparationStates[runId] ??
            _activity[runId]?.state ??
            _terminalStateForRun(runId);
  bool ownsScheduledRun(RunId runId) =>
      !_closed &&
      (_preparationStates.containsKey(runId) || _activity.containsKey(runId));
  Future<void>? get activeRunFuture => _activeRunFuture;
  bool get isRunning => _running;
  bool get isAdvancing => _advancing;
  bool get isClosed => _closed;
  int get revision => _revision;

  /// Changes only when strategy-owned association/history may have committed.
  int get sessionStateRevision => _sessionStateRevision;
  RunId? get latestRunId => _latestRunId;
  ResolvedOrchestrationStrategy? get capturedStrategy =>
      _capturedStrategy ?? strategy;
  bool get canStart =>
      !_closed && !_running && !_advancing && unavailableReason == null;
  PendingToolApproval? get pendingApproval => _pendingApproval;
  Object? get failure => _failure;

  String? get unavailableReason {
    if (_closed) return 'Model execution is unavailable: window is closing.';
    if (_releaseFailure != null) {
      return 'Session execution is unavailable: its previous execution could '
          'not be released.';
    }
    if (configurationUnavailableReason != null) {
      return configurationUnavailableReason;
    }
    if (model == null || model!.trim().isEmpty) {
      return 'Model execution is unavailable: no model is configured.';
    }
    try {
      _runtime.lifecycle.validateResolvedStrategy(
        session.strategyId,
        (_running || _advancing ? _capturedStrategy : strategy) ??
            _runtime.lifecycle.resolveSessionStrategy(session.id),
      );
    } on Object {
      return 'Session execution is unavailable: its strategy is not available.';
    }
    try {
      ((_running || _advancing ? _capturedProvider : null) ??
              _runtime.registry.resolve(
                modelProviderCapability,
                providerId: providerId,
              ))
          .streamChannel;
    } on Object {
      return 'Model execution is unavailable: the selected provider is not '
          'available. Check its configuration and backend activation.';
    }
    return null;
  }

  String? get failureMessage => switch (_failure) {
    null => null,
    ModelFailure(:final kind) => 'Run failed: model ${kind.name}.',
    InvalidRunOperation(:final message) => 'Run failed: $message',
    ProviderUnavailable() || ProviderEndpointUnavailable() =>
      'Run failed: the selected model provider is unavailable.',
    _ => 'Run failed. Check strategy, model and Task Environment availability.',
  };

  /// Acceptance locks synchronously. Completion reports scheduling, not Run end.
  /// An expected service binding constrains, but never selects, the core choice.
  Future<RunId> startRun({
    ResolvedOrchestrationStrategy? expectedStrategy,
  }) async {
    if (!canStart) {
      throw StateError(unavailableReason ?? 'A Run is already active.');
    }
    final selectedStrategy =
        strategy ?? _runtime.lifecycle.resolveSessionStrategy(session.id);
    if (expectedStrategy != null) {
      _runtime.lifecycle.validateResolvedStrategy(
        session.strategyId,
        expectedStrategy,
      );
      if (!selectedStrategy.binding.isSameRegistration(
        expectedStrategy.binding,
      )) {
        throw StateError(
          'The Run strategy differs from the captured service binding.',
        );
      }
    }
    _capturedStrategy = selectedStrategy;
    _capturedProvider = _runtime.registry.resolve(
      modelProviderCapability,
      providerId: providerId,
    );
    final runId = _runIds.nextRunId();
    _latestRunId = runId;
    _preparationStates[runId] = RunState.created;
    _failure = null;
    _currentRun = null;
    _running = true;
    _advancing = true;
    _activeRunFuture = Future<void>.microtask(() => _advance(runId: runId));
    refresh();
    return runId;
  }

  bool resolveApproval(PendingToolApproval approval, {required bool approved}) {
    final interruption = _pendingInterruption;
    if (_closed ||
        _advancing ||
        !_running ||
        !identical(approval, _pendingApproval) ||
        interruption == null ||
        (approved && approval.hasUnsafeAuthorityText)) {
      return false;
    }
    _advancing = true;
    _activeRunFuture = Future<void>.microtask(
      () => _advance(
        resolution: ToolApprovalResolution(
          interruptionId: interruption.id,
          toolInvocationId: interruption.toolInvocationId,
          approved: approved,
        ),
      ),
    );
    refresh();
    return true;
  }

  Future<void> _advance({
    RunId? runId,
    ToolApprovalResolution? resolution,
  }) async {
    SessionOrchestrationRun? execution;
    try {
      if (resolution == null) {
        // Terminal execution may retain backend mutation guards until close.
        await _ownedExecution?.close();
        _ownedExecution = null;
        final binding = _capturedProvider!;
        final adapter = ModelProviderCapabilityAdapter(
          binding,
          selectedModel: model!,
        );
        final tools = await buildModelToolCatalogForSession(
          sessionId: session.id,
          environmentRuntime: _runtime.lifecycle.environmentRuntime,
          extensions: _runtime.extensions,
        );
        execution = await createSessionOrchestrationRun(
          lifecycle: _runtime.lifecycle,
          sessionId: session.id,
          runId: runId!,
          resolvedStrategy: _capturedStrategy,
          contextComposer: _runtime.contextComposer,
          model: adapter,
          toolCatalog: tools,
          policy: const ApprovalGatedToolPolicy(),
        );
        _ownedExecution = execution;
        if (!_closed) {
          _currentRun = execution;
          _sessionStateRevision++;
          _observeActivity(execution.activity);
          refresh();
        }
        await execution.start();
      } else {
        execution = _currentRun!;
        await execution.resolveApproval(resolution);
      }
      if (!_closed) _inspectRun(execution.run);
    } on Object catch (error) {
      if (!_closed) {
        final run = execution?.run;
        if ((run == null || run.state == RunState.created) && runId != null) {
          _preparationStates[runId] = RunState.failed;
        }
        if (run?.state == RunState.running || run?.state == RunState.waiting) {
          run!.fail(error);
        }
        _failure = error;
        _pendingApproval = null;
        _pendingInterruption = null;
        _running = false;
      }
    } finally {
      if (!_running || _closed) {
        try {
          await execution?.close();
          if (identical(_ownedExecution, execution)) _ownedExecution = null;
        } on Object catch (error) {
          _releaseFailure ??= error;
          if (!_closed) _failure ??= error;
        }
      }
      if (!_closed) {
        if (_activitySource case final source?) _captureActivity(source);
        if (!_running) {
          _detachActivity();
          _sessionStateRevision++;
        }
        _advancing = false;
      }
      _activeRunFuture = null;
      refresh();
    }
  }

  void _observeActivity(RunActivitySource source) {
    _activitySource = source;
    _activitySubscription = source.changes.listen((_) {
      if (_closed ||
          !identical(_activitySource, source) ||
          _activityUpdateScheduled) {
        return;
      }
      _activityUpdateScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _activityUpdateScheduled = false;
        if (_closed) return;
        if (_activitySource case final current?) _captureActivity(current);
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    });
    _captureActivity(source);
  }

  void _captureActivity(RunActivitySource source) {
    final snapshot = source.snapshot;
    if (identical(_activity[snapshot.runId], snapshot)) return;
    _activity[snapshot.runId] = snapshot;
    if (_preparationStates[snapshot.runId] != RunState.failed) {
      _preparationStates.remove(snapshot.runId);
    }
    _notify(() => _activityChanges.value++);
    _notify(onActivityChanged);
    refresh();
  }

  void refresh() {
    if (_closed) return;
    _revision++;
    _notify(notifyListeners);
    _notify(onChanged);
  }

  void _notify(VoidCallback? callback) {
    if (_closed) return;
    try {
      callback?.call();
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Session execution observation',
        ),
      );
    }
  }

  void _detachActivity() {
    final subscription = _activitySubscription;
    _activitySource = null;
    _activitySubscription = null;
    unawaited(subscription?.cancel());
  }

  void _inspectRun(AgentRun run) {
    _pendingApproval = null;
    _pendingInterruption = null;
    switch (run.state) {
      case RunState.waiting:
        if (run.interruptions.values.toList() case [
          final ToolApprovalInterruption interruption,
        ]) {
          _pendingInterruption = interruption;
          _pendingApproval = PendingToolApproval(interruption);
        } else {
          throw const InvalidRunOperation(
            'Expected exactly one tool approval while waiting.',
          );
        }
      case RunState.completed:
      case RunState.failed:
        _failure = run.failure;
        _running = false;
      case RunState.cancelled:
        _failure = const InvalidRunOperation('The Run was cancelled.');
        _running = false;
      case RunState.created:
      case RunState.running:
        throw InvalidRunOperation(
          'Run stopped advancing in unexpected state ${run.state.name}.',
        );
    }
  }

  /// Drains only active advancement; waiting approvals are never resolved here.
  Future<void> close() {
    _closed = true;
    _detachActivity();
    return _closing ??= closeResources([
      () async => await _activeRunFuture,
      () async => await _ownedExecution?.close(),
      () async {
        _activityChanges.dispose();
        super.dispose();
      },
    ]);
  }
}
