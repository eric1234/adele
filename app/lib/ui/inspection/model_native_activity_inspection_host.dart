import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// One immutable Run/model/output occurrence, keyed by the common group host.
/// Only the projector sees native data; widget factories receive safe snapshots.
final class ModelNativeActivityInspectionHost extends StatefulWidget {
  const ModelNativeActivityInspectionHost({
    super.key,
    required this.extensions,
    required this.output,
  });

  final ExtensionRegistry extensions;
  final ModelNativeOutput output;

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
    if (!identical(oldWidget.output, widget.output) ||
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
      selected = resolver.resolve(widget.output.providerNativeMetadata.kind);
    } on ModelNativeActivityPresentationUnavailable {
      _binding = null;
      _presentation = null;
      return;
    } on AmbiguousModelNativeActivityPresentation {
      _binding = null;
      _presentation = const Text(
        'Model native activity inspection is ambiguous: multiple contributions '
        'match this native kind.',
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
        // A replacement must freshly project and mount even with the same value.
      }
    }
    _binding = selected;
    _presentation = null;
    final ResolvedModelNativeActivityPresentation? projected;
    try {
      projected = resolver.project(widget.output);
    } on Object {
      _presentation = const Text(
        'Model native activity could not be projected.',
      );
      return;
    }
    if (projected == null) return;
    _binding = projected.binding;
    try {
      projected.binding.validate();
      final presentation = projected.binding.value.createInspection(
        projected.projection,
      );
      projected.binding.validate();
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
    _resolvePresentation();
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
