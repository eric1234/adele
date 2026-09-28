import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';

import '../project_display_name.dart';

final class AdeleShell extends StatelessWidget {
  const AdeleShell({
    super.key,
    required this.project,
    required this.selectors,
    required this.onSelectProject,
    this.openingProject = false,
    this.projectError,
    this.task,
    this.environment,
    this.taskBrowser,
    this.sessionContent,
    this.sessionLabel,
    this.onProject,
    this.onTask,
    this.navigating = false,
    this.navigationError,
    this.inspection,
    this.inspectionScrollController,
    this.console,
  });

  final Project? project;
  final List<ExtensionBinding<ProjectSelectorContribution>> selectors;
  final ValueChanged<ExtensionBinding<ProjectSelectorContribution>>
  onSelectProject;
  final bool openingProject;
  final String? projectError;
  final Task? task;
  final Environment? environment;
  final Widget? taskBrowser;
  final Widget? sessionContent;
  final String? sessionLabel;
  final VoidCallback? onProject;
  final VoidCallback? onTask;
  final bool navigating;
  final String? navigationError;
  final Widget? inspection;
  final ScrollController? inspectionScrollController;
  final Widget? console;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Text('ADELE'),
              if (project case final project?) ...[
                const Text(' > '),
                TextButton(
                  key: const ValueKey('project-breadcrumb'),
                  onPressed: navigating ? null : onProject,
                  child: Text(projectDisplayName(project)),
                ),
                const Text(' > '),
                if (sessionContent != null && task != null) ...[
                  TextButton(
                    key: const ValueKey('task-breadcrumb'),
                    onPressed: navigating ? null : onTask,
                    child: Text(task!.title),
                  ),
                  const Text(' > '),
                  Text(sessionLabel ?? 'Session'),
                ] else
                  const Text('Tasks'),
              ],
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (navigationError case final error?)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            if (navigating) const LinearProgressIndicator(),
            Expanded(
              child: project == null
                  ? _projectSelection(context)
                  : sessionContent == null
                  ? taskBrowser ??
                        const Center(child: Text('Task Browser unavailable'))
                  : _sessionLayout(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _projectSelection(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'No Project is open',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                if (selectors.isEmpty)
                  const Text('No Project selectors are available.'),
                for (final selector in selectors)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton(
                      onPressed: openingProject
                          ? null
                          : () => onSelectProject(selector),
                      child: Text(selector.value.displayName),
                    ),
                  ),
                if (openingProject)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('Selecting Project...'),
                  ),
                if (projectError case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _sessionLayout() => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _sessionAndInspection()),
        if (console case final content?)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .45),
            child: content,
          ),
      ],
    ),
  );

  Widget _sessionAndInspection() => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = constraints.maxWidth >= 840;
      return Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: sessionContent,
            ),
          ),
          if (inspection case final content?)
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                controller: inspectionScrollController,
                padding: const EdgeInsets.all(16),
                child: content,
              ),
            ),
        ],
      );
    },
  );
}
