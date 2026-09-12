/// Stock local directory selection without product lifecycle ownership.
library;

import 'dart:io';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'src/directory_picker_unavailable.dart'
    if (dart.library.ui) 'src/directory_picker_flutter.dart'
    as picker;

final PluginId localDirectoryProjectSelectorPluginId = PluginId(
  'dev.adele.plugin.local-directory-project-selector',
);

final class LocalDirectoryProjectSelectorPlugin {
  const LocalDirectoryProjectSelectorPlugin({
    Future<String?> Function() pickDirectory = picker.pickDirectory,
  }) : _pickDirectory = pickDirectory;

  final Future<String?> Function() _pickDirectory;

  /// Registers the selector without opening a picker or accessing the filesystem.
  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: projectSelectorContributions,
        id: ExtensionId(
          'dev.adele.plugin.local-directory-project-selector.project-selector',
        ),
        value: ProjectSelectorContribution(
          displayName: 'Open Local Directory...',
          selectProject: _selectProject,
        ),
      );

  Future<Uri?> _selectProject() async {
    final String? path = await _pickDirectory();
    if (path == null) return null;
    if (path.isEmpty) {
      throw StateError('The directory picker returned an empty path.');
    }
    return Directory(path).absolute.uri.normalizePath();
  }
}
