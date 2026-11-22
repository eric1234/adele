/// Interpreted-only access to one record field's current form draft.
library;

Object? readSettingsFieldValue() => _unavailable();
int readSettingsFieldRevision() => _unavailable();
bool settingsFieldEditingEnabled() => _unavailable();
String? readSettingsFieldError() => _unavailable();

/// Returns null on acceptance. A rejection is bounded display text, not an
/// exception or permission to retry against a newer revision automatically.
String? proposeSettingsFieldValue(int revision, Object? value) =>
    _unavailable();

Never _unavailable() =>
    throw UnsupportedError('Interpreted Settings field editor bridge only.');
