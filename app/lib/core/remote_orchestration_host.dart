import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Adapts one exact backend generation into the existing strategy registry.
final class RemoteOrchestrationStrategyAdapter
    implements RemoteExtensionAdapter<OrchestrationStrategyContribution> {
  const RemoteOrchestrationStrategyAdapter();

  @override
  ExtensionPoint<OrchestrationStrategyContribution> get point =>
      orchestrationStrategyContributions;

  @override
  OrchestrationStrategyContribution createContribution(
    RemoteExtensionContext remote,
  ) {
    final metadata = remote.exposure.metadata;
    final strategyId = metadata['strategyId'];
    final routeId = metadata['routeId'];
    if (remote.exposure.serviceId != remoteOrchestrationServiceId ||
        metadata.length != 2 ||
        strategyId is! String ||
        strategyId.trim().isEmpty ||
        routeId is! String ||
        routeId.trim().isEmpty) {
      throw const ExtensionContractException(
        'Orchestration exposure requires its supported service and only '
        'nonblank strategyId and routeId metadata.',
      );
    }
    final strategy = _RemoteStrategy(
      remote,
      OrchestrationStrategyId(strategyId),
      routeId,
    );
    return OrchestrationStrategyContribution(
      strategyId: strategy.strategyId,
      materialize: strategy.materialize,
    );
  }
}

final class _RemoteStrategy {
  _RemoteStrategy(this.remote, this.strategyId, this.routeId);

  final RemoteExtensionContext remote;
  final OrchestrationStrategyId strategyId;
  final String routeId;
  final Set<String> _executions = {};

  Future<OrchestrationExecution> materialize(
    OrchestrationStrategyHostContext context,
  ) async {
    void validate() {
      remote.validate();
      context.host.validateBinding();
      if (context.session.strategyId != strategyId ||
          context.session.id != context.host.sessionId) {
        throw ArgumentError(
          'The remote strategy and canonical Session differ.',
        );
      }
    }

    validate();
    // Retain this exact channel for authority-free cleanup after retirement.
    final client = RemoteOrchestrationServiceClient(remote.channel);
    final executionId = await client.materialize(
      routeId,
      RemoteOrchestrationSession.fromLocal(context.session),
      context.host.id.value,
    );
    if (executionId.trim().isEmpty || !_executions.add(executionId)) {
      throw const AdeleProtocolException(
        'Backend returned an empty or already-live orchestration execution.',
      );
    }
    final execution = _RemoteExecution(
      remote,
      context,
      client,
      executionId,
      () => _executions.remove(executionId),
    );
    try {
      validate();
      execution.detachRetirement = remote.onRetire(execution._release);
      return execution;
    } on Object {
      await execution.close();
      rethrow;
    }
  }
}

/// Handles retain semantic provenance, never a usable host invocation. No table
/// is shared with another execution, registration, or replacement generation.
final class _RemoteExecution implements OrchestrationExecution {
  _RemoteExecution(
    this.remote,
    this.context,
    this.client,
    this.executionId,
    this.forget,
  );

  final RemoteExtensionContext remote;
  final OrchestrationStrategyHostContext context;
  final RemoteOrchestrationServiceClient client;
  final String executionId;
  final void Function() forget;
  final String _nonce = base64UrlEncode(
    List<int>.generate(24, (_) => Random.secure().nextInt(256)),
  );
  final Map<String, _Snapshot> _snapshots = {};
  int _nextHandle = 0;
  Future<void>? _advancing;
  Future<void>? _closing;
  Future<void>? _releasing;
  bool _released = false;
  void Function()? detachRetirement;

  OrchestrationExecutionHost get host => context.host;

  void validate() {
    remote.validate();
    host.validateBinding();
    if (_released || context.session.id != host.sessionId) {
      throw const InvalidRunOperation(
        'The remote execution is closed or foreign.',
      );
    }
  }

  @override
  Future<void> start() => _enter(null);

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      _enter(resolution);

  Future<void> _enter(ToolApprovalResolution? resolution) {
    if (_closing != null || _advancing != null) {
      return Future<void>.error(
        const InvalidRunOperation('The remote execution is closed or busy.'),
      );
    }
    final operation = _advance(resolution);
    _advancing = operation;
    return operation.whenComplete(() => _advancing = null);
  }

