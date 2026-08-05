import 'dart:convert';
import 'dart:io';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

final class WorkspaceDemoFileService implements WorkspaceDemoService {
  WorkspaceDemoFileService(Directory developmentRoot)
    : _root = _canonicalDirectory(developmentRoot);

  final Directory _root;

  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    final String path = await _confinedPath(directory, expectedDirectory: true);
    final List<DirectoryEntry> entries = <DirectoryEntry>[];
    await for (final FileSystemEntity entity in Directory(
      path,
    ).list(followLinks: false)) {
      final FileSystemEntityType type = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      final DirectoryEntryKind? kind = switch (type) {
        FileSystemEntityType.directory => DirectoryEntryKind.directory,
        FileSystemEntityType.file => DirectoryEntryKind.file,
        _ => null,
      };
      if (kind == null) continue;
      entries.add(
        DirectoryEntry(
          resource: ResourceRef(uri: File(entity.path).absolute.uri),
          name: _basename(entity.path),
          kind: kind,
        ),
      );
    }
    entries.sort((DirectoryEntry left, DirectoryEntry right) {
      final int kindOrder = left.kind.index.compareTo(right.kind.index);
      if (kindOrder != 0) return kindOrder;
      final int folded = left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      );
      return folded != 0 ? folded : left.name.compareTo(right.name);
    });
    return DirectoryListing(directory: directory, entries: entries);
  }

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) async {
    final String path = await _confinedPath(file, expectedDirectory: false);
    try {
      final List<int> bytes = await File(path).readAsBytes();
      return TextFileContents(
        resource: file,
        text: utf8.decode(bytes, allowMalformed: false),
      );
    } on FormatException {
      throw WorkspaceDemoFailure(
        code: 'not_text',
        message: 'The requested file is not valid UTF-8 text.',
        details: <String, Object?>{'resourceUri': file.uri.toString()},
      );
    } on FileSystemException {
      throw WorkspaceDemoFailure(
        code: 'unreadable',
        message: 'The requested file could not be read.',
        details: <String, Object?>{'resourceUri': file.uri.toString()},
      );
    }
  }

  Future<String> _confinedPath(
    ResourceRef resource, {
    required bool expectedDirectory,
  }) async {
    if (resource.uri.scheme != 'file') {
      throw WorkspaceDemoFailure(
        code: 'unsupported_scheme',
        message: 'Only file resources are supported.',
        details: const {},
      );
    }
    final String requested = File.fromUri(resource.uri).absolute.path;
    final FileSystemEntityType type = await FileSystemEntity.type(
      requested,
      followLinks: true,
    );
    if (type == FileSystemEntityType.notFound) {
      throw WorkspaceDemoFailure(
        code: 'not_found',
        message: 'The requested resource does not exist.',
        details: const {},
      );
    }
    final String canonical = type == FileSystemEntityType.directory
        ? Directory(requested).resolveSymbolicLinksSync()
        : File(requested).resolveSymbolicLinksSync();
    final String rootPath = _root.path;
    if (canonical != rootPath &&
        !canonical.startsWith('$rootPath${Platform.pathSeparator}')) {
      throw WorkspaceDemoFailure(
        code: 'outside_development_root',
        message: 'The requested resource is outside the development root.',
        details: const {},
      );
    }
    if (expectedDirectory && type != FileSystemEntityType.directory) {
      throw const WorkspaceDemoFailure(
        code: 'not_a_directory',
        message: 'The requested resource is not a directory.',
        details: {},
      );
    }
    if (!expectedDirectory && type != FileSystemEntityType.file) {
      throw const WorkspaceDemoFailure(
        code: 'not_a_file',
        message: 'The requested resource is not a regular file.',
        details: {},
      );
    }
    return canonical;
  }
}

Directory _canonicalDirectory(Directory directory) {
  return Directory(directory.absolute.resolveSymbolicLinksSync());
}

String _basename(String path) {
  final List<String> parts = path.split(Platform.pathSeparator);
  return parts.lastWhere((String part) => part.isNotEmpty);
}
