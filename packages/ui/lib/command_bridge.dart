/// Writes at most 16,384 UTF-16 code units to the system clipboard for an
/// explicitly opted-in, admitted prepared Session Command operation.
///
/// Returns true only after the native write succeeds, or false if the platform
/// cannot copy the text. Invalid or retired access throws. This never reads the
/// clipboard. A write already submitted to the OS cannot be recalled.
Future<bool> writeCommandClipboard(String text) {
  throw UnsupportedError('Interpreted frontend bridge only.');
}

/// Shows bounded, selectable, nonmodal feedback for an explicitly opted-in
/// prepared Session Command. No callbacks or authority outlive the operation.
/// Messages are limited to 16,384 UTF-16 code units and are never logged.
void showCommandFeedback(String message) {
  throw UnsupportedError('Interpreted frontend bridge only.');
}
