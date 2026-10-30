import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:flutter/material.dart';

/// Hosts only the captured presenter. Failure or retirement never re-resolves it.
final class SessionContentInspectionHost extends StatefulWidget {
  const SessionContentInspectionHost({super.key, required this.selection});

  final SelectedSessionContentInspection selection;

  @override
  State<SessionContentInspectionHost> createState() =>
      _SessionContentInspectionHostState();
}

final class _SessionContentInspectionHostState
    extends State<SessionContentInspectionHost> {
  Widget? _presentation;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_changed);
    _create();
  }

  Future<void> _create() async {
    final selection = widget.selection;
    try {
      if (!selection.isActive) return;
      final presentation = await selection.presentation;
      if (!mounted || !selection.isActive) return;
      selection.presenter.validate();
      setState(() => _presentation = presentation);
    } catch (_) {
      if (mounted && selection.isActive) setState(() => _failed = true);
    }
  }

  void _changed() {
    if (mounted && !widget.selection.isActive) {
      setState(() => _presentation = null);
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.selection.isActive || _failed) {
      return const Text('Content Inspection is unavailable.');
    }
    return _presentation ?? const Text('Loading content Inspection...');
  }
}
