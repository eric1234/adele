import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_session_host.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/shell/task_title_form.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatefulWidget {
  const AdeleApplication({
    super.key,
    this.createRuntime = AdeleRuntime.new,
    this.bootstrapPlugins,
    this.readChatGptConfiguration = StockChatGptConfiguration.fromEnvironment,
    this.runIds,
  });

  /// Called once when mounted; this application owns and closes the result.
  final AdeleRuntime Function() createRuntime;

  final Future<void> Function(ApplicationPluginBootstrap)? bootstrapPlugins;
  final StockChatGptConfiguration? Function() readChatGptConfiguration;
  final RunIdSource? runIds;

  @override
  State<AdeleApplication> createState() => _AdeleApplicationState();
}

final class _AdeleApplicationState extends State<AdeleApplication> {
  late final AdeleRuntime _runtime;
  late final AppLifecycleListener _lifecycleListener;
  late final StreamSubscription<ApplicationPluginState> _pluginSubscription;
  late final StreamSubscription<void> _extensionSubscription;
  Future<void>? _closing;
  Object? _bootstrapError;
  Project? _project;
  Task? _task;
  Environment? _environment;
  bool _openingProject = false;
  String? _projectError;
  bool _editingTask = false;
  bool _creatingTask = false;
  Future<TaskCreationResult>? _taskCreation;
  String? _taskError;
  StockChatGptConfiguration? _chatGptConfiguration;
  bool _modelConfigurationFailed = false;
  SessionExecutionController? _execution;
  Session? _session;
  late final PreparedSessionHost _sessionHost;
  late final ApplicationFrontendBootstrap _frontends;
  bool _frontendsStarted = false;
  String? _sessionError;
  final WindowInspection _inspection = WindowInspection();
  final ValueNotifier<bool> _retainingPresentations = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _runtime = widget.createRuntime();
    _sessionHost = PreparedSessionHost(
      extensions: _runtime.extensions,
      backends: _runtime.plugins,
      inspectActivity: _inspectActivity,
      controllerForSession: (session) {
        final controller = _execution;
        if (_closing != null ||
            controller == null ||
            controller.isClosed ||
            !identical(controller.session, session)) {
          throw StateError('No execution controller for this Session.');
        }
        return controller;
      },
    );
    _frontends = ApplicationFrontendBootstrap(
      extensions: _runtime.extensions,
      sessionHost: _sessionHost,
    );
    _inspection.addListener(_inspectionChanged);
    try {
      _chatGptConfiguration = widget.readChatGptConfiguration();
    } on Object {
      _modelConfigurationFailed = true;
    }
    _pluginSubscription = _runtime.plugins.changes.listen((state) {
      debugPrint('ADELE backend plugins: ${state.name}');
      final catalog = _runtime.plugins.catalog;
      if (!_frontendsStarted && _closing == null && catalog != null) {
        _frontendsStarted = true;
        unawaited(_frontends.start(catalog));
      }
      _execution?.refresh();
      if (mounted && _closing == null) setState(() {});
    });
    _extensionSubscription = _runtime.extensions.changes.listen((_) {
      _execution?.refresh();
      if (mounted && _closing == null) setState(() {});
    });
    unawaited(_bootstrapPlugins());
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        _retainingPresentations.value = true;
        _frontends.retainPresentations();
        await _closeRuntime();
        return AppExitResponse.exit;
      },
      onDetach: () {
        _frontends.releasePresentations();
        unawaited(_closeRuntime());
      },
    );
  }

  void _inspectionChanged() {
    if (mounted && _closing == null) setState(() {});
  }

  bool _inspectActivity(Session session, InspectionTarget target) {
    final execution = _execution;
    if (!mounted ||
        _closing != null ||
        execution == null ||
        !identical(_session, session) ||
        execution.isClosed ||
        target.sessionId != session.id) {
      return false;
    }
    final activity = execution.activityForRun(target.runId);
    if (activity == null) return false;
    if (target is ModelOutputInspectionTarget) {
      return _inspection.inspectOutput(
        session: session,
        activity: activity,
        modelInvocationId: target.modelInvocationId,
        outputSequence: target.outputSequence,
      );
    }
    return _inspection.inspectActivity(
      session: session,
      activity: activity,
      modelInvocationId: target.modelInvocationId,
    );
  }

  void _inspectOutput(
    Session session,
    InspectionCardId originCardId,
    ModelOutputInspectionTarget target,
  ) {
    final execution = _execution;
    if (!mounted ||
        _closing != null ||
        execution == null ||
        execution.isClosed ||
        !identical(_session, session) ||
        target.sessionId != session.id) {
      return;
    }
    final activity = execution.activityForRun(target.runId);
    if (activity == null) return;
    _inspection.inspectOutput(
      session: session,
      activity: activity,
      modelInvocationId: target.modelInvocationId,
      outputSequence: target.outputSequence,
      originCardId: originCardId,
    );
  }

  Future<void> _bootstrapPlugins() async {
    try {
      if (widget.bootstrapPlugins case final bootstrap?) {
        await bootstrap(_runtime.plugins);
      } else {
        await _runtime.plugins.start();
      }
    } on Object catch (error) {
      if (mounted && _closing == null) _bootstrapError = error;
    } finally {
      _execution?.refresh();
      if (mounted && _closing == null) setState(() {});
    }
  }

  void _createSession(
    ExtensionBinding<SessionPresentationContribution> choice,
  ) {
    final Task? task = _task;
    if (!mounted ||
        _closing != null ||
        task == null ||
        _session != null ||
        _creatingTask ||
        _editingTask) {
      return;
    }
    try {
      // Resolve presentation ambiguity, strategy and exact sibling affinity
      // before canonical lifecycle publication. No strategy is a default.
      final selection = _sessionHost.resolve(choice);
      selection.validate();
      final Session session = _runtime.lifecycle.createSession(
        taskId: task.id,
        strategyId: choice.value.strategyId,
        resolvedStrategy: selection.strategy,
      );
      // Publication is independent of both presentation and controller setup.
      _session = session;
      _inspection.presentSession(session);
      final StockChatGptConfiguration? configuration = _chatGptConfiguration;
      final controller = SessionExecutionController(
        runtime: _runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: configuration?.model,
        strategy: selection.pinStrategy ? selection.strategy : null,
        runIds: widget.runIds,
        configurationUnavailableReason: _modelConfigurationFailed
            ? 'Model configuration is invalid. Execution is unavailable.'
            : configuration == null
            ? 'Model selection is not configured.'
            : null,
        onChanged: () {
          if (mounted && _closing == null) setState(() {});
        },
        onActivityChanged: () {
          if (_inspection.cards.isNotEmpty) _inspectionChanged();
        },
      );
      _execution = controller;
      _sessionHost.bind(session, selection);
      setState(() {
        _sessionError = null;
      });
    } on Object {
      setState(
        () => _sessionError = _session == null
            ? 'Could not create the selected Session.'
            : 'Session exists, but execution setup is unavailable.',
      );
    }
  }

  String? get _taskUnavailableReason {
    final ApplicationPluginState state = _runtime.plugins.state;
    if (_closing != null ||
        state == ApplicationPluginState.closing ||
        state == ApplicationPluginState.closed) {
      return 'Task Environment support is unavailable: runtime is closing.';
    }
    if (state == ApplicationPluginState.starting) {
      return 'Starting Task Environment support...';
    }
    final Object? failure = _bootstrapError ?? _runtime.plugins.failure;
    if (failure != null) {
      return 'Task Environment support is unavailable: $failure';
    }
    if (_runtime.registry.providersFor(environmentProviderCapability).isEmpty) {
      return 'Task Environment support is unavailable. '
          'Launch ADELE through the maintained repository launcher to prepare '
          'backend artifacts.';
    }
    return null;
  }

  Future<void> _createTask(String title) async {
    final Project? project = _project;
    if (!mounted ||
        project == null ||
        !_editingTask ||
        _creatingTask ||
        _session != null ||
        _closing != null) {
      return;
    }
    final String? unavailable = _taskUnavailableReason;
    final String trimmed = title.trim();
    if (unavailable != null || trimmed.isEmpty) {
      setState(() {
        _taskError = unavailable ?? 'Task title must not be blank.';
      });
      return;
    }
    setState(() {
      _creatingTask = true;
      _taskError = null;
    });
    try {
      final Future<TaskCreationResult> creating = _runtime.lifecycle.createTask(
        projectId: project.id,
        title: trimmed,
      );
      _taskCreation = creating;
      final TaskCreationResult created = await creating;
      if (!mounted || _closing != null) return;
      setState(() {
        _task = created.task;
        _environment = created.environment;
        _editingTask = false;
      });
    } on Object catch (error) {
      if (mounted && _closing == null) {
        setState(() => _taskError = 'Could not create Task: $error');
      }
    } finally {
      if (mounted && _closing == null) {
        setState(() => _creatingTask = false);
      }
    }
  }

  bool get _environmentReady {
    final Environment? environment = _environment;
    if (environment == null || _closing != null) return false;
    final EnvironmentMaterialization? materialization = _runtime
        .lifecycle
        .environmentRuntime
        .currentMaterialization(environment.id);
    if (materialization == null) return false;
    try {
      materialization.validateBinding();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _closeRuntime() => _closing ??= () async {
    _frontends.stopStarting();
    _inspection.removeListener(_inspectionChanged);
    if (!_retainingPresentations.value) _inspection.clear();
    final Future<void>? settlingRun = _execution?.close();
    try {
      try {
        // Establishment owns real external work. Let it settle before bounded
        // backend shutdown; closing already prevents further window updates.
        await _taskCreation;
      } on Object {
        // Task failure does not prevent runtime/provider cleanup.
      }
      try {
        await settlingRun;
      } on Object {
        // Run failure must not bypass backend/runtime cleanup.
      }
      try {
        await _runtime.close();
      } finally {
        // Registrations and actions retire now; exit-retained display subtrees
        // are released only on detach/dispose, not in Flutter's async exit loop.
        await _frontends.close();
      }
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'ADELE application',
          context: ErrorDescription('while closing the application runtime'),
        ),
      );
    }
  }();

  Future<void> _openProject(
    ExtensionBinding<ProjectSelectorContribution> selector,
  ) async {
    if (_openingProject || _closing != null || _project != null) return;
    setState(() {
      _openingProject = true;
      _projectError = null;
    });
    try {
      selector.validate();
      final provider = _runtime.lifecycle.resolveProjectProvider(
        selector.value.projectProviderId,
      );
      void validateSelection() {
        if (!mounted || _closing != null) {
          throw StateError('Project selection is closed.');
        }
        _frontends.validateProjectProvider(
          selector,
          provider,
          _runtime.plugins,
        );
      }

      validateSelection();
      final Uri? source = await selector.value.selectProject();
      if (source == null || !mounted || _closing != null) return;
      // A retired selector must not publish a late result into the lifecycle.
      validateSelection();
      final Project project = await _runtime.lifecycle.openProject(
        sourceLocation: source,
        provider: provider,
        validateSelection: validateSelection,
      );
      if (!mounted || _closing != null) return;
      setState(() => _project = project);
    } on Object catch (error) {
      if (mounted && _closing == null) {
        setState(() => _projectError = 'Could not open Project: $error');
      }
    } finally {
      if (mounted && _closing == null) {
        setState(() => _openingProject = false);
      }
    }
  }

  @override
  void didUpdateWidget(covariant AdeleApplication oldWidget) {
    super.didUpdateWidget(oldWidget);
    _execution?.refresh();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    unawaited(_pluginSubscription.cancel());
    unawaited(_extensionSubscription.cancel());
    _frontends.releasePresentations();
    // Flutter disposal cannot await; graceful desktop exit awaits above.
    unawaited(_closeRuntime());
    _inspection.dispose();
    _retainingPresentations.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final choices = <ExtensionBinding<SessionPresentationContribution>>[];
    for (final candidate in _runtime.extensions.discover(
      sessionPresentationContributions,
    )) {
      try {
        _sessionHost.resolve(candidate);
        choices.add(candidate);
      } on Object {
        // Unavailable/ambiguous strategy or affinity is not a usable choice.
      }
    }
    return ValueListenableBuilder<bool>(
      valueListenable: _retainingPresentations,
      builder: (context, retaining, child) => PreparedFrontendRetention(
        notifier: _retainingPresentations,
        child: IgnorePointer(
          ignoring: retaining,
          child: ExcludeFocus(excluding: retaining, child: child!),
        ),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: AdeleShell(
          project: _project,
          task: _task,
          environment: _environment,
          environmentReady: _environmentReady,
          inspection: _inspection.cards.isEmpty
              ? null
              : InspectionStackHost(
                  cards: _inspection.cards,
                  cardBuilder: (context, card) => InspectionHost(
                    card: card,
                    activity: _execution?.activityForRun(card.target.runId),
                    heading: 'Run activity',
                    extensions: _runtime.extensions,
                    onCollapse: () => _inspection.collapse(card.id),
                    onExpand: () => _inspection.expand(card.id),
                    onDismiss: () => _inspection.dismiss(card.id),
                    onInspectOutput: session == null
                        ? (_) {}
                        : (target) => _inspectOutput(session, card.id, target),
                  ),
                ),
          taskControls: _session != null
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_taskUnavailableReason case final String reason) ...[
                      Semantics(liveRegion: true, child: Text(reason)),
                      const SizedBox(height: 16),
                    ],
                    if (_editingTask)
                      TaskTitleForm(
                        creating: _creatingTask,
                        enabled: _taskUnavailableReason == null,
                        error: _taskError,
                        onSubmit: _createTask,
                        onCancel: () {
                          if (_closing != null || _creatingTask) return;
                          setState(() {
                            _editingTask = false;
                            _taskError = null;
                          });
                        },
                      )
                    else
                      FilledButton(
                        onPressed: _taskUnavailableReason == null
                            ? () {
                                if (!mounted ||
                                    _closing != null ||
                                    _session != null) {
                                  return;
                                }
                                setState(() => _editingTask = true);
                              }
                            : null,
                        child: const Text('New Task'),
                      ),
                  ],
                ),
          sessionControls: _session != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_sessionError case final String error) Text(error),
                    SessionPresentationHost(
                      session: _session!,
                      extensions: _runtime.extensions,
                    ),
                    if (_execution case final controller?)
                      RunExecutionStatus(
                        pendingApproval: controller.pendingApproval,
                        enabled:
                            !controller.isAdvancing && !controller.isClosed,
                        isAdvancing: controller.isAdvancing,
                        failureMessage: controller.failureMessage,
                        unavailableReason: controller.unavailableReason,
                        onDecision: (approval, approved) => controller
                            .resolveApproval(approval, approved: approved),
                      ),
                  ],
                )
              : _task != null && !_editingTask
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_sessionError case final String error)
                      Semantics(liveRegion: true, child: Text(error)),
                    if (choices.isEmpty)
                      const Text('No Session presentations are available.')
                    else
                      for (final choice in choices)
                        FilledButton(
                          onPressed: _closing == null && !_creatingTask
                              ? () => _createSession(choice)
                              : null,
                          child: Text(
                            'New ${choice.value.displayName} Session',
                          ),
                        ),
                  ],
                )
              : null,
          selectors: _runtime.extensions.discover(projectSelectorContributions),
          onSelectProject: _openProject,
          openingProject: _openingProject,
          projectError: _projectError,
        ),
        theme: buildAdeleTheme(),
        title: 'ADELE',
      ),
    );
  }
}
