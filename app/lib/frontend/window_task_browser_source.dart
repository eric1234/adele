import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/foundation.dart';

import '../core/product_lifecycle.dart';
import '../ui/project_display_name.dart';
import 'prepared_session_host.dart';
import 'task_browser_bridge.dart';

/// One presented browser's authority over the current window's Project.
/// The canonical graph remains in the lifecycle; this source retains only local
/// creation choices, never provider state or plugin-owned Session content.
final class WindowTaskBrowserSource extends ChangeNotifier
    implements TaskBrowserSource {
  WindowTaskBrowserSource({
    required this.project,
    required this.lifecycle,
    required this.extensions,
    required this.sessionHost,
    required this.browser,
    required this.isCurrent,
    required this.isBusy,
    required this.selectedTask,
    required this.onSelectTask,
    required this.establishTask,
    required this.activateSession,
    required this.onDispose,
    this.executionStatusFor,
    this.executionChanges,
  }) {
    executionChanges?.addListener(refresh);
  }

  final Project project;
  final ProductLifecycleCoordinator lifecycle;
  InMemoryProductStore get store => lifecycle.store;
  final ExtensionRegistry extensions;
  final PreparedSessionHost sessionHost;
  final ExtensionBinding<TaskBrowserContribution> browser;
  final bool Function() isCurrent;
  final bool Function() isBusy;
  final Task? Function() selectedTask;
  final void Function(Task?) onSelectTask;
  final Future<TaskCreationResult> Function(String) establishTask;
  final void Function(Session, SessionPresentationSelection) activateSession;
  final VoidCallback onDispose;

  /// Passive retained-owner lookup, never an execution-owner factory.
  /// Values follow the public Task Browser snapshot's executionStatus contract.
  final String Function(Session)? executionStatusFor;

  /// Generic status changes only, not per-packet execution activity.
  final Listenable? executionChanges;
  final Map<String, SessionPresentationSelection> _options = {};
  Task? _optionsTask;
  int _nextOption = 0;
  bool _busy = false;
  bool _disposed = false;
  int _notifications = 0;

  void _validate() {
    if (_disposed ||
        !isCurrent() ||
        !identical(store.project(project.id), project)) {
      throw StateError('Task Browser is no longer presented.');
    }
    browser.validate();
    if (!browser.isSameRegistration(
      TaskBrowserResolver(extensions).resolve(),
    )) {
      throw StateError('Task Browser selection is no longer current.');
    }
  }

  Task _requireTask() {
    final task = selectedTask();
    if (task == null ||
        task.projectId != project.id ||
        !identical(store.task(task.id), task)) {
      throw StateError('Select a Task in this Project first.');
    }
    return task;
  }

  void refresh() {
    if (_disposed) return;
    _notifications++;
    try {
      notifyListeners();
    } finally {
      _notifications--;
    }
  }

  @override
  Map<String, Object?> read() {
    _validate();
    final task = selectedTask();
    if (task != null) _requireTask();
    if (!identical(_optionsTask, task)) {
      _options.clear();
      _optionsTask = task;
    }
    final usable = <String>{};
    if (task != null) {
      for (final candidate in extensions.discover(
        sessionPresentationContributions,
      )) {
        try {
          final selection = sessionHost.resolve(candidate);
          String? handle;
          for (final entry in _options.entries) {
            final retained = entry.value;
            try {
              retained.validate();
              if (retained.presentation.isSameRegistration(
                    selection.presentation,
                  ) &&
                  retained.strategy.binding.isSameRegistration(
                    selection.strategy.binding,
                  )) {
                handle = entry.key;
                break;
              }
            } on Object {
              // An old option never migrates to a replacement generation.
            }
          }
          handle ??= 'option-${_nextOption++}';
          _options.putIfAbsent(handle, () => selection);
          usable.add(handle);
        } on Object {
          // Missing/ambiguous strategy or affinity is not a creation choice.
        }
      }
    }
    _options.removeWhere((handle, _) => !usable.contains(handle));
    final environment = task == null
        ? null
        : store.primaryEnvironmentFor(task.id);
    return {
      'project': {
        'id': project.id.value,
        'displayName': projectDisplayName(project),
      },
      'selectedTaskId': task?.id.value,
      'tasks': [for (final task in store.tasksFor(project.id)) _taskRow(task)],
      'selectedTask': task == null
          ? null
          : {
              'id': task.id.value,
              'title': task.title,
              'primaryEnvironment': environment == null
                  ? null
                  : {
                      'id': environment.id.value,
                      'providerId': environment.providerId.value,
                    },
              'sessions': [
                for (final session in store.sessionsForTask(task.id))
                  _sessionRow(session),
              ],
              'sessionCreationOptions': [
                for (final entry in _options.entries)
                  {
                    'opaqueHandle': entry.key,
                    'displayName': entry.value.presentation.value.displayName,
                  },
              ],
            },
    };
  }

  String _executionStatus(Session session) {
    final status = executionStatusFor?.call(session) ?? 'idle';
    return switch (status) {
      'idle' ||
      'preparing' ||
      'running' ||
      'waitingForApproval' ||
      'completed' ||
      'cancelled' ||
      'failed' => status,
      _ => throw StateError('Unknown Session execution status.'),
    };
  }

  Map<String, Object?> _taskRow(Task task) {
    final sessions = store.sessionsForTask(task.id);
    final counts = {
      'preparing': 0,
      'running': 0,
      'waiting': 0,
      'terminal': 0,
      'completed': 0,
      'cancelled': 0,
      'failed': 0,
    };
    for (final session in sessions) {
      final status = _executionStatus(session);
      if (status == 'idle') continue;
      final category = status == 'waitingForApproval' ? 'waiting' : status;
      counts[category] = counts[category]! + 1;
      if (status == 'completed' ||
          status == 'cancelled' ||
          status == 'failed') {
        counts['terminal'] = counts['terminal']! + 1;
      }
    }
    return {
      'id': task.id.value,
      'title': task.title,
      'sessionCount': sessions.length,
      'executionCounts': counts,
    };
  }

  Map<String, Object?> _sessionRow(Session session) {
    var label = session.strategyId.value;
    var available = false;
    try {
      final presentation = SessionPresentationResolver(
        extensions,
      ).resolve(session.strategyId);
      label = presentation.value.displayName;
      sessionHost.resolve(presentation, session: session).validate();
      available = true;
    } on Object {
      // Persisted Sessions remain visible even when their execution is absent.
    }
    return {
      'id': session.id.value,
      'strategyId': session.strategyId.value,
      'presentationName': label,
      'available': available,
      'executionStatus': _executionStatus(session),
    };
  }

  Future<void> _operate(Future<void> Function() operation) async {
    _validate();
    if (_busy || isBusy()) {
      throw StateError('A Task Browser operation is already pending.');
    }
    _busy = true;
    try {
      await operation();
    } finally {
      _busy = false;
      refresh();
    }
  }

  @override
  Future<void> selectTask(String? taskId) => _operate(() async {
    Task? task;
    if (taskId != null) {
      task = store.task(TaskId(taskId));
      if (task == null || task.projectId != project.id) {
        throw StateError('Task does not belong to this Project.');
      }
    }
    onSelectTask(task);
  });

  @override
  Future<void> createTask(String title) => _operate(() async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw StateError('Task title must not be blank.');
    final created = await establishTask(trimmed);
    // Retirement cannot roll back establishment, but must prevent late navigation.
    _validate();
    if (created.task.projectId != project.id ||
        !identical(store.task(created.task.id), created.task)) {
      throw StateError('Created Task is not in this Project.');
    }
    onSelectTask(created.task);
  });

  @override
  Future<void> createSession(String optionHandle) => _operate(() async {
    final task = _requireTask();
    final selection = _options[optionHandle];
    if (!identical(task, _optionsTask) || selection == null) {
      throw StateError('Session creation option is no longer available.');
    }
    selection.validate();
    // Revalidate uniqueness and affinity without replacing the retained choice.
    final current = sessionHost.resolve(selection.presentation);
    if (!current.strategy.binding.isSameRegistration(
      selection.strategy.binding,
    )) {
      throw StateError('Session creation option is no longer current.');
    }
    final session = lifecycle.createSession(
      taskId: task.id,
      strategyId: selection.strategy.strategyId,
      resolvedStrategy: selection.strategy,
    );
    activateSession(session, selection);
  });

  @override
  Future<void> openSession(String sessionId) => _operate(() async {
    final task = _requireTask();
    final session = store.session(SessionId(sessionId));
    if (session == null || session.taskId != task.id) {
      throw StateError('Session does not belong to the selected Task.');
    }
    final presentation = SessionPresentationResolver(
      extensions,
    ).resolve(session.strategyId);
    final selection = sessionHost.resolve(presentation, session: session)
      ..validate();
    activateSession(session, selection);
  });

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    executionChanges?.removeListener(refresh);
    _options.clear();
    onDispose();
    // A bridge can detect retirement and revoke this source from its own change
    // callback. Authority ends now; notifier cleanup waits until delivery ends.
    if (_notifications > 0) {
      scheduleMicrotask(super.dispose);
    } else {
      super.dispose();
    }
  }
}
