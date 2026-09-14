import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// Hosts one tool invocation's presentation without execution or approval access.
class ToolActivityInspectionHost extends StatefulWidget {
  const ToolActivityInspectionHost({
    super.key,
    required this.extensions,
    required this.source,
  });

  final ExtensionRegistry extensions;
  final ToolActivityInspectionSource source;

  @override
  State<ToolActivityInspectionHost> createState() =>
      _ToolActivityInspectionHostState();
}

class _ToolActivityInspectionHostState
    extends State<ToolActivityInspectionHost> {
  late StreamSubscription<void> _changes;
  ExtensionBinding<ToolActivityInspectionContribution>? _binding;
  Widget? _presentation;
  String _unavailableReason = 'Tool activity inspection is unavailable.';

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
  void didUpdateWidget(ToolActivityInspectionHost oldWidget) {
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

  void _resolvePresentation() {
    final ExtensionBinding<ToolActivityInspectionContribution> selected;
    try {
      selected = ToolActivityInspectionResolver(
        widget.extensions,
      ).resolve(widget.source.snapshot.toolId);
    } on ToolActivityInspectionUnavailable {
      _binding = null;
      _presentation = null;
      _unavailableReason = 'Tool activity inspection is unavailable.';
      return;
    } on AmbiguousToolActivityInspection {
      _binding = null;
      _presentation = null;
      _unavailableReason =
          'Tool activity inspection is ambiguous: multiple contributions match '
          'this tool.';
      return;
    } on Object {
      _binding = null;
      _presentation = null;
      _unavailableReason =
          'Tool activity inspection is unavailable: the source could not be read.';
      return;
    }

    final ExtensionBinding<ToolActivityInspectionContribution>? retained =
        _binding;
    if (retained != null) {
      try {
        // Validate the generation even when a replacement reuses its ID/value.
        retained.validate();
        if (retained.id == selected.id &&
            identical(retained.value, selected.value)) {
          return;
        }
      } on StaleExtensionBinding {
        // Only fresh resolution may select a replacement below.
      }
    }

    _binding = selected;
    _presentation = null;
    try {
      selected.validate();
      final Widget presentation = selected.value.createPresentation(
        widget.source,
      );
      selected.validate();
      _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    } catch (_) {
      // A failed binding stays retained: rebuilds must not retry its factory.
      _unavailableReason =
          'Tool activity inspection is unavailable: the presentation could not '
          'be created.';
    }
  }

  @override
  Widget build(BuildContext context) {
    _resolvePresentation();
    return _presentation ?? Text(_unavailableReason);
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }
}
