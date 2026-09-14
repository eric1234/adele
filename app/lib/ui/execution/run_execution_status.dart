import 'package:flutter/material.dart';

import 'pending_tool_approval.dart';

/// Common host-owned execution feedback, independent of Session strategy UI.
final class RunExecutionStatus extends StatelessWidget {
  const RunExecutionStatus({
    super.key,
    required this.pendingApproval,
    required this.enabled,
    required this.isAdvancing,
    required this.failureMessage,
    required this.unavailableReason,
    required this.onDecision,
  });

  final PendingToolApproval? pendingApproval;
  final bool enabled;
  final bool isAdvancing;
  final String? failureMessage;
  final String? unavailableReason;
  final void Function(PendingToolApproval, bool) onDecision;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pendingApproval case final PendingToolApproval approval)
          _ToolApprovalCard(
            key: ObjectKey(approval),
            approval: approval,
            enabled: enabled,
            onDecision: (approved) => onDecision(approval, approved),
          ),
        if (isAdvancing)
          Semantics(liveRegion: true, child: const Text('Running...')),
        if (failureMessage case final String failure)
          Semantics(
            liveRegion: true,
            child: Text(failure, style: TextStyle(color: colors.error)),
          ),
        if (unavailableReason case final String unavailable)
          Semantics(liveRegion: true, child: Text(unavailable)),
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
