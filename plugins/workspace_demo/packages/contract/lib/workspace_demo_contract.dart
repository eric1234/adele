/// Experimental shared contract declarations for the workspace demo plugin.
library;

import 'dart:collection';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

part 'workspace_demo_contract.g.dart';

enum DirectoryEntryKind { directory, file }

@AdeleValue()
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

@AdeleValue()
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

@AdeleValue()
final class TextFileContents {
  const TextFileContents({required this.resource, required this.text});

  final ResourceRef resource;
  final String text;
}

@AdeleContract('workspaceDemo')
abstract interface class WorkspaceDemoService {
  @AdeleMethod('listDirectory')
  Future<DirectoryListing> listDirectory(ResourceRef directory);

  @AdeleMethod('readTextFile')
  Future<TextFileContents> readTextFile(ResourceRef file);
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
