import 'dart:async';
import 'dart:convert';
import 'dart:io';

const captureBlocks = 3200;

String captureBlock(String stream, int index) =>
    '$stream:${index.toString().padLeft(4, '0')}:${'x' * 4080}\n';

String captureMarker(String stream, String stage) =>
    '$stream:$stage\r\u001b[32m\u03bb\u{1f680}\u001b[0m\n';

String captureBulk(String stream) {
  final text = StringBuffer(captureMarker(stream, 'START'));
  for (var index = 0; index < captureBlocks; index++) {
    if (index == captureBlocks ~/ 2) {
      text.write(captureMarker(stream, 'MIDDLE'));
    }
    text.write(captureBlock(stream, index));
  }
  return text.toString();
}

/// The socket is an external test handshake, never an output transport.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 && arguments.last == 'presentation') {
    await _presentation(int.parse(arguments.first));
    return;
  }
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    int.parse(arguments.single),
  ).timeout(const Duration(seconds: 30));
  final releases = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  Future<void> gate(String stage, String release) async {
    socket.writeln('$stage:$pid:${Directory.current.path}');
    await socket.flush();
    if (!await releases.moveNext().timeout(const Duration(seconds: 90)) ||
        releases.current != release) {
      throw StateError('Expected $release at $stage.');
    }
  }

  await gate('connected', 'produce');
  stdout.write(captureMarker('stdout', 'START'));
  stderr.write(captureMarker('stderr', 'START'));
  await stdout.flush();
  await stderr.flush();
  await gate('started', 'bulk');
  for (final stream in ['stdout', 'stderr']) {
    final sink = stream == 'stdout' ? stdout : stderr;
    for (var index = 0; index < captureBlocks; index++) {
      if (index == captureBlocks ~/ 2) {
        sink.write(captureMarker(stream, 'MIDDLE'));
      }
      sink.write(captureBlock(stream, index));
      // Bound the fixture's own pending writes without forcing one host SQLite
      // transaction per 4 KiB application write.
      if (index % 32 == 31) await sink.flush();
    }
    await sink.flush();
  }
  await gate('bulk', 'late');
  stdout.write(captureMarker('stdout', 'LATE'));
  stderr.write(captureMarker('stderr', 'LATE'));
  await stdout.flush();
  await stderr.flush();
  await gate('late', 'hidden');
  stdout.write(captureMarker('stdout', 'HIDDEN'));
  stderr.write(captureMarker('stderr', 'HIDDEN'));
  await stdout.flush();
  await stderr.flush();
  await gate('hidden', 'exit');
  await releases.cancel();
  socket.destroy();
}

// The normal application proof needs observable intermediate states, not the
// independent full-capture test's multi-megabyte throughput workload above.
Future<void> _presentation(int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final releases = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  Future<void> gate(String stage, String release) async {
    socket.writeln('$stage:$pid:${Directory.current.path}');
    await socket.flush();
    if (!await releases.moveNext().timeout(const Duration(seconds: 90)) ||
        releases.current != release) {
      throw StateError('Expected $release at $stage.');
    }
  }

  await gate('connected', 'produce');
  stdout.write(
    'T3B_BEGIN\nT3B_PID=$pid\n\u001b[31mT3B_RED\u001b[0m\n'
    'obsolete status\rT3B_CR\u001b[K\nT3B_PART',
  );
  await stdout.flush();
  await gate('started', 'middle');
  stdout.write('-continued\n');
  for (var index = 0; index < 1200; index++) {
    if (index == 560) stdout.write('T3B_MIDDLE\n');
    stdout.write('T3B_ROW_${index.toString().padLeft(4, '0')}:${'x' * 48}\n');
    if (index % 64 == 63) await stdout.flush();
  }
  stdout.write('T3B_BULK_END\n');
  await stdout.flush();
  stderr.write('T3B_ERR_MIDDLE\n');
  await stderr.flush();
  await gate('middle', 'late');
  stdout.write('\u001b[32mT3B_LATE\u001b[0m\nT3B_LATE_PART');
  await stdout.flush();
  await gate('late', 'hidden');
  stdout.write('-hidden\nT3B_HIDDEN\n');
  await stdout.flush();
  stderr.write('T3B_ERR_HIDDEN\n');
  await stderr.flush();
  await gate('hidden', 'closed');
  stdout.write('T3B_AFTER_CLOSE\n');
  await stdout.flush();
  await gate('closed', 'exit');
  await releases.cancel();
  socket.destroy();
  exitCode = 23;
}
