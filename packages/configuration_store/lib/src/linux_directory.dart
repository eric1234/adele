import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Dart's listSync eagerly materializes a whole directory. Linux transactions
// need a bounded synchronous read: awaiting a stream while holding a
// process-scoped lock would let another operation in the owning isolate enter.
// Return at most maximum + 1 names so the caller can diagnose overflow.
List<String> linuxDirectoryNames(String path, int maximum) {
  if (path.contains('\u0000')) throw ArgumentError.value(path, 'path');
  final names = <String>[];
  // Resolve all symbols before relying on the thread-local errno value.
  final open = _open;
  final read = _read;
  final close = _close;
  final errno = _errno;
  final nativePath = path.toNativeUtf8();
  final Pointer<Void> directory;
  try {
    directory = open(nativePath);
    if (directory == nullptr) {
      throw FileSystemException(
        'Cannot open directory',
        path,
        OSError('', errno().value),
      );
    }
  } finally {
    malloc.free(nativePath);
  }
  try {
    while (true) {
      errno().value = 0;
      final entry = read(directory);
      if (entry == nullptr) {
        final error = errno().value;
        if (error != 0) {
          throw FileSystemException(
            'Cannot read directory',
            path,
            OSError('', error),
          );
        }
        return names;
      }
      final name = entry.ref.name;
      final bytes = <int>[];
      for (var i = 0; i < 256 && name[i] != 0; i++) {
        bytes.add(name[i]);
      }
      if (bytes.length == 256) {
        throw FileSystemException(
          'Unsupported Linux directory entry length',
          path,
        );
      }
      // Match Dart I/O's replacement decoding for non-UTF-8 Unix filenames.
      final value = utf8.decode(bytes, allowMalformed: true);
      if (value == '.' || value == '..') continue;
      names.add(value);
      if (names.length > maximum) return names;
    }
  } finally {
    if (close(directory) != 0) {
      throw FileSystemException(
        'Cannot close directory',
        path,
        OSError('', errno().value),
      );
    }
  }
}

// Linux readdir64's fixed-width layout is independent of ino_t/off_t size.
final class _Dirent64 extends Struct {
  @Uint64()
  external int inode;
  @Int64()
  external int offset;
  @Uint16()
  external int length;
  @Uint8()
  external int type;
  @Array(256)
  external Array<Uint8> name;
}

final _libc = DynamicLibrary.process();
final _open = _libc
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('opendir');
final _read = _libc
    .lookupFunction<
      Pointer<_Dirent64> Function(Pointer<Void>),
      Pointer<_Dirent64> Function(Pointer<Void>)
    >('readdir64');
final _close = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'closedir',
    );
final _errno = _libc
    .lookupFunction<Pointer<Int> Function(), Pointer<Int> Function()>(
      '__errno_location',
      isLeaf: true,
    );
