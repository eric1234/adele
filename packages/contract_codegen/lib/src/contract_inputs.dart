import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/file_source.dart';
import 'package:analyzer/source/source.dart';
// The context's source factory is intentionally tied to analyzer 8.4.1.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Filesystem evidence for one authoritative contract generation.
///
/// Only the exact generated sibling is excluded. The caller owns its overlay,
/// must use [resources] underneath it, and must call [validate] before publishing
/// a receipt. Unsupported discovery or filesystem operations decline caching,
/// without replacing the ordinary analyzer operation or its diagnostics.
final class ContractInputs {
  ContractInputs({required String excludedOutput})
    : _excludedOutput = p.normalize(p.absolute(excludedOutput));

  static final _physical = PhysicalResourceProvider.INSTANCE;

  final String _excludedOutput;
  final Map<String, String> _observations = {};
  final Map<String, String> _evidence = {};
  bool _cacheable = true;
  String? _changedPath;

  late final ResourceProvider resources = _Resources(this);

  Map<String, String> get observations => Map.unmodifiable(_observations);

  bool get cacheable => _cacheable && _changedPath == null;

  /// Discover inactive URI alternatives as well as the analyzer's selected graph.
  /// Configuration, options includes and SDK metadata are recorded by the actual
  /// context's filesystem accesses, not a second approximation of its discovery.
  void discover(AnalysisContext context, String sourcePath) {
    if (!cacheable) return;
    if (context is! DriverBasedAnalysisContext) {
      _cacheable = false;
      return;
    }
    var provider = context.resourceProvider;
    while (provider is OverlayResourceProvider) {
      provider = provider.baseProvider;
    }
    if (!identical(provider, resources)) {
      _cacheable = false;
      return;
    }
    try {
      final factory = context.driver.sourceFactory;
      final rootUri = factory.pathToUri(sourcePath);
      if (rootUri == null) {
        _cacheable = false;
        return;
      }
      final pending = <Source>[
        FileSource(resources.getFile(sourcePath), rootUri),
      ];
      void add(Source? containing, String? uri) {
        if (uri == null) {
          _cacheable = false;
          return;
        }
        final source = factory.resolveUri(containing, uri);
        if (source == null) {
          _cacheable = false;
        } else {
          pending.add(source);
        }
      }

      add(null, 'dart:core');
      add(null, 'dart:async');
      final visited = <String>{};
      while (pending.isNotEmpty && cacheable) {
        final source = pending.removeLast();
        final path = source.fullName;
        if (!p.isAbsolute(path) || p.normalize(path) != path) {
          _cacheable = false;
          break;
        }
        if (path == _excludedOutput || !visited.add(path)) {
          continue;
        }
        final canonicalUri = factory.pathToUri(path);
        if (canonicalUri == null) {
          _cacheable = false;
          break;
        }
        final file = resources.getFile(path);
        if (!file.exists) continue;
        final parsed = parseString(
          content: file.readAsStringSync(),
          path: path,
          throwIfDiagnostics: false,
        );
        if (parsed.errors.isNotEmpty) {
          _cacheable = false;
          break;
        }
        // Match analyzer's file: -> package:/dart: canonicalization, including
        // generated package-source fallback for relative imports.
        final containing = FileSource(file, canonicalUri);
        void directive(Directive value) {
          if (value is UriBasedDirective) {
            add(containing, value.uri.stringValue);
          } else if (value is PartOfDirective && value.uri != null) {
            add(containing, value.uri!.stringValue);
          }
          if (value is NamespaceDirective) {
            for (final alternative in value.configurations) {
              add(containing, alternative.uri.stringValue);
            }
          }
        }

        for (final value in parsed.unit.directives) {
          directive(value);
          if (value is LibraryDirective || value is PartOfDirective) {
            final comment = value.documentationComment;
            if (comment != null) {
              for (final docImport in comment.docImports) {
                directive(docImport.import);
              }
            }
          }
        }
      }
    } on _InputChanged {
      rethrow;
    } catch (_) {
      _cacheable = false;
    }
  }

  /// Recheck content and invocation-local metadata, including ctime. Metadata is
  /// not persisted: harmless timestamp changes between invocations are not inputs.
  /// [writtenOutputs] permits a caller-owned publication pass; those paths remain
  /// observations and affected contracts must be regenerated before certification.
  /// Aliases and directory inventories are never exempted.
  void validate({Set<String> writtenOutputs = const {}}) {
    if (_changedPath case final path?) _changed(path);
    if (!cacheable) return;
    for (final entry in _observations.entries) {
      final path = _decodeKey(entry.key).$2;
      if (writtenOutputs.contains(path)) continue;
      if (observe(entry.key) != entry.value) {
        _changed(path);
      }
    }
    for (final entry in _evidence.entries) {
      if (writtenOutputs.contains(entry.key)) continue;
      if (_snapshot(entry.key).evidence != entry.value) _changed(entry.key);
    }
  }

