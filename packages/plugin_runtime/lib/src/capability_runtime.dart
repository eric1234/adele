import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';

import 'backend_connection.dart';

final class AdeleRequestChannelEndpoint implements CapabilityEndpoint {
  const AdeleRequestChannelEndpoint({
    required this.channel,
    required this.serviceId,
    required bool Function() isAvailable,
  }) : _isAvailable = isAvailable;

  final AdeleRequestChannel channel;
  final bool Function() _isAvailable;
  @override
  final String serviceId;
  @override
  bool get isAvailable => _isAvailable();
}

extension ProviderBindingRequestChannel on ProviderBinding {
  AdeleRequestChannel get requestChannel =>
      endpointAs<AdeleRequestChannelEndpoint>().channel;
}

final class PluginCapabilityActivation {
  PluginCapabilityActivation._({
    required this.connection,
    required this.registrations,
  });

  final PluginBackendConnection connection;
  final CapabilityRegistrationGroup registrations;
  bool _closed = false;

  static Future<PluginCapabilityActivation> register({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
    required Iterable<ProviderDescriptor> providers,
  }) async {
    if (connection.isClosed) {
      throw InvalidProviderRegistration(
        'Plugin generation ${connection.pluginId} is inactive.',
      );
    }
    final CapabilityRegistrationGroup registrations =
        CapabilityRegistrationGroup();
    try {
      for (final ProviderDescriptor provider in providers) {
        if (provider.pluginId != connection.pluginId) {
          throw InvalidProviderRegistration(
            'Provider ${provider.id} belongs to ${provider.pluginId}, not '
            '${connection.pluginId}.',
          );
        }
        registrations.add(
          registry.register(
            provider: provider,
            endpoint: AdeleRequestChannelEndpoint(
              channel: connection,
              serviceId: provider.serviceId,
              isAvailable: () => !connection.isClosed,
            ),
          ),
        );
      }
    } on Object {
      await registrations.close();
      rethrow;
    }
    final PluginCapabilityActivation activation = PluginCapabilityActivation._(
      connection: connection,
      registrations: registrations,
    );
    unawaited(
      connection.terminated
          .then((Object _) => activation.retire())
          .catchError((Object _) {}),
    );
    return activation;
  }

  Future<void> retire() async {
    if (_closed) return;
    _closed = true;
    await registrations.close();
  }

  Future<void> close() async {
    await retire();
    if (!connection.isClosed) await connection.close();
  }
}
