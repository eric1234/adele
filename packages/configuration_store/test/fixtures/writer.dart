import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';

import '../support.dart';

Future<void> main(List<String> arguments) async {
  final settings = ConfigurationStore(rootsAt(arguments[0]));
  final store = arguments.length > 3
      ? settings.recordFile(
          collectionId: arguments.length > 4 ? arguments[4] : 'providers',
          recordId: arguments[3],
        )
      : settings;
  final mode = arguments[1];
  if (mode == 'list' || mode == 'first-list' || mode == 'opening-list') {
    void scan() {
      stdout.writeln('unlocked');
      if (stdin.readLineSync() != 'scan') throw StateError('Expected scan');
    }

    stdout.writeln('listing');
    final entries = await IOOverrides.runWithIOOverrides(
      () => settings.listCollection('providers'),
      StagingOverrides(
        beforeLock: () => stdout.writeln('waiting'),
        missingLock: mode == 'opening-list' ? scan : null,
        afterMissingLock: mode == 'first-list' ? scan : null,
      ),
    );
    stdout.writeln('listed:${entries.length}');
    return;
  }
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
          : mode.contains('create')
          ? store.create(edited)
          : store.save(snapshot, edited),
      StagingOverrides(
        beforeRename: mode.startsWith('pause') && !mode.contains('delete')
            ? pause
            : null,
        beforeDelete: mode == 'pause-delete' ? pause : null,
      ),
    );
    stdout.writeln('committed');
  } on ConfigurationConflictException {
    stdout.writeln('conflict');
  } on ConfigurationLimitException {
    stdout.writeln('limit');
  }
}
