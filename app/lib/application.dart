import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/resource_cleanup.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_console_host.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_session_host.dart';
import 'package:adele_desktop/frontend/prepared_task_browser_host.dart';
import 'package:adele_desktop/frontend/window_task_browser_source.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_desktop/ui/console/workbench_console.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/execution/session_execution_owners.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/task_browser/task_browser_presentation_host.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatefulWidget {
  const AdeleApplication({
    super.key,
    this.createRuntime = NativeAdeleRuntime.new,
    this.bootstrapPlugins,
    this.readChatGptConfiguration = StockChatGptConfiguration.fromEnvironment,
    this.runIds,
  });

  /// Called once when mounted; this application owns and closes the result.
  final NativeAdeleRuntime Function() createRuntime;

  final Future<void> Function(ApplicationPluginBootstrap)? bootstrapPlugins;
  final StockChatGptConfiguration? Function() readChatGptConfiguration;
  final RunIdSource? runIds;

  @override
  State<AdeleApplication> createState() => _AdeleApplicationState();
}

final class _AdeleApplicationState extends State<AdeleApplication> {
  late final NativeAdeleRuntime _runtime;
  late final AppLifecycleListener _lifecycleListener;
  late final StreamSubscription<ApplicationPluginState> _pluginSubscription;
  late final StreamSubscription<void> _extensionSubscription;
  late final StreamSubscription<void> _providerSubscription;
  Future<void>? _closing;
  bool _closeFailureReported = false;
  Object? _bootstrapError;
  Project? _project;
  Task? _task;
  Environment? _environment;
  bool _openingProject = false;
  String? _projectError;
  bool _creatingTask = false;
  Future<TaskCreationResult>? _taskCreation;
  StockChatGptConfiguration? _chatGptConfiguration;
  bool _modelConfigurationFailed = false;
  SessionExecutionController? _execution;
  late final SessionExecutionOwners _executions;
  Object? _presentation;
  VoidCallback? _validatePresentation;
  Session? _session;
  late final PreparedSessionHost _sessionHost;
  late final ConsoleController _console;
  late final PreparedConsoleHost _consoleHost;
  late final ApplicationFrontendBootstrap _frontends;
  bool _frontendsStarted = false;
  String? _sessionLabel;
  bool _navigating = false;
  String? _navigationError;
  final Set<WindowTaskBrowserSource> _browsers = {};
  final WindowInspection _inspection = WindowInspection();
  final ValueNotifier<bool> _retainingPresentations = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _runtime = widget.createRuntime();
    _console = ConsoleController(
      _runtime.extensions,
      cleanupTimeout: const Duration(seconds: 3),
    );
    _consoleHost = PreparedConsoleHost(
      store: _runtime.store,
      terminals: _runtime.terminals,
      extensions: _runtime.extensions,
      controller: _console,
      backends: _runtime.plugins,
    );
    _sessionHost = PreparedSessionHost(
      extensions: _runtime.extensions,
      backends: _runtime.plugins,
      inspectActivity: _inspectActivity,
      lookupControllerForSession: (session) => _executions.lookup(session),
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
      backends: _runtime.plugins,
      sessionHost: _sessionHost,
      consoleHost: _consoleHost,
      taskBrowserHost: PreparedTaskBrowserHost(
        sourceForProject: _browserSource,
      ),
    );
    _inspection.addListener(_inspectionChanged);
    try {
      _chatGptConfiguration = widget.readChatGptConfiguration();
    } on Object {
      _modelConfigurationFailed = true;
    }
    _executions = SessionExecutionOwners(
      runtime: _runtime,
      providerId: stockChatGptProviderId,
      model: _chatGptConfiguration?.model,
      runIds: widget.runIds,
      configurationUnavailableReason: _modelConfigurationFailed
          ? 'Model configuration is invalid. Execution is unavailable.'
          : _chatGptConfiguration == null
          ? 'Model selection is not configured.'
          : null,
    );
    _pluginSubscription = _runtime.plugins.changes.listen((state) {
      debugPrint('ADELE backend plugins: ${state.name}');
      final catalog = _runtime.plugins.catalog;
      if (!_frontendsStarted && _closing == null && catalog != null) {
        _frontendsStarted = true;
        unawaited(_frontends.start(catalog));
      }
      _executions.refresh();
      _refreshBrowsers();
      if (mounted && _closing == null) setState(() {});
    });
    _extensionSubscription = _runtime.extensions.changes.listen((_) {
      _executions.refresh();
      _refreshBrowsers();
      if (mounted && _closing == null) setState(() {});
    });
    _providerSubscription = _runtime.registry.changes.listen((_) {
      _executions.refresh();
      _refreshBrowsers();
      if (mounted && _closing == null) setState(() {});
    });
    unawaited(_bootstrapPlugins());
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        _retainingPresentations.value = true;
        _frontends.retainPresentations();
        await _closeAndReport();
        return AppExitResponse.exit;
      },
      onDetach: () {
        _frontends.releasePresentations();
        unawaited(_closeAndReport());
      },
    );
  }

  void _inspectionChanged() {
    if (mounted && _closing == null) setState(() {});
  }

  void _executionChanged() {
    if (mounted && _closing == null) setState(() {});
  }

  void _activityChanged() {
    if (_inspection.cards.isNotEmpty) _inspectionChanged();
  }

  bool _hasPresentationAuthority(Session session, Object? presentation) {
    if (!mounted ||
        _closing != null ||
        _navigating ||
        presentation == null ||
        !identical(_presentation, presentation) ||
        !identical(_session, session)) {
      return false;
    }
    try {
      _validatePresentation!();
      return true;
    } on Object {
      return false;
    }
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
    Object? presentation,
    InspectionCardId originCardId,
    ModelOutputInspectionTarget target,
  ) {
    final execution = _execution;
    if (!_hasPresentationAuthority(session, presentation) ||
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
      _executions.refresh();
      if (mounted && _closing == null) setState(() {});
    }
  }

  WindowTaskBrowserSource _browserSource(Project project) {
    late final WindowTaskBrowserSource source;
    source = WindowTaskBrowserSource(
      project: project,
      lifecycle: _runtime.lifecycle,
      extensions: _runtime.extensions,
      sessionHost: _sessionHost,
      browser: TaskBrowserResolver(_runtime.extensions).resolve(),
      isCurrent: () =>
          mounted &&
          _closing == null &&
          identical(_project, project) &&
          _session == null &&
          !_navigating,
      selectedTask: () => _task,
      isBusy: () => _creatingTask || _navigating,
      onSelectTask: _selectTask,
      establishTask: _createTask,
      activateSession: _activateSession,
      onDispose: () => _browsers.remove(source),
      executionStatusFor: _executions.statusFor,
      executionChanges: _executions,
    );
    _browsers.add(source);
    return source;
  }

  void _refreshBrowsers() {
    for (final browser in _browsers.toList()) {
      browser.refresh();
    }
  }

  void _selectTask(Task? task) {
    if (!mounted || _closing != null || _session != null || _creatingTask) {
      throw StateError('Task selection is currently unavailable.');
    }
    if (task != null &&
        (task.projectId != _project?.id ||
            !identical(_runtime.store.task(task.id), task))) {
      throw StateError('Task does not belong to the current Project.');
    }
    setState(() {
      _task = task;
      _environment = task == null
          ? null
          : _runtime.store.primaryEnvironmentFor(task.id);
      _navigationError = null;
    });
    _refreshBrowsers();
  }

  /// New and retained Sessions share controller, binding, and Inspection setup.
  void _activateSession(
    Session session,
    SessionPresentationSelection selection,
  ) {
    final task = _task;
    if (!mounted ||
        _closing != null ||
        _session != null ||
        _creatingTask ||
        task == null ||
        task.projectId != _project?.id ||
        !identical(_runtime.store.task(task.id), task) ||
        !identical(_runtime.store.session(session.id), session) ||
        session.taskId != task.id) {
      throw StateError('Session is not in the currently selected Task.');
    }
    selection.validate();
    final SessionExecutionController controller;
    try {
      controller = _executions.getOrCreate(
        session,
        strategy: selection.pinStrategy ? selection.strategy : null,
      );
      selection.validateController(controller);
      _sessionHost.bind(session, selection);
    } on Object {
      _sessionHost.unbind(session);
      rethrow;
    }
    controller.addListener(_executionChanged);
    controller.activityChanges.addListener(_activityChanged);
    setState(() {
      _presentation = Object();
      _validatePresentation = selection.validate;
      _session = session;
      _environment = _consoleHost.environmentForSession(session);
      _execution = controller;
      _sessionLabel = selection.presentation.value.displayName;
      _navigationError = null;
    });
    _console.setSession(session);
    _inspection.presentSession(session);
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

  Future<TaskCreationResult> _createTask(String title) async {
    final Project? project = _project;
    if (!mounted ||
        project == null ||
        _creatingTask ||
        _session != null ||
        _closing != null) {
      throw StateError('Task creation is currently unavailable.');
    }
    final String? unavailable = _taskUnavailableReason;
    final String trimmed = title.trim();
    if (unavailable != null || trimmed.isEmpty) {
      throw StateError(unavailable ?? 'Task title must not be blank.');
    }
    setState(() {
      _creatingTask = true;
    });
    try {
      final Future<TaskCreationResult> creating = _runtime.lifecycle.createTask(
        projectId: project.id,
        title: trimmed,
      );
      _taskCreation = creating;
      return await creating;
    } finally {
      _taskCreation = null;
      if (mounted && _closing == null) {
        setState(() => _creatingTask = false);
        _refreshBrowsers();
      }
    }
  }

  Future<void> _showBrowser({required bool keepTask}) async {
    if (!mounted ||
        _closing != null ||
        _navigating ||
        _creatingTask ||
        _project == null) {
      return;
    }
    final session = _session;
    final task = keepTask ? _task : null;
    if (task != null &&
        (task.projectId != _project!.id ||
            !identical(_runtime.store.task(task.id), task))) {
      return;
    }
    if (session == null) {
      _selectTask(task);
      return;
    }
    final execution = _execution!;
    setState(() {
      _navigating = true;
      _navigationError = null;
    });
    try {
      await _sessionHost.prepareToDeactivate(session);
      if (!mounted || _closing != null || !identical(_session, session)) return;
      _presentation = null;
      _validatePresentation = null;
      _sessionHost.unbind(session);
      execution.removeListener(_executionChanged);
      execution.activityChanges.removeListener(_activityChanged);
      _console.setSession(null);
      _inspection.presentSession(null);
      setState(() {
        _execution = null;
        _session = null;
        _sessionLabel = null;
        _navigationError = null;
        _task = task;
        _environment = task == null
            ? null
            : _runtime.store.primaryEnvironmentFor(task.id);
      });
    } on Object {
      if (mounted && _closing == null) {
        setState(
          () => _navigationError =
              'Could not leave this Session. Save pending changes and try again.',
        );
      }
    } finally {
      if (mounted && _closing == null) setState(() => _navigating = false);
    }
  }

  Future<void> _closeRuntime() => _closing ??= () {
    _presentation = null;
    _validatePresentation = null;
    _frontends.stopStarting();
    _execution?.removeListener(_executionChanged);
    _execution?.activityChanges.removeListener(_activityChanged);
    final settlingRuns = _executions.close();
    final closingConsole = _console.close();
    final closingConsoleHost = _consoleHost.close();
    _inspection.removeListener(_inspectionChanged);
    if (!_retainingPresentations.value) _inspection.clear();
    // All owners are fenced before waiting. Storage/backends remain available
    // for normal admitted settlement, including hidden Session history writes.
    final draining = Future.wait<void>([
      settlingRuns,
      closingConsole,
      closingConsoleHost,
      if (_taskCreation case final creating?)
        creating.then<void>((_) {}, onError: (Object _) {}),
    ]);
    return closeResources([
      () async => await draining,
      _runtime.close,
      _frontends.close,
    ]);
  }();

  Future<void> _closeAndReport() async {
    try {
      await _closeRuntime();
    } on Object catch (error, stackTrace) {
      if (_closeFailureReported) return;
      _closeFailureReported = true;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'ADELE application',
          context: ErrorDescription('while closing the application runtime'),
        ),
      );
    }
  }

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
      setState(() {
        _project = project;
        _task = null;
        _environment = null;
        _session = null;
      });
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
    _executions.refresh();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    unawaited(_pluginSubscription.cancel());
    unawaited(_extensionSubscription.cancel());
    unawaited(_providerSubscription.cancel());
    _frontends.releasePresentations();
    // Flutter disposal cannot await; graceful desktop exit awaits above.
    unawaited(_closeAndReport());
    _console.dispose();
    _inspection.dispose();
    _retainingPresentations.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final presentation = _presentation;
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
          sessionLabel: _sessionLabel,
          onProject: () => _showBrowser(keepTask: false),
          onTask: () => _showBrowser(keepTask: true),
          navigating: _navigating,
          navigationError: _navigationError,
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
                        : (target) => _inspectOutput(
                            session,
                            presentation,
                            card.id,
                            target,
                          ),
                  ),
                ),
          taskBrowser: _project == null || session != null
              ? null
              : TaskBrowserPresentationHost(
                  project: _project!,
                  extensions: _runtime.extensions,
                ),
          sessionContent: session == null
              ? null
              : IgnorePointer(
                  ignoring: _navigating,
                  child: ExcludeFocus(
                    excluding: _navigating,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SessionPresentationHost(
                          session: session,
                          extensions: _runtime.extensions,
                        ),
                        if (_execution case final controller?)
                          RunExecutionStatus(
                            pendingApproval: controller.pendingApproval,
                            enabled:
                                !controller.isAdvancing &&
                                !controller.isClosed &&
                                controller.unavailableReason == null &&
                                _hasPresentationAuthority(
                                  session,
                                  presentation,
                                ),
                            isAdvancing: controller.isAdvancing,
                            failureMessage: controller.failureMessage,
                            unavailableReason: controller.unavailableReason,
                            onDecision: (approval, approved) {
                              if (_hasPresentationAuthority(
                                    session,
                                    presentation,
                                  ) &&
                                  controller.unavailableReason == null) {
                                controller.resolveApproval(
                                  approval,
                                  approved: approved,
                                );
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                ),
          console: session == null
              ? null
              : IgnorePointer(
                  ignoring: _navigating,
                  child: ExcludeFocus(
                    excluding: _navigating,
                    child: WorkbenchConsole(controller: _console),
                  ),
                ),
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
