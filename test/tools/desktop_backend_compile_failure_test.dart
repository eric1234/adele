import 'dart:io';

import 'package:test/test.dart';

import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  // Linux run and build share preparation. Fail every entrypoint on run and
  // check build at both ends of the same compilation sequence.
  for (final (command, entrypoints) in [
    ('run', backendEntrypoints),
    ('build', [backendEntrypoints.first, backendEntrypoints.last]),
  ]) {
    for (final failedEntrypoint in entrypoints) {
      test('$command never launches after $failedEntrypoint fails', () async {
        fixture.environment['ADELE_TEST_FAIL_ENTRYPOINT'] = failedEntrypoint;
        final ProcessResult result = await fixture.invoke(<String>[
          command,
          'linux',
          '--profile',
        ]);
        expect(result.exitCode, 17);
        expect(result.stderr, contains('snapshot compiler failed'));
        expect(result.stderr, contains('failed with exit code 17'));
        if (failedEntrypoint == localDirectoryProjectEntrypoint) {
          expect(
            result.stderr,
            contains(
              'local-directory-project-compilation failed with exit code 17',
            ),
          );
        }
        if (failedEntrypoint == sessionEvaluatorEntrypoint) {
          expect(
            result.stderr,
            contains('session-evaluator-compilation failed with exit code 17'),
          );
        }
        expect(fixture.commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          ...toolCompilationEvents,
          'generate|aot|--incremental',
          for (final entrypoint in backendEntrypoints.take(
            backendEntrypoints.indexOf(failedEntrypoint) + 1,
          )) ...[
            'compile|$entrypoint',
            if (entrypoint != failedEntrypoint) 'compiled|$entrypoint',
          ],
        ]);
        expect(fixture.launchArguments.existsSync(), isFalse);
        fixture.expectNoPublishedInstallations();
      });
    }
  }

  for (final failure in ['exit', 'missing', 'empty']) {
    test(
      'native helper $failure failure prevents runtime activation',
      () async {
        if (failure == 'exit') {
          fixture.environment['ADELE_TEST_FAIL_PTY'] = '1';
        } else {
          fixture.environment['ADELE_TEST_PTY_ARTIFACT'] = failure;
        }
        final result = await fixture.invoke(['build', 'linux']);
        expect(result.exitCode, failure == 'exit' ? 37 : 1);
        expect(result.stderr, contains('git-pty-helper-compilation'));
        expect(fixture.launchArguments.existsSync(), isFalse);
        expect(fixture.frontendArguments.existsSync(), isFalse);
        fixture.expectNoPublishedInstallations();
      },
    );
  }

  for (final entrypoint in [hostEntrypoint, sessionEvaluatorEntrypoint]) {
    test(
      'compiler success with empty $entrypoint artifact blocks launch',
      () async {
        fixture.environment['ADELE_TEST_EMPTY_ARTIFACT'] = entrypoint;
        final result = await fixture.invoke(['run', 'linux']);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('produced no non-empty artifact'));
        expect(fixture.launchArguments.existsSync(), isFalse);
        fixture.expectNoPublishedInstallations();
      },
    );
    test(
      'compiler success without $entrypoint artifact blocks launch',
      () async {
        fixture.environment['ADELE_TEST_OMIT_ARTIFACT'] = entrypoint;
        final ProcessResult result = await fixture.invoke(<String>[
          'run',
          'linux',
        ]);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('produced no artifact'));
        expect(fixture.commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          ...toolCompilationEvents,
          'generate|aot|--incremental',
          for (final compiled in backendEntrypoints.take(
            backendEntrypoints.indexOf(entrypoint) + 1,
          )) ...['compile|$compiled', 'compiled|$compiled'],
        ]);
        expect(fixture.launchArguments.existsSync(), isFalse);
        fixture.expectNoPublishedInstallations();
      },
    );
  }
}
