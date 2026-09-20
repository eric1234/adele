import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// Presents an existing canonical Session without owning its state or execution.
class SessionPresentationHost extends StatefulWidget {
  const SessionPresentationHost({
    super.key,
    required this.session,
    required this.extensions,
  });

  final Session session;
  final ExtensionRegistry extensions;

  @override
  State<SessionPresentationHost> createState() =>
      _SessionPresentationHostState();
}

class _SessionPresentationHostState extends State<SessionPresentationHost> {
  late StreamSubscription<void> _changes;
  ExtensionBinding<SessionPresentationContribution>? _binding;
  Widget? _presentation;
  String _unavailableReason = 'Session presentation is unavailable.';

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
  void didUpdateWidget(SessionPresentationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.extensions, widget.extensions)) {
      unawaited(_changes.cancel());
      _listen();
    }
    if (!identical(oldWidget.session, widget.session) ||
        !identical(oldWidget.extensions, widget.extensions)) {
      _binding = null;
      _presentation = null;
    }
  }

  void _resolvePresentation() {
    final ExtensionBinding<SessionPresentationContribution> selected;
    try {
      selected = SessionPresentationResolver(
        widget.extensions,
      ).resolve(widget.session.strategyId);
    } on SessionPresentationUnavailable {
      _binding = null;
      _presentation = null;
      _unavailableReason = 'Session presentation is unavailable.';
      return;
    } on AmbiguousSessionPresentation {
      _binding = null;
      _presentation = null;
      _unavailableReason =
          'Session presentation is ambiguous: multiple contributions match '
          'this strategy.';
      return;
    }

    final ExtensionBinding<SessionPresentationContribution>? retained =
        _binding;
    if (retained != null) {
      try {
        // Discovery creates new wrappers. Validate the retained generation before
        // comparing values, even if a replacement reuses the same object and ID.
        retained.validate();
        if (retained.id == selected.id &&
            identical(retained.value, selected.value)) {
          return;
        }
      } on StaleExtensionBinding {
        // Only fresh resolution may select the replacement below.
      }
    }

    _binding = selected;
    _presentation = null;
    try {
      selected.validate();
      final Widget presentation = selected.value.createPresentation(
        widget.session,
      );
      selected.validate();
      _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    } catch (_) {
      // Retain the failed binding too: ordinary rebuilds must not retry a broken
      // factory. A different Session or registration can create a fresh instance.
      _unavailableReason =
          'Session presentation is unavailable: the presentation could not '
          'be created.';
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
