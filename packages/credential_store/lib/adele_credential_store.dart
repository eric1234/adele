import 'src/native.dart';

export 'src/failure.dart';

/// Internal host bridge, not a plugin API or an application credential service.
///
/// All operations are synchronous and may block on the OS keyring or a prompt.
/// Call them only on an operation isolate, never the Flutter UI isolate. The app
/// owns asynchronous dispatch (for example, `Isolate.run`), ordering, admission,
/// mutation verification, uncertain outcomes, and shutdown/draining.
abstract final class NativeCredentialStore {
  static const maximumBytes = maximumCredentialBytes;

  /// Whether this platform has an implemented backend, not keyring health.
  /// This getter performs no native call and does not initialize a store.
  static bool get isSupported => nativePlatformSupported;

  /// Returns null only for a successful lookup with no matching credential.
  /// Must run on an operation isolate.
  static String? read(String reference) =>
      invokeCredentials(1, reference, null).$2;

  /// Reads and validates the one credential internally, returning no secret.
  /// Must run on an operation isolate; this is not a metadata-only lookup.
  static bool contains(String reference) =>
      invokeCredentials(4, reference, null).$1;

  /// Stores nonempty, NUL-free, valid Unicode encoded as at most 2560 UTF-8 bytes.
  /// Must run on an operation isolate. A failure may have an uncertain outcome.
  static void write(String reference, String secret) {
    invokeCredentials(2, reference, secret);
  }

  /// Deletes only the exact reference. An already absent item is a no-op.
  /// Must run on an operation isolate. A failure may have an uncertain outcome.
  static void delete(String reference) {
    invokeCredentials(3, reference, null);
  }
}
