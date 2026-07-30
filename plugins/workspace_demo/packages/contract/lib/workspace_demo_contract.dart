/// Experimental shared contract declarations for the workspace demo plugin.
library;

import 'dart:collection';

import 'package:adele_plugin_api/adele_plugin_api.dart';

enum DirectoryEntryKind { directory, file }

final class DirectoryEntry {
  const DirectoryEntry({
    required this.resource,
    required this.name,
    required this.kind,
  });

  final ResourceRef resource;
  final String name;
  final DirectoryEntryKind kind;
}

final class DirectoryListing {
  DirectoryListing({
    required this.directory,
    required List<DirectoryEntry> entries,
  }) : entries = UnmodifiableListView<DirectoryEntry>(
         List<DirectoryEntry>.of(entries),
       );

  final ResourceRef directory;
  final List<DirectoryEntry> entries;
}

final class TextFileContents {
  const TextFileContents({required this.resource, required this.text});

  final ResourceRef resource;
  final String text;
}

abstract interface class WorkspaceDemoService {
  Future<DirectoryListing> listDirectory(ResourceRef directory);

  Future<TextFileContents> readTextFile(ResourceRef file);
}

/// Minimal frontend-facing snapshot used by the experimental eval bridge.
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({required this.names, required this.uris});

  final List<String> names;
  final List<String> uris;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value);

  final String value;
}

/// Implemented by the ADELE eval bridge during Phase 1.
Future<WorkspaceDemoViewData> loadWorkspaceDemoDirectory() {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}

/// Implemented by the ADELE eval bridge during Phase 1.
Future<WorkspaceDemoTextData> loadWorkspaceDemoText(String uri) {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}

final class WorkspaceDemoFailure implements Exception {
  const WorkspaceDemoFailure({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'WorkspaceDemoFailure($code): $message';
}
