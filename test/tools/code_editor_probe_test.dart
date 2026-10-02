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
    'upstream control admits only SDKs satisfying declared stable constraint',
    () {
      for (final version in ['3.13.2', '3.13.4', '3.14.0']) {
        validateCodeEditorUpstreamSdk({'dartSdkVersion': version});
      }
      for (final version in [
        '3.10.9',
        '3.13.1',
        '3.13.2-dev',
        '4.0.0',
        'unknown',
      ]) {
        expect(
          () => validateCodeEditorUpstreamSdk({'dartSdkVersion': version}),
          throwsStateError,
        );
      }
      expect(() => validateCodeEditorUpstreamSdk({}), throwsStateError);
    },
  );

  test('profile build passes the selected SDK to the interactive label', () {
    final controlSdk = <String, Object?>{
      'frameworkVersion': '3.47.0',
      'dartSdkVersion': '3.13.2',
    };
    validateCodeEditorProbeToolchain(pin, sdk);
    validateCodeEditorUpstreamSdk(controlSdk);
    for (final (selectedSdk, configuration, flutterVersion) in [
      (sdk, 'adele-pin-compatibility-only', '3.38.10'),
      (sdk, 'adele-pin-causal-patch', '3.38.10'),
      (controlSdk, 'upstream-unmodified', '3.47.0'),
    ]) {
      expect(
        codeEditorProbeBuildArguments(
          selectedSdk,
          configuration: configuration,
        ),
        [
          'build',
          'linux',
          '--profile',
          '--no-pub',
          '--verbose',
          '--dart-define=ADELE_CODEFORGE_CONFIGURATION=$configuration',
          '--dart-define=FLUTTER_VERSION=$flutterVersion',
        ],
      );
    }
    final interactive = File(
      'tools/code_editor_probe/fixtures/interactive.dart.template',
    ).readAsStringSync();
    expect(
      interactive,
      contains("const flutter = String.fromEnvironment('FLUTTER_VERSION');"),
    );
    expect(
      interactive,
      contains(r"'Flutter $flutter / Dart ${Platform.version}\n'"),
    );
  });

  test(
    'upstream is unmodified and versioned reproduction cannot mask a patch',
    () async {
      for (final options in [
        (upstream: true, patch: false, verify: false, investigate: false),
        (upstream: true, patch: true, verify: false, investigate: false),
        (upstream: false, patch: true, verify: true, investigate: false),
        (upstream: false, patch: false, verify: true, investigate: true),
      ]) {
        await expectLater(
          runCodeEditorProbe(
            repository: Directory.current,
            output: Directory('/unused-invalid-configuration'),
            verifyKnownDefects: options.verify,
            upstreamControl: options.upstream,
            correctnessPatch: options.patch,
            investigate: options.investigate,
          ),
          throwsArgumentError,
        );
      }
    },
  );

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
    'historical probe inputs remain separate from the adopted dependency',
    () {
      expect(codeForgeProbeVersion, '10.14.0');
      expect(codeForgeProbeSha256, hasLength(64));
      expect(codeForgeProbeRust, '1.93.0');
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('.adele/dependencies/code_forge'),
      );
      expect(
        File('pubspec.yaml').readAsStringSync(),
        isNot(contains('tools/code_editor_probe')),
      );
      expect(
        File('packages/ui/pubspec.yaml').readAsStringSync(),
        isNot(contains('code_forge')),
      );
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

  test('profile success requires clean completion and zero exit', () {
    validateCodeEditorProbeSmoke(
      ProcessResult(1, 0, 'CODEFORGE_PROBE_COMPLETE\n', 'platform chatter'),
    );
    expect(
      () => validateCodeEditorProbeSmoke(ProcessResult(1, 0, '', '')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('missing completion'),
        ),
      ),
    );
    expect(
      () => validateCodeEditorProbeSmoke(
        ProcessResult(1, 23, 'CODEFORGE_PROBE_COMPLETE', ''),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('exited 23'),
        ),
      ),
    );
  });

  for (final stream in ['stdout', 'stderr']) {
    for (final marker in [
      'CODEFORGE_INIT_FAILED',
      'CODEFORGE_BUNDLE_FAILED',
      'CODEFORGE_SMOKE_FAILED',
      'CODEFORGE_OTHER_FAILED',
    ]) {
      test(
        'profile rejects $marker on $stream despite exit 0 and completion',
        () {
          final failure = '$marker: first diagnostic\n';
          final result = ProcessResult(
            1,
            0,
            'CODEFORGE_PROBE_COMPLETE\n${stream == 'stdout' ? failure : ''}',
            stream == 'stderr' ? failure : '',
          );
          expect(
            () => validateCodeEditorProbeSmoke(result),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('explicit failure: $marker'),
              ),
            ),
          );
        },
      );
    }

    test('missing-library proof accepts only init failure on $stream', () {
      validateCodeEditorProbeMissingLibrary(
        ProcessResult(
          1,
          1,
          stream == 'stdout' ? 'CODEFORGE_INIT_FAILED' : '',
          stream == 'stderr' ? 'CODEFORGE_INIT_FAILED' : '',
        ),
      );
      for (final marker in [
        'CODEFORGE_FRB_INIT_RETURNED',
        'CODEFORGE_NATIVE_INITIALIZED',
        'CODEFORGE_PROBE_COMPLETE',
        'CODEFORGE_BUNDLE_FAILED',
        'CODEFORGE_SMOKE_FAILED',
      ]) {
        final result = ProcessResult(
          1,
          1,
          'CODEFORGE_INIT_FAILED\n${stream == 'stdout' ? marker : ''}',
          stream == 'stderr' ? marker : '',
        );
        expect(
          () => validateCodeEditorProbeMissingLibrary(result),
          throwsStateError,
          reason: marker,
        );
      }
    });
  }

  test('missing-library proof rejects unexplained or wrong exit status', () {
    for (final result in [
      ProcessResult(1, 0, 'CODEFORGE_INIT_FAILED', ''),
      ProcessResult(1, 23, 'CODEFORGE_INIT_FAILED', ''),
      ProcessResult(1, 1, '', ''),
      ProcessResult(1, 1, 'CODEFORGE_BUNDLE_FAILED', ''),
    ]) {
      expect(
        () => validateCodeEditorProbeMissingLibrary(result),
        throwsStateError,
      );
    }
  });

  for (final validator in {
    'profile': validateCodeEditorProbeSmoke,
    'missing library': validateCodeEditorProbeMissingLibrary,
  }.entries) {
    test('${validator.key} distinguishes timeout and signal termination', () {
      for (final status in {
        124: 'timed out',
        -9: 'signal 9',
        137: 'signal 9',
        143: 'signal 15',
      }.entries) {
        expect(
          () => validator.value(
            ProcessResult(
              1,
              status.key,
              'CODEFORGE_PROBE_COMPLETE\nCODEFORGE_INIT_FAILED',
              '',
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains(status.value),
            ),
          ),
        );
      }
    });
  }

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
