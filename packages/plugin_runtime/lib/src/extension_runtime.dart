import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'backend_connection.dart';
import 'capability_runtime.dart';

/// Host implementations of known public extension contracts, not contributions.
final class RemoteExtensionAdapterRegistry {
  RemoteExtensionAdapterRegistry(
    Iterable<RemoteExtensionAdapter<Object>> adapters,
  ) {
    for (final adapter in adapters) {
      if (_adapters.containsKey(adapter.point.value)) {
        throw ArgumentError('Duplicate remote adapter for ${adapter.point}.');
      }
      _adapters[adapter.point.value] = adapter;
    }
  }

  final Map<String, RemoteExtensionAdapter<Object>> _adapters = {};

  RemoteExtensionAdapter<Object> _require(String pointId) =>
      _adapters[pointId] ??
      (throw ExtensionContractException(
        'Unsupported remote extension point $pointId.',
      ));
}

abstract interface class RemoteExtensionAdapter<T extends Object> {
  ExtensionPoint<T> get point;

  /// Validates point-specific metadata and builds one exact-generation proxy.
  T createContribution(RemoteExtensionContext context);
}

/// The exact advertised route and registration lifetime captured by a proxy.
final class RemoteExtensionContext {
  RemoteExtensionContext._(this.connection, this.exposure)
    : configurationContext = connection.configurationContext(
        exposure.configurationContext,
      );

  final PluginBackendConnection connection;
  final AdeleExtensionExposure exposure;
  final ConfigurationContextId configurationContext;
  final Set<PluginHostInvocation> _invocations = {};
  ExtensionRegistration? _registration;
  bool _retired = false;

  void validate() {
    if (_retired || connection.isClosed || (_registration?.isClosed ?? true)) {
      throw StaleExtensionBinding(ExtensionId(exposure.extensionId));
    }
  }

  AdeleRequestChannel get channel {
    validate();
    return connection.channelFor(configurationContext, exposure.serviceId);
  }

  /// Authority exists only for this operation and this exact registration.
  Future<T> invoke<T>(
    Map<String, AdeleBackendDispatcher> services,
    Future<T> Function(PluginHostInvocation invocation) operation,
  ) async {
    validate();
    final invocation = connection.openHostInvocation(services);
    _invocations.add(invocation);
    try {
      final result = await operation(invocation);
      validate();
      return result;
    } finally {
      invocation.close();
      _invocations.remove(invocation);
    }
  }

  void _retire() {
    _retired = true;
    for (final invocation in _invocations) {
      invocation.close();
    }
    _invocations.clear();
  }
}

final class PluginExtensionActivation {
  PluginExtensionActivation._(this.connection);

  final PluginBackendConnection connection;
  final List<RemoteExtensionContext> _contexts = [];
  final List<ExtensionRegistration> _registrations = [];
  Future<void>? _retiring;

  static Future<PluginExtensionActivation> registerAdvertised({
    required PluginBackendConnection connection,
    required ExtensionRegistry registry,
    required RemoteExtensionAdapterRegistry adapters,
  }) async {
    if (connection.isClosed) {
      throw const ExtensionRegistrationException(
        'Backend generation is inactive.',
      );
    }
    final activation = PluginExtensionActivation._(connection);
    try {
      for (final exposure in connection.extensionExposures) {
        final adapter = adapters._require(exposure.extensionPointId);
        final context = RemoteExtensionContext._(connection, exposure);
        activation._contexts.add(context);
        final contribution = adapter.createContribution(context);
        final registration = registry.register(
          point: adapter.point,
          id: ExtensionId(exposure.extensionId),
          value: contribution,
        );
        context._registration = registration;
        activation._registrations.add(registration);
      }
    } on Object {
      await activation.retire();
      rethrow;
    }
    unawaited(connection.terminated.then((_) => activation.retire()));
    return activation;
  }

  Future<void> retire() => _retiring ??= _retire();

  Future<void> _retire() {
    for (final context in _contexts) {
      context._retire();
    }
    // Start every close synchronously, so no binding survives an await here.
    return Future.wait<void>([
      for (final registration in _registrations.reversed) registration.close(),
    ]);
  }

  Future<void> close() async {
    try {
      await retire();
    } finally {
      await connection.close();
    }
  }
}

/// One backend attempt owns both registration phases, with all-or-nothing cleanup.
final class PluginBackendActivation {
  PluginBackendActivation._(
    this.connection,
    this._capabilities,
    this._extensions,
  );

  final PluginBackendConnection connection;
  final PluginCapabilityActivation _capabilities;
  final PluginExtensionActivation _extensions;
  Future<void>? _retiring;

  static Future<PluginBackendActivation> registerAdvertised({
    required PluginBackendConnection connection,
    required CapabilityRegistry capabilities,
    required ExtensionRegistry extensions,
    required RemoteExtensionAdapterRegistry adapters,
  }) async {
    PluginCapabilityActivation? acquired;
    PluginExtensionActivation? acquiredExtensions;
    try {
      acquired = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: capabilities,
      );
      acquiredExtensions = await PluginExtensionActivation.registerAdvertised(
        connection: connection,
        registry: extensions,
        adapters: adapters,
      );
      if (connection.isClosed) {
        throw const PluginConnectionClosed(
          'Backend terminated during activation.',
        );
      }
      return PluginBackendActivation._(
        connection,
        acquired,
        acquiredExtensions,
      );
    } on Object {
      try {
        await Future.wait<void>([
          if (acquiredExtensions != null) acquiredExtensions.retire(),
          if (acquired != null) acquired.retire(),
        ]);
      } finally {
        await connection.close();
      }
      rethrow;
    }
  }

  Future<void> retire() => _retiring ??= Future.wait<void>([
    _extensions.retire(),
    _capabilities.retire(),
  ]);

  Future<void> close() async {
    try {
      await retire();
    } finally {
      await connection.close();
    }
  }
}
