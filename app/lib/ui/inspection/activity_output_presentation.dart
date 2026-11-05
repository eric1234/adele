import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
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
    this.status = SessionRunActivityStatus.live,
  });

  final ExtensionRegistry extensions;
  final RunActivitySnapshot? activity;
  final ModelOutputInspectionTarget target;
  final bool compact;
  final SessionRunActivityStatus status;

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
            sessionId: snapshot.sessionId,
            runId: snapshot.runId,
            activity: tool,
            extensions: extensions,
            compact: compact,
            status: status,
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
          if (status == SessionRunActivityStatus.interrupted &&
              rejection != null)
            const Text('Interrupted Run; historical proposal.'),
          Text(
            'Proposal: ${compact ? compactDisplayText(proposal.alias) : inspectionDisplayText(proposal.alias)}',
            maxLines: 3,
          ),
          Text(
            rejection != null
                ? 'Proposal rejected: ${rejection.kind.name}.'
                : status == SessionRunActivityStatus.interrupted
                ? 'Interrupted Run. No proposal decision recorded.'
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
      return Column(
        key: occurrenceKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status == SessionRunActivityStatus.interrupted)
            const Text('Interrupted Run; historical model activity.'),
          if (compact)
            ModelNativeActivityCompactHost(
              key: occurrenceKey,
              extensions: extensions,
              presentation: presentation,
              fallback: Text(
                compactDisplayText(presentation.compactText),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            ModelNativeActivityInspectionHost(
              key: occurrenceKey,
              extensions: extensions,
              presentation: presentation,
            ),
        ],
      );
    }
    return const Text('Activity output is unavailable.');
  }
}

final class _ToolOutput extends StatefulWidget {
  const _ToolOutput({
    super.key,
    required this.sessionId,
    required this.runId,
    required this.activity,
    required this.extensions,
    required this.compact,
    required this.status,
    required this.runEndedWithoutOutcome,
  });

  final SessionId sessionId;
  final RunId runId;
  final ToolInvocationActivity activity;
  final ExtensionRegistry extensions;
  final bool compact;
  final SessionRunActivityStatus status;
  final bool runEndedWithoutOutcome;

  @override
  State<_ToolOutput> createState() => _ToolOutputState();
}

final class _ToolOutputState extends State<_ToolOutput> {
  late final _ToolSource _source = _ToolSource(
    widget.sessionId,
    widget.runId,
    widget.activity,
  );

  @override
  void didUpdateWidget(_ToolOutput oldWidget) {
    super.didUpdateWidget(oldWidget);
    _source.update(widget.activity);
  }

  @override
  Widget build(BuildContext context) {
    final interrupted = widget.status == SessionRunActivityStatus.interrupted;
    final String? notice;
    if (interrupted) {
      notice = widget.activity.outcome != null
          ? 'Interrupted Run; recorded tool outcome.'
          : widget.activity.changes.any(
              (change) => change.kind == ToolActivityKind.executionStarted,
            )
          ? 'Interrupted Run; execution started, no outcome recorded. '
                'Effects may have occurred.'
          : 'Interrupted Run; tool prepared, no execution start recorded.';
    } else {
      notice = widget.runEndedWithoutOutcome
          ? widget.compact
                ? 'Run ended; last observed activity.'
                : 'Run ended without a terminal tool result. '
                      'Last observed activity:'
          : null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notice != null)
          Padding(
            padding: EdgeInsets.only(bottom: widget.compact ? 4 : 8),
            child: Text(notice),
          ),
        if (interrupted && widget.activity.outcome == null)
          const Text(
            'Recorded approvals are historical, not actionable. '
            'Last observed activity:',
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
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }
}

final class _ToolSource extends ChangeNotifier
    implements ToolActivityInspectionSource {
  _ToolSource(this.sessionId, this.runId, this._snapshot);

  @override
  final SessionId sessionId;
  @override
  final RunId runId;

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
