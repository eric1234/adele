import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';

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
    this.environmentReady = false,
    this.taskControls,
  });

  final Project? project;
  final List<ExtensionBinding<ProjectSelectorContribution>> selectors;
  final ValueChanged<ExtensionBinding<ProjectSelectorContribution>>
  onSelectProject;
  final bool openingProject;
  final String? projectError;
  final Task? task;
  final Environment? environment;
  final bool environmentReady;
  final Widget? taskControls;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'ADELE',
                style: textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Agent development environment',
                style: textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: _StatusCard(
                        icon: project == null
                            ? Icons.folder_off_outlined
                            : Icons.folder_open_outlined,
                        message: project == null
                            ? 'No Project is open'
                            : _projectDisplayName(project!.sourceLocation),
                        children: <Widget>[
                          if (project case final Project project) ...<Widget>[
                            const Text('Project is open'),
                            const SizedBox(height: 8),
                            SelectableText(project.sourceLocation.toString()),
                            const SizedBox(height: 24),
                            if (task case final Task task) ...[
                              Text(
                                'Task: ${task.title}',
                                style: textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                environmentReady
                                    ? 'Primary Environment ready'
                                    : 'Primary Environment unavailable',
                              ),
                              if (environment
                                  case final Environment environment)
                                SelectableText(
                                  'Environment: ${environment.id}',
                                ),
                            ] else
                              Text(
                                'No Tasks yet',
                                style: textTheme.titleMedium,
                              ),
                            if (taskControls case final Widget controls) ...[
                              const SizedBox(height: 24),
                              controls,
                            ],
                          ] else ...<Widget>[
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
                            if (projectError case final String error)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    error,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _projectDisplayName(Uri source) {
  for (final String segment in source.pathSegments.reversed) {
    if (segment.isNotEmpty) return segment;
  }
  return source.host.isNotEmpty ? source.host : source.toString();
}

final class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.message,
    required this.children,
  });

  final IconData icon;
  final String message;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surface,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
