import 'dart:async';

// The pin has no StreamIterator and its Stream.single getter is not executable.
// reduce rejects empty EOF, waits for successful EOF, and cancels on any extra.
Future<String> readPreparedHandoff(Stream<String> completion) {
  return completion
      .map((String path) {
        final windows = RegExp(
          r'^[a-zA-Z]:[\\/]|^\\\\[^\\]+\\[^\\]+\\',
        ).hasMatch(path);
        final location = Uri.file(path, windows: windows);
        final segments = location.pathSegments;
        if (path.isEmpty ||
            path.contains('\u0000') ||
            (!windows && !path.startsWith('/')) ||
            !location.hasAbsolutePath ||
            segments.isEmpty ||
            segments.last != 'README.md') {
          throw const FormatException('Invalid evaluation handoff completion.');
        }
        return path;
      })
      .reduce((String first, String extra) {
        throw const FormatException('Multiple evaluation handoff completions.');
      });
}
