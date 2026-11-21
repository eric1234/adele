import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Adapts one advertised preference source, not a model provider or host grant.
final class RemoteRunModelPreferenceAdapter
    implements RemoteExtensionAdapter<RunModelPreferenceContribution> {
  const RemoteRunModelPreferenceAdapter();

  @override
  ExtensionPoint<RunModelPreferenceContribution> get point =>
      runModelPreferencesExtensionPoint;

  @override
  RunModelPreferenceContribution createContribution(
    RemoteExtensionContext remote,
  ) {
    if (remote.exposure.serviceId != remoteRunModelPreferenceServiceId ||
        remote.exposure.metadata.isNotEmpty) {
      throw const ExtensionContractException(
        'Invalid Run model preference advertisement.',
      );
    }
    return RunModelPreferenceContribution(
      captureRun: (session, runId) async {
        try {
          // Acquiring the channel checks this registration. No host invocation
          // is opened and no authority token is sent with the semantic IDs.
          final client = RemoteRunModelPreferenceServiceClient(remote.channel);
          try {
            final preference = await client.captureRun(
              session.id.value,
              runId.value,
            );
            return preference?.toLocal();
          } finally {
            // Retirement wins even over malformed late responses and RPC errors.
            remote.validate();
          }
        } on StaleExtensionBinding {
          throw const RunModelPreferenceFailure(
            RunModelPreferenceFailureKind.unavailable,
          );
        } on PluginConnectionClosed {
          throw const RunModelPreferenceFailure(
            RunModelPreferenceFailureKind.unavailable,
          );
        } on AdeleProtocolException {
          throw const RunModelPreferenceFailure(
            RunModelPreferenceFailureKind.malformed,
          );
        } on RunModelPreferenceFailure {
          rethrow;
        } on Object {
          throw const RunModelPreferenceFailure(
            RunModelPreferenceFailureKind.failed,
          );
        }
      },
    );
  }
}
