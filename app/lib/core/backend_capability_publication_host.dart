import 'dart:async';
import 'dart:math';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_capability_publisher.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Mediates publication through the authenticated connection, never a supplied
/// plugin identity. The activation owns every registration, not this handle table.
final class BackendCapabilityPublicationHost implements AdeleBackendDispatcher {
  BackendCapabilityPublicationHost({required this.connection}) {
    connection.validateInfrastructureContext();
    _detachRevocation = connection.onInfrastructureRevoked(() {
      unawaited(close());
    });
  }

  static const maxGroups = 64;
  static const maxPendingMutations = 64;
  static final _random = Random.secure();
  static final _handlePattern = RegExp(r'^[0-9a-f]{32}-[0-9a-f]{16}$');

  final PluginBackendConnection connection;
  final _scope = List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _groups = <String, PluginCapabilityGroup>{};
  PluginBackendActivation? _activation;
  Future<void> _tail = Future<void>.value();
  void Function()? _detachRevocation;
  int _nextGroup = 0;
  int _pending = 0;
  bool _closed = false;

  /// Readiness precedes host registration. Attach exactly once after successful
  /// composite activation; requests before attachment fail instead of deadlocking.
  void attach(PluginBackendActivation activation) {
    _validateGeneration();
    if (_activation != null || !identical(activation.connection, connection)) {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.notAuthorized,
      );
    }
    activation.validate();
    _activation = activation;
  }

  void _validateGeneration() {
    try {
      if (_closed) throw StateError('Publication closed.');
      connection.validateInfrastructureContext();
      _activation?.validate();
    } on Object {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.generationUnavailable,
      );
    }
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final id = request['requestId'];
    final requestId = id is int && id >= 0 ? id : null;
    try {
      _validateGeneration();
      final activation = _activation;
      if (activation == null) {
        throw const AdeleCapabilityPublicationFailure(
          AdeleCapabilityPublicationFailureKind.notReady,
        );
      }
      final method = request['method'];
      final payload = request['payload'];
      if (requestId == null ||
          request.length != 4 ||
          request['kind'] != 'request' ||
          payload is! Map ||
          !const {
            'publish',
            'adoptAdvertised',
            'replace',
            'retire',
          }.contains(method)) {
        throw const AdeleCapabilityPublicationFailure(
          AdeleCapabilityPublicationFailureKind.invalidRequest,
        );
      }
      final hasGroup = method == 'replace' || method == 'retire';
      final hasExposures = method != 'retire';
      if (payload.length != (hasGroup ? 1 : 0) + (hasExposures ? 1 : 0) ||
          (hasGroup && !payload.containsKey('group')) ||
          (hasExposures && !payload.containsKey('exposures'))) {
        throw const AdeleCapabilityPublicationFailure(
          AdeleCapabilityPublicationFailureKind.invalidRequest,
        );
      }
      final handle = hasGroup ? _validateHandle(payload['group']) : null;
      final exposures = hasExposures
          ? adeleDecodeCapabilityPublication(payload['exposures'])
          : const <AdeleCapabilityExposure>[];
      if (_pending >= maxPendingMutations) {
        throw const AdeleCapabilityPublicationFailure(
          AdeleCapabilityPublicationFailureKind.capacityExceeded,
        );
      }
      _pending++;
      final operation = _tail.then((_) async {
        _validateGeneration();
        return _mutate(activation, method as String, handle, exposures);
      });
      _tail = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      try {
        final result = await operation;
        _validateGeneration();
        return _response(requestId, result);
      } finally {
        _pending--;
      }
    } on AdeleCapabilityPublicationFailure catch (failure) {
      var kind = failure.kind;
      try {
        _validateGeneration();
      } on Object {
        kind = AdeleCapabilityPublicationFailureKind.generationUnavailable;
      }
      return _response(requestId, {'failure': kind.name});
    } on Object {
      return _response(requestId, {'failure': 'outcomeUnknown'});
    }
  }

  Future<Map<String, Object?>> _mutate(
    PluginBackendActivation activation,
    String method,
    String? handle,
    List<AdeleCapabilityExposure> exposures,
  ) async {
    final previous = handle == null ? null : _groups[handle];
    if (handle != null && previous == null) {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.staleGroup,
      );
    }
    if (handle == null && _groups.length >= maxGroups) {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.capacityExceeded,
      );
    }
    PluginCapabilityGroup? result;
    try {
      switch (method) {
        case 'retire':
          await activation.retireCapabilityGroup(previous!);
          _groups.remove(handle);
          return {'retired': true};
        case 'adoptAdvertised':
          result = activation.adoptAdvertisedCapabilityGroup(
            expected: exposures,
          );
        case 'publish':
          result = await activation.publishCapabilityGroup(
            exposures: exposures,
          );
        case 'replace':
          result = await activation.replaceCapabilityGroup(
            expected: previous!,
            exposures: exposures,
          );
      }
      _validateGeneration();
      if (previous != null) _groups.remove(handle);
      final next =
          '$_scope-${(_nextGroup++).toRadixString(16).padLeft(16, '0')}';
      _groups[next] = result!;
      return {'group': next};
    } on Object {
      if (previous?.isRetired ?? false) {
        // Individual host retirement can invalidate a group before all members
        // close. Drain its exact survivors before dropping backend cleanup access.
        try {
          await activation.retireCapabilityGroup(previous!);
        } on Object {
          // Group retirement attempts every member; generation retirement also
          // owns any cleanup when it wins the race.
        }
        _groups.remove(handle);
      }
      // A late completion cannot leave a newly introduced registration orphaned.
      // Ready adoption itself has not changed any executable registrations.
      if (result != null && method != 'adoptAdvertised') {
        try {
          await activation.retireCapabilityGroup(result);
        } on Object {
          // Whole-generation retirement owns cleanup if it won this race.
        }
      }
      _validateGeneration();
      throw AdeleCapabilityPublicationFailure(
        previous?.isRetired ?? false
            ? AdeleCapabilityPublicationFailureKind.replacementUnavailable
            : AdeleCapabilityPublicationFailureKind.rejected,
      );
    }
  }

  String _validateHandle(Object? value) {
    if (value is! String ||
        !_handlePattern.hasMatch(value) ||
        !value.startsWith('$_scope-')) {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.notAuthorized,
      );
    }
    return value;
  }

  static Map<String, Object?> _response(
    int? id,
    Map<String, Object?> payload,
  ) => {'kind': 'response', 'requestId': id, 'ok': true, 'payload': payload};

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) async => send(await dispatch(command));

  @override
  Future<void> close() {
    _closed = true;
    _detachRevocation?.call();
    _detachRevocation = null;
    _groups.clear();
    return _tail;
  }
}
