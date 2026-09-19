import 'package:adele_contract/adele_contract.dart';

import 'backend_connection.dart';

/// A presentation-local unary channel to one captured backend and context.
/// Neither plugin identity nor configuration selection crosses this boundary.
final class OwningBackendChannel {
  OwningBackendChannel({
    required PluginBackendConnection connection,
    required ConfigurationContextId configurationContext,
    required Iterable<String> backendServices,
    required void Function() validateOwner,
    required void Function() validatePresentation,
  }) : _connection = connection,
       _validateOwner = validateOwner,
       _validatePresentation = validatePresentation {
    for (final serviceId in backendServices) {
      adeleValidateServiceId(serviceId);
      if (_channels.containsKey(serviceId)) {
        throw const FormatException(
          'backendServices must not contain duplicates.',
        );
      }
      _channels[serviceId] = connection.channelFor(
        configurationContext,
        serviceId,
      );
    }
    // Validate context ownership even when there are no allowlisted services.
    connection.channelFor(configurationContext, 'context-validation');
    validate();
  }

  final PluginBackendConnection _connection;
  final void Function() _validateOwner;
  final void Function() _validatePresentation;
  final Map<String, AdeleRequestChannel> _channels = {};

  void validate() {
    _validatePresentation();
    _validateOwner();
    if (_connection.isClosed) {
      throw const PluginConnectionClosed('The owning backend is closed.');
    }
  }

  Future<Object?> request(
    String serviceId,
    String method,
    Map<String, Object?> payload,
  ) async {
    validate();
    final channel = _channels[serviceId];
    if (channel == null) {
      throw StateError('Backend service $serviceId is not allowlisted.');
    }
    final snapshot = adeleSnapshotJsonMap(
      payload,
      maxNodes: adelePluginBackendJsonMaxNodes,
    );
    validate();
    final Object? result;
    try {
      result = await channel.request(method, snapshot);
    } finally {
      validate();
    }
    return adeleSnapshotJsonMap({
      'value': result,
    }, maxNodes: adelePluginBackendJsonMaxNodes)['value'];
  }
}
