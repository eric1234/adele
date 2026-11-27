import 'dart:io';

/// The Flutter SDK's bundled compiler and its matching standalone AOT runtime.
({String dart, String aotRuntime}) backendTestSdk() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return _executables(executable);
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return _executables(executable);
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}

({String dart, String aotRuntime}) _executables(File dart) => (
  dart: dart.path,
  aotRuntime: dart.parent.uri
      .resolve(Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime')
      .toFilePath(),
);
