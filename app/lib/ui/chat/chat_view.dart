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
        if (controller.pendingApproval case final PendingToolApproval approval)
          _ToolApprovalCard(
            key: ObjectKey(approval),
            approval: approval,
            enabled: !controller.isAdvancing && !controller.isClosed,
            onDecision: (approved) =>
                controller.resolveApproval(approval, approved: approved),
          ),
        if (controller.isAdvancing)
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
          decoration: const InputDecoration(labelText: 'Ask ADELE...'),
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

final class _ToolApprovalCard extends StatelessWidget {
  const _ToolApprovalCard({
    super.key,
    required this.approval,
    required this.enabled,
    required this.onDecision,
  });

  final PendingToolApproval approval;
  final bool enabled;
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text('Approval required', style: textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            Text(approval.effectLabel, style: textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(approval.summary),
            if (approval.hasUnsafeAuthorityText) ...[
              const SizedBox(height: 8),
              const Text(
                'Allow once is unavailable: tool identity, summary, or targets '
                'contain unsafe display controls or cannot be displayed reliably. '
                'Review the escaped details and choose Deny.',
              ),
            ],
            if (approval.isUncertain) ...[
              const SizedBox(height: 8),
              const Text('Effects may extend beyond the listed target.'),
            ],
            const SizedBox(height: 8),
            SelectableText('Tool: ${approval.toolAlias}'),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Details'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    'Tool ID: ${approval.toolId}\n'
                    'Effects: ${approval.effectNames.join(', ')}\n'
                    'Uncertainty: ${approval.uncertainty.name}\n'
                    '${approval.targets.map((uri) => 'Target: $uri').join('\n')}',
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    approval.canonicalArgumentsJson,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: enabled ? () => onDecision(false) : null,
                  child: const Text('Deny'),
                ),
                FilledButton(
                  onPressed: enabled && !approval.hasUnsafeAuthorityText
                      ? () => onDecision(true)
                      : null,
                  child: const Text('Allow once'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
