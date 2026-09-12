import 'package:flutter/material.dart';

/// Transitional title-only presentation, not a Task Browser extension API.
final class TaskTitleForm extends StatefulWidget {
  const TaskTitleForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    required this.creating,
    required this.enabled,
    this.error,
  });

  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final bool creating;
  final bool enabled;
  final String? error;

  @override
  State<TaskTitleForm> createState() => _TaskTitleFormState();
}

final class _TaskTitleFormState extends State<TaskTitleForm> {
  final TextEditingController _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool canSubmit = widget.enabled && !widget.creating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _title,
          autofocus: true,
          enabled: canSubmit,
          decoration: const InputDecoration(labelText: 'Task title'),
          onSubmitted: canSubmit ? widget.onSubmit : null,
        ),
        if (widget.error case final String error)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        if (widget.creating)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: const Text('Creating Task...'),
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: widget.creating ? null : widget.onCancel,
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: canSubmit ? () => widget.onSubmit(_title.text) : null,
              child: const Text('Create Task'),
            ),
          ],
        ),
      ],
    );
  }
}
