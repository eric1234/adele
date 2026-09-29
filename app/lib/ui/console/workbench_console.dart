import 'dart:async';

import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';

import 'console_controller.dart';

/// Shared console chrome. The parent owns placement and the controller lifetime.
class WorkbenchConsole extends StatefulWidget {
  const WorkbenchConsole({super.key, required this.controller});

  final ConsoleController controller;

  @override
  State<WorkbenchConsole> createState() => _WorkbenchConsoleState();
}

class _WorkbenchConsoleState extends State<WorkbenchConsole> {
  @override
  void didUpdateWidget(WorkbenchConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.unmountPresentation();
    }
  }

  @override
  void deactivate() {
    widget.controller.unmountPresentation();
    super.deactivate();
  }

  Future<bool> _confirm(ConsoleCloseRequest request) async {
    if (!mounted || !request.isPending) return false;
    final navigator = Navigator.of(context, rootNavigator: true);
    late final DialogRoute<bool> route;
    var answered = false;
    void answer(bool accepted) {
      if (!answered &&
          request.isPending &&
          navigator.mounted &&
          identical(route.navigator, navigator) &&
          route.isCurrent) {
        answered = true;
        navigator.pop(accepted);
      }
    }

    route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (_) => AlertDialog(
        title: const Text('Close console'),
        content: Text(request.message),
        actions: [
          TextButton(
            onPressed: () => answer(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => answer(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    var settled = false;
    unawaited(
      request.withdrawn.then((_) {
        if (settled) return;
        // Unmount/replacement can invalidate during tree teardown. Retain only
        // the exact route/Navigator and mutate its history after that frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!settled &&
              navigator.mounted &&
              identical(route.navigator, navigator) &&
              route.isActive) {
            navigator.removeRoute(route);
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }),
    );
    try {
      return await navigator.push(route) ?? false;
    } finally {
      settled = true;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final tabs = controller.eligibleTabs;
      final actions = controller.actions;
      final residents = controller.residentPresentations;
      final colors = Theme.of(context).colorScheme;
      return LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 368),
          child: Material(
            color: colors.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: constraints.maxHeight.clamp(0, 48).toDouble(),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text('Console'),
                              ),
                              if (controller.visible)
                                for (final tab in tabs)
                                  Container(
                                    key: ObjectKey(tab),
                                    constraints: const BoxConstraints(
                                      maxWidth: 240,
                                    ),
                                    color:
                                        identical(tab, controller.selectedTab)
                                        ? colors.secondaryContainer
                                        : null,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Tooltip(
                                            message:
                                                tab.metadata.description ??
                                                tab.metadata.title,
                                            child: TextButton(
                                              onPressed: () =>
                                                  controller.select(tab),
                                              child: Semantics(
                                                label:
                                                    '${tab.metadata.title} (${tab.metadata.status.name})',
                                                selected: identical(
                                                  tab,
                                                  controller.selectedTab,
                                                ),
                                                excludeSemantics: true,
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Flexible(
                                                      child: Text(
                                                        tab.metadata.title,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      tab.metadata.status.name,
                                                      style: Theme.of(
                                                        context,
                                                      ).textTheme.labelSmall,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip:
                                              'Close ${tab.metadata.title}',
                                          onPressed: () => unawaited(
                                            controller.closeTab(tab, _confirm),
                                          ),
                                          icon: const Icon(
                                            Icons.close,
                                            size: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                      if (actions.isNotEmpty)
                        PopupMenuButton<ConsoleActionBinding>(
                          tooltip: 'New console',
                          icon: const Icon(Icons.add),
                          onSelected: (action) =>
                              unawaited(controller.invoke(action)),
                          itemBuilder: (context) => [
                            for (final action in actions)
                              PopupMenuItem(
                                value: action,
                                enabled: !action.isPending,
                                child: Text(
                                  action.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      IconButton(
                        tooltip: controller.visible
                            ? 'Hide console'
                            : 'Show console',
                        onPressed: controller.isClosed
                            ? null
                            : controller.toggleVisibility,
                        icon: Icon(
                          controller.visible
                              ? Icons.expand_more
                              : Icons.expand_less,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.visible)
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: SizedBox(
                        height: 320,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (controller.warning case final warning?)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: (constraints.maxHeight - 48)
                                      .clamp(0, 56)
                                      .toDouble(),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    warning,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: colors.error),
                                  ),
                                ),
                              ),
                            Expanded(
                              child: ClipRect(
                                child: residents.isEmpty
                                    ? Center(
                                        child: Text(
                                          tabs.isNotEmpty
                                              ? 'Select a console tab.'
                                              : actions.isEmpty
                                              ? 'No console contributions are available.'
                                              : 'Create a console from the + menu.',
                                        ),
                                      )
                                    : Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          for (final resident in residents)
                                            _ResidentView(
                                              key: ObjectKey(resident),
                                              resident: resident,
                                              selected: identical(
                                                resident.tab,
                                                controller.selectedTab,
                                              ),
                                            ),
                                        ],
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Stable parentage and finite layout even while hidden. Lifetime and interaction
/// are enforced by access grants too, not by these next-frame wrappers alone.
class _ResidentView extends StatefulWidget {
  const _ResidentView({
    super.key,
    required this.resident,
    required this.selected,
  });

  final ConsoleResidentPresentation resident;
  final bool selected;

  @override
  State<_ResidentView> createState() => _ResidentViewState();
}

class _ResidentViewState extends State<_ResidentView> {
  final _focus = FocusScopeNode(debugLabel: 'Console presentation');

  ConsolePresentationAccess get _access => widget.resident.access;

  @override
  void initState() {
    super.initState();
    _access.changes.addListener(_accessChanged);
    _accessChanged();
  }

  void _accessChanged() {
    final interactive = _access.interaction?.isActive == true;
    if (!interactive && _focus.hasFocus) _focus.unfocus();
    _focus.canRequestFocus = interactive;
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !widget.selected,
    child: TickerMode(
      enabled: widget.selected,
      child: ExcludeSemantics(
        excluding: !widget.selected,
        child: IgnorePointer(
          ignoring: !widget.selected,
          child: ExcludeFocus(
            excluding: !widget.selected,
            child: FocusScope(node: _focus, child: widget.resident.widget),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _access.changes.removeListener(_accessChanged);
    _focus.dispose();
    super.dispose();
  }
}
