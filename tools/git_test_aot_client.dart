import 'dart:convert';
import 'dart:io';

// A locator, not authority: the worker checks the connecting process itself.
const gitTestAotLocator = 'ADELE_GIT_TEST_AOT_SOCKET';

enum GitTestAot {
  host(
    'plugin_backend_host',
    'packages/plugin_backend_host/bin/adele_backend_host.dart',
  ),
  git('git_backend', 'plugins/git/packages/backend/bin/git_backend.dart');

  const GitTestAot(this.package, this.entrypoint);
  final String package;
  final String entrypoint;
}

Future<bool> requestGitTestAot({
  required GitTestAot recipe,
  required String repositoryRoot,
  required String dartExecutable,
  required String output,
}) async {
  final locator = Platform.environment[gitTestAotLocator];
  if (!Platform.isLinux || locator == null) return false;
  final socket = await Socket.connect(
    InternetAddress(locator, type: InternetAddressType.unix),
    0,
  );
  try {
    socket.writeln(
      jsonEncode([recipe.entrypoint, repositoryRoot, dartExecutable, output]),
    );
    await socket.flush();
    final line = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final result = jsonDecode(line);
    if (result is bool) return result;
    throw StateError('Git test AOT preparation failed: $result');
  } finally {
    socket.destroy();
  }
}
