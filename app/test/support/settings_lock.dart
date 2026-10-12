import 'dart:io';

// Dart's POSIX locks coordinate processes, not isolates in the same process.
void main(List<String> arguments) {
  final handle = File(arguments.single).openSync(mode: FileMode.append);
  try {
    handle.lockSync(FileLock.blockingExclusive);
    stdout.writeln('locked');
    if (stdin.readLineSync() != 'release') {
      throw StateError('Expected lock release command.');
    }
    handle.unlockSync();
  } finally {
    handle.closeSync();
  }
}
