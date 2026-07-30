// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:adele_desktop/phase1/workspace_demo/workspace_demo_proxy.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

Future<void> main(List<String> arguments) async {
  final PluginBackendHost host = await PluginBackendHost.start(
    dartaotruntimeExecutable: arguments[0],
    hostArtifactPath: arguments[1],
    onDiagnostic: (String message) => stderr.writeln(message),
  );
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: 'dev.adele.workspace-demo',
    artifactUri: File(arguments[2]).absolute.uri,
    arguments: <String>[Directory(arguments[3]).absolute.path],
  );
  final WorkspaceDemoService service = WorkspaceDemoProxy(connection);
  final DirectoryListing listing = await service.listDirectory(
    ResourceRef(uri: Directory(arguments[3]).absolute.uri),
  );
  stdout.writeln(
    'entries=${listing.entries.map((DirectoryEntry entry) => entry.name).toList()}',
  );
  final DirectoryEntry file = listing.entries.firstWhere(
    (DirectoryEntry entry) => entry.kind == DirectoryEntryKind.file,
  );
  final TextFileContents contents = await service.readTextFile(file.resource);
  stdout.writeln('text=${contents.text.trim()}');
  await connection.close();
  stdout.writeln(
    'pluginClosed=${connection.isClosed} hostClosed=${host.isClosed}',
  );
  await host.close();
  stdout.writeln('hostClosed=${host.isClosed}');
}
