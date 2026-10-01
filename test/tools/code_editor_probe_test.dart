import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/code_editor_probe.dart';

void main() {
  final pin =
      jsonDecode(File('toolchain.json').readAsStringSync())
          as Map<String, Object?>;
  final sdk = <String, Object?>{
    'frameworkVersion': pin['flutter'],
    'frameworkRevision': pin['flutterRevision'],
    'engineRevision': pin['engineRevision'],
    'dartSdkVersion': pin['dart'],
  };

  test('probe enforces all integrated SDK identities before preparation', () {
    validateCodeEditorProbeToolchain(pin, sdk);
    for (final key in sdk.keys) {
      expect(
        () => validateCodeEditorProbeToolchain(pin, {...sdk, key: 'wrong'}),
        throwsStateError,
        reason: key,
      );
      expect(
        () => validateCodeEditorProbeToolchain(pin, {...sdk}..remove(key)),
        throwsStateError,
        reason: key,
      );
    }
  });

  test(
    'packaged launch cannot use development loader overrides or Cargo PATH',
    () {
      final original = {
        'LD_LIBRARY_PATH': '/development/library',
        'LD_PRELOAD': '/development/preload.so',
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR':
            '/cargo/target/release',
        'PATH': '/home/developer/.cargo/bin:/usr/bin',
        'HOME': '/home/developer',
      };
      final clean = codeEditorProbeRuntimeEnvironment(original);
      expect(clean.keys, unorderedEquals(['PATH', 'HOME']));
      expect(clean['PATH'], '/usr/bin:/bin');
      expect(original, hasLength(5));
    },
  );

  test(
    'candidate and locks stay isolated from normal workspace resolution',
    () {
      expect(codeForgeProbeVersion, '10.14.0');
      expect(codeForgeProbeSha256, hasLength(64));
      expect(codeForgeProbeRust, '1.93.0');
      for (final path in ['pubspec.yaml', 'app/pubspec.yaml', 'pubspec.lock']) {
        expect(File(path).readAsStringSync(), isNot(contains('code_forge')));
      }
      final patch = File(
        'tools/code_editor_probe/fixtures/compatibility.patch',
      ).readAsStringSync();
      expect(patch, contains("String get _toolchain => '1.93.0'"));
      expect(patch, contains("'--locked'"));
      expect(patch, contains('--enforce-lockfile'));
      expect(patch, isNot(contains('frb_generated')));
      expect(patch, isNot(contains('controller.dart')));
      final lock = File(
        'tools/code_editor_probe/fixtures/pubspec.lock',
      ).readAsStringSync();
      expect(lock, contains('version: "2.13.0"'));
      expect(lock, contains('path: "../code_forge"'));
      final runner = File(
        'tools/code_editor_probe/fixtures/cargokit_runner.lock.template',
      ).readAsStringSync();
      expect(runner, contains('@CODEFORGE_BUILD_TOOL@'));
      expect(runner, isNot(contains('/tmp/')));
    },
  );

  test(
    'missing-library proof rejects timeout and post-load mapping failure',
    () {
      validateCodeEditorProbeMissingLibrary(
        ProcessResult(1, 1, 'CODEFORGE_INIT_FAILED', ''),
      );
      for (final result in [
        ProcessResult(1, 0, 'CODEFORGE_INIT_FAILED', ''),
        ProcessResult(1, 124, 'CODEFORGE_INIT_FAILED', ''),
        ProcessResult(1, -9, 'CODEFORGE_INIT_FAILED', ''),
        ProcessResult(1, 1, 'CODEFORGE_BUNDLE_FAILED', ''),
        ProcessResult(
          1,
          1,
          'CODEFORGE_FRB_INIT_RETURNED\nCODEFORGE_INIT_FAILED',
          '',
        ),
      ]) {
        expect(
          () => validateCodeEditorProbeMissingLibrary(result),
          throwsStateError,
        );
      }
    },
  );

  test(
    'CLI rejects incomplete options before downloading or building',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'tools/adele.dart',
        'probe-code-editor',
      ]);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('requires --output NEW_DIRECTORY'));
    },
  );
}
