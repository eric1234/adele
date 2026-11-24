/// Interpreted-only access to one record field's current form draft.
library;

/// Reads the field's scalar, a read-only map of its declared scalar properties,
/// or null when unset. No other record fields are accessible through this map.
Object? readSettingsFieldValue() => _unavailable();
int readSettingsFieldRevision() => _unavailable();
bool settingsFieldEditingEnabled() => _unavailable();
String? readSettingsFieldError() => _unavailable();

/// Replaces the field with a scalar or one complete map of declared properties.
/// Returns null on acceptance. A rejection is bounded display text, not an
/// exception or permission to retry against a newer revision automatically.
String? proposeSettingsFieldValue(int revision, Object? value) =>
    _unavailable();

/// As above, with copied, nonpersistent context for the owning form behavior.
/// A rejected proposal publishes neither the value nor its context. At most
/// 32 strings of at most 128 UTF-16 code units each; no handles or callbacks.
String? proposeSettingsFieldValueWithContext(
  int revision,
  Object? value,
  List<String> context,
) => _unavailable();

Never _unavailable() =>
    throw UnsupportedError('Interpreted Settings field editor bridge only.');
