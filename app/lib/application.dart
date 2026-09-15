import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/resource_cleanup.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/plugins/stock_backend_plugins.dart';
import 'package:adele_desktop/plugins/stock_chat_execution_status.dart';
import 'package:adele_desktop/plugins/stock_chat_frontend.dart';
import 'package:adele_desktop/plugins/stock_openai.dart';
import 'package:adele_desktop/plugins/stock_openai_activity_frontend.dart';
import 'package:adele_desktop/plugins/stock_tool_inspection_frontends.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/shell/task_title_form.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatefulWidget {
  const AdeleApplication({
    super.key,
    this.createRuntime = AdeleRuntime.new,
    this.bootstrapPlugins,
    this.readChatGptConfiguration = StockChatGptConfiguration.fromEnvironment,
    this.runIds,
    this.chatFrontendArtifact = const String.fromEnvironment(
      'ADELE_CHAT_FRONTEND_ARTIFACT',
    ),
    this.filesystemFrontendArtifact = const String.fromEnvironment(
      'ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT',
    ),
    this.commandFrontendArtifact = const String.fromEnvironment(
      'ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT',
    ),
    this.openaiActivityFrontendArtifact = const String.fromEnvironment(
      'ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT',
    ),
  });

  /// Called once when mounted; this application owns and closes the result.
  final AdeleRuntime Function() createRuntime;

  final Future<void> Function(ApplicationPluginBootstrap)? bootstrapPlugins;
  final StockChatGptConfiguration? Function() readChatGptConfiguration;
  final RunIdSource? runIds;
  final String chatFrontendArtifact;
  final String filesystemFrontendArtifact;
  final String commandFrontendArtifact;
  final String openaiActivityFrontendArtifact;

  @override
  State<AdeleApplication> createState() => _AdeleApplicationState();
}

final class _AdeleApplicationState extends State<AdeleApplication> {
  late final AdeleRuntime _runtime;
  late final AppLifecycleListener _lifecycleListener;
  late final StreamSubscription<ApplicationPluginState> _pluginSubscription;
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
  ChatController? _chat;
  Session? _session;
  StockChatFrontend? _frontend;
  Future<void>? _frontendActivation;
  bool _frontendFailed = false;
  String? _sessionError;
  final WindowInspection _inspection = WindowInspection();
  final List<StockToolInspectionFrontend> _toolFrontends = [];
  Future<void>? _toolFrontendActivation;
  StockOpenAiActivityFrontendActivation? _openaiActivityFrontend;
  Future<void>? _openaiActivityFrontendActivation;