  /// Validate receipt key syntax without touching the filesystem.
  static void validateKey(String key) => _decodeKey(key);

  /// Re-evaluate one JSON-encoded [kind, absolutePath, ...] observation without
  /// constructing an analyzer context. Throws on malformed/unknown keys or races.
  static String observe(String key) => capture(key).value;

  /// Capture the value and its bracketed invocation evidence together, avoiding
  /// duplicate stat/canonical probes around each warm validation read.
  static ({String value, String stamp}) capture(String key) {
    final (kind, path, excluded) = _decodeKey(key);
    final ignoreDirectoryTimes =
        kind != 'directory' || p.dirname(excluded!) == path;
    final before = _stat(path, ignoreDirectoryTimes: ignoreDirectoryTimes);
    String value;
    try {
      value = switch (kind) {
        'read' =>
          sha256.convert(_physical.getFile(path).readAsBytesSync()).toString(),
        'file' => _physical.getFile(path).exists.toString(),
        'folder' => _physical.getFolder(path).exists.toString(),
        'type' => _types(path),
        'canonical' => _canonical(path),
        'directory' => _inventory(
          _physical.getFolder(path).getChildren(),
          excluded!,
        ),
        _ => throw FormatException('Unknown contract input kind: $kind'),
      };
    } on FileSystemException catch (error) {
      value = _failure(error);
    }
    if (_stat(path, ignoreDirectoryTimes: ignoreDirectoryTimes) != before) {
      throw _InputChanged(path);
    }
    return (value: value, stamp: before);
  }

  /// Invocation-only race evidence for a warm observation. Do not persist this
  /// stamp as cache identity. Existence/type probes do not depend on directory
  /// timestamps; inventories exclude the generated sibling's directory changes.
  static String stamp(String key) {
    final (kind, path, excluded) = _decodeKey(key);
    return _stat(
      path,
      ignoreDirectoryTimes: kind != 'directory' || p.dirname(excluded!) == path,
    );
  }

  static (String, String, String?) _decodeKey(String key) {
    final decoded = jsonDecode(key);
    if (decoded is! List ||
        decoded.length < 2 ||
        decoded[0] is! String ||
        decoded[1] is! String) {
      throw const FormatException('Invalid contract input observation');
    }
    final kind = decoded[0] as String;
    final path = decoded[1] as String;
    if (!const {
      'read',
      'file',
      'folder',
      'type',
      'canonical',
      'directory',
    }.contains(kind)) {
      throw FormatException('Unknown contract input kind: $kind');
    }
    if (!p.isAbsolute(path) || p.normalize(path) != path) {
      throw const FormatException('Contract input path must be absolute');
    }
    String? excluded;
    if (kind == 'directory') {
      if (decoded.length != 3 || decoded[2] is! String) {
        throw const FormatException('Invalid directory observation');
      }
      excluded = decoded[2] as String;
      if (!p.isAbsolute(excluded) || p.normalize(excluded) != excluded) {
        throw const FormatException('Excluded output path must be absolute');
      }
    } else if (decoded.length != 2) {
      throw const FormatException('Invalid contract input observation');
    }
    return (kind, path, excluded);
  }

  T _track<T>(
    String kind,
    String path,
    T Function() operation,
    String Function(T) encode,
  ) {
    if (!cacheable || path == _excludedOutput) return operation();
    if (!p.isAbsolute(path) || p.normalize(path) != path) {
      _cacheable = false;
      return operation();
    }
    late final ({String type, String canonical, String evidence}) before;
    String? directoryEvidence;
    try {
      before = _snapshot(path);
      if (kind == 'directory' && path != p.dirname(_excludedOutput)) {
        directoryEvidence = _stat(path);
      }
    } catch (_) {
      _cacheable = false;
      return operation();
    }
    final previous = _evidence[path];
    if (previous != null && previous != before.evidence) _changed(path);
    void finish(String? value) {
      late final ({String type, String canonical, String evidence}) after;
      String? afterDirectory;
      try {
        after = _snapshot(path);
        if (directoryEvidence != null) afterDirectory = _stat(path);
      } catch (_) {
        _cacheable = false;
        return;
      }
      if (before != after || directoryEvidence != afterDirectory) {
        _changed(path);
      }
      _evidence[path] = before.evidence;
      _store('type', path, before.type);
      _store('canonical', path, before.canonical);
      if (value != null) _store(kind, path, value);
    }

    late final T result;
    try {
      result = operation();
    } catch (error) {
      finish(kind == 'canonical' ? before.canonical : _failure(error));
      // Missing reads are reproducible negative probes. Other failures are not
      // assumed to be a complete account of permissions or decoding semantics.
      if (error is! FileSystemException ||
          io.FileSystemEntity.typeSync(path) !=
              io.FileSystemEntityType.notFound) {
        _cacheable = false;
      }
      rethrow;
    }
    String? value;
    try {
      value = encode(result);
    } on _InputChanged {
      rethrow;
    } catch (_) {
      _cacheable = false;
    }
    finish(value);
    return result;
  }

