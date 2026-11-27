import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

const gitPluginId = 'dev.adele.plugin.git';
final gitProviderId = ProviderId('dev.adele.environment.git-worktree');

/// Locates an already-established stock Git fixture, not an Environment API.
String gitWorktreeFixturePath(Project project, Environment environment) {
  final state = environment.providerState!;
  expect(state['schemaVersion'], isA<int>().having((value) => value, 'v2', 2));
  expect(state['environmentId'], environment.id.value);
  final relative = state['worktreeRelativePath']! as String;
  expect(relative, matches(r'^\.adele/worktrees/[a-z0-9][a-z0-9-]*$'));
  final source = Directory(
    Directory.fromUri(project.sourceLocation).resolveSymbolicLinksSync(),
  );
  final path = Directory.fromUri(source.uri.resolve(relative)).path;
  expect(Directory(path).resolveSymbolicLinksSync(), path);
  return path;
}

Future<String> git(Directory directory, List<String> arguments) async {
  final result = await Process.run('git', [
    '-c',
    'user.name=ADELE Test',
    '-c',
    'user.email=adele-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: directory.path);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString();
}
