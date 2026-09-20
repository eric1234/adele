import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// One immutable Run/model/output occurrence, keyed by the common group host.
/// The host and widget factories receive only safe presentation evidence.
final class ModelNativeActivityInspectionHost extends StatefulWidget {
  const ModelNativeActivityInspectionHost({
    super.key,
    required this.extensions,
    required this.presentation,
  });

  final ExtensionRegistry extensions;
  final ModelNativePresentation presentation;

  @override
  State<ModelNativeActivityInspectionHost> createState() =>
      _ModelNativeActivityInspectionHostState();
}

final class _ModelNativeActivityInspectionHostState
    extends State<ModelNativeActivityInspectionHost> {
  late StreamSubscription<void> _changes;
  ExtensionBinding<ModelNativeActivityPresentationContribution>? _binding;
  Widget? _presentation;

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
  void didUpdateWidget(ModelNativeActivityInspectionHost oldWidget) {
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

  void _resolvePresentation() {
    final resolver = ModelNativeActivityPresentationResolver(widget.extensions);
    final ExtensionBinding<ModelNativeActivityPresentationContribution>
    selected;
    try {
      selected = resolver.resolve(widget.presentation.kind);
    } on ModelNativeActivityPresentationUnavailable {
      _binding = null;
      _presentation = const Text(
        'Model native activity rich inspection is unavailable.',
      );
      return;
    } on AmbiguousModelNativeActivityPresentation {
      _binding = null;
      _presentation = const Text(
        'Model native activity inspection is ambiguous: multiple contributions '
        'match this presentation kind.',
      );
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
        // A replacement must freshly mount even with the same value.
      }
    }
    _binding = selected;
    _presentation = null;
    try {
      selected.validate();
      final presentation = selected.value.createInspection(widget.presentation);
      selected.validate();
      _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    } on Object {
      // Retain failed bindings so ordinary rebuilds do not retry plugin code.
      _presentation = const Text(
        'Model native activity inspection could not be created.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PreparedFrontendRetention.isRetaining(context)) _resolvePresentation();
    return _presentation == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _presentation,
          );
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }
}
