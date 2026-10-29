/// Bounded failure categories. No native diagnostic or secret is retained.
enum NativeCredentialFailureKind {
  invalidReference,
  invalidSecret,
  unavailable,
  failed,
  corruptData,
}

/// A deliberately redacted error without a native cause or input payload.
final class NativeCredentialFailure implements Exception {
  const NativeCredentialFailure(this.kind);

  final NativeCredentialFailureKind kind;

  @override
  String toString() => 'NativeCredentialFailure(${kind.name})';
}
