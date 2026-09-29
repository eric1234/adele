import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'product_lifecycle.dart';
import 'project_database.dart';

/// No caller-controlled owner or path crosses the plugin boundary.
Map<String, AdeleBackendDispatcher> projectStorageServices(
  ProductLifecycleCoordinator lifecycle,
  PluginBackendConnection connection,
) => {
  projectStorageServiceId: ProjectStorageServiceDispatcher(
    ProjectStorageHost(
      lifecycle: lifecycle,
      owner: PluginId(connection.pluginId),
      validateAccess: connection.validateInfrastructureContext,
    ),
  ),
};

/// Application-private mediation of one exact generation's schema ownership.
final class ProjectStorageHost implements ProjectStorageService {
  ProjectStorageHost({
    required this.lifecycle,
    required this.owner,
    required this.validateAccess,
  });

  final ProductLifecycleCoordinator lifecycle;
  final PluginId owner;
  final void Function() validateAccess;

  ProjectDatabase? _database(
    String sessionId,
    ProjectStorageAccessMode accessMode,
  ) {
    // A generated dispatcher can queue requests. Revalidate at service entry,
    // immediately before synchronous storage, not just on transport admission.
    validateAccess();
    return lifecycle.databaseForSession(
      SessionId(sessionId),
      accessMode: accessMode,
    );
  }

  ProjectDatabase _requireDatabase(
    String sessionId,
    ProjectStorageAccessMode accessMode,
  ) =>
      _database(sessionId, accessMode) ??
      (throw StateError('This Session belongs to a volatile Project.'));

  @override
  Future<bool> isDurableSession(String sessionId) async =>
      _database(sessionId, ProjectStorageAccessMode.durable) != null;

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    _requireDatabase(
      sessionId,
      accessMode,
    ).ensurePluginSchema(owner.value, migrations);
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async =>
      _requireDatabase(sessionId, accessMode).queryPluginRows(sql, parameters);

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) async {
    _requireDatabase(
      sessionId,
      accessMode,
    ).executePluginTransaction(statements);
  }
}
