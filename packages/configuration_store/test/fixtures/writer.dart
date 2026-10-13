import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';

import '../support.dart';

void main(List<String> arguments) {
  final settings = ConfigurationStore(rootsAt(arguments[0]));
  final store = arguments.length > 3
      ? settings.recordFile(collectionId: 'providers', recordId: arguments[3])
      : settings;
  final mode = arguments[1];
  if (mode == 'probe') {
    final lock = File(store.lockPath).openSync(mode: FileMode.append);
    try {
      try {
        lock.lockSync();
        stdout.writeln('unlocked');
        lock.unlockSync();
      } on FileSystemException catch (error) {
        // Linux fcntl reports EACCES or EAGAIN for a held advisory lock.
        if (error.osError?.errorCode != 11 && error.osError?.errorCode != 13) {
          rethrow;
        }
        stdout.writeln('locked');
      }
    } finally {
      lock.closeSync();
    }
    return;
  }

  final snapshot = store.load();
  final edited = snapshot.document.setScalar([
    'value',
  ], int.parse(arguments[2]));
  stdout.writeln('loaded');
  if (stdin.readLineSync() != 'save') throw StateError('Expected save command');
  stdout.writeln('saving');
  try {
    void pause(File _) {
      stdout.writeln('staged');
      if (stdin.readLineSync() != 'publish') {
        throw StateError('Expected publish command');
      }
    }

    IOOverrides.runWithIOOverrides(
      () => mode.contains('delete')
          ? store.delete(snapshot)
          : store.save(snapshot, edited),
      StagingOverrides(
        beforeRename: mode == 'pause' ? pause : null,
        beforeDelete: mode == 'pause-delete' ? pause : null,
      ),
    );
    stdout.writeln('committed');
  } on ConfigurationConflictException {
    stdout.writeln('conflict');
  }
}
