import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

const binaryStderr = <int>[0, 255, 128, 13, 10, 27, 91, 50, 74];

Future<void> main(List<String> arguments) async {
  switch (arguments.first) {
    case 'echo':
      stderr.add(binaryStderr);
      await Future.wait<void>([stdout.addStream(stdin), stderr.flush()]);
      await stdout.flush();
      exitCode = arguments.length > 1 ? int.parse(arguments[1]) : 0;
    case 'empty':
      await stdin.drain<void>();
    case 'cwd':
      await stdin.drain<void>();
      stdout.write(
        jsonEncode({
          'cwd': Directory.current.path,
          'pwd': Platform.environment['PWD'],
          'term': Platform.environment['TERM'],
          'environment': Platform.environment,
          'arguments': arguments.skip(1).toList(),
        }),
      );
      await stdout.flush();
    case 'outputs':
      // Fill both pipes before accepting input: a sequential collector/writer
      // deadlocks rather than accidentally passing a small pipe-sized fixture.
      await Future.wait<void>([
        _output(stdout, int.parse(arguments[1])),
        _output(stderr, int.parse(arguments[2])),
      ]);
      final inputLength = await stdin.fold<int>(
        0,
        (size, bytes) => size + bytes.length,
      );
      if (arguments.length > 3 && inputLength != int.parse(arguments[3])) {
        exitCode = 91;
      }
    case 'refuse':
      final close = DynamicLibrary.open(
        'libc.so.6',
      ).lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      close(0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    case 'wait':
      await Future<void>.delayed(const Duration(seconds: 60));
    case 'tree':
    case 'overflow-tree':
    case 'exit-tree':
    case 'escaped-tree':
      ProcessSignal.sigterm.watch().listen((_) {});
      final ready = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connected = ready.first;
      final childArguments = [
        Platform.resolvedExecutable,
        Platform.script.toFilePath(),
        'holder',
        '${ready.port}',
      ];
      await Process.start(
        arguments.first == 'escaped-tree'
            ? '/usr/bin/setsid'
            : childArguments.removeAt(0),
        arguments.first == 'escaped-tree'
            ? ['--', ...childArguments]
            : childArguments,
        mode: ProcessStartMode.inheritStdio,
      );
      final socket = await connected;
      final childPid = await utf8.decoder.bind(socket).join();
      await ready.close();
      await File(arguments[1]).writeAsString('$pid $childPid');
      if (arguments.first == 'exit-tree' || arguments.first == 'escaped-tree') {
        exit(23);
      }
      if (arguments.first == 'overflow-tree') {
        await _output(
          arguments[2] == 'stdout' ? stdout : stderr,
          3 * 1024 * 1024,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 60));
    case 'holder':
      ProcessSignal.sigterm.watch().listen((_) {});
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        int.parse(arguments[1]),
      );
      socket.write('$pid');
      await socket.flush();
      await socket.close();
      await Future<void>.delayed(const Duration(seconds: 60));
    default:
      throw ArgumentError.value(arguments.first);
  }
}

Future<void> _output(IOSink sink, int count) async {
  final bytes = Uint8List.fromList(
    List<int>.generate(64 * 1024, (i) => i % 256),
  );
  for (var offset = 0; offset < count; offset += bytes.length) {
    final remaining = count - offset;
    sink.add(
      remaining < bytes.length
          ? Uint8List.sublistView(bytes, 0, remaining)
          : bytes,
    );
    await sink.flush();
  }
}
