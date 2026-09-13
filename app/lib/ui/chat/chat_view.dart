import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/material.dart';

import 'chat_controller.dart';

/// Temporary stock Chat surface; history remains owned by the Chat plugin.
final class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatView> createState() => _ChatViewState();
}

final class _ChatViewState extends State<ChatView> {
  final TextEditingController _prompt = TextEditingController();

  void _submit() {
    if (widget.controller.submit(_prompt.text)) _prompt.clear();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChatController controller = widget.controller;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? unavailable = controller.unavailableReason;
    final bool enabled = !controller.isRunning && unavailable == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Session', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        for (final ChatEntry entry in controller.snapshot.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Align(
              alignment: entry is ChatUserMessage
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: entry is ChatUserMessage
                      ? colors.surfaceContainerHighest
                      : colors.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(entry.content),
                ),
              ),
            ),
          ),
        if (controller.isRunning)
          Semantics(liveRegion: true, child: const Text('Running...')),
        if (controller.failureMessage case final String failure)
          Semantics(
            liveRegion: true,
            child: Text(failure, style: TextStyle(color: colors.error)),
          ),
        if (unavailable != null)
          Semantics(liveRegion: true, child: Text(unavailable)),
        const SizedBox(height: 12),
        TextField(
          controller: _prompt,
          enabled: enabled,
          minLines: 1,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'Ask about the code...'),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: enabled ? _submit : null,
            child: const Text('Send'),
          ),
        ),
      ],
    );
  }
}
