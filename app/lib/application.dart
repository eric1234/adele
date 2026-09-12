import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatefulWidget {
  const AdeleApplication({super.key, this.createRuntime = AdeleRuntime.new});

  /// Called once when mounted; this application owns and closes the result.
  final AdeleRuntime Function() createRuntime;

  @override
  State<AdeleApplication> createState() => _AdeleApplicationState();
}

final class _AdeleApplicationState extends State<AdeleApplication> {
  late final AdeleRuntime _runtime;
  late final AppLifecycleListener _lifecycleListener;
  Future<void>? _closing;
  Project? _project;
  bool _openingProject = false;
  String? _projectError;

  @override
  void initState() {
    super.initState();
    _runtime = widget.createRuntime();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _closeRuntime();
        return AppExitResponse.exit;
      },
      onDetach: () => unawaited(_closeRuntime()),
    );
  }

  Future<void> _closeRuntime() => _closing ??= () async {
    try {
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
