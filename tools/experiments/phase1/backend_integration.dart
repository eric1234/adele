// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:adele_desktop/phase1/workspace_demo/workspace_demo_proxy.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) {
    stderr.writeln(
      'Usage: backend_integration <repo> <dart> <flutter> <development-root>',
    );
    exitCode = 64;
    return;
  }
  final Directory repository = Directory(arguments[0]).absolute;
  final Directory developmentRoot = Directory(arguments[3]).absolute;
  await developmentRoot.create(recursive: true);
  await File('${developmentRoot.path}/phase1.txt').writeAsString('phase one');

  final PluginBuildResult build = await const DevelopmentPluginBuilder()
      .prepareBackend(
        repositoryRoot: repository,
        pluginDirectory: Directory('${repository.path}/plugins/workspace_demo'),
        dartExecutable: arguments[1],
        flutterExecutable: arguments[2],
        expectedDartVersion: '3.10.9',
        expectedFlutterVersion: '3.38.10',
      );
  stdout.writeln('buildId=${build.buildId}');
  stdout.writeln('backendArtifact=${build.backendArtifact.path}');
  for (final PluginBuildDiagnostic diagnostic in build.diagnostics) {
    stdout.writeln('stage=${diagnostic.stage} exitCode=${diagnostic.exitCode}');
  }

  final PluginBackendConnection connection = await const PluginBackendLauncher()
      .launch(
        artifactUri: build.backendArtifact.uri,
        arguments: <String>[developmentRoot.path],
        onDiagnostic: (String message) => stdout.writeln('runtime=$message'),
      );
  final WorkspaceDemoService service = WorkspaceDemoProxy(connection);
  final ResourceRef root = ResourceRef(uri: developmentRoot.uri);
  final DirectoryListing listing = await service.listDirectory(root);
  stdout.writeln(
    'listing=${listing.entries.map((DirectoryEntry entry) => entry.name).toList()}',
  );
  final DirectoryEntry file = listing.entries.singleWhere(
    (DirectoryEntry entry) => entry.name == 'phase1.txt',
  );
  final TextFileContents contents = await service.readTextFile(file.resource);
  stdout.writeln('contents=${contents.text}');
  await connection.close();
  stdout.writeln('closed=${connection.isClosed}');
}
