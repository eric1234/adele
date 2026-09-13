import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/model_provider_host.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/read_only_tool_policy.dart';
import 'package:adele_desktop/core/run_id_source.dart';
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
        'This interaction is read-only. Inspect source with read/search tools; '
        'do not modify files or execute commands.';
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
  Object? _failure;

  ChatSessionSnapshot get snapshot => _snapshot;
  SessionOrchestrationRun? get currentRun => _currentRun;
  Future<void>? get activeRunFuture => _activeRunFuture;
  bool get isRunning => _running;
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
    _activeRunFuture = _executePrompt();
    onChanged?.call();
    return true;
  }

  Future<void> _executePrompt() async {
    try {
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
      final ReadOnlyToolPolicy policy = const ReadOnlyToolPolicy();
      final SessionOrchestrationRun execution = createSessionOrchestrationRun(
        lifecycle: _runtime.lifecycle,
        sessionId: session.id,
        runId: runId,
        contextComposer: _runtime.contextComposer,
        model: adapter,
        toolCatalog: tools,
        policy: policy,
      );
      // Accepted work still settles on close, but must not update presentation.
      if (!_closed) _currentRun = execution;
      await execution.start();
      if (!_closed) _failure = execution.run.failure;
    } on Object catch (error) {
      if (!_closed) _failure = error;
    } finally {
      if (!_closed) {
        _snapshot = _chat.snapshot();
        _running = false;
        _activeRunFuture = null;
        onChanged?.call();
      }
    }
  }

  /// Blocks acceptance and presentation immediately, then drains accepted work.
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _activeRunFuture;
    }();
  }
}
