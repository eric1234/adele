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

final class PluginCapabilityExposure {
  const PluginCapabilityExposure({
    required this.provider,
    required this.configurationContext,
  });

  final ProviderDescriptor provider;
  final ConfigurationContextId configurationContext;
}

extension ProviderBindingRequestChannel on ProviderBinding {
  AdeleRequestChannel get requestChannel =>
      endpointAs<AdeleRequestChannelEndpoint>().channel;

  AdeleStreamChannel get streamChannel {
    final AdeleRequestChannel channel = requestChannel;
    if (channel is! AdeleStreamChannel) {
      throw StateError('The provider does not support generated streaming.');
    }
    return channel;
  }
}

final class PluginCapabilityActivation {
  PluginCapabilityActivation._({
    required this.connection,
    required this.registrations,
  });

  final PluginBackendConnection connection;
  final CapabilityRegistrationGroup registrations;
  Future<void>? _retiring;

  bool owns(ProviderBinding binding) {
    binding.endpointAs<CapabilityEndpoint>();
    return _retiring == null &&
        !connection.isClosed &&
        registrations.owns(binding);
  }

  static Future<PluginCapabilityActivation> registerAdvertised({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
  }) => register(
    connection: connection,
    registry: registry,
    exposures: connection.capabilityExposures.map(
      (AdeleCapabilityExposure exposure) => PluginCapabilityExposure(
        provider: ProviderDescriptor(
          id: ProviderId(exposure.providerId),
          capability: CapabilityKey(
            id: CapabilityId(exposure.capabilityId),
            majorVersion: exposure.capabilityMajorVersion,
          ),
          pluginId: connection.pluginId,
          displayName: exposure.displayName,
          serviceId: exposure.serviceId,
          rank: exposure.rank,
        ),
        configurationContext: connection.configurationContext(
          exposure.configurationContext,
        ),
      ),
    ),
  );

  static Future<PluginCapabilityActivation> register({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
    required Iterable<PluginCapabilityExposure> exposures,
  }) async {
    if (connection.isClosed) {
      throw InvalidProviderRegistration(
        'Plugin generation ${connection.pluginId} is inactive.',
      );
    }
    final CapabilityRegistrationGroup registrations =
        CapabilityRegistrationGroup();
    try {
      for (final PluginCapabilityExposure exposure in exposures) {
        final ProviderDescriptor provider = exposure.provider;
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
              channel: connection.channelFor(
                exposure.configurationContext,
                provider.serviceId,
              ),
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

  Future<void> retire() => _retiring ??= registrations.close();

  Future<void> close() async {
    await retire();
    if (!connection.isClosed) await connection.close();
  }
}
