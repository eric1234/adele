import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Usage: <lock-file> <ready-file>');
    exitCode = 64;
    return;
  }
  final RandomAccessFile lockHandle = await File(
    arguments[0],
  ).open(mode: FileMode.append);
  var locked = false;
  try {
    await lockHandle.lock(FileLock.blockingExclusive);
    locked = true;
    await File(arguments[1]).writeAsString('ready', flush: true);
    await stdin.first;
  } finally {
    try {
      if (locked) await lockHandle.unlock();
    } finally {
      await lockHandle.close();
    }
  }
}
