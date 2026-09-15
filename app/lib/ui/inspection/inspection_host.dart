import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/activity_output_presentation.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';

/// Keyed card composition inside the shell's independently scrollable viewport.
final class InspectionStackHost extends StatefulWidget {
  const InspectionStackHost({
    super.key,
    required this.cards,
    required this.cardBuilder,
  });

  final List<InspectionCard> cards;
  final Widget Function(BuildContext, InspectionCard) cardBuilder;

  @override
  State<InspectionStackHost> createState() => _InspectionStackHostState();
}

final class _InspectionStackHostState extends State<InspectionStackHost> {
  @override
  void initState() {
    super.initState();
    _revealNewest();
  }

  @override
  void didUpdateWidget(InspectionStackHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newest = widget.cards.firstOrNull;
    if (newest != null &&
        !oldWidget.cards.any((card) => identical(card.id, newest.id))) {
      _revealNewest();
    }
  }

  void _revealNewest() {
    final id = widget.cards.firstOrNull?.id;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(widget.cards.firstOrNull?.id, id)) return;
      final position = Scrollable.maybeOf(context)?.position;
      position?.jumpTo(position.minScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final card in widget.cards)
        Padding(
          key: ValueKey(card.id),
          padding: const EdgeInsets.only(bottom: 12),
          child: widget.cardBuilder(context, card),
        ),
    ],
  );
}

/// Common card chrome; group rows and individual headers are compact only.
final class InspectionHost extends StatelessWidget {
  const InspectionHost({
    super.key,
    required this.card,
    required this.activity,
    required this.heading,
    required this.extensions,
    required this.onCollapse,
    required this.onExpand,
    required this.onDismiss,
    required this.onInspectOutput,
  });

  final InspectionCard card;
  final RunActivitySnapshot? activity;
  final String heading;
  final ExtensionRegistry extensions;
  final VoidCallback onCollapse;
  final VoidCallback onExpand;
  final VoidCallback onDismiss;
  final ValueChanged<ModelOutputInspectionTarget> onInspectOutput;

  @override
  Widget build(BuildContext context) {
    final target = card.target;
    final snapshot = activity;
    final model =
        snapshot?.runId == target.runId &&
            snapshot?.sessionId == target.sessionId
        ? snapshot!.models
              .where((model) => model.id == target.modelInvocationId)
              .firstOrNull
        : null;
    final outputs = [...?model?.outputs]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: switch (target) {
                      ActivityGroupInspectionTarget() => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ACTIVITY',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Text(
                            model == null
                                ? 'Activity is unavailable.'
                                : heading,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      ModelOutputInspectionTarget() =>
                        ActivityOutputPresentation(
                          extensions: extensions,
                          activity: activity,
                          target: target,
                          compact: true,
                        ),
                    },
                  ),
                ),
                IconButton(
                  tooltip: card.isCollapsed
                      ? 'Expand Inspection'
                      : 'Collapse Inspection',
                  onPressed: card.isCollapsed ? onExpand : onCollapse,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: Icon(
                    card.isCollapsed ? Icons.expand_more : Icons.expand_less,
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss Inspection',
                  onPressed: onDismiss,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          // Collapsing hides the body without replacing its sources or runtimes.
          Visibility(
            visible: !card.isCollapsed,
            maintainState: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: switch (target) {
                    ModelOutputInspectionTarget() => ActivityOutputPresentation(
                      extensions: extensions,
                      activity: activity,
                      target: target,
                      compact: false,
                    ),
                    ActivityGroupInspectionTarget() => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final output in outputs)
                          if (switch (output.item) {
                            ModelToolProposalOutput() => true,
                            ModelNativeOutput(
                              presentation: ModelNativePresentation(),
                            ) =>
                              true,
                            _ => false,
                          })
                            _outputRow(output, target),
                      ],
                    ),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _outputRow(ModelOutputActivity output, InspectionTarget group) {
    final target = ModelOutputInspectionTarget(
      sessionId: group.sessionId,
      runId: group.runId,
      modelInvocationId: group.modelInvocationId,
      outputSequence: output.sequence,
    );
    return TextButton(
      key: ValueKey((
        group.sessionId,
        group.runId,
        group.modelInvocationId,
        output.sequence,
      )),
      onPressed: () => onInspectOutput(target),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        alignment: Alignment.centerLeft,
      ),
      child: Row(
        children: [
          Expanded(
            child: IgnorePointer(
              child: ActivityOutputPresentation(
                extensions: extensions,
                activity: activity,
                target: target,
                compact: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    );
  }
}
