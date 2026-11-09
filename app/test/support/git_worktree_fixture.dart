import 'dart:io';

import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

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