  T _read<T>(
    File file,
    T Function() operation, {
    bool metadataOnly = false,
  }) => _track('read', file.path, operation, (result) {
    // Metadata getters do not consume bytes. Reuse a prior digest only after
    // _track has checked the same invocation's stat/canonical evidence.
    if (metadataOnly) {
      final previous = _observations[jsonEncode(['read', file.path])];
      if (previous != null) return previous;
    }
    final bytes = file.readAsBytesSync();
    // Dart's FileStat timestamps have millisecond precision. A stat bracket
    // alone cannot bind a separately read string to the bytes being hashed.
    if (result is String) {
      late final String decoded;
      try {
        decoded = utf8.decode(bytes);
      } on FormatException {
        _changed(file.path);
      }
      if (decoded != result) _changed(file.path);
    }
    return sha256.convert(bytes).toString();
  });

  void _store(String kind, String path, String value) {
    final key = jsonEncode([
      kind,
      path,
      if (kind == 'directory') _excludedOutput,
    ]);
    final previous = _observations[key];
    if (previous != null && previous != value) _changed(path);
    _observations[key] = value;
  }

  Never _changed(String path) {
    _changedPath ??= path;
    throw _InputChanged(path);
  }

  ({String type, String canonical, String evidence}) _snapshot(String path) =>
      _state(path, ignoreDirectoryTimes: true);

  static String _types(String path) => jsonEncode([
    io.FileSystemEntity.typeSync(path, followLinks: false).toString(),
    io.FileSystemEntity.typeSync(path).toString(),
  ]);

  static String _canonical(String path) {
    try {
      return jsonEncode(['path', io.File(path).resolveSymbolicLinksSync()]);
    } on io.FileSystemException catch (error) {
      return jsonEncode(['error', error.osError?.errorCode]);
    }
  }

  static String _stat(String path, {bool ignoreDirectoryTimes = false}) =>
      _state(path, ignoreDirectoryTimes: ignoreDirectoryTimes).evidence;

  static ({String type, String canonical, String evidence}) _state(
    String path, {
    bool ignoreDirectoryTimes = false,
  }) {
    final stat = io.FileStat.statSync(path);
    final type = jsonEncode([
      io.FileSystemEntity.typeSync(path, followLinks: false).toString(),
      stat.type.toString(),
    ]);
    final canonical = _canonical(path);
    // Directory existence does not depend on unrelated children. Listings have
    // their own inventory and a short-lived metadata bracket while being read.
    final times =
        !(ignoreDirectoryTimes &&
            stat.type == io.FileSystemEntityType.directory);
    return (
      type: type,
      canonical: canonical,
      evidence: jsonEncode([
        type,
        canonical,
        stat.mode,
        if (times) ...[
          stat.modified.microsecondsSinceEpoch,
          stat.changed.microsecondsSinceEpoch,
          stat.size,
        ],
      ]),
    );
  }

  static String _inventory(List<Resource> children, String excluded) {
    final entries = [
      for (final child in children)
        if (child.path != excluded)
          [child.path, child is Folder ? 'folder' : 'file'],
    ]..sort((a, b) => a[0].compareTo(b[0]));
    return sha256.convert(utf8.encode(jsonEncode(entries))).toString();
  }

  static String _failure(Object error) => jsonEncode([
    'error',
    if (error is FileSystemException &&
        io.FileSystemEntity.typeSync(error.path) ==
            io.FileSystemEntityType.notFound)
      'missing'
    else
      error.runtimeType.toString(),
  ]);
}

final class _InputChanged extends StateError {
  _InputChanged(String path)
    : super('Contract input changed during generation: $path');
}

final class _Resources implements ResourceProvider {
  _Resources(this.inputs);

  final ContractInputs inputs;

  @override
  p.Context get pathContext => ContractInputs._physical.pathContext;

  @override
  File getFile(String path) =>
      _File(this, ContractInputs._physical.getFile(path));

  @override
  Folder getFolder(String path) =>
      _Folder(this, ContractInputs._physical.getFolder(path));

