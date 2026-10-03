import 'dart:async';
import 'dart:math' as math;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../frontend/prepared_frontend.dart';
import 'main_content_controller.dart';

/// One bounded row of equally sized panes from registered contributions.
/// All panes remain mounted, even outside the horizontal viewport.
class MainContentHost extends StatefulWidget {
  const MainContentHost({
    super.key,
    required this.session,
    required this.extensions,
    this.isCurrent,
  });

  final Session session;
  final ExtensionRegistry extensions;

  /// Optional composition-root guard for departure before the next widget frame.
  /// Once observed false, that attachment cannot become active again.
  final bool Function()? isCurrent;

  @override
  State<MainContentHost> createState() => _MainContentHostState();
}

class _MainContentHostState extends State<MainContentHost> {
  late MainContentController _controller;
  final _scroll = ScrollController();
  final Map<MainContentEntry, _PaneViewState> _views = {};
  DialogRoute<void>? _inputRoute;
  MainContentActionEntry? _inputAction;
  bool _building = false;
  bool _rebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    _controller =
        MainContentController(
            session: widget.session,
            extensions: widget.extensions,
            isCurrent: () => widget.isCurrent?.call() ?? true,
          )
          ..onFocus = _focus
          ..addListener(_changed);
  }

  @override
  void didUpdateWidget(MainContentHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        !identical(oldWidget.extensions, widget.extensions)) {
      _controller.dispose();
      _dismissInput();
      _createController();
    }
  }

  void _changed() {
    if (_inputAction?.isActive == false) _dismissInput();
    if (!mounted || _building) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _openInput(MainContentActionEntry action) {
    if (!action.isActive || _inputRoute != null) return;
    Widget presentation;
    try {
      presentation = action.createPresentation();
    } on Object {
      // A failed input factory must not disturb existing pane presentations.
      presentation = const Center(
        child: Text('Main Content input is unavailable.'),
      );
    }
    if (!mounted || !action.isActive) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 260),
        child: SizedBox(
          width: 480,
          height: 260,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close input',
                    onPressed: _dismissInput,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(child: presentation),
            ],
          ),
        ),
      ),
    );
    _inputAction = action;
    _inputRoute = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_inputRoute, route)) {
          _inputRoute = null;
          _inputAction = null;
        }
      }),
    );
  }

  void _dismissInput() {
    final route = _inputRoute;
    if (route == null) return;
    _inputRoute = null;
    _inputAction = null;
    // Departure may happen during build or teardown. Remove only the captured
    // route after that frame, never whichever route happens to be current later.
    void remove() {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      remove();
    }
  }

  void _focus(MainContentEntry entry, bool keyboardFocus) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final view = _views[entry];
      if (!mounted || !entry.isActive || view == null || !view.mounted) return;
      final target = view.context.findRenderObject();
      if (target != null && _scroll.hasClients) {
        // Deliberately target this position, not Scrollable.ensureVisible, which
        // would also scroll enclosing Inspection/console/workbench viewports.
        final position = _scroll.position;
        final leading = RenderAbstractViewport.of(
          target,
        ).getOffsetToReveal(target, 0).offset;
        position.ensureVisible(
          target,
          alignmentPolicy: leading < position.pixels
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
      if (keyboardFocus) entry.requestKeyboardFocus(view.focusContent);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    _building = true;
    try {
      if (PreparedFrontendRetention.isRetaining(context)) {
        _controller.retainForShutdown();
      } else {
        _controller.reconcile();
      }
      final entries = _controller.entries;
      final actions = _controller.actions;
      if (_inputAction?.isActive == false) _dismissInput();
      return Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedHeight || !constraints.hasBoundedWidth) {
              throw FlutterError(
                'MainContentHost requires bounded constraints.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (actions.isNotEmpty)
                  SizedBox(
                    height: math.min(40, constraints.maxHeight),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final action in actions)
                            TextButton(
                              key: ObjectKey(action),
                              onPressed: () => _openInput(action),
                              child: Text(action.label),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  key: const ValueKey('main-content-panes'),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (entries.isEmpty) {
                        return const Center(
                          child: Text(
                            'No Main Content is available for this Session.',
                          ),
                        );
                      }
                      final width = math.max(
                        320.0,
                        (constraints.maxWidth - (entries.length - 1)) /
                            entries.length,
                      );
                      return SingleChildScrollView(
                        controller: _scroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          height: constraints.maxHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < entries.length; i++) ...[
                                if (i != 0)
                                  SizedBox(
                                    key: ValueKey<MainContentEntry>(entries[i]),
                                    width: 1,
                                    child: ColoredBox(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                                    ),
                                  ),
                                _PaneView(
                                  key: ObjectKey(entries[i]),
                                  entry: entries[i],
                                  width: width,
                                  views: _views,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      _building = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _dismissInput();
    _scroll.dispose();
    super.dispose();
  }
}

class _PaneView extends StatefulWidget {
  const _PaneView({
    super.key,
    required this.entry,
    required this.width,
    required this.views,
  });

  final MainContentEntry entry;
  final double width;
  final Map<MainContentEntry, _PaneViewState> views;

  @override
  State<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<_PaneView> {
  final _focusScope = FocusScopeNode();

  @override
  void initState() {
    super.initState();
    widget.views[widget.entry] = this;
  }

  void focusContent() {
    if (_focusScope.focusedChild != null) {
      _focusScope.requestFocus();
    } else {
      _focusScope.nextFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.info.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                if (entry.info.canClose)
                  IconButton(
                    tooltip: 'Close ${entry.info.title}',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    onPressed: entry.requestClose,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FocusScope(node: _focusScope, child: entry.presentation),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.views.remove(widget.entry);
    _focusScope.dispose();
    super.dispose();
  }
}
