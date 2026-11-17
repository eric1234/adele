import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Transport adaptation only; the host composer owns authorization semantics.
final class RemoteToolAuthorizationPolicyAdapter
    implements RemoteExtensionAdapter<ToolAuthorizationPolicyContribution> {
  const RemoteToolAuthorizationPolicyAdapter();

  @override
  ExtensionPoint<ToolAuthorizationPolicyContribution> get point =>
      toolAuthorizationPolicies;

  @override
  ToolAuthorizationPolicyContribution createContribution(
    RemoteExtensionContext remote,
  ) {
    if (remote.exposure.serviceId != remoteToolAuthorizationPolicyServiceId) {
      throw const ExtensionContractException(
        'Unsupported tool authorization policy service.',
      );
    }
    final metadata = remote.exposure.metadata;
    final routeId = metadata['routeId'];
    if (metadata.length != 1 || routeId is! String) {
      throw const ExtensionContractException(
        'Tool authorization policy metadata requires only a routeId string.',
      );
    }
    if (routeId.isEmpty ||
        routeId.length > 256 ||
        !RegExp(r'^[A-Za-z0-9]').hasMatch(routeId) ||
        RegExp(r'[^A-Za-z0-9._:-]').hasMatch(routeId)) {
      throw const ExtensionContractException(
        'Invalid tool authorization policy route ID.',
      );
    }
    return ToolAuthorizationPolicyContribution(
      evaluate: (request) => remote.invoke(const {}, (_) async {
        // The invocation fences this exact registration but grants no services.
        // Its context token is deliberately not sent to the policy backend.
        final decision = await RemoteToolAuthorizationPolicyServiceClient(
          remote.channel,
        ).evaluate(routeId, RemoteToolAuthorizationRequest.fromLocal(request));
        return localToolAuthorizationDecision(decision);
      }),
    );
  }
}