  @override
  void initState() {
    super.initState();
    _runtime = widget.createRuntime();
    _inspection.addListener(_inspectionChanged);
    try {
      _chatGptConfiguration = widget.readChatGptConfiguration();
    } on Object {
      _modelConfigurationFailed = true;
    }
    _pluginSubscription = _runtime.plugins.changes.listen((state) {
      debugPrint('ADELE backend plugins: ${state.name}');
      _frontend?.refresh();
      if (mounted && _closing == null) setState(() {});
    });
    unawaited(_bootstrapPlugins());
    _frontendActivation = _activateFrontend();
    _toolFrontendActivation = _activateToolFrontends();
    _openaiActivityFrontendActivation = _activateOpenAiActivityFrontend();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _closeRuntime();
        return AppExitResponse.exit;
      },
      onDetach: () => unawaited(_closeRuntime()),
    );
  }

  Future<void> _activateFrontend() async {
    try {
      final StockChatFrontend frontend = await StockChatFrontend.activate(
        extensions: _runtime.extensions,
        artifactPath: widget.chatFrontendArtifact,
        inspectActivity: _inspectActivity,
        controllerForSession: (session) {
          final ChatController? controller = _chat;
          if (controller == null || !identical(controller.session, session)) {
            throw StateError(
              'No stock interaction controller for this Session.',
            );
          }
          return controller;
        },
      );
      if (!mounted || _closing != null) {
        await frontend.close();
      } else {
        _frontend = frontend;
      }
    } on Object {
      // Presentation failure never tears down backend or canonical product state.
      if (mounted && _closing == null) _frontendFailed = true;
    } finally {
      _frontendActivation = null;
      if (mounted && _closing == null) setState(() {});
    }
  }

  Future<void> _activateToolFrontends() async {
    // Explicit stock selection is provisional; each frontend fails independently.
    try {
      for (final activate in <Future<StockToolInspectionFrontend> Function()>[
        () => StockToolInspectionFrontend.activateFilesystem(
          extensions: _runtime.extensions,
          artifactPath: widget.filesystemFrontendArtifact,
        ),
        () => StockToolInspectionFrontend.activateCommand(
          extensions: _runtime.extensions,
          artifactPath: widget.commandFrontendArtifact,
        ),
      ]) {
        try {
          final frontend = await activate();
          if (!mounted || _closing != null) {
            await frontend.close();
          } else {
            _toolFrontends.add(frontend);
          }
        } on Object {
          // No presenter is a normal unavailable state, never a backend failure.
        }
      }
    } finally {
      _toolFrontendActivation = null;
    }
  }

  void _inspectionChanged() {
    if (mounted && _closing == null) setState(() {});
  }

  Future<void> _activateOpenAiActivityFrontend() async {
    try {
      final frontend = await activateStockOpenAiActivityFrontend(
        extensions: _runtime.extensions,
        artifactPath: widget.openaiActivityFrontendArtifact,
      );
      if (!mounted || _closing != null) {
        await frontend.close();
      } else {
        _openaiActivityFrontend = frontend;
      }
    } on Object {
      // Native evidence and model execution do not require its presentation.
    } finally {
      _openaiActivityFrontendActivation = null;
    }
  }

  bool _inspectActivity(
    Session session,
    RunId runId,
    ModelInvocationId modelInvocationId,
  ) {
    final ChatController? chat = _chat;
    if (!mounted ||
        _closing != null ||
        chat == null ||
        !identical(_session, session) ||
        chat.isClosed ||
        chat.activitySummary(runId, modelInvocationId) == null) {
      return false;
    }
    final RunActivitySnapshot? activity = chat.activityForRun(runId);
    if (activity == null) return false;
    final outputSequence = chat
        .activitySummary(runId, modelInvocationId)!
        .outputSequence;
    if (outputSequence != null) {
      return _inspection.inspectOutput(
        session: session,
        activity: activity,
        modelInvocationId: modelInvocationId,
        outputSequence: outputSequence,
      );
    }
    return _inspection.inspectActivity(
      session: session,
      activity: activity,
      modelInvocationId: modelInvocationId,
    );
  }

  void _inspectOutput(
    Session session,
    InspectionCardId originCardId,
    ModelOutputInspectionTarget target,
  ) {
    final chat = _chat;
    if (!mounted ||
        _closing != null ||
        chat == null ||
        chat.isClosed ||
        !identical(_session, session) ||
        target.sessionId != session.id ||
        chat.activitySummary(target.runId, target.modelInvocationId) == null) {
      return;
    }
    final activity = chat.activityForRun(target.runId);
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
        await bootstrapStockBackendPlugins(
          _runtime.plugins,
          chatGptConfiguration: _chatGptConfiguration,
        );
      }
    } on Object catch (error) {
      if (mounted && _closing == null) _bootstrapError = error;
    } finally {
      _frontend?.refresh();
      if (mounted && _closing == null) setState(() {});
    }
  }

  void _createSession() {
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
      final Session session = _runtime.lifecycle.createSession(
        taskId: task.id,
        strategyId: chatStrategyId,
      );
      // Publication is independent of both presentation and controller setup.
      _session = session;
      _inspection.presentSession(session);
      final StockChatGptConfiguration? configuration = _chatGptConfiguration;
      final ChatController chat = ChatController(
        runtime: _runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: configuration?.model,
        runIds: widget.runIds,
        configurationUnavailableReason: _modelConfigurationFailed
            ? 'ChatGPT configuration is invalid. Model execution is unavailable.'
            : configuration == null
            ? 'ChatGPT is not configured. Set '
                  'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE before launching ADELE.'
            : null,
        onChanged: () {
          _frontend?.refresh();
          if (mounted && _closing == null) setState(() {});
        },
        onActivityChanged: () {
          if (_inspection.cards.isNotEmpty) _inspectionChanged();
        },
      );
      setState(() {
        _chat = chat;
        _sessionError = null;
      });
    } on Object {
      setState(
        () => _sessionError = _session == null
            ? 'Could not create the stock Chat Session.'
            : 'Session exists, but stock execution setup is unavailable.',
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
    _inspection.removeListener(_inspectionChanged);
    _inspection.clear();
    final Future<void>? settlingRun = _chat?.close();
    try {
      try {
        // Establishment owns real external work. Let it settle before bounded
        // backend shutdown; closing already prevents further window updates.
        await _taskCreation;
      } on Object {
        // Task failure does not prevent runtime/provider cleanup.
      }
      try {
        await _frontendActivation;
        await _toolFrontendActivation;
        await _openaiActivityFrontendActivation;
      } on Object {
        // A frontend cleanup failure cannot prevent backend/runtime cleanup.
      }
      try {
        await settlingRun;
      } on Object {
        // Run failure must not bypass backend/runtime cleanup.
      }
      try {
        await _runtime.close();
      } finally {
        // Keep the inert input mounted while exit observers await Run settlement.
        // Removing it earlier disposes Flutter lifecycle listeners mid-dispatch.
        await closeResources([
          if (_frontend case final frontend?) frontend.close,
          for (final frontend in _toolFrontends) frontend.close,
          if (_openaiActivityFrontend case final frontend?) frontend.close,
        ]);
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
      final Uri? source = await selector.value.selectProject();
      if (source == null || !mounted || _closing != null) return;
      // A retired selector must not publish a late result into the lifecycle.
      selector.validate();
      final Project project = _runtime.lifecycle.createProject(source);
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
    _frontend?.refresh();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    unawaited(_pluginSubscription.cancel());
    // Flutter disposal cannot await; graceful desktop exit awaits above.
    unawaited(_closeRuntime());
    _inspection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
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
                  activity: _chat?.activityForRun(card.target.runId),
                  heading:
                      _chat
                          ?.activitySummary(
                            card.target.runId,
                            card.target.modelInvocationId,
                          )
                          ?.content ??
                      'Activity is unavailable.',
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
                  if (_frontendFailed)
                    const Text(
                      'Session presentation unavailable: the prepared frontend '
                      'could not be activated.',
                    ),
                  if (_sessionError case final String error) Text(error),
                  SessionPresentationHost(
                    session: _session!,
                    extensions: _runtime.extensions,
                  ),
                  if (_chat case final ChatController controller)
                    StockChatExecutionStatus(controller: controller),
                ],
              )
            : _task != null && !_editingTask
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_sessionError case final String error)
                    Semantics(liveRegion: true, child: Text(error)),
                  FilledButton(
                    onPressed: _closing == null && !_creatingTask
                        ? _createSession
                        : null,
                    child: const Text('New Session'),
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
    );
  }
}
