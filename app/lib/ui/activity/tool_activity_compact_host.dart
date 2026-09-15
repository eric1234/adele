import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// Resolves only the compact role and preserves factual content if unavailable.
final class ToolActivityCompactHost extends StatefulWidget {
  const ToolActivityCompactHost({
    super.key,
    required this.extensions,
    required this.source,
    required this.fallback,
  });

  final ExtensionRegistry extensions;
  final ToolActivityInspectionSource source;
  final Widget fallback;

  @override
  State<ToolActivityCompactHost> createState() =>
      _ToolActivityCompactHostState();
}

final class _ToolActivityCompactHostState
    extends State<ToolActivityCompactHost> {
  late StreamSubscription<void> _changes;
  ExtensionBinding<ToolActivityCompactPresentationContribution>? _binding;
  Widget? _presentation;
  bool _ambiguous = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _changes = widget.extensions.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(ToolActivityCompactHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.extensions, widget.extensions)) {
      unawaited(_changes.cancel());
      _listen();
    }
    if (!identical(oldWidget.source, widget.source) ||
        !identical(oldWidget.extensions, widget.extensions)) {
      _binding = null;
      _presentation = null;
    }
  }

  void _resolve() {
    _ambiguous = false;
    final ExtensionBinding<ToolActivityCompactPresentationContribution>
    selected;
    try {
      selected = ToolActivityCompactPresentationResolver(
        widget.extensions,
      ).resolve(widget.source.snapshot.toolId);
    } on AmbiguousToolActivityCompactPresentation {
      _binding = null;
      _presentation = null;
      _ambiguous = true;
      return;
    } on Object {
      _binding = null;
      _presentation = null;
      return;
    }
    final retained = _binding;
    if (retained != null) {
      try {
        retained.validate();
        if (retained.id == selected.id &&
            identical(retained.value, selected.value)) {
          return;
        }
      } on StaleExtensionBinding {
        // A same-ID/value replacement still requires a fresh subtree.
      }
    }
    _binding = selected;
    _presentation = null;
    try {
      selected.validate();
      final presentation = selected.value.createPresentation(widget.source);
      selected.validate();
      _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    } on Object {
      // Retain a failed binding rather than repeatedly invoking its factory.
    }
  }

  @override
  Widget build(BuildContext context) {
    _resolve();
    if (_ambiguous) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widget.fallback,
          const Text('Tool compact presentation is ambiguous.'),
        ],
      );
    }
    return PreparedFrontendFallback(
      fallback: widget.fallback,
      child: _presentation ?? widget.fallback,
    );
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }
}
