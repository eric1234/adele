import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_toml_document/adele_toml_document.dart';

/// Internal, synchronous global settings editing, not a plugin filesystem API.
///
/// Route all operations through CFG2's one owning host isolate per process, off
/// the UI isolate. Writes do not reconfigure running consumers.
final class GlobalSettingsStore {
  const GlobalSettingsStore({required this.store, required this.catalog});

  final ConfigurationStore store;
  final SettingsCatalog catalog;

  /// Loads valid TOML without materializing defaults or validating unknown keys.
  /// Known overrides are validated individually when resolved or edited.
  GlobalSettingsSnapshot load() {
    final baseline = store.load();
    return GlobalSettingsSnapshot._(catalog, baseline, baseline.document);
  }

  /// Uses the snapshot's original whole-document baseline, without retry/merge.
  /// The returned snapshot is the baseline for subsequent edits.
  GlobalSettingsSnapshot save(GlobalSettingsSnapshot snapshot) {
    if (!identical(snapshot._catalog, catalog)) {
      throw ArgumentError('The snapshot belongs to another settings catalog.');
    }
    final saved = store.save(snapshot._baseline, snapshot.document);
    if (identical(saved, snapshot._baseline)) return snapshot;
    return GlobalSettingsSnapshot._(catalog, saved, saved.document);
  }
}

/// An immutable edit buffer retaining the last loaded/saved persistence baseline.
final class GlobalSettingsSnapshot {
  const GlobalSettingsSnapshot._(this._catalog, this._baseline, this.document);

  final SettingsCatalog _catalog;
  final ConfigurationSnapshot _baseline;
  final TomlDocument document;

  /// Whether the file existed at the baseline, not whether edits are pending.
  bool get exists => _baseline.exists;

  ResolvedSetting<T> resolve<T extends Object>(SettingId id) {
    _catalog.definition(id);
    Object value;
    try {
      value = document.readScalar([id.value]);
    } on TomlException catch (error) {
      // With exactly one valid literal root key there is no parent traversal:
      // CFG1's path failure can only mean the leaf is absent, not malformed TOML.
      if (error.kind == TomlFailureKind.path) return _catalog.resolve<T>(id);
      if (error.kind == TomlFailureKind.type) {
        throw InvalidSettingOverride(id, error.message);
      }
      rethrow;
    }
    return _catalog.resolve<T>(id, globalOverrides: {id: value});
  }

  /// Validates the new value before editing. Explicit default-equal values stay
  /// present. CFG1 rejects unsupported existing values or scalar type changes.
  GlobalSettingsSnapshot setOverride(SettingId id, Object? value) {
    final validated = _catalog.definition(id).validate(value);
    final TomlDocument edited;
    try {
      edited = document.setScalar([id.value], validated);
    } on TomlException catch (error) {
      if (error.kind == TomlFailureKind.type) {
        throw InvalidSettingOverride(id, error.message);
      }
      rethrow;
    }
    return _withDocument(edited);
  }

  /// Removes a supported scalar override, never writes its default. This explicit
  /// removal can discard an invalid scalar; unsupported structures still fail.
  GlobalSettingsSnapshot resetOverride(SettingId id) {
    _catalog.definition(id);
    final TomlDocument edited;
    try {
      edited = document.removeScalar([id.value]);
    } on TomlException catch (error) {
      if (error.kind == TomlFailureKind.type) {
        throw InvalidSettingOverride(id, error.message);
      }
      rethrow;
    }
    return _withDocument(edited);
  }

  GlobalSettingsSnapshot _withDocument(TomlDocument edited) =>
      identical(edited, document)
      ? this
      : GlobalSettingsSnapshot._(_catalog, _baseline, edited);
}
