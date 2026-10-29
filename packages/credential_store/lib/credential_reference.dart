import 'dart:math';

/// A nonsecret, persistable association identity, not credential access authority.
///
/// This internal host value is independent of record, plugin, account, display
/// name and runtime generation. Importing it does not import native storage.
final class CredentialReference {
  CredentialReference._(this.value);

  factory CredentialReference.generate() {
    final random = Random.secure();
    return CredentialReference._(
      'cred1_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}',
    );
  }

  factory CredentialReference.parse(String value) {
    if (value.length != 38 || !_format.hasMatch(value)) {
      throw const FormatException('Invalid credential reference.');
    }
    return CredentialReference._(value);
  }

  static final _format = RegExp(r'^cred1_[0-9a-f]{32}$');
  final String value;

  @override
  bool operator ==(Object other) =>
      other is CredentialReference && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
