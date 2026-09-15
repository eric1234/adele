import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// One exact safe output occurrence, with independent compact-role liveness.
final class ModelNativeActivityCompactHost extends StatefulWidget {
  const ModelNativeActivityCompactHost({
    super.key,
    required this.extensions,
    required this.presentation,
    required this.fallback,
  });

  final ExtensionRegistry extensions;
  final ModelNativePresentation presentation;
  final Widget fallback;

  @override
  State<ModelNativeActivityCompactHost> createState() =>
      _ModelNativeActivityCompactHostState();
}

final class _ModelNativeActivityCompactHostState
    extends State<ModelNativeActivityCompactHost> {
  late StreamSubscription<void> _changes;
  ExtensionBinding<ModelNativeActivityCompactPresentationContribution>?
  _binding;
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
  void didUpdateWidget(ModelNativeActivityCompactHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.extensions, widget.extensions)) {
      unawaited(_changes.cancel());
      _listen();
    }
    if (!identical(oldWidget.presentation, widget.presentation) ||
        !identical(oldWidget.extensions, widget.extensions)) {
      _binding = null;
      _presentation = null;
    }
  }

  void _resolve() {
    _ambiguous = false;
    final ExtensionBinding<ModelNativeActivityCompactPresentationContribution>
    selected;
    try {
      selected = ModelNativeActivityCompactPresentationResolver(
        widget.extensions,
      ).resolve(widget.presentation.kind);
    } on AmbiguousModelNativeActivityCompactPresentation {
      _binding = null;
      _presentation = null;
      _ambiguous = true;
      return;
    } on ModelNativeActivityCompactPresentationUnavailable {
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
        // Fresh resolution cannot reuse a retired view, even with the same value.
      }
    }
    _binding = selected;
    _presentation = null;
    try {
      selected.validate();
      final presentation = selected.value.createPresentation(
        widget.presentation,
      );
      selected.validate();
      _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    } on Object {
      // A failed factory remains selected until fresh resolution is necessary.
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
          const Text(
            'Model native activity compact presentation is ambiguous.',
          ),
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
