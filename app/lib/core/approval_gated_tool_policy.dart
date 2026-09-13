import 'package:agent_kernel/agent_kernel.dart';

/// Allows certain source reads and gates source mutation and process execution.
final class ApprovalGatedToolPolicy implements ToolPolicy {
  const ApprovalGatedToolPolicy();

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) {
    final EffectDescription description = input.effects;
    if (description.effects.length != 1) return ToolPolicyDecision.deny;
    return switch ((description.effects.single, description.uncertainty)) {
      (ToolEffect.sourceRead, EffectUncertainty.none) =>
        ToolPolicyDecision.allow,
      (ToolEffect.sourceMutation, EffectUncertainty.none) =>
        ToolPolicyDecision.ask,
      (ToolEffect.processExecution, _) => ToolPolicyDecision.ask,
      _ => ToolPolicyDecision.deny,
    };
  }
}
