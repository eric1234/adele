import 'dart:io';

import 'package:test/test.dart';

import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  for (final String command in <String>['run', 'build']) {
    for (final kind in frontendCompilations.keys) {
      for (final String failure in <String>['exit', 'missing', 'empty']) {
        test(
          '$command never launches after $kind frontend $failure failure',
          () async {
            fixture.environment['ADELE_TEST_FRONTEND_TARGET'] = kind;
            if (failure == 'exit') {
              fixture.environment['ADELE_TEST_FAIL_FRONTEND'] = '1';
            } else {
              fixture.environment['ADELE_TEST_FRONTEND_ARTIFACT'] = failure;
            }
            final ProcessResult result = await fixture.invoke(<String>[
              command,
              'linux',
              '--profile',
            ]);
            expect(result.exitCode, failure == 'exit' ? 23 : 1);
            expect(result.stderr, contains('$kind-frontend-compilation'));
            if (failure == 'exit') {
              expect(result.stderr, contains('frontend compiler failed'));
              expect(result.stderr, contains('failed with exit code 23'));
              expect(
                fixture.frontendEnvironment.readAsLinesSync()[1],
                contains('/.staging/'),
              );
            } else {
              expect(result.stderr, contains('produced no non-empty artifact'));
            }
            expect(fixture.commands.readAsLinesSync(), <String>[
              'inspect-sdk',
              ...toolCompilationEvents,
              'generate|aot|--incremental',
              for (final entrypoint in backendEntrypoints) ...[
                'compile|$entrypoint',
                'compiled|$entrypoint',
              ],
              'compile|git-pty-helper',
              for (final frontend in frontendCompilations.entries.take(
                frontendCompilations.keys.toList().indexOf(kind) + 1,
              )) ...[
                'compile|${frontend.value}',
                if (frontend.key != kind || failure != 'exit')
                  'compiled|${frontend.value}',
              ],
            ]);
            expect(fixture.launchArguments.existsSync(), isFalse);
            fixture.expectNoPublishedInstallations();
          },
        );
      }
    }
  }

  test('frontend failure never reuses a retained successful artifact', () async {
    final ProcessResult first = await fixture.invoke(<String>[
      'build',
      'linux',
    ]);
    expect(first.exitCode, 0, reason: first.stderr.toString());
    final File previous = File(
      '${fixture.launchDefines()['ADELE_PLUGIN_INSTALLATION_ROOT']}/chat-strategy/frontend.evc',
    );
    fixture.changeSource(chatSource);
    fixture.launchArguments.deleteSync();
    fixture.commands.deleteSync();

    fixture.environment['ADELE_TEST_FRONTEND_ARTIFACT'] = 'missing';
    final ProcessResult second = await fixture.invoke(<String>['run', 'linux']);
    expect(second.exitCode, 1);
    expect(second.stderr, contains('produced no non-empty artifact'));
    expect(previous.readAsStringSync(), 'frontend bytecode\n');
    expect(
      fixture.frontendEnvironment.readAsLinesSync()[1],
      isNot(previous.path),
    );
    expect(
      fixture.commands.readAsLinesSync(),
      isNot(contains('flutter-launch')),
    );
    expect(fixture.launchArguments.existsSync(), isFalse);
  });
}
