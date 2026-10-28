import 'dart:io';
import 'dart:isolate';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// One read-only startup snapshot, not a watcher or a configuration writer.
/// Normal startup captures the application's settings owner; standalone loading
/// uses a short-lived read-only isolate for independent prepared-host consumers.
final class PreparedSettingsSnapshot {
  PreparedSettingsSnapshot._(this._catalog, this._values, this._failures);

  factory PreparedSettingsSnapshot.fromResolution(
    PreparedPluginCatalog catalog,
    SettingsCatalog resolvedCatalog, {
    required Map<SettingId, ResolvedSetting<Object>> values,
    required Map<SettingId, Object> failures,
  }) {
    final definitions = catalog.settings.definitions;
    if (definitions.length != resolvedCatalog.definitions.length ||
        definitions.any(
          (definition) =>
              !identical(definition, resolvedCatalog.definition(definition.id)),
        )) {
      throw ArgumentError(
        'Settings belong to another prepared catalog snapshot.',
      );
    }
    return PreparedSettingsSnapshot._(
      catalog,
      Map.unmodifiable(values),
      Map.unmodifiable(failures),
    );
  }

  /// Explicit default/override resolution for standalone hosts and fixtures.
  /// This path never reads user configuration files.
  factory PreparedSettingsSnapshot.resolve(
    PreparedPluginCatalog catalog, {
    Map<SettingId, Object?> globalOverrides = const {},
  }) {
    final values = <SettingId, ResolvedSetting<Object>>{};
    final failures = <SettingId, Object>{};
    try {
      final settings = catalog.settings;
      for (final definition in settings.definitions) {
        try {
          values[definition.id] = settings.resolve<Object>(
            definition.id,
            globalOverrides: globalOverrides,
          );
        } on Object catch (error) {
          failures[definition.id] = error;
        }
      }
    } on Object catch (error) {
      return PreparedSettingsSnapshot.fromFailure(catalog, error);
    }
    return PreparedSettingsSnapshot._(
      catalog,
      Map.unmodifiable(values),
      Map.unmodifiable(failures),
    );
  }

  factory PreparedSettingsSnapshot.fromFailure(
    PreparedPluginCatalog catalog,
    Object error,
  ) => PreparedSettingsSnapshot._(
    catalog,
    const {},
    Map.unmodifiable({
      for (final installation in catalog.installations)
        for (final definition
            in installation.settingsSchema?.definitions ??
                <SettingDefinition<Object>>[])
          definition.id: error,
    }),
  );

  final PreparedPluginCatalog _catalog;
  final Map<SettingId, ResolvedSetting<Object>> _values;
  final Map<SettingId, Object> _failures;

  static Future<PreparedSettingsSnapshot> load(
    PreparedPluginCatalog catalog, {
    PlatformStorageRoots? roots,
  }) async {
    final SettingsCatalog settings;
    try {
      settings = catalog.settings;
    } on Object catch (error) {
      // Aggregation must never pick a winner for colliding declarations.
      return PreparedSettingsSnapshot._(catalog, const {}, {
        for (final installation in catalog.installations)
          for (final definition
              in installation.settingsSchema?.definitions ??
                  <SettingDefinition<Object>>[])
            definition.id: error,
      });
    }
    if (settings.definitions.isEmpty) {
      return PreparedSettingsSnapshot._(catalog, const {}, const {});
    }
    try {
      final result = await Isolate.run(() => _load(settings, roots));
      return PreparedSettingsSnapshot._(
        catalog,
        Map.unmodifiable(result.$1),
        Map.unmodifiable(result.$2),
      );
    } on Object catch (error) {
      return PreparedSettingsSnapshot._(catalog, const {}, {
        for (final definition in settings.definitions) definition.id: error,
      });
    }
  }

  /// Invalid known overrides fail their owning component before publication.
  /// An omitted/malformed schema alone does not disable executable components.
  void validateInstallation(PreparedPluginInstallation installation) {
    _validateOwner(installation);
    for (final definition
        in installation.settingsSchema?.definitions ??
            <SettingDefinition<Object>>[]) {
      if (_failures[definition.id] case final failure?) throw failure;
    }
  }

  /// Projects only declarations of this exact installation, never a namespace
  /// prefix or another installation with matching semantic identity.
  Map<String, Object> valuesForInstallation(
    PreparedPluginInstallation installation,
  ) {
    validateInstallation(installation);
    return Map.unmodifiable({
      for (final definition
          in installation.settingsSchema?.definitions ??
              <SettingDefinition<Object>>[])
        definition.id.value: read(installation, definition.id.value).value,
    });
  }

  ResolvedSetting<Object> read(
    PreparedPluginInstallation installation,
    String id,
  ) {
    _validateOwner(installation);
    final key = SettingId(id);
    final definitions = installation.settingsSchema?.definitions;
    if (definitions == null ||
        !definitions.any(
          (definition) =>
              definition.id == key &&
              definition.owner.value == installation.metadata.id.value,
        )) {
      throw StateError('Setting $id is not declared by this installation.');
    }
    if (_failures[key] case final failure?) throw failure;
    return _values[key] ??
        (throw StateError('Setting $id has no resolved startup value.'));
  }

  void _validateOwner(PreparedPluginInstallation installation) {
    if (!_catalog.installations.any(
      (entry) => identical(entry, installation),
    )) {
      throw StateError('Settings belong to another prepared catalog snapshot.');
    }
  }
}

(Map<SettingId, ResolvedSetting<Object>>, Map<SettingId, Object>) _load(
  SettingsCatalog catalog,
  PlatformStorageRoots? roots,
) {
  final values = <SettingId, ResolvedSetting<Object>>{};
  final failures = <SettingId, Object>{};
  try {
    final snapshot = GlobalSettingsStore(
      store: ConfigurationStore(
        roots ??
            PlatformStorageRoots.resolve(
              operatingSystem: Platform.operatingSystem,
              environment: Platform.environment,
            ),
      ),
      catalog: catalog,
    ).load();
    for (final definition in catalog.definitions) {
      try {
        values[definition.id] = snapshot.resolve<Object>(definition.id);
      } on Object catch (error) {
        failures[definition.id] = error;
      }
    }
  } on Object catch (error) {
    for (final definition in catalog.definitions) {
      failures[definition.id] = error;
    }
  }
  return (values, failures);
}
