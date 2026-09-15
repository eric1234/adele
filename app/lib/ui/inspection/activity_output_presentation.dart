import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:flutter/material.dart';

/// Resolves one exact output occurrence without provider or tool interpretation.
final class ActivityOutputPresentation extends StatelessWidget {
  const ActivityOutputPresentation({
    super.key,
    required this.extensions,
    required this.activity,
    required this.target,
    required this.compact,
  });

  final ExtensionRegistry extensions;
  final RunActivitySnapshot? activity;
  final ModelOutputInspectionTarget target;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final snapshot = activity;
    final model =
        snapshot?.runId == target.runId &&
            snapshot?.sessionId == target.sessionId
        ? snapshot!.models
              .where((model) => model.id == target.modelInvocationId)
              .firstOrNull
        : null;
    final output = model?.outputs
        .where((output) => output.sequence == target.outputSequence)
        .firstOrNull;
    final occurrenceKey = ValueKey((
      target.sessionId,
      target.runId,
      target.modelInvocationId,
      target.outputSequence,
    ));
    final bool terminal = switch (snapshot?.state) {
      RunState.completed || RunState.failed || RunState.cancelled => true,
      _ => false,
    };
    if (output?.item case ModelToolProposalOutput(:final proposal)) {
      final tool = snapshot!.tools
          .where(
            (tool) =>
                tool.modelInvocationId == target.modelInvocationId &&
                tool.proposalSequence == target.outputSequence,
          )
          .firstOrNull;
      if (tool != null) {
        return KeyedSubtree(
          key: occurrenceKey,
          child: _ToolOutput(
            key: ValueKey((tool.id, tool.toolId)),
            activity: tool,
            extensions: extensions,
            compact: compact,
            runEndedWithoutOutcome: terminal && tool.outcome == null,
          ),
        );
      }
      final rejection = snapshot.rejectedProposals
          .where(
            (rejection) =>
                rejection.modelInvocationId == target.modelInvocationId &&
                rejection.proposalSequence == target.outputSequence,
          )
          .firstOrNull;
      return Column(
        key: occurrenceKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Proposal: ${compact ? compactDisplayText(proposal.alias) : inspectionDisplayText(proposal.alias)}',
            maxLines: 3,
          ),
          Text(
            rejection != null
                ? 'Proposal rejected: ${rejection.kind.name}.'
                : terminal
                ? 'Not processed before the Run ended.'
                : 'Waiting to be processed.',
          ),
        ],
      );
    }
    if (output?.item case ModelNativeOutput(
      presentation: final ModelNativePresentation presentation,
    )) {
      return compact
          ? ModelNativeActivityCompactHost(
              key: occurrenceKey,
              extensions: extensions,
              presentation: presentation,
              fallback: Text(
                compactDisplayText(presentation.compactText),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            )
          : ModelNativeActivityInspectionHost(
              key: occurrenceKey,
              extensions: extensions,
              presentation: presentation,
            );
    }
    return const Text('Activity output is unavailable.');
  }
}

final class _ToolOutput extends StatefulWidget {
  const _ToolOutput({
    super.key,
    required this.activity,
    required this.extensions,
    required this.compact,
    required this.runEndedWithoutOutcome,
  });

  final ToolInvocationActivity activity;
  final ExtensionRegistry extensions;
  final bool compact;
  final bool runEndedWithoutOutcome;

  @override
  State<_ToolOutput> createState() => _ToolOutputState();
}

final class _ToolOutputState extends State<_ToolOutput> {
  late final _ToolSource _source = _ToolSource(widget.activity);

  @override
  void didUpdateWidget(_ToolOutput oldWidget) {
    super.didUpdateWidget(oldWidget);
    _source.update(widget.activity);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.runEndedWithoutOutcome)
        Padding(
          padding: EdgeInsets.only(bottom: widget.compact ? 4 : 8),
          child: Text(
            widget.compact
                ? 'Run ended; last observed activity.'
                : 'Run ended without a terminal tool result. '
                      'Last observed activity:',
          ),
        ),
      if (widget.compact)
        ToolActivityCompactHost(
          key: ValueKey(_source),
          extensions: widget.extensions,
          source: _source,
          fallback: Text(
            'Tool: ${compactDisplayText(widget.activity.alias)}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        )
      else
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
