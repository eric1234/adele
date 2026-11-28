import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../../tools/git_test_aot_client.dart';
import '../../../tools/git_test_aot_worker.dart';

Future<int> runFixtureWorker(
  File peer,
  Directory root,
  String mode,
  GitTestDelivery Function(Directory) open, {
  Set<GitTestAot> allowedRecipes = const {GitTestAot.host},
}) => runGitTestAotWorker(
  repository: root,
  allowedRecipes: allowedRecipes,
  dartExecutable: Platform.resolvedExecutable,
  suiteExecutable: File('/proc/self/exe').resolveSymbolicLinksSync(),
  workingDirectory: root.path,
  executable: Platform.resolvedExecutable,
  arguments: [peer.path, mode, root.path],
  environment: {
    gitTestAotLocator: '/stale/worker.sock',
    'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR': '/fixture/native',
  },
  openStore: open,
);

// Simulate independent Flutter suite processes and isolates, using exactly the
// private child environment used by the real suites (not an injectable locator).
Future<void> main(List<String> args) async {
  final [mode, root] = args;
  if (mode == 'owner') {
    exitCode = await runFixtureWorker(
      File.fromUri(Platform.script),
      Directory(root),
      'block',
      (scope) => (_, _) async {
        stdout.writeln('ADMITTED ${scope.path}');
        await stdin.transform(utf8.decoder).first;
        if (!scope.existsSync()) throw StateError('Live scope was deleted');
        await File('$root/drained').writeAsString(scope.path);
      },
    );
    return;
  }
  final socket = Platform.environment[gitTestAotLocator];
  Future<bool> request(
    String name, {
    String? checkout,
    String? compiler,
    GitTestAot recipe = GitTestAot.host,
  }) => requestGitTestAot(
    recipe: recipe,
    repositoryRoot: checkout ?? root,
    dartExecutable: compiler ?? Platform.resolvedExecutable,
    output: '$root/$name.aot',
  );
  if (mode == 'direct') {
    if (await request('direct')) throw StateError('Unexpected scope');
    return;
  }
  if (mode == 'peer') {
    if (!await request('peer')) throw StateError('Missing scope');
    return;
  }
  if (mode == 'block') {
    await request('block');
    return;
  }
  if (Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'] !=
      '/fixture/native') {
    throw StateError('Lost loader environment');
  }
  if (mode == 'desktop' || mode == 'git') {
    if (!await request('$mode-host') ||
        await request('$mode-git', recipe: GitTestAot.git) != (mode == 'git')) {
      throw StateError('Wrong recipes admitted by $mode worker');
    }
    return;
  }
  await File('$root/locator').writeAsString(socket!);
  if (mode == 'empty') return;
  if (mode == 'reject') {
    final escaped = await Process.run('/usr/bin/setsid', [
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
      'peer',
      root,
    ]);
    if (escaped.exitCode == 0 ||
        !escaped.stderr.toString().contains(
          'Not a suite in this Git test worker',
        )) {
      throw StateError(
        'Wrong process group did not get rejected: ${escaped.stderr}',
      );
    }
    if (await request('wrong-sdk', compiler: '/other/bin/dart')) {
      throw StateError('Wrong SDK accepted');
    }
    try {
      await request('wrong-checkout', checkout: Directory.systemTemp.path);
    } on StateError catch (error) {
      if (!error.message.toString().contains('different checkout')) rethrow;
      exitCode = 37;
      return;
    }
    throw StateError('Wrong checkout accepted');
  }
  final otherProcess = Process.run(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    'peer',
    root,
  ]);
  final local = await Future.wait([
    for (final name in ['first', 'second'])
      Isolate.run(
        () => requestGitTestAot(
          recipe: GitTestAot.host,
          repositoryRoot: root,
          dartExecutable: Platform.resolvedExecutable,
          output: '$root/$name.aot',
        ),
      ),
  ]);
  final result = await otherProcess;
  if (result.exitCode != 0 || local.contains(false)) {
    throw StateError('Independent requests failed: ${result.stderr} $local');
  }
}
