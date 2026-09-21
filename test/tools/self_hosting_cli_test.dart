import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('self-hosting CLI remains importable without a Flutter engine', () async {
    // The shared runtime is selector-free and must remain plain-Dart.
    // Help compiles that import graph without credentials, providers, or a Run.
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'app/tool/self_hosting/cli.dart', '--help'],
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      result.stdout,
      contains('Usage: dart run app/bin/adele_self_host.dart'),
    );
    expect(result.stdout, isNot(contains('Run evidence:')));
  });

  group('SDK-only self-hosting launcher', () {
    late Directory temporary;
    late Directory repository;
    late Directory caller;
    late File events;
    late File generated;
    late File launcher;
    late File child;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('adele self host ');
      repository = Directory('${temporary.path}/repository')..createSync();
      caller = Directory('${temporary.path}/caller directory')..createSync();
      for (final path in [
        'app/bin/adele_self_host.dart',
        'tools/contract_artifacts.dart',
        'packages/plugin_builder/lib/plugin_builder.dart',
        'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      ]) {
        final destination = File('${repository.path}/$path');
        destination.parent.createSync(recursive: true);
        File(path).copySync(destination.path);
      }
      launcher = File('${repository.path}/app/bin/adele_self_host.dart');
      child = File('${repository.path}/app/tool/self_hosting/cli.dart');
      child.parent.createSync(recursive: true);
      generated = File('${child.parent.path}/contract.g.dart');
      events = File('${repository.path}/events.jsonl');
      final generator = File(
        '${repository.path}/packages/contract_codegen/bin/contract_codegen.dart',
      );
      generator.parent.createSync(recursive: true);
      generator.writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  File(${jsonEncode(events.path)}).writeAsStringSync(
    jsonEncode({
      'stage': 'generate',
      'cwd': Directory.current.path,
      'arguments': arguments,
      'executable': Platform.resolvedExecutable,
    }) + '\\n',
    mode: FileMode.append,
  );
  stdout.writeln('generator stdout');
  if (Platform.environment['ADELE_TEST_FAIL_GENERATION'] == '1') {
    stderr.writeln('generator stderr');
    exitCode = 29;
    return;
  }
  File('app/tool/self_hosting/contract.g.dart').writeAsStringSync(
    "part of 'cli.dart';\\nconst generatedValue = 'generated before compilation';\\n",
  );
}
''');
      child.writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

part 'contract.g.dart';

void main(List<String> arguments) {
  File(${jsonEncode(events.path)}).writeAsStringSync(
    jsonEncode({
      'stage': 'child',
      'cwd': Directory.current.path,
      'arguments': arguments,
      'executable': Platform.resolvedExecutable,
      'generated': generatedValue,
    }) + '\\n',
    mode: FileMode.append,
  );
  stdout.writeln('child stdout');
  stderr.writeln('child stderr');
  exitCode = int.parse(Platform.environment['ADELE_TEST_CHILD_EXIT'] ?? '0');
}
''');
    });

    tearDown(() => temporary.deleteSync(recursive: true));

    Future<ProcessResult> invoke(
      List<String> arguments, {
      Map<String, String> environment = const {},
    }) => Process.run(
      Platform.resolvedExecutable,
      [launcher.path, ...arguments],
      workingDirectory: caller.path,
      // The launcher and generator must use the executing SDK, not PATH.
      environment: {'PATH': caller.path, ...environment},
    );

    List<Object?> readEvents() =>
        events.readAsLinesSync().map(jsonDecode).toList();

    for (final childExit in [0, 37]) {
      test(
        'generates before child compilation and preserves cwd, argv and exit $childExit',
        () async {
          expect(generated.existsSync(), isFalse);
          final unprepared = await Process.run(Platform.resolvedExecutable, [
            child.path,
          ], workingDirectory: caller.path);
          expect(unprepared.exitCode, isNot(0));
          expect(unprepared.stderr, contains('contract.g.dart'));
          expect(events.existsSync(), isFalse);

          final arguments = [
            '--prompt-file',
            'relative prompt.txt',
            '',
            r'quote "and" $literal',
            '--output-dir',
            '../output directory',
            '--help',
          ];
          final result = await invoke(
            arguments,
            environment: {'ADELE_TEST_CHILD_EXIT': '$childExit'},
          );
          expect(result.exitCode, childExit, reason: result.stderr.toString());
          expect(readEvents(), [
            {
              'stage': 'generate',
              'cwd': repository.path,
              'arguments': <String>[],
              'executable': Platform.resolvedExecutable,
            },
            {
              'stage': 'child',
              'cwd': caller.path,
              'arguments': arguments,
              'executable': Platform.resolvedExecutable,
              'generated': 'generated before compilation',
            },
          ]);
          expect(generated.existsSync(), isTrue);
          expect(result.stdout, contains('generator stdout\nchild stdout'));
          expect(result.stderr, 'child stderr\n');
        },
      );
    }

    for (final retained in [false, true]) {
      test(
        'generation failure stops child with retained output=$retained',
        () async {
          if (retained) {
            generated.writeAsStringSync(
              "part of 'cli.dart';\nconst generatedValue = 'retained';\n",
            );
          }
          final result = await invoke(
            ['--help'],
            environment: {'ADELE_TEST_FAIL_GENERATION': '1'},
          );
          expect(result.exitCode, 29);
          expect(readEvents(), [
            {
              'stage': 'generate',
              'cwd': repository.path,
              'arguments': <String>[],
              'executable': Platform.resolvedExecutable,
            },
          ]);
          expect(result.stdout, contains('generator stdout'));
          expect(result.stdout, isNot(contains('child stdout')));
          expect(result.stderr, contains('generator stderr'));
          expect(
            result.stderr,
            contains('contract-generation failed with exit code 29'),
          );
          expect(result.stderr, isNot(contains('child stderr')));
          // A missing part would produce a compiler error if the child was started.
          expect(result.stderr, isNot(contains('contract.g.dart')));
          expect(generated.existsSync(), retained);
          if (retained) {
            expect(
              generated.readAsStringSync(),
              contains("generatedValue = 'retained'"),
            );
          }
        },
      );
    }
  });
}
