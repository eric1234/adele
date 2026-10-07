import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_core_extensions/remote_command.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Adapts context-free backend Commands; composition and admission stay public.
final class RemoteCommandAdapter
    implements RemoteExtensionAdapter<CommandContribution> {
  const RemoteCommandAdapter();

  @override
  ExtensionPoint<CommandContribution> get point => commandContributions;

  @override
  CommandContribution createContribution(RemoteExtensionContext remote) {
    if (remote.exposure.serviceId != remoteCommandServiceId) {
      throw const ExtensionContractException('Unsupported Command service.');
    }
    final metadata = remote.exposure.metadata;
    final commandId = metadata['commandId'];
    final label = metadata['label'];
    final routeId = metadata['routeId'];
    if (metadata.length != 3 ||
        commandId is! String ||
        label is! String ||
        routeId is! String) {
      throw const ExtensionContractException(
        'Command metadata requires only commandId, label, and routeId strings.',
      );
    }
    if (routeId.isEmpty ||
        routeId.length > 256 ||
        !RegExp(r'^[A-Za-z0-9]').hasMatch(routeId) ||
        RegExp(r'[^A-Za-z0-9._:-]').hasMatch(routeId)) {
      throw const ExtensionContractException('Invalid Command route ID.');
    }
    return CommandContribution(
      id: CommandId(commandId),
      label: label,
      availability: () {
        remote.validate();
        return CommandAvailability.enabled;
      },
      // Channel acquisition validates the exact registration before dispatch.
      // No host authority or late registration check is needed after admission.
      invoke: () => RemoteCommandServiceClient(remote.channel).invoke(routeId),
    );
  }
}
