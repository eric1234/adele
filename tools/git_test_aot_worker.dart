import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'git_test_aot_client.dart';
import 'git_test_aot_store.dart' show createPrivateGitTestDirectory;

typedef GitTestDelivery =
    Future<void> Function(GitTestAot recipe, File destination);

final _getpgid = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32), int Function(int)>('getpgid');

Map<String, String> testWorkerEnvironment(Map<String, String>? overrides) =>
    {...Platform.environment, ...?overrides}..remove(gitTestAotLocator);

/// All isolates and processes in this worker use ONE launcher-owned store.
/// Nothing on disk is a scope locator or an invitation to recover a store.
Future<int> runGitTestAotWorker({
  required Directory repository,
  required String dartExecutable,
  required String suiteExecutable,
  required GitTestDelivery Function(Directory scope) openStore,
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required Map<String, String>? environment,
}) async {
  final timer = Stopwatch()..start();
  Directory? owned;
  final sessions = <Socket>{};
  final requests = <Future<void>>{};
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  ServerSocket? server;
  Process? child;
  ProcessSignal? interrupted;
  var accepting = true;

  void terminate(ProcessSignal signal) {
    interrupted = signal;
    accepting = false;
    if (child case final process?) {
      // The participating Flutter worker has its own Linux process group.
      // Cover interruption between Process.start and setsid taking effect.
      if (!Process.killPid(-process.pid, ProcessSignal.sigkill)) {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }

  try {
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      subscriptions.add(signal.watch().listen(terminate));
    }
    final scope = owned = await createPrivateGitTestDirectory(
      Directory.systemTemp,
      'adele-git-test-',
    );
    final root = repository.resolveSymbolicLinksSync();
    final deliver = openStore(scope);
    final locator = '${scope.path}/worker.sock';
    server = await ServerSocket.bind(
      InternetAddress(locator, type: InternetAddressType.unix),
      0,
    );

    Future<void> serve(Socket socket) async {
      try {
        final line = await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        final message = jsonDecode(line);
        Object response;
        try {
          // Linux SO_PEERCRED, struct ucred { pid_t pid; uid_t uid; gid_t gid; }.
          // An inherited path alone (including in an AOT backend's environment)
          // cannot admit work. Both the pinned tester and this child group must match.
          final peer = socket.getRawOption(
            RawSocketOption(RawSocketOption.levelSocket, 17, Uint8List(12)),
          );
          final peerPid = ByteData.sublistView(peer).getInt32(0, Endian.host);
          if (child == null ||
              _getpgid(peerPid) != child.pid ||
              File('/proc/$peerPid/exe').resolveSymbolicLinksSync() !=
                  suiteExecutable) {
            throw StateError('Not a suite in this Git test worker');
          }
          if (!accepting ||
              message is! List ||
              message.length != 4 ||
              !message.every((e) => e is String)) {
            throw StateError('Invalid or interrupted Git test AOT request');
          }
          final [recipe, checkout, dart, output] = message.cast<String>();
          if (!Directory(checkout).isAbsolute ||
              Directory(checkout).resolveSymbolicLinksSync() != root) {
            throw StateError('Git test worker belongs to a different checkout');
          }
          final stock = GitTestAot.values
              .where((r) => r.entrypoint == recipe)
              .firstOrNull;
          if (stock == null || dart != dartExecutable) {
            response = false; // Not the recipe this launcher can supply.
          } else {
            await deliver(stock, File(output));
            response = true;
          }
        } on Object catch (error) {
          response = error.toString();
        }
        socket.writeln(jsonEncode(response));
        await socket.flush();
      } on SocketException {
        // The consumer may have exited. No other connection uses its copy.
      } on StateError {
        // A disconnected client sent no complete request.
      } on FormatException {
        // No complete frame to admit or reply to.
      } finally {
        sessions.remove(socket);
        socket.destroy();
      }
    }

    server.listen((socket) {
      if (!accepting) {
        socket.destroy();
        return;
      }
      sessions.add(socket);
      final request = serve(socket);
      requests.add(request);
      unawaited(request.whenComplete(() => requests.remove(request)));
    });
    stdout.writeln('==> git-test-aot scope: ${timer.elapsedMicroseconds} us');
    child = await Process.start(
      '/usr/bin/setsid',
      [executable, ...arguments],
      workingDirectory: workingDirectory,
      environment: {
        ...testWorkerEnvironment(environment),
        gitTestAotLocator: locator,
      },
      includeParentEnvironment: false,
      mode: ProcessStartMode.inheritStdio,
    );
    if (interrupted case final signal?) terminate(signal);
    final code = await child.exitCode;
    child = null;
    return code;
  } finally {
    try {
      accepting = false;
      await server?.close();
      for (final socket in sessions.toList()) {
        socket.destroy();
      }
      // Closing a socket does not cancel an admitted compiler or copy.
      await Future.wait(requests.toList());
      await owned?.delete(recursive: true);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      if (interrupted case final signal?) Process.killPid(pid, signal);
    }
  }
}
