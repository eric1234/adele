import 'package:agent_kernel/agent_kernel.dart';

/// Allows only explicitly described, certain source reads, never approval.
final class ReadOnlyToolPolicy implements ToolPolicy {
  const ReadOnlyToolPolicy();

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) {
    final EffectDescription description = input.effects;
    return description.uncertainty == EffectUncertainty.none &&
            description.effects.isNotEmpty &&
            description.effects.every(
              (effect) => effect == ToolEffect.sourceRead,
            )
        ? ToolPolicyDecision.allow
        : ToolPolicyDecision.deny;
  }
}
