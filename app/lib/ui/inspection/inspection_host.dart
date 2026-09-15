import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:flutter/material.dart';

/// Common group composition. Native/tool interpretation belongs to contributions.
final class InspectionHost extends StatelessWidget {
  const InspectionHost({
    super.key,
    required this.selection,
    required this.activity,
    required this.heading,
    required this.extensions,
    required this.onClose,
  });

  final ActivityInspectionSelection selection;
  final RunActivitySnapshot? activity;
  final String heading;
  final ExtensionRegistry extensions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final RunActivitySnapshot? snapshot = activity;
    final ModelInvocationActivity? model =
        snapshot?.runId == selection.runId &&
            snapshot?.sessionId == selection.sessionId
        ? snapshot!.models
              .where((model) => model.id == selection.modelInvocationId)
              .firstOrNull
        : null;
    final tools = <int, ToolInvocationActivity>{
      if (model != null)
        for (final tool in snapshot!.tools)
          if (tool.modelInvocationId == model.id) tool.proposalSequence: tool,
    };
    final rejected = <int, RejectedToolProposalActivity>{
      if (model != null)
        for (final proposal in snapshot!.rejectedProposals)
          if (proposal.modelInvocationId == model.id)
            proposal.proposalSequence: proposal,
    };
    final bool terminal = switch (snapshot?.state) {
      RunState.completed || RunState.failed || RunState.cancelled => true,
      _ => false,
    };
    final outputs = [...?model?.outputs]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Inspection',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close Inspection',
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (model == null)
              const Text('Activity is unavailable.')
            else ...[
              const Text('ACTIVITY'),
              const SizedBox(height: 4),
              Text(heading, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              // Outputs, not preparation/completion order, own these positions.
              for (final output in outputs)
                if (output.item case ModelToolProposalOutput(:final proposal))
                  Padding(
                    key: ValueKey((selection.runId, model.id, output.sequence)),
                    padding: const EdgeInsets.only(bottom: 16),
                    child: switch (tools[output.sequence]) {
                      final ToolInvocationActivity tool => _ToolInspectionItem(
                        key: ValueKey(tool.id),
                        activity: tool,
                        extensions: extensions,
                        runEndedWithoutOutcome:
                            terminal && tool.outcome == null,
                      ),
                      null => _UnresolvedProposal(
                        alias: proposal.alias,
                        rejection: rejected[output.sequence],
                        terminal: terminal,
                      ),
                    },
                  )
                else if (output.item case final ModelNativeOutput native)
                  ModelNativeActivityInspectionHost(
                    key: ValueKey((selection.runId, model.id, output.sequence)),
                    extensions: extensions,
                    output: native,
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _UnresolvedProposal extends StatelessWidget {
  const _UnresolvedProposal({
    required this.alias,
    required this.rejection,
    required this.terminal,
  });

  final String alias;
  final RejectedToolProposalActivity? rejection;
  final bool terminal;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Proposal: ${inspectionDisplayText(alias)}', maxLines: 3),
      Text(
        rejection != null
            ? 'Proposal rejected: ${rejection!.kind.name}.'
            : terminal
            ? 'Not processed before the Run ended.'
            : 'Waiting to be processed.',
      ),
    ],
  );
}

final class _ToolInspectionItem extends StatefulWidget {
  const _ToolInspectionItem({
    super.key,
    required this.activity,
    required this.extensions,
    required this.runEndedWithoutOutcome,
  });

  final ToolInvocationActivity activity;
  final ExtensionRegistry extensions;
  final bool runEndedWithoutOutcome;

  @override
  State<_ToolInspectionItem> createState() => _ToolInspectionItemState();
}

final class _ToolInspectionItemState extends State<_ToolInspectionItem> {
  late final _ToolSource _source = _ToolSource(widget.activity);

  @override
  void didUpdateWidget(_ToolInspectionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    _source.update(widget.activity);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.runEndedWithoutOutcome)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Run ended without a terminal tool result. '
            'Last observed activity:',
          ),
        ),
      ToolActivityInspectionHost(
        key: ValueKey(_source),
        extensions: widget.extensions,
        source: _source,
      ),
    ],
  );

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }
}

final class _ToolSource extends ChangeNotifier
    implements ToolActivityInspectionSource {
  _ToolSource(this._snapshot);

  ToolInvocationActivity _snapshot;

  @override
  ToolInvocationActivity get snapshot => _snapshot;

  void update(ToolInvocationActivity value) {
    assert(value.id == _snapshot.id && value.toolId == _snapshot.toolId);
    if (identical(value, _snapshot)) return;
    _snapshot = value;
    notifyListeners();
  }
}
