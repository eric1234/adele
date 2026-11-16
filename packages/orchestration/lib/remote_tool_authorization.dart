/// Data-only transport for independent tool authorization policies.
library;

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/remote_model_tool.dart' as tool;

import 'adele_orchestration.dart' as local;

part 'remote_tool_authorization.g.dart';

enum RemoteToolAuthorizationDecision { allow, deny, ask, abstain }

RemoteToolAuthorizationDecision remoteToolAuthorizationDecision(
  local.ToolAuthorizationDecision decision,
) => switch (decision) {
  local.ToolAuthorizationDecision.allow =>
    RemoteToolAuthorizationDecision.allow,
  local.ToolAuthorizationDecision.deny => RemoteToolAuthorizationDecision.deny,
  local.ToolAuthorizationDecision.ask => RemoteToolAuthorizationDecision.ask,
  local.ToolAuthorizationDecision.abstain =>
    RemoteToolAuthorizationDecision.abstain,
};

local.ToolAuthorizationDecision localToolAuthorizationDecision(
  RemoteToolAuthorizationDecision decision,
) => switch (decision) {
  RemoteToolAuthorizationDecision.allow =>
    local.ToolAuthorizationDecision.allow,
  RemoteToolAuthorizationDecision.deny => local.ToolAuthorizationDecision.deny,
  RemoteToolAuthorizationDecision.ask => local.ToolAuthorizationDecision.ask,
  RemoteToolAuthorizationDecision.abstain =>
    local.ToolAuthorizationDecision.abstain,
};

/// An immutable normalized invocation snapshot, without host-service authority.
@AdeleValue('toolAuthorization.request')
final class RemoteToolAuthorizationRequest {
  RemoteToolAuthorizationRequest({
    required this.toolId,
    required Map<String, Object?> canonicalArguments,
    required Map<String, Object?> effects,
    required this.runId,
    required this.sessionId,
    required this.projectId,
    required this.toolInvocationId,
  }) : canonicalArguments = adeleSnapshotJsonMap(canonicalArguments),
       effects = adeleSnapshotJsonMap(effects) {
    toLocal();
  }

  final String toolId;
  final Map<String, Object?> canonicalArguments;
  final Map<String, Object?> effects;
  final String runId;
  final String sessionId;
  final String projectId;
  final String toolInvocationId;

  static RemoteToolAuthorizationRequest fromLocal(
    local.ToolAuthorizationRequest value,
  ) => RemoteToolAuthorizationRequest(
    toolId: value.toolId.value,
    canonicalArguments: value.canonicalArguments,
    effects: tool.RemoteEffectDescription.fromLocal(value.effects).toJson(),
    runId: value.runId.value,
    sessionId: value.sessionId.value,
    projectId: value.projectId.value,
    toolInvocationId: value.toolInvocationId.value,
  );

  local.ToolAuthorizationRequest toLocal() => local.ToolAuthorizationRequest(
    toolId: local.ToolId(toolId),
    canonicalArguments: canonicalArguments,
    effects: tool.RemoteEffectDescription.fromJson(effects).toLocal(),
    runId: local.RunId(runId),
    sessionId: local.SessionId(sessionId),
    projectId: local.ProjectId(projectId),
    toolInvocationId: local.ToolInvocationId(toolInvocationId),
  );
}

/// Evaluates data only. Exceptions remain failures, never authorization decisions.
@AdeleService('toolAuthorizationPolicy')
abstract interface class RemoteToolAuthorizationPolicyService {
  @AdeleMethod('evaluate')
  Future<RemoteToolAuthorizationDecision> evaluate(
    String routeId,
    RemoteToolAuthorizationRequest request,
  );
}
