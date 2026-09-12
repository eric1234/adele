import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/plugins/stock_backend_plugins.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/shell/task_title_form.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatefulWidget {
  const AdeleApplication({
    super.key,
    this.createRuntime = AdeleRuntime.new,
    this.bootstrapPlugins = bootstrapStockBackendPlugins,
  });

  /// Called once when mounted; this application owns and closes the result.
  final AdeleRuntime Function() createRuntime;

  final Future<void> Function(ApplicationPluginBootstrap) bootstrapPlugins;

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

  @override
  void initState() {
    super.initState();
    _runtime = widget.createRuntime();
    _pluginSubscription = _runtime.plugins.changes.listen((state) {
      debugPrint('ADELE backend plugins: ${state.name}');
      if (mounted && _closing == null) setState(() {});
    });
    unawaited(_bootstrapPlugins());
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _closeRuntime();
        return AppExitResponse.exit;
      },
      onDetach: () => unawaited(_closeRuntime()),
    );
  }

  Future<void> _bootstrapPlugins() async {
    try {
      await widget.bootstrapPlugins(_runtime.plugins);
    } on Object catch (error) {
      if (mounted && _closing == null) _bootstrapError = error;
    } finally {
      if (mounted && _closing == null) setState(() {});
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
    try {
      try {
        // Establishment owns real external work. Let it settle before bounded
        // backend shutdown; closing already prevents further window updates.
        await _taskCreation;
      } on Object {
        // Task failure does not prevent runtime/provider cleanup.
      }
      await _runtime.close();
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
  void dispose() {
    _lifecycleListener.dispose();
    unawaited(_pluginSubscription.cancel());
    // Flutter disposal cannot await; graceful desktop exit awaits above.
    unawaited(_closeRuntime());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AdeleShell(
        project: _project,
        task: _task,
        environment: _environment,
        environmentReady: _environmentReady,
        taskControls: Column(
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
                        if (!mounted || _closing != null) return;
                        setState(() => _editingTask = true);
                      }
                    : null,
                child: const Text('New Task'),
              ),
          ],
        ),
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
