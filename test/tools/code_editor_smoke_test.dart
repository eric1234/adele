import 'dart:io';

import 'package:test/test.dart';

import '../../tools/code_editor_probe.dart';
import '../../tools/code_editor_smoke.dart';

void main() {
  test('manual build identity comes from production preparation metadata', () {
    final identity = codeEditorSmokeIdentity({
      'version': '10.14.0',
      'archiveSha256': 'archive-digest',
      'patches': ['01-build.patch', '03-embedding.patch'],
      'flutterRustBridge': '2.13.0',
      'rust': '1.93.0',
    }, preparationIdentity: 'prepared-digest');
    expect(identity, contains('CodeForge 10.14.0'));
    expect(identity, contains('archive archive-digest'));
    expect(identity, contains('01-build.patch, 03-embedding.patch'));
    expect(identity, contains('FRB 2.13.0 | Rust 1.93.0'));
    expect(identity, endsWith('prepared prepared-digest'));
  });

  test('integrated smoke markers use the existing settlement validator', () {
    const completed = '''
CODEFORGE_FRB_INIT_RETURNED
CODEFORGE_NATIVE_INITIALIZED
CODEFORGE_NOTICES_BUNDLED
CODEFORGE_PLATFORM_INPUT_OK
CODEFORGE_CLIPBOARD_READONLY_OK
CODEFORGE_RENDERED
CODEFORGE_UNMOUNTED_OWNER_RETAINED
CODEFORGE_PREPARED_REMOUNT_OK
CODEFORGE_NATIVE_DISPOSED
CODEFORGE_PROBE_COMPLETE
''';
    expect(
      () => validateCodeEditorProbeSmoke(ProcessResult(1, 0, completed, '')),
      returnsNormally,
    );
    expect(
      () => validateCodeEditorProbeSmoke(
        ProcessResult(1, 0, completed, 'CODEFORGE_SMOKE_FAILED'),
      ),
      throwsStateError,
    );
    expect(
      () => validateCodeEditorProbeMissingLibrary(
        ProcessResult(1, 1, 'CODEFORGE_INIT_FAILED', ''),
      ),
      returnsNormally,
    );
    expect(
      () => validateCodeEditorProbeMissingLibrary(
        ProcessResult(1, 124, 'CODEFORGE_INIT_FAILED', ''),
      ),
      throwsStateError,
    );
  });

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
    expect(source, contains('smoke_settlement.dart'));
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
      'code_editor_dependency.dart',
      'code_editor_probe.dart',
    ]);
    expect(source, isNot(contains('buildNativeCodeEditorForTests')));
    expect(source, isNot(contains("'cargo'")));
    expect(source, contains('codeEditorProbeRuntimeEnvironment(environment)'));
    expect(
      source.indexOf("run('prepare-evc'"),
      lessThan(source.indexOf("run('profile-build'")),
    );
    expect(
      source,
      contains(r"artifact.copy('${bundle.path}/data/editor_frontend.evc')"),
    );
  });
}
