import 'package:adele_contract/adele_contract.dart';

part 'adele_project_storage.g.dart';

/// Bounds apply to each response, not to a Session's total retained history.
const int relationalQueryRowLimit = 1000;
const int relationalQueryByteLimit = 1024 * 1024;

/// One parameterized statement inside a host-owned transaction.
@AdeleValue('project.storage.statement')
final class RelationalStatement {
  RelationalStatement({
    required this.sql,
    required Map<String, Object?> parameters,
    required this.expectedRows,
  }) : parameters = adeleSnapshotJsonMap(parameters) {
    validateRelationalParameters(this.parameters.values);
    if (expectedRows != null && expectedRows! < 0) {
      throw ArgumentError.value(expectedRows, 'expectedRows');
    }
  }

  final String sql;
  final Map<String, Object?> parameters;

  /// A mismatch rolls back the entire transaction; null makes no row-count claim.
  final int? expectedRows;
}

@AdeleValue('project.storage.row')
final class RelationalRow {
  RelationalRow({required Map<String, Object?> values})
    : values = adeleSnapshotJsonMap(values) {
    validateRelationalParameters(this.values.values);
  }

  final Map<String, Object?> values;
}

/// The current concrete SQL value subset, not arbitrary JSON or SQLite objects.
void validateRelationalParameters(Iterable<Object?> values) {
  for (final value in values) {
    if (value != null && value is! String && value is! int) {
      throw const FormatException(
        'Relational values must be strings, integers, or null.',
      );
    }
  }
}

/// Supplied only through an exact backend generation's infrastructure context.
/// Owner identity is implicit in that connection, never supplied by the caller.
@AdeleService('dev.adele.project.storage')
abstract interface class ProjectStorageService {
  /// False only for a published Session in an explicitly volatile Project.
  /// Missing Sessions and closed storage fail rather than becoming volatile.
  @AdeleMethod('isDurableSession')
  Future<bool> isDurableSession(String sessionId);

  /// Each SQL element advances this plugin owner's version once, starting at 1.
  /// Current unreleased owners supply one current version-1 baseline only.
  @AdeleMethod('ensureSchemaForSession')
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
  );

  /// A single read-only query. Oversized results fail, never silently truncate.
  @AdeleMethod('queryForSession')
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
  );

  /// Executes all statements in one transaction before reporting success.
  @AdeleMethod('transactionForSession')
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
  );
}