  Future<void> _advance(ToolApprovalResolution? resolution) async {
    validate();
    final services = _ExecutionHostOperation(this, resolution);
    try {
      await remote.invoke(
        {
          remoteOrchestrationHostServiceId:
              RemoteOrchestrationHostServiceDispatcher(services),
        },
        (invocation) async {
          services.invocation = invocation;
          try {
            final state = resolution == null
                ? await client.start(executionId, invocation.id)
                : await client.resolveApproval(
                    executionId,
                    RemoteApprovalResolution.fromLocal(resolution),
                    invocation.id,
                  );
            // A backend cannot return while detached reverse work retains host
            // authority. Revoke first, drain evidence, then reject that response.
            final pending = services.pending;
            invocation.close();
            if (pending != null) {
              await pending;
              throw const AdeleProtocolException(
                'Remote advance returned with an outstanding host operation.',
              );
            }
            validate();
            if (state.name != host.state.name ||
                host.state == RunState.created ||
                host.state == RunState.running) {
              throw const AdeleProtocolException(
                'Remote advance did not settle the actual host Run.',
              );
            }
          } finally {
            invocation.close();
            services.approval = null;
            await services.pending;
          }
        },
      );
    } on Object {
      await _release();
      rethrow;
    }
    if (host.state != RunState.waiting) await _release();
  }

  String _handle() => '$_nonce-${_nextHandle++}';

  RemoteStrategyModelTurn retain(StrategyModelTurn turn) {
    final snapshotHandle = _handle();
    final snapshot = _Snapshot(turn.tools);
    _snapshots[snapshotHandle] = snapshot;
    return RemoteStrategyModelTurn.fromLocal(
      turn,
      toolSnapshotHandle: snapshotHandle,
      proposalHandle: (proposal) {
        final handle = _handle();
        snapshot.proposals[handle] = proposal;
        return handle;
      },
    );
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await _advancing;
    } on Object {
      // The caller advancing the Run owns its primary failure.
    } finally {
      await _release();
    }
  }

  Future<void> _release() => _releasing ??= _dispose();

  Future<void> _dispose() async {
    _released = true;
    _snapshots.clear();
    try {
      await client.release(executionId).timeout(const Duration(seconds: 2));
    } on Object {
      // An unacknowledged release cannot leave an unbounded backend state map.
      // Terminate only this generation, without replacing primary Run evidence.
      try {
        await remote.connection.close();
      } on Object {
        // Connection cleanup owns its transport failure; authority is gone.
      }
    } finally {
      // Concurrent retirement must join this release, not skip its pending
      // acknowledgement or failure-driven connection teardown.
      detachRetirement?.call();
      forget();
    }
  }
}

final class _Snapshot {
  _Snapshot(this.tools);

  final StrategyToolSnapshot tools;
  final Map<String, ProviderToolProposal> proposals = {};
}

/// The token selects this captured host and optional real approval, not any IDs
/// or resolution fields supplied by a backend. Calls are unary and serialized.
final class _ExecutionHostOperation implements RemoteOrchestrationHostService {
  _ExecutionHostOperation(this.execution, this.approval);

  final _RemoteExecution execution;
  ToolApprovalResolution? approval;
  PluginHostInvocation? invocation;
  Future<void>? pending;

  OrchestrationExecutionHost get host => execution.host;

  void validate() {
    execution.validate();
    if (invocation == null || invocation!.isClosed) {
      throw const InvalidRunOperation(
        'The orchestration host invocation ended.',
      );
    }
  }

  Future<T> perform<T>(FutureOr<T> Function() operation) async {
    validate();
    if (pending != null) {
      throw const InvalidRunOperation('An orchestration host call is active.');
    }
    final settled = Completer<void>();
    pending = settled.future;
    try {
      final value = await operation();
      validate();
      return value;
    } finally {
      pending = null;
      settled.complete();
    }
  }

  @override
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  ) => perform(() {
    if ((transition == RemoteRunTransition.fail) != (failure != null)) {
      throw const AdeleProtocolException('Lifecycle failure payload mismatch.');
    }
    switch (transition) {
      case RemoteRunTransition.start:
        host.start();
      case RemoteRunTransition.complete:
        host.complete();
      case RemoteRunTransition.fail:
        host.fail(failure!.toLocal());
    }
    return RemoteRunState.values.byName(host.state.name);
  });

  @override
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  ) => perform(() async {
    final turn = await host.invokeModel(material.toLocal());
    validate();
    return execution.retain(turn);
  });

  @override
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  ) => perform(() async {
    final snapshot = execution._snapshots[toolSnapshotHandle];
    final proposal = snapshot?.proposals.remove(proposalHandle);
    if (snapshot == null || proposal == null) {
      throw const InvalidRunOperation(
        'Unknown, foreign, or consumed orchestration proposal handle.',
      );
    }
    return RemoteStrategyToolResult.fromLocal(
      await host.processProposal(tools: snapshot.tools, proposal: proposal),
    );
  });

  @override
  Future<RemoteSemanticModelInput> applyCurrentApproval() => perform(() async {
    final resolution = approval;
    if (resolution == null) {
      throw const InvalidRunOperation(
        'No current host approval is authorized.',
      );
    }
    approval = null;
    return RemoteSemanticModelInput.fromLocal(
      await host.resolveApproval(resolution),
    );
  });
}
