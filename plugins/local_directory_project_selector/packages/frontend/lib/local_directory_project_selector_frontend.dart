import 'package:adele_ui/directory_picker_bridge.dart';

/// Returns a directory URI string, or null when the native picker is cancelled.
Future<String?> selectProject() async {
  final String? path = await pickDirectory();
  if (path == null) return null;
  if (path.isEmpty) {
    throw StateError('The directory picker returned an empty path.');
  }

  // dart_eval defaults Uri.directory to POSIX, even on a Windows host.
  final bool windows =
      path.startsWith(r'\\') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path);
  final Uri uri = Uri.directory(path, windows: windows).normalizePath();
  if (uri.scheme != 'file' || !uri.isAbsolute || !uri.hasAbsolutePath) {
    throw StateError('The directory picker returned a relative path.');
  }
  return uri.toString();
}
