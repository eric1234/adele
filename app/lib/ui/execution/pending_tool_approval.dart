import 'package:agent_kernel/agent_kernel.dart';

import 'approval_display.dart';

/// Immutable host presentation and identity token, not execution authority.
final class PendingToolApproval {
  PendingToolApproval(ToolApprovalInterruption interruption)
    : toolAlias = approvalDisplayText(
        interruption.invocation.tool.modelDefinition.alias,
      ),
      toolId = approvalDisplayText(interruption.toolId.value),
      effects = interruption.effects.effects,
      summary = approvalDisplayText(interruption.effects.summary),
      uncertainty = interruption.effects.uncertainty,
      targets = List<String>.unmodifiable(
        interruption.effects.targets.map(
          (target) => approvalDisplayText(target.uri.toString()),
        ),
      ),
      canonicalArgumentsJson = approvalDisplayJson(
        interruption.canonicalArguments,
      ),
      hasUnsafeAuthorityText =
          <String>[
            interruption.invocation.tool.modelDefinition.alias,
            interruption.toolId.value,
            interruption.effects.summary,
          ].any(hasUnsafeApprovalControls) ||
          interruption.effects.targets.any(
            (target) => hasUnsafeApprovalTarget(target.uri),
          );

  final String toolAlias;
  final String toolId;
  final Set<ToolEffect> effects;
  final String summary;
  final EffectUncertainty uncertainty;
  final List<String> targets;
  final String canonicalArgumentsJson;

  /// Only raw identity/summary and decoded URI targets block approval. Canonical
  /// payloads may contain arbitrary source text: escape them, do not reject them.
  final bool hasUnsafeAuthorityText;

  bool get isUncertain => uncertainty != EffectUncertainty.none;
  Iterable<String> get effectNames => effects.map((effect) => effect.name);
  String get effectLabel => switch (effects.toList()) {
    [ToolEffect.sourceMutation] => 'Modify source',
    [ToolEffect.processExecution] => 'Run command',
    _ => 'Tool effects',
  };
}
