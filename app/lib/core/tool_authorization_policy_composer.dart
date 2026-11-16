import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';

import 'product_lifecycle.dart';

/// Host-owned authorization composition for one canonical Run and Session.
final class ToolAuthorizationPolicyComposer implements ToolPolicy {
  const ToolAuthorizationPolicyComposer({
    required this.extensions,
    required this.lifecycle,
    required this.session,
    required this.runId,
    this.legacyPolicy,
  });

  final ExtensionRegistry extensions;
  final ProductLifecycleCoordinator lifecycle;
  final Session session;
  final RunId runId;

  /// Explicit transitional participant, not a discovery/failure fallback.
  /// Normal Session execution supplies ApprovalGatedToolPolicy until migration.
  final ToolPolicy? legacyPolicy;

  @override
  Future<ToolPolicyDecision> evaluate(ToolPolicyInput input) async {
    lifecycle.validateSessionInput(session);
    final invocation = input.invocation;
    if (invocation.context.runId != runId ||
        invocation.context.sessionId != session.id) {
      throw ArgumentError('Authorization requires this canonical Run/Session.');
    }
    final request = ToolAuthorizationRequest(
      toolId: invocation.toolId,
      canonicalArguments: invocation.canonicalArguments,
      effects: input.effects,
      runId: runId,
      sessionId: session.id,
      projectId: lifecycle.store.task(session.taskId)!.projectId,
      toolInvocationId: invocation.id,
    );
    final bindings = extensions.discover(toolAuthorizationPolicies).toList()
      ..sort((a, b) => a.id.value.compareTo(b.id.value));
    var effective = legacyPolicy == null
        ? ToolPolicyDecision.allow
        : await legacyPolicy!.evaluate(input);
    for (final binding in bindings) {
      binding.validate();
      final decision = await binding.value.evaluate(request);
      binding.validate();
      switch (decision) {
        case ToolAuthorizationDecision.deny:
          effective = ToolPolicyDecision.deny;
        case ToolAuthorizationDecision.ask:
          if (effective != ToolPolicyDecision.deny) {
            effective = ToolPolicyDecision.ask;
          }
        case ToolAuthorizationDecision.allow ||
            ToolAuthorizationDecision.abstain:
          break;
      }
    }
    // Earlier participants may retire while a later evaluator is awaiting.
    // Do not short-circuit Deny: an evaluation failure is not an ordinary denial.
    for (final binding in bindings) {
      binding.validate();
    }
    lifecycle.validateSessionInput(session);
    return effective;
  }
}
