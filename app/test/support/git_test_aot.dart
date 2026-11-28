import 'dart:io';

import 'package:plugin_builder/plugin_builder.dart';

import '../../../tools/git_test_aot_client.dart';

export '../../../tools/git_test_aot_client.dart' show GitTestAot;

/// Only these stock, repository-root compilations may request a private copy
/// from an eligible maintained worker. Other compilations use the builder
/// directly, even if their output is also named host.aot or backend.aot.
extension GitTestPreparation on GitTestAot {
  Future<void> prepare({
    required Directory repositoryRoot,
    required String dartExecutable,
    required File artifact,
    required String stage,
    bool absoluteEntrypoint = false,
  }) async {
    if (await requestGitTestAot(
      recipe: this,
      repositoryRoot: repositoryRoot.absolute.path,
      dartExecutable: dartExecutable,
      output: artifact.absolute.path,
    )) {
      return;
    }
    await compileAotSnapshot(
      dartExecutable: dartExecutable,
      workingDirectory: repositoryRoot,
      entrypoint: absoluteEntrypoint
          ? '${repositoryRoot.absolute.path}/$entrypoint'
          : entrypoint,
      artifact: artifact,
      stage: stage,
    );
  }
}
