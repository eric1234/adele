import 'package:adele_plugin_backend_support/adele_backend_records.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// One immutable, exact-installation startup projection, never an edit baseline.
final class StartupRecordsView {
  factory StartupRecordsView.fromProjection(
    PreparedPluginCatalog catalog,
    PreparedPluginInstallation installation, {
    required List<Map<String, Object?>> records,
    Iterable<RecordDiagnosticView> diagnostics = const [],
  }) {
    if (!catalog.installations.any((entry) => identical(entry, installation))) {
      throw ArgumentError(
        'Records belong to another prepared catalog snapshot.',
      );
    }
    final definitions = {
      for (final definition
          in installation.recordsSchema?.definitions ??
              const <RecordTypeDefinition>[])
        if (definition.owner == installation.metadata.id &&
            installation.backendConsumedRecordTypes.contains(definition.id))
          definition.id.value: definition,
    };
    final copied = adeleCopyBackendRecords(records).toList();
    for (final record in copied) {
      final definition = definitions[record['type']];
      if (definition == null ||
          definition.collection.value != record['collection']) {
        throw const FormatException(
          'Startup record type is not opted in by this installation.',
        );
      }
      final values = record['values']! as Map<String, Object>;
      final known = {for (final field in definition.fields) field.id.value};
      if (values.keys.any((key) => !known.contains(key))) {
        throw const FormatException(
          'Startup record contains undeclared fields.',
        );
      }
      definition.validate(
        ConfigurationRecordId(record['id']! as String),
        values,
      );
    }
    copied.sort((a, b) {
      for (final key in ['collection', 'type', 'id']) {
        final order = (a[key]! as String).compareTo(b[key]! as String);
        if (order != 0) return order;
      }
      return 0;
    });
    return StartupRecordsView._(
      catalog,
      installation,
      List.unmodifiable(copied),
      List.unmodifiable(diagnostics),
    );
  }

  const StartupRecordsView._(
    this._catalog,
    this._installation,
    this.records,
    this.diagnostics,
  );

  final PreparedPluginCatalog _catalog;
  final PreparedPluginInstallation _installation;
  final List<Map<String, Object>> records;

  /// Attributable host diagnostics; never part of the backend payload.
  final List<RecordDiagnosticView> diagnostics;

  List<Map<String, Object>> recordsForInstallation(
    PreparedPluginCatalog catalog,
    PreparedPluginInstallation installation,
  ) {
    if (!identical(catalog, _catalog) ||
        !identical(installation, _installation)) {
      throw ArgumentError('Records belong to another prepared installation.');
    }
    return records;
  }
}

/// App-side diagnostic data, without a native document or original exception.
final class RecordDiagnosticView {
  const RecordDiagnosticView({
    required this.collection,
    required this.fileName,
    required this.recordId,
    required this.message,
  });

  final RecordCollectionId collection;
  final String fileName;
  final ConfigurationRecordId? recordId;
  final String message;
}
