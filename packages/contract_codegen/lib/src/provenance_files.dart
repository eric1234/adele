import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Linux invocation-local race evidence. Not an incremental freshness key.
/// Every content input additionally has an independently checked SHA-256.
final class ProvenanceFiles {
  final stamps = <String, String>{};
  final reads = <String>{};

  void watch(String path, {bool read = false, bool listing = false}) {
    if (path.length > 1 && path.endsWith('/')) {
      return watch(
        path.substring(0, path.length - 1),
        read: read,
        listing: listing,
      );
    }
    if (!path.startsWith('/') ||
        Uri.file(path).normalizePath().toFilePath() != path) {
      throw UnsupportedError('Noncanonical provenance input: $path');
    }
    if (path != '/') {
      final parent = File(path).parent.path;
      if (!stamps.containsKey(parent)) watch(parent);
    }
    final previous = stamps[path];
    if (previous == null ||
        listing &&
            previous.startsWith('dir:') &&
            !previous.endsWith(':listing')) {
      final info = linuxLstat(path);
      if (info != null && info.mode & 0xf000 == 0x4000 && path != '/') {
        // Renaming an ancestor away and back doesn't touch descendant inodes.
        // Ignore unrelated churn only in nonswappable system anchors.
        final parent = linuxLstat(File(path).parent.path)!;
        listing = listing || parent.uid != 0 || parent.mode & 0x12 != 0;
      }
      final stamp = _stamp(path, info, listing: listing);
      if (previous != null && !stamp.startsWith('$previous:')) _changed(path);
      stamps[path] = stamp;
      if (stamp == 'missing') {
        // A missing leaf alone cannot detect create/delete. Guard the nearest
        // existing parent even when several intermediate components are absent.
        var parent = File(path).parent.path;
        while (stamps[parent] == 'missing') {
          parent = File(parent).parent.path;
        }
        watch(parent, listing: true);
      }
    }
    if (read && stamps[path]!.startsWith('file:')) reads.add(path);
  }

  void verify() {
    for (final entry in stamps.entries) {
      final actual = _stamp(
        entry.key,
        linuxLstat(entry.key),
        listing:
            entry.value.startsWith('dir:') && entry.value.endsWith(':listing'),
      );
      if (actual != entry.value) _changed(entry.key);
    }
  }

  void merge(Map<String, String> other) {
    for (final entry in other.entries) {
      final old = stamps[entry.key];
      if (old != null && old != entry.value) {
        if (old.startsWith('${entry.value}:') && old.endsWith(':listing')) {
          continue;
        }
        if (!entry.value.startsWith('$old:') ||
            !entry.value.endsWith(':listing')) {
          _changed(entry.key);
        }
      }
      stamps[entry.key] = entry.value;
    }
  }

  static Never _changed(String path) => throw StateError(
    'Contract generation input changed; restart maintained preparation: $path',
  );
}

// Dart FileStat loses sub-millisecond ctime, including a fast edit/restore.
// Use the fixed-width Linux statx UAPI (not the ABI-specific libc stat struct).
// The two small scratch buffers are reused synchronously for this isolate.
final _linux = _LinuxStatx();

typedef LinuxPathStat = ({
  int deviceMajor,
  int deviceMinor,
  int inode,
  int mode,
  int size,
  int nlink,
  int uid,
  int ctimeNs,
  int mtimeNs,
});

/// No-follow stat, or null for a missing component. Unlike dart:io FileStat,
/// preserves Linux's inode, link count and nanosecond change times.
LinuxPathStat? linuxLstat(String path) => _linux.read(path);

String _stamp(String path, LinuxPathStat? stat, {required bool listing}) {
  if (stat == null) return 'missing';
  final kind = switch (stat.mode & 0xf000) {
    0x4000 => 'dir',
    0x8000 => 'file',
    _ => throw UnsupportedError('Linked or special provenance input: $path'),
  };
  final identity =
      '$kind:${stat.deviceMajor}:${stat.deviceMinor}:${stat.inode}:${stat.mode}';
  if (kind == 'dir' && !listing) return identity;
  return '$identity:${stat.size}:${stat.ctimeNs}:${stat.mtimeNs}${kind == 'dir' ? ':listing' : ''}';
}

final class _LinuxStatx {
  final _libc = DynamicLibrary.process();
  late final _calloc = _libc
      .lookupFunction<
        Pointer<Uint8> Function(Size, Size),
        Pointer<Uint8> Function(int, int)
      >('calloc');
  late final _statx = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>)
      >('statx');
  late final _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  late final _path = _calloc(4096, 1);
  late final _buf = _calloc(256, 1);

  LinuxPathStat? read(String path) {
    final bytes = utf8.encode(path);
    if (bytes.length >= 4096 || bytes.contains(0)) {
      throw UnsupportedError('Unsupported provenance path: $path');
    }
    _path.asTypedList(bytes.length + 1)
      ..setRange(0, bytes.length, bytes)
      ..[bytes.length] = 0;
    if (_statx(-100, _path, 0x100, 0x7ff, _buf) != 0) {
      final errno = _errno().value;
      if (errno == 2 || errno == 20) return null;
      throw UnsupportedError('statx failed ($errno): $path');
    }
    final words = _buf.cast<Uint32>();
    // Type/mode, link count, uid, mtime, ctime, inode and size. Never atime.
    if ((words[0] & 0x3cf) != 0x3cf) {
      throw UnsupportedError('Incomplete statx: $path');
    }
    final wide = _buf.cast<Uint64>();
    return (
      deviceMajor: words[34],
      deviceMinor: words[35],
      inode: wide[4],
      mode: _buf.cast<Uint16>()[14],
      size: wide[5],
      nlink: words[4],
      uid: words[5],
      ctimeNs: wide[12] * 1000000000 + words[26],
      mtimeNs: wide[14] * 1000000000 + words[30],
    );
  }
}
