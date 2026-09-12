/// Narrow public ADELE core-owned extension contracts.
library;

import 'package:adele_plugin_api/adele_plugin_api.dart';

/// Zero or more independently selectable contributions, without priority or an
/// implicit default. The host retains and validates the exact [ExtensionBinding]
/// before invocation and before accepting a returned URI. A retired binding must
/// not migrate to a replacement registration; cancellation remains a no-op.
final ExtensionPoint<ProjectSelectorContribution> projectSelectorContributions =
    ExtensionPoint<ProjectSelectorContribution>(
      'dev.adele.extension.project-selectors',
    );

/// Selects a project location, not a product identity or lifecycle object.
final class ProjectSelectorContribution {
  const ProjectSelectorContribution({
    required this.displayName,
    required this.selectProject,
  });

  final String displayName;

  /// Returns only the selected URI, or null for user cancellation. Failures must
  /// propagate rather than becoming cancellation. A URI need not name a local
  /// directory. The host creates the Project after validating the retained
  /// binding; the selector does not create a Project, Task, or Environment.
  final Future<Uri?> Function() selectProject;
}
