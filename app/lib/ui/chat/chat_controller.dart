import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/model_provider_host.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/ui/execution/pending_tool_approval.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_product/adele_product.dart' show Session;
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Window-local stock Chat interaction, not shared Session lifecycle authority.
final class ChatController {
  ChatController({
    required AdeleRuntime runtime,
    required this.session,
    required this.providerId,
    required this.model,
    RunIdSource? runIds,
    this.configurationUnavailableReason,
    this.onChanged,
  }) : _runtime = runtime,
       _runIds = runIds ?? MonotonicRunIdSource() {
    if (!identical(runtime.store.session(session.id), session) ||
        session.strategyId != chatStrategyId) {
      throw ArgumentError(
        'Chat presentation requires a canonical Chat Session.',
      );
    }
    _chat = runtime.chat.sessions.obtain(session.id);
    _chat.instructions =
        'Inspect source with read/search tools as needed. Source mutations and '
        'commands may be proposed when needed, but they require explicit user '
        'approval before execution.';
    _snapshot = _chat.snapshot();
  }

  final AdeleRuntime _runtime;
  final Session session;
  final ProviderId providerId;
  final String? model;
  final RunIdSource _runIds;
  final String? configurationUnavailableReason;
  final void Function()? onChanged;
  late final ChatSessionState _chat;
  late ChatSessionSnapshot _snapshot;
  SessionOrchestrationRun? _currentRun;
  Future<void>? _activeRunFuture;
  Future<void>? _closing;
  bool _closed = false;
  bool _running = false;
  bool _advancing = false;
  PendingToolApproval? _pendingApproval;
  ToolApprovalInterruption? _pendingInterruption;
  Object? _failure;

  ChatSessionSnapshot get snapshot => _snapshot;
  SessionOrchestrationRun? get currentRun => _currentRun;

  /// Current start/resume operation, not the lifetime of a waiting Run.
  Future<void>? get activeRunFuture => _activeRunFuture;

  /// Blocks new prompts through both advancement and approval waits.
  bool get isRunning => _running;
  bool get isAdvancing => _advancing;
  bool get isClosed => _closed;
  PendingToolApproval? get pendingApproval => _pendingApproval;
  Object? get failure => _failure;

  String? get unavailableReason {
    if (_closed) return 'Model execution is unavailable: window is closing.';
    if (configurationUnavailableReason != null) {
      return configurationUnavailableReason;
    }
    if (model == null || model!.trim().isEmpty) {
      return 'Model execution is unavailable: no model is configured.';
    }
    try {
      // Availability is only a probe. Each accepted Run resolves its own binding.
      _runtime.registry
          .resolve(modelProviderCapability, providerId: providerId)
          .streamChannel;
    } on Object {
      return 'Model execution is unavailable: the selected ChatGPT provider '
          'is not available. Check its configuration and backend activation.';
    }
    return null;
  }

  String? get failureMessage => switch (_failure) {
    null => null,
    ModelFailure(:final kind) => 'Run failed: model ${kind.name}.',
    InvalidRunOperation(:final message) => 'Run failed: $message',
    ProviderUnavailable() || ProviderEndpointUnavailable() =>
      'Run failed: the selected model provider is unavailable.',
    _ => 'Run failed. Check model and Task Environment availability.',
  };

  /// Acceptance is synchronous so duplicate submissions cannot race preparation.
  bool submit(String prompt) {
    if (_closed || _running || prompt.trim().isEmpty) return false;
    if (unavailableReason != null) {
      onChanged?.call();
      return false;
    }
    _chat.append(ChatUserMessage(prompt));
    _snapshot = _chat.snapshot();
    _failure = null;
    _currentRun = null;
    _running = true;
    _advancing = true;
    // Publish the drain future before preparation can fail synchronously.
    _activeRunFuture = Future<void>.microtask(_advance);
    onChanged?.call();
    return true;
  }

  /// Accepts only this window's exact current card, once, before async work starts.
  bool resolveApproval(PendingToolApproval approval, {required bool approved}) {
    final ToolApprovalInterruption? interruption = _pendingInterruption;
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
    onChanged?.call();
    return true;
  }

  Future<void> _advance({ToolApprovalResolution? resolution}) async {
    SessionOrchestrationRun? execution;
    try {
      if (resolution == null) {
        final RunId runId = _runIds.nextRunId();
        final ProviderBinding binding = _runtime.registry.resolve(
          modelProviderCapability,
          providerId: providerId,
        );
        final ModelProviderCapabilityAdapter adapter =
            ModelProviderCapabilityAdapter(binding, selectedModel: model!);
        final ToolCatalog tools = await buildModelToolCatalogForSession(
          sessionId: session.id,
          environmentRuntime: _runtime.lifecycle.environmentRuntime,
          extensions: _runtime.extensions,
        );
        execution = createSessionOrchestrationRun(
          lifecycle: _runtime.lifecycle,
          sessionId: session.id,
          runId: runId,
          contextComposer: _runtime.contextComposer,
          model: adapter,
          toolCatalog: tools,
          policy: const ApprovalGatedToolPolicy(),
        );
        // Accepted work settles on close, without late presentation updates.
        if (!_closed) _currentRun = execution;
        await execution.start();
      } else {
        execution = _currentRun!;
        await execution.resolveApproval(resolution);
      }
      if (!_closed) _inspectRun(execution.run);
    } on Object catch (error) {
      if (!_closed) {
        // An unsupported settled shape must not leave invisible actionable work.
        final AgentRun? run = execution?.run;
        if (run?.state == RunState.running || run?.state == RunState.waiting) {
          run!.fail(error);
        }
        _failure = error;
        _pendingApproval = null;
        _pendingInterruption = null;
        _running = false;
      }
    } finally {
      _activeRunFuture = null;
      if (!_closed) {
        _snapshot = _chat.snapshot();
        _advancing = false;
        onChanged?.call();
      }
    }
  }

  void _inspectRun(AgentRun run) {
    _pendingApproval = null;
    _pendingInterruption = null;
    switch (run.state) {
      case RunState.waiting:
        final List<RunInterruption> interruptions = run.interruptions.values
            .toList();
        if (interruptions case [final ToolApprovalInterruption interruption]) {
          _pendingInterruption = interruption;
          _pendingApproval = PendingToolApproval(interruption);
        } else {
          throw const InvalidRunOperation(
            'Expected exactly one tool approval while Chat is waiting.',
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
          'Chat stopped advancing in unexpected state ${run.state.name}.',
        );
    }
  }

  /// Drains only in-flight advancement. A quiescent waiting Run is abandoned with
  /// the window/runtime, without resolving or executing its pending invocation.
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _activeRunFuture;
    }();
  }
}
