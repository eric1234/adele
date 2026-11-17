import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_backend_configuration.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'prepared_records.dart';

/// Nonsecret observations for one host-selected installation and connection.
/// The existing infrastructure transport authenticates the actual generation.
final class BackendConfigurationHost implements AdeleBackendDispatcher {
  BackendConfigurationHost({
    required this.connection,
    required PreparedPluginCatalog catalog,
    required PreparedPluginInstallation installation,
    required CurrentRecordsLoader loadRecords,
  }) : _catalog = catalog,
       _installation = installation,
       _loadRecords = loadRecords {
    connection.validateInfrastructureContext();
    if (connection.pluginId != installation.metadata.id.value ||
        !catalog.installations.any((entry) => identical(entry, installation)) ||
        installation.backendConsumedRecordTypes.isEmpty ||
        installation.backendConsumedRecordTypes.any(
          (id) =>
              !(installation.recordsSchema?.definitions.any(
                    (definition) =>
                        definition.id == id &&
                        definition.owner == installation.metadata.id,
                  ) ??
                  false),
        )) {
      throw const AdeleConfigurationFailure(
        AdeleConfigurationFailureKind.notAuthorized,
      );
    }
  }

  final PluginBackendConnection connection;
  final PreparedPluginCatalog _catalog;
  final PreparedPluginInstallation _installation;
  final CurrentRecordsLoader _loadRecords;
  bool _closed = false;

  void _validateGeneration() {
    try {
      if (_closed) throw StateError('Configuration access is closed.');
      connection.validateInfrastructureContext();
    } on Object {
      throw const AdeleConfigurationFailure(
        AdeleConfigurationFailureKind.generationUnavailable,
      );
    }
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final requestId = request['requestId'];
    final safeRequestId = requestId is int && requestId >= 0 ? requestId : null;
    try {
      _validateGeneration();
      final payload = request['payload'];
      if (safeRequestId == null ||
          request.length != 4 ||
          request['kind'] != 'request' ||
          request['method'] != 'currentRecords' ||
          payload is! Map ||
          payload.isNotEmpty) {
        throw const AdeleConfigurationFailure(
          AdeleConfigurationFailureKind.notAuthorized,
        );
      }
      final view = await _loadRecords(_catalog, _installation);
      _validateGeneration();
      final records = view.recordsForInstallation(_catalog, _installation);
      // Only plain sendable containers cross the AOT boundary, never host
      // diagnostics or the view itself. It has already validated and bounded data.
      return _response(safeRequestId, {
        'records': [
          for (final record in records)
            <String, Object>{
              'collection': record['collection']!,
              'type': record['type']!,
              'id': record['id']!,
              'values': Map<String, Object>.of(
                record['values']! as Map<String, Object>,
              ),
            },
        ],
        'isComplete': view.diagnostics.isEmpty,
      });
    } on AdeleConfigurationFailure catch (failure) {
      return _failure(safeRequestId, failure.kind);
    } on Object {
      // Store, schema, ownership and transport-bound failures are never empty
      // observations, and native exception text must not reach the backend.
      return _failure(
        safeRequestId,
        AdeleConfigurationFailureKind.configurationUnavailable,
      );
    }
  }

  Map<String, Object?> _failure(
    int? requestId,
    AdeleConfigurationFailureKind kind,
  ) {
    try {
      _validateGeneration();
    } on AdeleConfigurationFailure {
      kind = AdeleConfigurationFailureKind.generationUnavailable;
    }
    return _response(requestId, {'failure': kind.name});
  }

  static Map<String, Object?> _response(
    int? requestId,
    Map<String, Object?> payload,
  ) => {
    'kind': 'response',
    'requestId': requestId,
    'ok': true,
    'payload': payload,
  };

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) async => send(await dispatch(command));

  /// Fences publication without cancelling worker I/O; the Settings owner drains it.
  @override
  Future<void> close() {
    _closed = true;
    return Future<void>.value();
  }
}
