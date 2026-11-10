import 'dart:async';

/// Accepts one absolute README path only after successful stream completion.
/// The caller owns [completion] and may cancel it while this helper is waiting.
/// StreamIterator cancellation is indistinguishable from EOF: callers must
/// revalidate their captured lifetime/cancellation state after awaiting this
/// helper, before publishing or using the returned path.
Future<String> readSessionEvaluationHandoff(
  StreamIterator<String> completion,
) async {
  if (!await completion.moveNext()) {
    throw const FormatException('Missing evaluation handoff completion.');
  }
  final path = completion.current;
  final windows = RegExp(
    r'^[a-zA-Z]:[\\/]|^\\\\[^\\]+\\[^\\]+\\',
  ).hasMatch(path);
  final Uri location;
  try {
    location = Uri.file(path, windows: windows);
  } on FormatException {
    throw const FormatException('Invalid evaluation handoff completion.');
  }
  if (path.isEmpty ||
      path.contains('\u0000') ||
      (!windows && !path.startsWith('/')) ||
      !location.hasAbsolutePath ||
      location.pathSegments.lastOrNull != 'README.md') {
    throw const FormatException('Invalid evaluation handoff completion.');
  }
  if (await completion.moveNext()) {
    throw const FormatException('Multiple evaluation handoff completions.');
  }
  return path;
}
