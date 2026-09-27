import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

import '../../frontend/prepared_frontend.dart';

/// Retains one exact browser factory result across unrelated window rebuilds.
class TaskBrowserPresentationHost extends StatefulWidget {
  const TaskBrowserPresentationHost({
    super.key,
    required this.project,
    required this.extensions,
  });

  final Project project;
  final ExtensionRegistry extensions;

  @override
  State<TaskBrowserPresentationHost> createState() =>
      _TaskBrowserPresentationHostState();
}

class _TaskBrowserPresentationHostState
    extends State<TaskBrowserPresentationHost> {
  late StreamSubscription<void> _changes;
  ExtensionBinding<TaskBrowserContribution>? _binding;
  Widget? _presentation;
  String _unavailableReason = 'Task Browser is unavailable.';

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
  void didUpdateWidget(TaskBrowserPresentationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.extensions, widget.extensions)) {
      unawaited(_changes.cancel());
      _listen();
    }
    if (!identical(oldWidget.project, widget.project) ||
        !identical(oldWidget.extensions, widget.extensions)) {
      _binding = null;
      _presentation = null;
    }
  }

  void _resolvePresentation() {
    final ExtensionBinding<TaskBrowserContribution> selected;
    try {
      selected = TaskBrowserResolver(widget.extensions).resolve();
    } on TaskBrowserUnavailable {
      _binding = null;
      _presentation = null;
      _unavailableReason = 'Task Browser is unavailable.';
      return;
    } on AmbiguousTaskBrowser {
      _binding = null;
      _presentation = null;
      _unavailableReason =
          'Task Browser is ambiguous: multiple contributions are available.';
      return;
    }
    if (_binding case final retained?) {
      try {
        retained.validate();
        if (retained.isSameRegistration(selected)) return;
      } on StaleExtensionBinding {
        // A replacement requires a fresh factory, even with the same value/ID.
      }
    }
    _binding = selected;
    _presentation = null;
    try {
      selected.validate();
      final presentation = selected.value.createPresentation(widget.project);
      selected.validate();
      _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    } on Object {
      // Retain the failed binding so unrelated rebuilds do not retry it.
      _unavailableReason =
          'Task Browser is unavailable: the presentation could not be created.';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PreparedFrontendRetention.isRetaining(context)) _resolvePresentation();
    return _presentation ?? Text(_unavailableReason);
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }
}
