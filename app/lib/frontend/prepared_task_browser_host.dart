import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'layout_builder_bridge.dart';
import 'prepared_frontend.dart';
import 'task_browser_bridge.dart';

/// Owns presentation-local sources without any strategy/backend dependency.
final class PreparedTaskBrowserHost {
  PreparedTaskBrowserHost({required this.sourceForProject});

  final TaskBrowserSource Function(Project) sourceForProject;
  final Set<TaskBrowserBridge> _bridges = {};
  bool _closed = false;

  Widget createPresentation({
    required PreparedFrontend generation,
    required TaskBrowserContribution contribution,
    required PreparedTaskBrowserPresentation descriptor,
    required Project project,
    required bool Function() isActive,
  }) {
    void validate() {
      if (_closed || !isActive()) {
        throw StateError('Task Browser hosting is unavailable.');
      }
    }

    validate();
    return generation.createPresentation(
      library: descriptor.library,
      entrypoint: descriptor.entrypoint,
      key: ObjectKey(project),
      createBridge: () {
        validate();
        final source = sourceForProject(project);
        late final TaskBrowserBridge bridge;
        bridge = TaskBrowserBridge(
          source: source,
          isActive: () => !_closed && isActive(),
          onDispose: () {
            _bridges.remove(bridge);
            source.dispose();
          },
        );
        _bridges.add(bridge);
        return PreparedFrontendBridges([const LayoutBuilderBridge(), bridge]);
      },
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final bridge in _bridges.toList()) {
      bridge.invalidate();
    }
  }
}