  @override
  Link getLink(String path) {
    inputs._cacheable = false;
    return ContractInputs._physical.getLink(path);
  }

  @override
  Resource getResource(String path) => wrap(
    inputs._track(
      'type',
      path,
      () => ContractInputs._physical.getResource(path),
      (_) => ContractInputs._types(path),
    ),
  );

  @override
  Folder? getStateLocation(String pluginId) {
    inputs._cacheable = false;
    final folder = ContractInputs._physical.getStateLocation(pluginId);
    return folder == null ? null : wrap(folder) as Folder;
  }

  Resource wrap(Resource resource) {
    if (resource is _Resource && identical(resource.provider, this)) {
      return resource;
    }
    if (resource is File) return _File(this, resource);
    if (resource is Folder) return _Folder(this, resource);
    inputs._cacheable = false;
    return resource;
  }
}

abstract class _Resource<T extends Resource> implements Resource {
  _Resource(this.provider, this.delegate);

  @override
  final _Resources provider;
  final T delegate;

  ContractInputs get inputs => provider.inputs;

  @override
  String get path => delegate.path;

  @override
  String get shortName => delegate.shortName;

  @override
  Folder get parent => provider.wrap(delegate.parent) as Folder;

  @override
  bool get exists => inputs._track(
    delegate is Folder ? 'folder' : 'file',
    path,
    () => delegate.exists,
    (value) => value.toString(),
  );

  @override
  int get hashCode => delegate.hashCode;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _Resource &&
      other.delegate == delegate;

  @override
  void delete() {
    inputs._cacheable = false;
    delegate.delete();
  }

  @override
  bool isOrContains(String path) => delegate.isOrContains(path);

  @override
  Resource resolveSymbolicLinksSync() => provider.wrap(
    inputs._track(
      'canonical',
      path,
      delegate.resolveSymbolicLinksSync,
      (resource) => jsonEncode(['path', resource.path]),
    ),
  );

  @override
  Uri toUri() => delegate.toUri();

  @override
  ResourceWatcher watch() {
    inputs._cacheable = false;
    return delegate.watch();
  }

  @override
  String toString() => delegate.toString();
}

final class _File extends _Resource<File> implements File {
  _File(super.provider, super.delegate);

  @override
  int get lengthSync =>
      inputs._read(delegate, () => delegate.lengthSync, metadataOnly: true);

  @override
  int get modificationStamp => inputs._read(
    delegate,
    () => delegate.modificationStamp,
    metadataOnly: true,
  );

  @override
  Uint8List readAsBytesSync() => inputs._track(
    'read',
    path,
    delegate.readAsBytesSync,
    (bytes) => sha256.convert(bytes).toString(),
  );

  @override
  String readAsStringSync() =>
      inputs._read(delegate, delegate.readAsStringSync);

  @override
  File copyTo(Folder parentFolder) {
    inputs._cacheable = false;
    return provider.wrap(delegate.copyTo(parentFolder)) as File;
  }

  @override
  File renameSync(String newPath) {
    inputs._cacheable = false;
    return provider.wrap(delegate.renameSync(newPath)) as File;
  }

  @override
  void writeAsBytesSync(List<int> bytes) {
    inputs._cacheable = false;
    delegate.writeAsBytesSync(bytes);
  }

  @override
  void writeAsStringSync(String content) {
    inputs._cacheable = false;
    delegate.writeAsStringSync(content);
  }
}

final class _Folder extends _Resource<Folder> implements Folder {
  _Folder(super.provider, super.delegate);

  @override
  bool get isRoot => delegate.isRoot;

  @override
  String canonicalizePath(String path) => delegate.canonicalizePath(path);

  @override
  bool contains(String path) => delegate.contains(path);

  @override
  Folder copyTo(Folder parentFolder) {
    inputs._cacheable = false;
    return provider.wrap(delegate.copyTo(parentFolder)) as Folder;
  }

  @override
  void create() {
    inputs._cacheable = false;
    delegate.create();
  }

  @override
  Resource getChild(String relPath) =>
      provider.getResource(canonicalizePath(relPath));

  @override
  File getChildAssumingFile(String relPath) =>
      provider.wrap(delegate.getChildAssumingFile(relPath)) as File;

  @override
  Folder getChildAssumingFolder(String relPath) =>
      provider.wrap(delegate.getChildAssumingFolder(relPath)) as Folder;

  @override
  List<Resource> getChildren() => inputs
      ._track(
        'directory',
        path,
        delegate.getChildren,
        (children) =>
            ContractInputs._inventory(children, inputs._excludedOutput),
      )
      .map(provider.wrap)
      .toList();
}
