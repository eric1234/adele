/// Reuses native strategies behind the public generated transport, without host
/// implementation dependencies. The backend supplies its bound channel factory.
library;

import 'dart:async';
import 'dart:collection';

import 'package:adele_contract/adele_contract.dart';

import 'adele_orchestration.dart';
import 'remote_orchestration.dart';

final class RemoteOrchestrationBackend implements RemoteOrchestrationService {
  RemoteOrchestrationBackend({
    required Map<String, OrchestrationStrategyContribution> routes,
    required AdeleRequestChannel Function(String context) hostChannel,
  }) : _routes = Map.unmodifiable(routes),
       _hostChannel = hostChannel {
    for (final route in routes.keys) {
      if (route.trim().isEmpty) {
        throw ArgumentError('Strategy routes must not be blank.');
      }
    }
  }

  final Map<String, OrchestrationStrategyContribution> _routes;
  final AdeleRequestChannel Function(String context) _hostChannel;
  final Map<String, _Execution> _executions = {};
  final Set<Future<void>> _materializing = {};
  int _nextExecution = 0;
  bool _closed = false;
  Future<void>? _closing;

  int get executionCount => _executions.length;

  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) async {
    _requireOpen();
    final contribution = _routes[routeId];
    final localSession = session.toLocal();
    if (contribution == null ||
        contribution.strategyId != localSession.strategyId) {
      throw ArgumentError('Unknown route or mismatched Session strategy.');
    }
    final host = _HostProxy(RunId(runId), localSession.id);
    final settled = Completer<void>();
    _materializing.add(settled.future);
    try {
      final execution = await contribution.materialize(
        OrchestrationStrategyHostContext(session: localSession, host: host),
      );
      if (_closed) {
        await execution.close();
        throw StateError(
          'The orchestration backend closed during materialization.',
        );
      }
      final id = 'execution-${_nextExecution++}';
      _executions[id] = _Execution(execution, host);
      return id;
    } finally {
      _materializing.remove(settled.future);
      settled.complete();
    }
  }

  @override
  Future<RemoteRunState> start(
    String executionId,
    String hostInvocationContext,
  ) => _advance(executionId, hostInvocationContext, null);

  @override
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String hostInvocationContext,
  ) => _advance(executionId, hostInvocationContext, resolution.toLocal());

  Future<RemoteRunState> _advance(
    String id,
    String context,
    ToolApprovalResolution? resolution,
  ) async {
    _requireOpen();
    final retained = _executions[id];
    if (retained == null) {
      throw const InvalidRunOperation('Unknown orchestration execution.');
    }
    retained.validateAdvance(resolution);
    try {
      if (context.trim().isEmpty) {
        throw const InvalidRunOperation(
          'A host operation context is required.',
        );
      }
      final state = await retained.advance(_hostChannel(context), resolution);
      if (state != RunState.waiting) await _releaseAfterAdvance(id, retained);
      return RemoteRunState.values.byName(state.name);
    } on Object {
      await _releaseAfterAdvance(id, retained);
      rethrow;
    }
  }

  Future<void> _releaseAfterAdvance(String id, _Execution retained) async {
    try {
      await retained.close();
      _executions.remove(id);
    } on Object {
      // Preserve the advance result. The existing closing entry retains its failed
      // close completion until explicit release (or backend close) reports it.
    }
  }

  @override
  Future<void> release(String executionId) async {
    final retained = _executions[executionId];
    if (retained == null) return;
    try {
      await retained.close();
    } finally {
      _executions.remove(executionId);
    }
  }

  /// Drains materialization/advancement and releases resources, never Run lifecycle.
  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await Future.wait(_materializing.toList());
    Object? firstError;
    StackTrace? firstStack;
    await Future.wait([
      for (final id in _executions.keys.toList())
        () async {
          try {
            await release(id);
          } on Object catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
          }
        }(),
    ]);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }

  void _requireOpen() {
    if (_closed) throw StateError('The orchestration backend is closed.');
  }
}

final class _Execution {
  _Execution(this.execution, this.host);

  final OrchestrationExecution execution;
  final _HostProxy host;
  Completer<void>? _advancing;
  Future<void>? _closing;

  void validateAdvance(ToolApprovalResolution? resolution) {
    if (_advancing != null || _closing != null) {
      throw const InvalidRunOperation('The execution is busy or closed.');
    }
    if (host.state !=
        (resolution == null ? RunState.created : RunState.waiting)) {
      throw const InvalidRunOperation(
        'The execution cannot advance in this state.',
      );
    }
  }

  Future<RunState> advance(
    AdeleRequestChannel channel,
    ToolApprovalResolution? resolution,
  ) async {
    final settled = Completer<void>();
    _advancing = settled;
    host.begin(channel, resolution);
    try {
      if (resolution == null) {
        await execution.start();
      } else {
        await execution.resolveApproval(resolution);
      }
      if (host.pending != null) {
        throw const InvalidRunOperation(
          'Strategy returned with an outstanding host operation.',
        );
      }
      await host.flush();
      if (host.state == RunState.created || host.state == RunState.running) {
        throw const InvalidRunOperation('Strategy did not settle or wait.');
      }
      return host.state;
    } on Object {
      // A queued intentional terminal transition still settles before the failed
      // response, but a failed RPC must never be converted into requested fail().
      if (host.pending == null && !host.invalid) {
        try {
          await host.flush();
        } on Object {
          // Preserve the strategy's primary error.
        }
      }
      rethrow;
    } finally {
      host.end();
      await host.pending;
      _advancing = null;
      settled.complete();
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _advancing?.future;
    host.end();
    host.snapshots.clear();
    await execution.close();
  }
}

final class _Snapshot implements StrategyToolSnapshot {
  _Snapshot(this.handle);

