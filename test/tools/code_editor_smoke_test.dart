import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/code_editor_smoke.dart';
import '../../tools/code_editor_smoke_support.dart';

void main() {
  test('smoke enforces all integrated SDK identities before preparation', () {
    final pin =
        jsonDecode(File('toolchain.json').readAsStringSync())
            as Map<String, Object?>;
    final sdk = <String, Object?>{
      'frameworkVersion': pin['flutter'],
      'frameworkRevision': pin['flutterRevision'],
      'engineRevision': pin['engineRevision'],
      'dartSdkVersion': pin['dart'],
    };
    validateCodeEditorSmokeToolchain(pin, sdk);
    for (final key in sdk.keys) {
      expect(
        () => validateCodeEditorSmokeToolchain(pin, {...sdk, key: 'wrong'}),
        throwsStateError,
        reason: key,
      );
      expect(
        () => validateCodeEditorSmokeToolchain(pin, {...sdk}..remove(key)),
        throwsStateError,
        reason: key,
      );
    }
    for (final key in [
      'flutter',
      'flutterRevision',
      'engineRevision',
      'dart',
    ]) {
      expect(
        () => validateCodeEditorSmokeToolchain({...pin}..remove(key), sdk),
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
      final clean = codeEditorSmokeRuntimeEnvironment(original);
      expect(clean.keys, unorderedEquals(['PATH', 'HOME']));
      expect(clean['PATH'], '/usr/bin:/bin');
      expect(original, hasLength(5));
      expect(original['PATH'], '/home/developer/.cargo/bin:/usr/bin');
    },
  );

  test('manual build identity comes from production preparation metadata', () {
    final identity = codeEditorSmokeIdentity({
      'version': '10.14.0',
      'archiveSha256': 'archive-digest',
      'patches': ['01-build.patch', '02-correctness.patch'],
      'flutterRustBridge': '2.13.0',
      'rust': '1.93.0',
    }, preparationIdentity: 'prepared-digest');
    expect(identity, contains('CodeForge 10.14.0'));
    expect(identity, contains('archive archive-digest'));
    expect(identity, contains('01-build.patch, 02-correctness.patch'));
    expect(identity, contains('FRB 2.13.0 | Rust 1.93.0'));
    expect(identity, endsWith('prepared prepared-digest'));
  });

  test('integrated smoke markers use the existing settlement validator', () {
    const completed = '''
CODEFORGE_FRB_INIT_RETURNED
CODEFORGE_NATIVE_INITIALIZED
CODEFORGE_PLATFORM_INPUT_OK
CODEFORGE_CLIPBOARD_READONLY_OK
CODEFORGE_UNMOUNTED_OWNER_RETAINED
CODEFORGE_PREPARED_REMOUNT_OK
CODEFORGE_NATIVE_DISPOSED
CODEFORGE_PROBE_COMPLETE
''';
    expect(
      () => validateCodeEditorSmoke(ProcessResult(1, 0, completed, '')),
      returnsNormally,
    );
    expect(
      () => validateCodeEditorSmoke(
        ProcessResult(1, 0, completed, 'CODEFORGE_SMOKE_FAILED'),
      ),
      throwsStateError,
    );
    expect(
      () => validateCodeEditorMissingLibrary(
        ProcessResult(1, 1, 'CODEFORGE_INIT_FAILED', ''),
      ),
      returnsNormally,
    );
    expect(
      () => validateCodeEditorMissingLibrary(
        ProcessResult(1, 124, 'CODEFORGE_INIT_FAILED', ''),
      ),
      throwsStateError,
    );
  });

  test('profile success requires clean completion and zero exit', () {
    validateCodeEditorSmoke(
      ProcessResult(1, 0, 'CODEFORGE_PROBE_COMPLETE\n', 'platform chatter'),
    );
    for (final result in [
      ProcessResult(1, 0, '', ''),
      ProcessResult(1, 0, '', 'CODEFORGE_PROBE_COMPLETE'),
    ]) {
      expect(
        () => validateCodeEditorSmoke(result),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('missing completion'),
          ),
        ),
      );
    }
    expect(
      () => validateCodeEditorSmoke(
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
            () => validateCodeEditorSmoke(result),
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
      validateCodeEditorMissingLibrary(
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
        'CODEFORGE_OTHER_FAILED',
      ]) {
        final result = ProcessResult(
          1,
          1,
          'CODEFORGE_INIT_FAILED\n${stream == 'stdout' ? marker : ''}',
          stream == 'stderr' ? marker : '',
        );
        expect(
          () => validateCodeEditorMissingLibrary(result),
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
      expect(() => validateCodeEditorMissingLibrary(result), throwsStateError);
    }
  });

  for (final validator in {
    'profile': validateCodeEditorSmoke,
    'missing library': validateCodeEditorMissingLibrary,
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

  test('packaged runtime has no compiler or source-checkout dependency', () {
    final source = File(
      'app/tool/code_editor_smoke/main.dart',
    ).readAsStringSync();
    expect(source, contains('PreparedFrontend.load(artifact)'));
    expect(source, contains('/data/editor_frontend.evc'));
    expect(source, contains('Platform.resolvedExecutable'));
    expect(source, isNot(contains('compile_frontend.dart')));
    expect(source, isNot(contains('package:dart_eval/')));
    expect(source, isNot(contains('Directory.current')));
    expect(source, isNot(contains('package:code_forge/')));
    expect(source, contains('code_editor_smoke_support.dart'));
  });

  test('runner remains SDK-only and never directly invokes Cargo', () {
    final source = File('tools/code_editor_smoke.dart').readAsStringSync();
    final imports = RegExp(
      r"^import '([^']+)';",
      multiLine: true,
    ).allMatches(source).map((match) => match[1]!).toList();
    expect(imports, [
      'dart:convert',
      'dart:io',
      'backend_artifacts.dart',
      'code_editor_dependency.dart',
      'code_editor_smoke_support.dart',
    ]);
    expect(source, isNot(contains('buildNativeCodeEditorForTests')));
    expect(source, isNot(contains("'cargo'")));
    expect(source, contains('codeEditorSmokeRuntimeEnvironment(environment)'));
    expect(
      source.indexOf("run('prepare-evc'"),
      lessThan(source.indexOf("run('profile-build'")),
    );
    expect(
      source,
      contains(r"artifact.copy('${bundle.path}/data/editor_frontend.evc')"),
    );
  });

  test(
    'workspace preparation extends the existing stock catalog and target',
    () {
      final runner = File('tools/code_editor_smoke.dart').readAsStringSync();
      final prepare = File(
        'app/tool/code_editor_smoke/prepare_test.dart',
      ).readAsStringSync();
      expect(runner, contains('bool workspace = false'));
      expect(runner, contains('await prepareDesktopPluginDefines('));
      expect(
        runner,
        contains('flutterExecutable: \'\$flutterRoot/bin/flutter\''),
      );
      expect(runner, isNot(contains('dev.adele.plugin.chat-strategy')));
      expect(runner, contains('--target=tool/code_editor_smoke/main.dart'));
      expect(
        runner.indexOf('await prepareDesktopPluginDefines('),
        lessThan(runner.indexOf("run('prepare-evc'")),
      );
      expect(
        runner.indexOf('validateCodeEditorMissingLibrary(missing)'),
        lessThan(runner.indexOf("'workspace-run'")),
      );
      expect(runner, contains("[...launch, '--workspace-smoke']"));
      expect(prepare, contains('ADELE_CODE_EDITOR_WORKSPACE'));
      expect(prepare, contains('ADELE_PLUGIN_INSTALLATION_ROOT'));
      expect(
        prepare.indexOf('await prepareMainContentFixture('),
        lessThan(prepare.indexOf('await installMainContentFixture(')),
      );
      expect(prepare, contains('await compileCodeEditorFrontend('));
    },
  );

  test('workspace runtime uses the real app and no preparation compiler', () {
    final source = File(
      'app/tool/code_editor_smoke/main.dart',
    ).readAsStringSync();
    final resources = File(
      'app/tool/main_content_fixture.dart',
    ).readAsStringSync();
    expect(source, contains("arguments.contains('--workspace')"));
    expect(source, contains("arguments.contains('--workspace-smoke')"));
    expect(source, contains('AdeleApplication('));
    expect(source, contains('mainContentHost: resources.host'));
    expect(source, contains('readChatGptConfiguration: () => null'));
    expect(source, contains('ADELE_EDITOR_WORKSPACE_READY'));
    expect(
      source,
      contains('runtime.plugins.state == ApplicationPluginState.ready'),
    );
    expect(source, contains('ADELE_EDITOR_WORKSPACE_COMPLETE'));
    expect(source, contains("await _press(root, 'New Chat Session')"));
    expect(source, contains('Session departure discards synthetic owners'));
    expect(source, isNot(contains('main_content_frontend_compiler.dart')));
    expect(resources, isNot(contains('package:dart_eval/')));
    expect(resources, isNot(contains('main_content_frontend_compiler.dart')));
  });
}
