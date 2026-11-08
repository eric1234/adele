import 'package:agent_kernel/agent_kernel.dart';

/// Explicit policy for deterministic integration fixtures, not application policy.
final class FixedToolPolicy implements ToolPolicy {
  const FixedToolPolicy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}
