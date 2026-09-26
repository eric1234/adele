import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';

import '../ui/execution/session_execution_controller.dart';
import '../ui/inspection/activity_inspection_selection.dart';
import '../ui/inspection/activity_output_presentation.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

/// Native per-presentation data/action source. No execution objects cross eval.
abstract interface class SessionExecutionSource implements Listenable {
  String currentSessionId();
  Map<String, Object?> readExecution();
  Future<String> startRun();
  String? openRunActivity(String runId);
  Map<String, Object?> readRunActivity(String handle);
  bool inspectActivity(String handle);
  Widget buildActivity(String handle);
  void invalidate();
}

final class SessionExecutionPresentationSource
    implements SessionExecutionSource, PreparedFrontendRetainable {
  SessionExecutionPresentationSource({
    required this.controller,
    required this.extensions,
    required bool Function() isActive,
    required bool Function(Session, InspectionTarget) inspect,
  }) : _isActive = isActive,
       _inspect = inspect;

  final SessionExecutionController controller;
  final ExtensionRegistry extensions;
  final bool Function() _isActive;
  final bool Function(Session, InspectionTarget) _inspect;
  static int _nextPresentation = 0;
  final int _presentation = _nextPresentation++;
  int _nextHandle = 0;
  bool _active = true;
  final Map<String, RunId> _runs = {};
  final Map<String, InspectionTarget> _emitted = {};
  final Map<(RunId, ModelInvocationId, int?), String> _handles = {};
  Map<RunId, RunActivitySnapshot>? _retainedActivity;

  RunActivitySnapshot? _activityForRun(RunId runId) => _retainedActivity == null
      ? controller.activityForRun(runId)
      : _retainedActivity![runId];

  bool get _available => _active && !controller.isClosed && _isActive();

  void _validate() {
    if (!_available) throw StateError('Session presentation is retired.');
  }

  String _newHandle() => 'p$_presentation-h${_nextHandle++}';

  @override
  String currentSessionId() {
    _validate();
    return controller.session.id.value;
  }

  @override
  Map<String, Object?> readExecution() {
    _validate();
    return {
      'canStart': controller.canStart,
      'running': controller.isRunning,
      'advancing': controller.isAdvancing,
      'failure': controller.failureMessage,
      'unavailableReason': controller.unavailableReason,
      'revision': controller.revision,
    };
  }

  @override
  Future<String> startRun() async {
    _validate();
    final runId = await controller.startRun();
    _validate();
    final handle = _newHandle();
    _runs[handle] = runId;
    return handle;
  }

  @override
  String? openRunActivity(String runId) {
    _validate();
    final RunId id;
    try {
      id = RunId(runId);
    } on FormatException {
      return null;
    }
    if (controller.retainedActivityForRun(id) == null) return null;
    for (final entry in _runs.entries) {
      if (entry.value == id) return entry.key;
    }
    final handle = _newHandle();
    _runs[handle] = id;
    return handle;
  }

  String _emit(RunId runId, ModelInvocationActivity model, [int? sequence]) {
    final key = (runId, model.id, sequence);
    return _handles.putIfAbsent(key, () {
      final handle = _newHandle();
      _emitted[handle] = sequence == null
          ? ActivityGroupInspectionTarget(
              sessionId: controller.session.id,
              runId: runId,
              modelInvocationId: model.id,
            )
          : ModelOutputInspectionTarget(
              sessionId: controller.session.id,
              runId: runId,
              modelInvocationId: model.id,
              outputSequence: sequence,
            );
      return handle;
    });
  }

  @override
  Map<String, Object?> readRunActivity(String handle) {
    _validate();
    final runId = _runs[handle];
    if (runId == null) {
      throw StateError('Run handle was not emitted to this view.');
    }
    final activity = controller.activityForRun(runId);
    final tools = {
      for (final tool in activity?.tools ?? <ToolInvocationActivity>[])
        (tool.modelInvocationId, tool.proposalSequence): tool,
    };
    final rejections = {
      for (final rejection
          in activity?.rejectedProposals ?? <RejectedToolProposalActivity>[])
        (rejection.modelInvocationId, rejection.proposalSequence): rejection,
    };
    return copyStructuredBridgeData({
          'runHandle': handle,
          'state': controller.stateForRun(runId)!.name,
          'models': [
            for (final model in activity?.models ?? <ModelInvocationActivity>[])
              {
                'handle': _emit(runId, model),
                'sequence': model.startSequence,
                'settlement': model.settlement?.name,
                'failure': model.failure?.message,
                'outputs': [
                  for (final output in model.outputs)
                    {
                      'handle': _emit(runId, model, output.sequence),
                      'sequence': output.sequence,
                      ...switch (output.item) {
                        ModelTextOutput(:final content) => {
                          'kind': 'text',
                          'content': content,
                        },
                        ModelToolProposalOutput(:final proposal) => {
                          'kind': 'tool',
                          'alias': proposal.alias,
                          'providerCallId': proposal.providerCallId,
                          'arguments': proposal.arguments,
                          'tool': switch (tools[(model.id, output.sequence)]) {
                            final tool? => {
                              'invocationId': tool.id.value,
                              'toolId': tool.toolId.value,
                              'preparedSequence': tool.preparedSequence,
                              'canonicalArguments': tool.canonicalArguments,
                              'lifecycle':
                                  tool.changes.reversed
                                      .where(
                                        (change) =>
                                            change.kind !=
                                            ToolActivityKind.progress,
                                      )
                                      .firstOrNull
                                      ?.kind
                                      .name ??
                                  ToolActivityKind.prepared.name,
                              'effects': _effectsData(tool.effects),
                              'changes': [
                                for (final change in tool.changes)
                                  {
                                    'sequence': change.sequence,
                                    'kind': change.kind.name,
                                    'policyDecision':
                                        change.policyDecision?.name,
                                    'effects': _effectsData(change.effects),
                                    'interruptionId':
                                        change.interruptionId?.value,
                                    'approved': change.approved,
                                    'progress': switch (change.progress) {
                                      final progress? => {
                                        'kind': progress.kind.name,
                                        'content': progress.content,
                                      },
                                      null => null,
                                    },
                                    'outcome': _outcomeData(change.outcome),
                                  },
                              ],
                              'outcome': _outcomeData(tool.outcome),
                            },
                            null => null,
                          },
                          'rejection': switch (rejections[(
                            model.id,
                            output.sequence,
                          )]) {
                            final rejection? => {
                              'sequence': rejection.sequence,
                              'kind': rejection.kind.name,
                              'message': rejection.message,
                            },
                            null => null,
                          },
                        },
                        ModelNativeOutput(:final presentation) => {
                          'kind': 'native',
                          'compactText': presentation?.compactText,
                          'presentation': presentation == null
                              ? null
                              : {
                                  'kind': presentation.kind,
                                  'compactText': presentation.compactText,
                                  'data': presentation.data,
                                },
                        },
                      },
                    },
                ],
              },
          ],
        })!
        as Map<String, Object?>;
  }

  InspectionTarget? _target(String handle) {
    if (!_available && _retainedActivity == null) return null;
    final target = _emitted[handle];
    if (target == null) return null;
    final model = _activityForRun(target.runId)?.models
        .where((model) => model.id == target.modelInvocationId)
        .firstOrNull;
    if (model == null) return null;
    if (target is ModelOutputInspectionTarget) {
      final output = model.outputs
          .where((output) => output.sequence == target.outputSequence)
          .firstOrNull;
      if (output == null ||
          switch (output.item) {
            ModelToolProposalOutput() ||
            ModelNativeOutput(presentation: ModelNativePresentation()) => false,
            _ => true,
          }) {
        return null;
      }
    }
    return target;
  }

  @override
  bool inspectActivity(String handle) {
    if (!_available) return false;
    final target = _target(handle);
    return target != null && _inspect(controller.session, target);
  }

  @override
  Widget buildActivity(String handle) {
    final target = _target(handle);
    if (target is! ModelOutputInspectionTarget) return const SizedBox.shrink();
    return _SessionActivity(
      key: ValueKey((_presentation, handle)),
      source: this,
      handle: handle,
    );
  }

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  void invalidate() {
    _active = false;
    _runs.clear();
    _emitted.clear();
    _handles.clear();
    _retainedActivity = null;
  }

  @override
  void retainPresentation() {
    if (_retainedActivity != null || !_active) return;
    _retainedActivity = {
      for (final activity in controller.activitySnapshots)
        activity.runId: activity,
    };
    _active = false;
  }
}

