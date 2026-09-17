/// Remote stock root-level AGENTS.md instruction source.
library;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:agents_md_plugin/agents_md_plugin.dart';

final class AgentsMdBackend implements RemoteInferenceContextSourceService {
  const AgentsMdBackend(this._hostRequests);

  final AdeleHostRequestMultiplexer _hostRequests;

  @override
  Future<List<RemoteInferenceInstruction>> snapshot(
    String sessionId,
    String runId,
    String hostInvocationContext,
  ) async {
    final files = AuthorizedEnvironmentReadServiceClient(
      _hostRequests.bind(
        hostInvocationContext: hostInvocationContext,
        serviceId: authorizedEnvironmentReadServiceId,
      ),
    );
    final EnvironmentTextFile file;
    try {
      file = await files.readFile('AGENTS.md');
    } on EnvironmentFailure catch (failure) {
      if (failure.code != 'not_found') rethrow;
      return const <RemoteInferenceInstruction>[];
    }
    return <RemoteInferenceInstruction>[
      for (final instruction in agentsMdInstructions(file))
        RemoteInferenceInstruction(
          key: instruction.key,
          text: instruction.text,
          revision: instruction.revision,
        ),
    ];
  }
}
