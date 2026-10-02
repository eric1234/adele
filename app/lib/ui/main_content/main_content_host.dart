import 'dart:math' as math;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../frontend/prepared_frontend.dart';
import 'main_content_controller.dart';

/// One bounded row of equally sized panes, including the existing strategy view.
/// All panes remain mounted, even outside the horizontal viewport.
class MainContentHost extends StatefulWidget {
  const MainContentHost({
    super.key,
    required this.session,
    required this.extensions,
    required this.strategyContent,
    required this.strategyTitle,
    this.isCurrent,
  });

  final Session session;
  final ExtensionRegistry extensions;
  final Widget strategyContent;
  final String strategyTitle;

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
            strategyContent: widget.strategyContent,
            strategyTitle: widget.strategyTitle,
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
      _createController();
    } else {
      _controller.updateStrategy(
        content: widget.strategyContent,
        title: widget.strategyTitle,
      );
    }
  }

  void _changed() {
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
      return Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedHeight || !constraints.hasBoundedWidth) {
              throw FlutterError(
                'MainContentHost requires bounded constraints.',
              );
            }
            final width = math.max(
              320.0,
              (constraints.maxWidth - (entries.length - 1)) / entries.length,
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
                            color: Theme.of(context).colorScheme.outlineVariant,
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
      );
    } finally {
      _building = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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
