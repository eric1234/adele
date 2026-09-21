import 'package:agent_kernel/agent_kernel.dart';

final class DevelopmentToolPolicy implements ToolPolicy {
  const DevelopmentToolPolicy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}
