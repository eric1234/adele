import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart'
    show runCommandToolId;
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart'
    show applyPatchToolId;
import 'package:flutter/widgets.dart';

/// Independent stock presentation activation over the existing D1 lifecycle.
/// Loading/retiring these generations never changes headless tool registrations.
final class StockToolInspectionFrontend {
  StockToolInspectionFrontend._(this._generation);

  final PreparedFrontend _generation;
  late final ExtensionRegistration _registration;
  bool _closed = false;
  Future<void>? _closing;

  static Future<StockToolInspectionFrontend> activateFilesystem({
    required ExtensionRegistry extensions,
    required String artifactPath,
  }) => _activate(
    extensions: extensions,
    artifactPath: artifactPath,
    toolId: applyPatchToolId,
    library: 'package:filesystem_tools_frontend/filesystem_tools_frontend.dart',
    entrypoint: 'buildApplyPatchInspection',
    extensionId: 'dev.adele.plugin.filesystem-tools.inspection',
  );

  static Future<StockToolInspectionFrontend> activateCommand({
    required ExtensionRegistry extensions,
    required String artifactPath,
  }) => _activate(
    extensions: extensions,
    artifactPath: artifactPath,
    toolId: runCommandToolId,
    library: 'package:command_tools_frontend/command_tools_frontend.dart',
    entrypoint: 'buildRunCommandInspection',
    extensionId: 'dev.adele.plugin.command-tools.inspection',
  );

  static Future<StockToolInspectionFrontend> _activate({
    required ExtensionRegistry extensions,
    required String artifactPath,
    required ToolId toolId,
    required String library,
    required String entrypoint,
    required String extensionId,
  }) async {
    if (artifactPath.isEmpty) {
      throw StateError(
        'No prepared $extensionId frontend artifact configured.',
      );
    }
    final PreparedFrontend generation = await PreparedFrontend.load(
      File(artifactPath),
    );
    if (generation.failure != null) {
      generation.invalidate();
      throw StateError('Could not load the prepared $extensionId frontend.');
    }
    final StockToolInspectionFrontend frontend = StockToolInspectionFrontend._(
      generation,
    );
    try {
      frontend._registration = extensions.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId(extensionId),
        value: ToolActivityInspectionContribution(
          toolId: toolId,
          createPresentation: (source) {
            if (!frontend._active) {
              throw StateError('The $extensionId frontend is retired.');
            }
            return generation.createPresentation(
              library: library,
              entrypoint: entrypoint,
              key: ObjectKey(source),
              createBridge: () => ToolActivityInspectionBridge(
                source: source,
                isActive: () => frontend._active,
              ),
            );
          },
        ),
      );
      return frontend;
    } on Object {
      generation.invalidate();
      rethrow;
    }
  }

  bool get _active => !_closed && !_registration.isClosed;

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final Future<void> retiring = _registration.close();
    _generation.invalidate();
    return _closing = retiring;
  }
}