Map<String, Object?>? _effectsData(EffectDescription? effects) =>
    effects == null
    ? null
    : {
        'effects': [for (final effect in effects.effects) effect.name],
        'targets': [
          for (final target in effects.targets) target.uri.toString(),
        ],
        'summary': effects.summary,
        'uncertainty': effects.uncertainty.name,
      };

Map<String, Object?>? _outcomeData(ToolOutcomeActivity? outcome) =>
    outcome == null
    ? null
    : {
        'disposition': outcome.disposition.name,
        'failureKind': outcome.failureKind?.name,
        'effectCertainty': outcome.effectCertainty.name,
        'modelContent': outcome.modelContent,
        'hostData': outcome.hostData,
      };

final class _SessionActivity extends StatelessWidget {
  const _SessionActivity({
    super.key,
    required this.source,
    required this.handle,
  });

  final SessionExecutionPresentationSource source;
  final String handle;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: source.controller.activityChanges,
    builder: (context, _) {
      final target = source._target(handle);
      if (target is! ModelOutputInspectionTarget) {
        return const SizedBox.shrink();
      }
      return TextButton(
        onPressed: () {
          if (context.mounted) source.inspectActivity(handle);
        },
        style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        child: IgnorePointer(
          child: ActivityOutputPresentation(
            extensions: source.extensions,
            activity: source._activityForRun(target.runId),
            target: target,
            compact: true,
          ),
        ),
      );
    },
  );
}