  final String handle;
  final Map<ProviderToolProposal, String> proposals = HashMap.identity();
}

final class _HostProxy implements OrchestrationExecutionHost {
  _HostProxy(this.id, this.sessionId);

  @override
  final RunId id;
  @override
  final SessionId sessionId;
  @override
  RunState get state => _state;
  RunState _state = RunState.created;

  final Map<StrategyToolSnapshot, _Snapshot> snapshots = HashMap.identity();
  final List<(RemoteRunTransition, RemoteOrchestrationFailure?, RunState)>
  _transitions = [];
  RemoteOrchestrationHostServiceClient? _client;
  ToolApprovalResolution? _approval;
  Object? _failure;
  StackTrace? _failureStack;
  Future<void>? pending;

  bool get invalid => _failure != null;

  void begin(AdeleRequestChannel channel, ToolApprovalResolution? approval) {
    _client = RemoteOrchestrationHostServiceClient(channel);
    _approval = approval;
  }

  void end() {
    _client = null;
    _approval = null;
    _transitions.clear();
  }

  @override
  void validateBinding() {
    if (_failure != null) Error.throwWithStackTrace(_failure!, _failureStack!);
    if (_client == null) {
      throw const InvalidRunOperation(
        'No active orchestration host operation.',
      );
    }
  }

  void _requireIdle() {
    validateBinding();
    if (pending != null) {
      throw const InvalidRunOperation(
        'An orchestration host operation is active.',
      );
    }
  }

  void _requireState(RunState expected) {
    if (_state != expected) {
      throw const InvalidRunOperation(
        'Invalid orchestration host lifecycle state.',
      );
    }
  }

  @override
  void start() {
    _requireIdle();
    _requireState(RunState.created);
    _state = RunState.running;
    _transitions.add((RemoteRunTransition.start, null, _state));
  }

  @override
  void complete() {
    _requireIdle();
    _requireState(RunState.running);
    _state = RunState.completed;
    _transitions.add((RemoteRunTransition.complete, null, _state));
  }

  @override
  void fail(Object error) {
    _requireIdle();
    if (_state != RunState.running && _state != RunState.waiting) {
      throw const InvalidRunOperation('Only an active Run can fail.');
    }
    final failure = RemoteOrchestrationFailure.fromLocal(error);
    _state = RunState.failed;
    _transitions.add((RemoteRunTransition.fail, failure, _state));
  }

  Future<void> flush() => _operation(() async {});

  Future<void> _flush() async {
    while (_transitions.isNotEmpty) {
      validateBinding();
      final (transition, failure, expected) = _transitions.removeAt(0);
      final actual = await _client!.transition(transition, failure);
      validateBinding();
      if (actual.name != expected.name) {
        throw const AdeleProtocolException(
          'Host transition returned a mismatched Run state.',
        );
      }
    }
  }

  @override
  Future<StrategyModelTurn> invokeModel(StrategyInferenceMaterial material) =>
      _operation(() async {
        _requireState(RunState.running);
        final remote = await _client!.invokeModel(
          RemoteStrategyInferenceMaterial.fromLocal(material),
        );
        validateBinding();
        final snapshot = _Snapshot(remote.toolSnapshotHandle);
        final turn = remote.toLocal(tools: snapshot);
        if (turn.settlement == ModelSettlement.completed) {
          for (int index = 0; index < turn.output.length; index++) {
            final item = turn.output[index];
            if (item is ModelToolProposalOutput) {
              snapshot.proposals[item.proposal] =
                  remote.output[index].proposalHandle!;
            }
          }
          if (snapshot.proposals.isNotEmpty) snapshots[snapshot] = snapshot;
        }
        return turn;
      });

  @override
  Future<StrategyToolResult> processProposal({
    required StrategyToolSnapshot tools,
    required ProviderToolProposal proposal,
  }) => _operation(() async {
    _requireState(RunState.running);
    final snapshot = snapshots[tools];
    final handle = snapshot?.proposals.remove(proposal);
    if (snapshot == null || handle == null) {
      throw const InvalidRunOperation(
        'Proposal and snapshot must be exact, issued, unused objects.',
      );
    }
    if (snapshot.proposals.isEmpty) snapshots.remove(tools);
    final result = (await _client!.processProposal(
      snapshot.handle,
      handle,
    )).toLocal();
    validateBinding();
    if (result is StrategyToolWaiting) _state = RunState.waiting;
    return result;
  });

  @override
  Future<SemanticToolOutcomeInput> resolveApproval(
    ToolApprovalResolution resolution,
  ) => _operation(() async {
    _requireState(RunState.waiting);
    if (!identical(resolution, _approval)) {
      throw const InvalidRunOperation(
        'Only the exact current resume resolution is authorized.',
      );
    }
    _approval = null;
    final item = (await _client!.applyCurrentApproval()).toLocal();
    validateBinding();
    if (item is! SemanticToolOutcomeInput) {
      throw const AdeleProtocolException(
        'Approval must return a tool outcome.',
      );
    }
    _state = RunState.running;
    return item;
  });

  Future<T> _operation<T>(Future<T> Function() operation) async {
    _requireIdle();
    final settled = Completer<void>();
    pending = settled.future;
    try {
      await _flush();
      final value = await operation();
      validateBinding();
      return value;
    } on Object catch (error, stack) {
      _failure ??= error;
      _failureStack ??= stack;
      rethrow;
    } finally {
      pending = null;
      settled.complete();
    }
  }
}
