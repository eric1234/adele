import 'dart:convert';
import 'dart:io';

import '../../../plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart'
    as backend;

// This AOT fixture runs the production entrypoint. Only its file-write completion
// is gated; collection, host path lookup, routing and cleanup stay production code.
Future<void> main(List<String> arguments, Object? bootstrapMessage) =>
    IOOverrides.runWithIOOverrides(
      () => backend.main(arguments, bootstrapMessage),
      _WriteOverrides(),
    );

final class _WriteOverrides extends IOOverrides {
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (![
      'evidence.json',
      'summary.json',
      'README.md',
    ].contains(file.uri.pathSegments.last)) {
      return file;
    }
    final control = super.createFile(
      '${file.parent.parent.parent.path}/.evaluator-write-gate.json',
    );
    if (!control.existsSync()) return file;
    final config = jsonDecode(control.readAsStringSync()) as Map;
    if (config['file'] != file.uri.pathSegments.last) return file;
    return _GatedFile(file, config['port'] as int);
  }
}

final class _GatedFile implements File {
  _GatedFile(this.file, this.port);

  final File file;
  final int port;

  @override
  File get absolute => file.absolute;

  @override
  String get path => file.path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    try {
      socket.writeln(jsonEncode({'path': file.path, 'pid': pid}));
      await socket.flush();
      final command = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      if (command != 'release') {
        throw const FileSystemException(
          'Injected backend publication failure.',
        );
      }
      return file;
    } finally {
      socket.destroy();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
