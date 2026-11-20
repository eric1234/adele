/// Transport contracts for remote instruction-source snapshots.
library;

import 'package:adele_contract/adele_contract.dart';

part 'remote_inference_context.g.dart';

@AdeleValue('inferenceContextSource.instruction')
final class RemoteInferenceInstruction {
  const RemoteInferenceInstruction({
    required this.key,
    required this.text,
    required this.revision,
  });

  final String key;
  final String text;
  final String? revision;
}

/// Source identity and configuration are supplied by readiness advertisements.
@AdeleService('inferenceContextSource')
abstract interface class RemoteInferenceContextSourceService {
  @AdeleMethod('snapshot')
  Future<List<RemoteInferenceInstruction>> snapshot(
    String sessionId,
    String runId,
    String hostInvocationContext,
  );
}

/// Opt-in source with a host-retained Run binding and no host operation grant.
@AdeleService('runBoundInferenceContextSource')
abstract interface class RemoteRunBoundInferenceContextSourceService {
  @AdeleMethod('captureRun')
  Future<String?> captureRun(String sessionId, String runId);

  @AdeleMethod('snapshot')
  Future<List<RemoteInferenceInstruction>> snapshot(
    String sessionId,
    String runId,
    String? binding,
  );
}
