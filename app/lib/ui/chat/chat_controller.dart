import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/model_provider_host.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/ui/execution/pending_tool_approval.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
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
    this.onActivityChanged,
  }) : _runtime = runtime,
       _runIds = runIds ?? MonotonicRunIdSource() {
    if (!identical(runtime.store.session(session.id), session) ||
        session.strategyId != chatStrategyId) {
      throw ArgumentError(
        'Chat presentation requires a canonical Chat Session.',
      );
    }
    _chat = runtime.chat.sessions.obtain(session.id);
    if (_chat.instructions.isEmpty) {
      _chat.instructions =
          'Inspect source with read/search tools as needed. Source mutations and '
          'commands may be proposed when needed, but they require explicit user '
          'approval before execution.';
    }
    _snapshot = _chat.snapshot();
    _presentationSubscription = runtime.extensions.changes.listen(
      (_) => _refreshNativePresentations(),
    );
  }

  final AdeleRuntime _runtime;
  final Session session;
  final ProviderId providerId;
  final String? model;
  final RunIdSource _runIds;
  final String? configurationUnavailableReason;
  final void Function()? onChanged;

  /// Read-only evidence changed, independently of compact Chat presentation.
  final void Function()? onActivityChanged;
  late final ChatSessionState _chat;
  late ChatSessionSnapshot _snapshot;
  late ChatUserMessage _activeUserMessage;
  final Map<ChatUserMessage, RunActivitySnapshot> _activity = {};
  final Map<(RunId, ModelInvocationId), ChatActivitySummary?>
  _activitySummaries = {};
  final Map<
    (RunId, ModelInvocationId),
    List<ExtensionBinding<ModelNativeActivityPresentationContribution>>
  >
  _nativePresentationAttempts = {};
  StreamSubscription<void>? _presentationSubscription;
  RunActivitySource? _activitySource;
  StreamSubscription<void>? _activitySubscription;
  bool _activityUpdateScheduled = false;
  int _visibleActivityCount = 0;
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

  /// Presentation-lifetime evidence only, never canonical Chat or Run authority.
  List<RunActivitySnapshot> get activitySnapshots =>
      List.unmodifiable(_activity.values);

  /// Reads retained evidence without capturing new progress or execution state.
  RunActivitySnapshot? activityForRun(RunId runId) {
    if (_closed) return null;
    for (final RunActivitySnapshot activity in _activity.values) {
      if (activity.runId == runId) return activity;
    }
    return null;
  }

  ChatActivitySummary? activitySummary(
    RunId runId,
    ModelInvocationId invocationId,
  ) {
    final RunActivitySnapshot? activity = activityForRun(runId);
    if (activity == null) return null;
    return _activitySummaries[(runId, invocationId)];
  }

  List<ChatTimelineEntry> get timeline => List.unmodifiable([
    for (final ChatEntry entry in _snapshot.entries) ...[
      ChatTimelineMessage(entry),
      if (_activity[entry] case final RunActivitySnapshot activity)
        for (final model in activity.models)
          if (_activitySummaries[(activity.runId, model.id)]
              case final ChatActivitySummary summary)
            summary,
    ],
  ]);

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
    _activeUserMessage = ChatUserMessage(prompt);
    _chat.append(_activeUserMessage);
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
        if (!_closed) {
          _currentRun = execution;
          _observeActivity(execution.activity, _activeUserMessage);
        }
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
        if (_activitySource case final RunActivitySource source) {
          _captureActivity(source, _activeUserMessage, notify: false);
        }
        if (!_running) _detachActivity();
        _snapshot = _chat.snapshot();
        _advancing = false;
        onChanged?.call();
      }
    }
  }

  void _observeActivity(RunActivitySource source, ChatUserMessage user) {
    _activitySource = source;
    // Subscribe before the initial read so no recorded evidence can be missed.
    _activitySubscription = source.changes.listen((_) {
      if (_closed || !identical(_activitySource, source)) return;
      if (_activityUpdateScheduled) return;
      _activityUpdateScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _activityUpdateScheduled = false;
        if (_closed) return;
        if (_activitySource case final RunActivitySource current) {
          _captureActivity(current, _activeUserMessage);
        }
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    });
    _captureActivity(source, user, notify: false);
  }

  void _captureActivity(
    RunActivitySource source,
    ChatUserMessage user, {
    bool notify = true,
  }) {
    final RunActivitySnapshot snapshot = source.snapshot;
    if (identical(_activity[user], snapshot)) return;
    _activity[user] = snapshot;
    _captureSummaries(snapshot);
    _notifyActivity(notify: notify);
  }

  void _notifyActivity({bool notify = true}) {
    final int count = timeline.whereType<ChatActivitySummary>().length;
    final bool changed = count != _visibleActivityCount;
    _visibleActivityCount = count;
    for (final callback in [
      onActivityChanged,
      // Tool progress stays inspectable without rebuilding compact UI per chunk.
      if (notify && changed) onChanged,
    ]) {
      if (_closed) return;
      try {
        callback?.call();
      } on Object catch (error, stack) {
        // Observation failures must not become Run failures or skip settlement.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Chat activity observation',
          ),
        );
      }
    }
  }

  List<ExtensionBinding<ModelNativeActivityPresentationContribution>>
  _nativePresentationBindings(ModelInvocationActivity model) {
    final kinds = {
      for (final output in model.outputs)
        if (output.item case final ModelNativeOutput native)
          native.providerNativeMetadata.kind,
    };
    return [
      for (final binding in _runtime.extensions.discover(
        modelNativeActivityPresentationContributions,
      ))
        if (kinds.contains(binding.value.nativeKind)) binding,
    ];
  }

  void _refreshNativePresentations() {
    if (_closed || _nativePresentationAttempts.isEmpty) return;
    for (final activity in _activity.values) {
      bool retry = false;
      for (final model in activity.models) {
        final key = (activity.runId, model.id);
        final previous = _nativePresentationAttempts[key];
        if (previous == null) continue;
        final current = _nativePresentationBindings(model);
        bool changed = previous.length != current.length;
        try {
          // Equal IDs, values and counts can still represent new generations.
          for (final binding in previous) {
            binding.validate();
          }
        } on StaleExtensionBinding {
          changed = true;
        }
        if (!changed) continue;
        _nativePresentationAttempts.remove(key);
        _activitySummaries.remove(key);
        retry = true;
      }
      if (retry) _captureSummaries(activity);
    }
    if (!_closed &&
        timeline.whereType<ChatActivitySummary>().length !=
            _visibleActivityCount) {
      _notifyActivity();
    }
  }

  void _detachActivity() {
    final StreamSubscription<void>? subscription = _activitySubscription;
    _activitySource = null;
    _activitySubscription = null;
    // Listener removal is synchronous; this notification-only source owns no
    // asynchronous execution cleanup to put ahead of the accepted Run drain.
    unawaited(subscription?.cancel());
  }

  void _captureSummaries(RunActivitySnapshot activity) {
    for (final model in activity.models) {
      if (_closed) return;
      final key = (activity.runId, model.id);
      if (model.settlement != ModelSettlement.completed ||
          model.failure != null ||
          _activitySummaries.containsKey(key)) {
        continue;
      }
      // Successful summaries outlive presentation retirement. Negative native
      // attempts below remain cached only for the matching registry generations.
      _activitySummaries[key] = null;
      final output = [...model.outputs]
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      final int count = output
          .where((output) => output.item is ModelToolProposalOutput)
          .length;
      final bindings = _nativePresentationBindings(model);
      String? compactNative;
      for (final item in output) {
        if (item.item case final ModelNativeOutput native) {
          try {
            final projected = ModelNativeActivityPresentationResolver(
              _runtime.extensions,
            ).project(native);
            if (projected != null) {
              compactNative = projected.projection.compactText;
              break;
            }
          } on Object {
            // Ambiguity and projector failure affect only this presentation.
          }
        }
      }
      if (_closed) return;
      if (count == 0 && compactNative == null) {
        if (output.any((item) => item.item is ModelNativeOutput)) {
          _nativePresentationAttempts[key] = bindings;
        }
        continue;
      }
      final String narration = count == 0
          ? ''
          : output
                .map((output) => output.item)
                .whereType<ModelTextOutput>()
                .map((item) => item.content)
                .join('\n')
                .trim();
      _activitySummaries[key] = ChatActivitySummary(
        runId: activity.runId,
        invocationId: model.id,
        content: narration.isNotEmpty
            ? narration
            : compactNative ??
                  '$count tool ${count == 1 ? 'operation' : 'operations'}',
      );
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
    _detachActivity();
    final subscription = _presentationSubscription;
    _presentationSubscription = null;
    unawaited(subscription?.cancel());
    _nativePresentationAttempts.clear();
    return _closing ??= () async {
      await _activeRunFuture;
    }();
  }
}

/// Stock Chat's mixed timeline is presentation, not a new ChatEntry variant.
sealed class ChatTimelineEntry {
  const ChatTimelineEntry();

  String get content;
}

final class ChatTimelineMessage extends ChatTimelineEntry {
  const ChatTimelineMessage(this.message);

  final ChatEntry message;

  @override
  String get content => message.content;
}

final class ChatActivitySummary extends ChatTimelineEntry {
  const ChatActivitySummary({
    required this.runId,
    required this.invocationId,
    required this.content,
  });

  final RunId runId;
  final ModelInvocationId invocationId;
  @override
  final String content;
}
