import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/plugins/chat_frontend_bridge.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/widgets.dart';

/// Transitional stock activation over a prepared generation, not discovery or
/// installation. Neither activation nor presentation compiles frontend source.
final class StockChatFrontend {
  StockChatFrontend._(this._generation, this._inspectActivity);

  final PreparedFrontend _generation;
  final bool Function(
    Session session,
    RunId runId,
    ModelInvocationId invocationId,
  )?
  _inspectActivity;
  late final ExtensionRegistration _registration;
  final Set<_ControllerSource> _sources = {};
  bool _closed = false;
  Future<void>? _closing;

  static Future<StockChatFrontend> activate({
    required ExtensionRegistry extensions,
    required String artifactPath,
    required ChatController Function(Session) controllerForSession,
    bool Function(Session session, RunId runId, ModelInvocationId invocationId)?
    inspectActivity,
  }) async {
    if (artifactPath.isEmpty) {
      throw StateError('No prepared stock Chat frontend artifact configured.');
    }
    final PreparedFrontend generation = await PreparedFrontend.load(
      File(artifactPath),
    );
    if (generation.failure != null) {
      generation.invalidate();
      throw StateError('Could not load the prepared stock Chat frontend.');
    }
    final StockChatFrontend frontend = StockChatFrontend._(
      generation,
      inspectActivity,
    );
    try {
      frontend._registration = extensions.register(
        point: sessionPresentationContributions,
        id: ExtensionId('dev.adele.plugin.chat-strategy.presentation'),
        value: SessionPresentationContribution(
          strategyId: chatStrategyId,
          createPresentation: (session) {
            if (!frontend._active) {
              throw StateError('The stock Chat presentation is retired.');
            }
            return _StockChatPresentation(
              frontend: frontend,
              controller: controllerForSession(session),
            );
          },
        ),
      );
      return frontend;
    } on Object {
      generation.invalidate();
      rethrow;
    }
  }

  bool get _active => !_closed && !_registration.isClosed;

  void refresh() {
    if (!_active) return;
    for (final _ControllerSource source in _sources.toList()) {
      source.refresh();
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final Future<void> retiring = _registration.close();
    _generation.invalidate();
    for (final _ControllerSource source in _sources.toList()) {
      source.close();
    }
    _sources.clear();
    return _closing = retiring;
  }
}

final class _StockChatPresentation extends StatefulWidget {
  const _StockChatPresentation({
    required this.frontend,
    required this.controller,
  });

  final StockChatFrontend frontend;
  final ChatController controller;

  @override
  State<_StockChatPresentation> createState() => _StockChatPresentationState();
}

final class _StockChatPresentationState extends State<_StockChatPresentation> {
  late final _ControllerSource _source;
  late final Widget _presentation;

  @override
  void initState() {
    super.initState();
    _source = _ControllerSource(
      widget.controller,
      isActive: () => widget.frontend._active,
      inspectActivity: widget.frontend._inspectActivity,
    );
    widget.frontend._sources.add(_source);
    _presentation = widget.frontend._generation.createChatPresentation(
      source: _source,
      isActive: () => widget.frontend._active && !_source.closed,
    );
  }

  @override
  void dispose() {
    widget.frontend._sources.remove(_source);
    _source.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _presentation;
}

/// The interpreted frontend receives this narrow source only through boxed
/// primitive snapshots/functions, never the controller or its authority graph.
final class _ControllerSource extends ChangeNotifier
    implements ChatFrontendSource {
  _ControllerSource(
    this._controller, {
    required bool Function() isActive,
    required bool Function(
      Session session,
      RunId runId,
      ModelInvocationId invocationId,
    )?
    inspectActivity,
  }) : _isActive = isActive,
       _inspectActivity = inspectActivity;

  final ChatController _controller;
  final bool Function() _isActive;
  final bool Function(
    Session session,
    RunId runId,
    ModelInvocationId invocationId,
  )?
  _inspectActivity;
  final Map<String, ChatActivitySummary> _emittedActivity = {};
  bool closed = false;

  @override
  ChatPresentationSnapshot get snapshot {
    _emittedActivity.clear();
    if (closed || !_isActive() || _controller.isClosed) {
      return ChatPresentationSnapshot(entries: const [], canSubmit: false);
    }
    final List<ChatPresentationEntry> entries = [];
    for (final ChatTimelineEntry entry in _controller.timeline) {
      switch (entry) {
        case ChatTimelineMessage(:final message):
          entries.add(
            ChatPresentationEntry(
              role: message is ChatUserMessage ? 'user' : 'assistant',
              content: message.content,
            ),
          );
        case ChatActivitySummary():
          final String id = jsonEncode([
            entry.runId.value,
            entry.invocationId.value,
          ]);
          _emittedActivity[id] = entry;
          entries.add(
            ChatPresentationEntry.activity(id: id, content: entry.content),
          );
      }
    }
    return ChatPresentationSnapshot(
      entries: entries,
      canSubmit:
          !_controller.isRunning && _controller.unavailableReason == null,
    );
  }

  @override
  bool submit(String prompt) => !closed && _controller.submit(prompt);

  @override
  bool inspectActivity(String id) {
    if (closed || !_isActive() || _controller.isClosed) return false;
    // Match only emitted IDs. Never decode a caller's string into authority.
    final ChatActivitySummary? summary = _emittedActivity[id];
    if (summary == null ||
        _controller.activitySummary(summary.runId, summary.invocationId) ==
            null) {
      return false;
    }
    return _inspectActivity?.call(
          _controller.session,
          summary.runId,
          summary.invocationId,
        ) ??
        false;
  }

  void refresh() {
    if (!closed) notifyListeners();
  }

  void close() {
    if (closed) return;
    closed = true;
    _emittedActivity.clear();
    dispose();
  }
}
