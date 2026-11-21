/// Data-only transport for capturing an optional Run model preference.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart' as model;

import 'src/run_model_preference.dart' as local;

part 'remote_run_model_preference.g.dart';

@AdeleValue('runModelPreference.preference')
final class RemoteRunModelPreference {
  RemoteRunModelPreference({
    required this.providerId,
    required this.modelId,
    required this.reasoningEffort,
  }) {
    toLocal();
  }

  final String providerId;
  final String modelId;

  /// Exact canonical enum name, or null for unspecified effort.
  final String? reasoningEffort;

  local.RunModelPreference toLocal() {
    const malformed = local.RunModelPreferenceFailure(
      local.RunModelPreferenceFailureKind.malformed,
    );
    if (providerId.length > local.RunModelPreference.maxProviderIdLength) {
      throw malformed;
    }
    final effort = model.ModelReasoningEffort.values
        .asNameMap()[reasoningEffort];
    if (reasoningEffort != null && effort == null) throw malformed;
    try {
      return local.RunModelPreference(
        providerId: capabilities.ProviderId(providerId),
        modelId: modelId,
        reasoningEffort: effort,
      );
    } on capabilities.InvalidCapabilityIdentity {
      throw malformed;
    }
  }
}

/// Session and Run identities confer no scoped host service authority.
@AdeleService('runModelPreference')
abstract interface class RemoteRunModelPreferenceService {
  @AdeleMethod('captureRun')
  Future<RemoteRunModelPreference?> captureRun(String sessionId, String runId);
}
