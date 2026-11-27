import 'dart:convert';
import 'dart:io';

/// Memoizes hashes of literal fixture text, never paths or repository contents.
/// Each editor builder keeps its own memo in the current test suite isolate.
final class FixtureTextDigests {
  final _digests = <String, Future<String>>{};

  Future<String> sha256(String text) => _digests.putIfAbsent(text, () async {
    final process = await Process.start('sha256sum', []);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.add(utf8.encode(text));
    await process.stdin.close();
    if (await process.exitCode != 0) throw StateError(await errors);
    return (await output).split(' ').first;
  });
}

Future<ProcessResult> runEditorFixtureCommand(
  String command,
  List<String> args,
) async {
  final result = await Process.run(
    command,
    args,
  ).timeout(const Duration(seconds: 15));
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  return result;
}
