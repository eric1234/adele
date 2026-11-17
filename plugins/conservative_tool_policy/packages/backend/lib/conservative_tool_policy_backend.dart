/// Stock Conservative tool authorization over the public data-only request.
library;

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';

const conservativeToolPolicyRouteId = 'conservative';

final class ConservativeToolPolicyBackend
    implements RemoteToolAuthorizationPolicyService {
  const ConservativeToolPolicyBackend();

  @override
  Future<RemoteToolAuthorizationDecision> evaluate(
    String routeId,
    RemoteToolAuthorizationRequest request,
  ) async {
    if (routeId != conservativeToolPolicyRouteId) {
      throw ArgumentError.value(routeId, 'routeId', 'Unknown policy route.');
    }
    final description = request.toLocal().effects;
    if (description.effects.length != 1) {
      return RemoteToolAuthorizationDecision.deny;
    }
    final effect = description.effects.single;
    if (effect == ToolEffect.processExecution) {
      return RemoteToolAuthorizationDecision.ask;
    }
    if (description.uncertainty != EffectUncertainty.none) {
      return RemoteToolAuthorizationDecision.deny;
    }
    return switch (effect) {
      ToolEffect.sourceRead ||
      ToolEffect.resourceInspection => RemoteToolAuthorizationDecision.allow,
      ToolEffect.sourceMutation => RemoteToolAuthorizationDecision.ask,
      _ => RemoteToolAuthorizationDecision.deny,
    };
  }
}
