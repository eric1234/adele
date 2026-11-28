import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tools/adele.dart' as tooling;
import '../../../tools/git_test_aot_client.dart' show gitTestAotLocator;
import 'code_editor_dependency_fixture.dart';
import 'desktop_launcher_inputs.dart';
import 'rich_editor_dependency_fixture.dart';

/// A private mutable repository and synthetic toolchain for one launcher test.
final class DesktopLauncherFixture {
  DesktopLauncherFixture._(this.root);

  final Directory root;
  late final Directory sdkBin;
  late final File commands;
  late final File generationArguments;
  late final File generatedContract;
  late final File contractSource;
  late final File buildInputs;
  late final File sdkVersion;
  late final File launchArguments;
  late final Directory _appTestInvocations;
  late final File gitHostedArguments;
  late final File frontendArguments;
  late final File frontendEnvironment;
  late final Map<String, String> environment;

  static Future<DesktopLauncherFixture> create() async {
    final root = Directory.systemTemp.createTempSync('adele launcher ');
    addTearDown(() => root.deleteSync(recursive: true));
    final fixture = DesktopLauncherFixture._(root);
    await fixture._populateRepository();
    return fixture;
  }

  Future<void> _populateRepository() async {
    // Copy the SDK-only launcher graph; the worker is never source-executed.
    for (final String path in <String>[
      'tools/adele.dart',
      'tools/backend_artifacts.dart',
      'tools/desktop_artifact_cache.dart',
      'tools/desktop_build_inputs.dart',
      'tools/desktop_build_inputs_worker.dart',
      'tools/desktop_tool_artifacts.dart',
      'tools/build_timing.dart',
      'tools/code_editor_dependency.dart',
      'tools/rich_editor_dependency.dart',
      'tools/code_editor_smoke.dart',
      'tools/code_editor_smoke_support.dart',
      'tools/contract_artifacts.dart',
      'tools/git_test_aot_client.dart',
      'tools/git_test_aot_inputs.dart',
      'tools/git_test_aot_store.dart',
      'tools/git_test_aot_worker.dart',
      'tools/test_contract_provenance.dart',
      'packages/contract_codegen/lib/src/provenance_files.dart',
      'tools/frontend_artifacts.dart',
      'tools/git_pty_artifact.dart',
      'tools/stock_frontend_descriptors.dart',
      'tools/test_runner.dart',
      'packages/plugin_builder/lib/plugin_builder.dart',
      'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      'plugins/git/packages/backend/native/git_pty_helper.c',
      'plugins/openai/records.schema.json',
      'plugins/agent_configuration/records.schema.json',
      modelPresetSchema,
      'plugins/chat_strategy/settings.schema.json',
      'plugins/conservative_tool_policy/settings.schema.json',
      'plugins/source_editor/settings.schema.json',
    ]) {
      final File destination = File('${root.path}/$path');
      destination.parent.createSync(recursive: true);
      File(path).copySync(destination.path);
    }
    await createCodeEditorDependencyFixture(root);
    await createRichEditorDependencyFixture(root);
    Directory('${root.path}/app').createSync();
    final File harness = File('${root.path}/app/$frontendHarness');
    harness.parent.createSync();
    harness.writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$toolFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$openaiFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$agentConfigurationFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$modelConfigurationFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$sessionEvaluatorFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$localDirectoryProjectFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$taskBrowserFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$terminalFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$sourceEditorFrontendHarness',
    ).writeAsStringSync('void main() {}');
    final diffHarness = File('${root.path}/app/$diffViewerFrontendHarness');
    diffHarness.parent.createSync(recursive: true);
    diffHarness.writeAsStringSync('void main() {}');
    for (final String entrypoint in <String>[
      codegenEntrypoint,
      ...backendEntrypoints,
    ]) {
      final File source = File('${root.path}/$entrypoint');
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('void main() {}');
    }
    final packages = {
      'adele_workspace': (
        path: '.',
        packageUri: 'lib/',
        dependencies: <String>[],
        devDependencies: ['analyzer', 'yaml'],
      ),
      'contract_codegen': (
        path: 'packages/contract_codegen',
        packageUri: 'lib/',
        dependencies: ['analyzer'],
        devDependencies: ['unused_test'],
      ),
      'analyzer': (
        path: 'external packages/analyzer',
        packageUri: 'custom lib/',
        dependencies: ['collection'],
        devDependencies: ['unused_test'],
      ),
      'yaml': (
        path: 'external packages/yaml',
        packageUri: 'lib/',
        dependencies: <String>[],
        devDependencies: <String>[],
      ),
      'collection': (
        path: 'external packages/collection',
        packageUri: 'lib/',
        dependencies: <String>[],
        devDependencies: <String>[],
      ),
      'unused_test': (
        path: 'external packages/unused_test',
        packageUri: 'lib/',
        dependencies: <String>[],
        devDependencies: <String>[],
      ),
    };
    for (final package in packages.entries) {
      final manifest = File('${root.path}/${package.value.path}/pubspec.yaml');
      manifest.parent.createSync(recursive: true);
      manifest.writeAsStringSync('''
name: ${package.key}
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
${package.value.dependencies.map((name) => '  $name: any').join('\n')}
dev_dependencies:
${package.value.devDependencies.map((name) => '  $name: any').join('\n')}
''');
    }
    for (final path in [
      generatorSource,
      analyzerSource,
      yamlSource,
      transitiveSource,
      unusedDevSource,
    ]) {
      final source = File('${root.path}/$path');
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('// fixture tool input\n');
    }
    File('${root.path}/pubspec.lock').writeAsStringSync('packages: {}\n');
    final packageConfig = File('${root.path}/.dart_tool/package_config.json');
    packageConfig.parent.createSync(recursive: true);
    packageConfig.writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final package in packages.entries)
            {
              'name': package.key,
              'rootUri': Directory(
                '${root.path}/${package.value.path}',
              ).uri.toString(),
              'packageUri': Uri(path: package.value.packageUri).toString(),
              'languageVersion': '3.10',
            },
        ],
      }),
    );
    File('${root.path}/.dart_tool/package_graph.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 1,
        'roots': ['adele_workspace', 'contract_codegen'],
        'packages': [
          for (final package in packages.entries)
            {
              'name': package.key,
              'version': '1.0.0',
              'dependencies': package.value.dependencies,
              'devDependencies': package.value.devDependencies,
            },
        ],
      }),
    );
    for (final path in <String>{
      ...tooling.analysisTargets.map((target) => target.path),
      ...tooling.testTargets.map((target) => target.path),
    }) {
      Directory('${root.path}/$path').createSync(recursive: true);
    }
    final Directory bin = Directory('${root.path}/bin')..createSync();
    final Directory flutterRoot = Directory('${root.path}/flutter sdk');
    sdkBin = Directory('${flutterRoot.path}/bin/cache/dart-sdk/bin')
      ..createSync(recursive: true);
    for (final path in [
      'bin/cache/dart-sdk/bin/dartvm',
      'bin/cache/dart-sdk/bin/snapshots/dartdev_aot.dart.snapshot',
      'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',
      'bin/cache/dart-sdk/bin/utils/gen_snapshot',
      'bin/cache/dart-sdk/lib/_internal/vm_platform_strong.dill',
      'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill',
      'bin/cache/dart-sdk/lib/_internal/vm_platform.dill',
      'bin/cache/flutter_tools.snapshot',
      'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot',
      'bin/cache/artifacts/engine/linux-x64/flutter_tester',
      'bin/cache/artifacts/engine/linux-x64/icudtl.dat',
      'bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill',
    ]) {
      final file = File('${flutterRoot.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fixture SDK input $path\n');
    }
    final logs = Directory('${root.path}/logs')..createSync();
    commands = File('${logs.path}/commands.txt');
    generationArguments = File('${logs.path}/generation-arguments.txt');
    generatedContract = File('${root.path}/contracts/contract.g.dart');
    generatedContract.parent.createSync();
    contractSource = File('${root.path}/contract.dart')
      ..writeAsStringSync('generated contracts\n');
    final sourcePaths = <String>{
      sharedSource,
      frontendBridge,
      chatSource,
      chatCompiler,
      nativeHeader,
      'native/ld',
      'native/libc.so',
      for (final kind in frontendCompilations.keys)
        'plugins/${kind.replaceAll('-', '_')}/packages/frontend/lib/fixture.dart',
    };
    for (final path in sourcePaths) {
      final file = File('${root.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('// fixture $path\n');
    }
    buildInputs = File('${root.path}/build-inputs.json')
      ..writeAsStringSync(
        jsonEncode({
          for (final backend in backendStages.entries)
            backend.key: <String>[
              '${root.path}/${backend.value}',
              '${root.path}/$sharedSource',
              generatedContract.path,
              '${root.path}/tools/desktop_build_inputs.dart',
              '${root.path}/tools/desktop_build_inputs_worker.dart',
            ]..sort(),
          for (final frontend in frontendCompilations.entries)
            '${frontend.key}-frontend-compilation': <String>[
              '${root.path}/app/${frontend.value.split('|').first}',
              '${root.path}/plugins/${frontend.key.replaceAll('-', '_')}/packages/frontend/lib/fixture.dart',
              '${root.path}/$sharedSource',
              '${root.path}/$frontendBridge',
              '${root.path}/tools/desktop_build_inputs.dart',
              '${root.path}/tools/desktop_build_inputs_worker.dart',
              if (frontend.key == 'chat') ...[
                '${root.path}/$chatSource',
                '${root.path}/$chatCompiler',
                generatedContract.path,
              ],
            ]..sort(),
        }),
      );
    sdkVersion = File('${root.path}/sdk-version.json')
      ..writeAsStringSync(
        jsonEncode({
          'flutterRoot': flutterRoot.path,
          'frameworkRevision': 'fixture-framework-1',
          'engineRevision': 'fixture-engine-1',
          'dartSdkVersion': 'fixture-dart-1',
        }),
      );
    launchArguments = File('${logs.path}/launch-arguments.txt');
    _appTestInvocations = Directory('${logs.path}/app-tests')..createSync();
    gitHostedArguments = File('${logs.path}/git-hosted-arguments.txt');
    frontendArguments = File('${logs.path}/frontend-arguments.txt');
    frontendEnvironment = File('${logs.path}/frontend-environment.txt');
    environment = <String, String>{
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR': '',
      gitTestAotLocator: '/inherited/worker.sock',
      for (final suffix in [
        'CREDENTIAL_FILE',
        'CLIENT_ID',
        'INSTANCE_ID',
        'OAUTH_ISSUER',
        'REDIRECT_URI',
        'ENDPOINT',
        'MODEL',
      ])
        'ADELE_OPENAI_CHATGPT_$suffix': '',
    };
    _writeExecutables(bin, logs, packageConfig);
  }

  void _writeExecutables(Directory bin, Directory logs, File packageConfig) {
    String generatorScript(String sdk, {bool aot = false}) =>
        '''
if [ "\$1" = run ]; then
  test "\$PWD" = '${root.path}' || exit 98
  test "\$2" = '$codegenEntrypoint' && test -f "\$2" || exit 97
  if [ "\$#" = 3 ]; then
    test "\$3" = --check || test "\$3" = --clean${aot ? ' || test "\$3" = --incremental' : ''} || exit 96
  else
    test "\$#" = 2 || exit 96
  fi
  printf 'generate|$sdk%s\n' "\${3:+|\$3}" >> '${commands.path}'
  ${aot ? '{ printf \'%s\\n\' "\$snapshot"; if [ "\$#" = 3 ]; then printf \'%s\\n\' "\$3"; fi; }' : 'printf \'%s\\n\' "\$@"'} > '${generationArguments.path}'
  printf 'contract generator output\n'
  if [ "\$ADELE_TEST_FAIL_GENERATION" = 1 ]; then
    printf 'contract generator failed\n' >&2
    exit 29
  fi
  if [ "\$3" = --check ]; then
    if [ ! -f '${generatedContract.path}' ] || ! cmp -s '${generatedContract.path}' '${contractSource.path}'; then
      printf 'contract outputs are missing or stale\n' >&2
      exit 31
    fi
  elif [ "\$3" = --clean ]; then
    rm -f '${generatedContract.path}'
  else
    cp '${contractSource.path}' '${generatedContract.path}'
  fi
  if [ -n "\$ADELE_TEST_MUTATE_TOOL_DURING_GENERATION" ]; then
    printf '\n// changed while launcher was already loaded\n' >> "\$ADELE_TEST_MUTATE_TOOL_DURING_GENERATION"
  fi
  exit 0
fi
''';
    writeExecutableScript(File('${bin.path}/flutter'), '''
if [ "\$1" = "--version" ]; then
  printf 'inspect-sdk\n' >> '${commands.path}'
  cat '${sdkVersion.path}'
elif [ "\$1" = pub ]; then
  test "\$PWD" = '${root.path}' || exit 98
  test -f '${root.path}/.adele/dependencies/code_forge/lib/code.dart' || exit 94
  test -f '${root.path}/.adele/dependencies/appflowy_editor/lib/editor.dart' || exit 94
  test "\$#" = 2 && test "\$2" = get || exit 97
  printf 'pub-get\n' >> '${commands.path}'
  if [ "\$ADELE_TEST_FAIL_DEPENDENCY" = pub-get ]; then exit 19; fi
elif [ "\$1" = analyze ] || { [ "\$1" = test ] && [ "\$2" != --no-pub ]; }; then
  test -f '${generatedContract.path}' || exit 95
  # This checkout is inside system temp, hence no Flutter worker gets a scope.
  if [ "\$1" = test ]; then test -z "\$$gitTestAotLocator" || exit 93; fi
  if [ "\$1" = test ] && [ "\$PWD" = '${root.path}/app' ]; then
    library_dir=\$(cat '${logs.path}/codeforge-build-dir') || exit 94
    test "\$FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR" = "\$library_dir" || exit 94
    test -s "\$FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR/libcode_forge.so" || exit 94
    printf '%s\n' "\$@" > '${_appTestInvocations.path}/'\$\$
    if [ "\$ADELE_TEST_FAIL_INTERACTION" = 1 ]; then
      for arg do
        case "\$arg" in plugin_interactions_test|plugin_interactions_test/*) exit 36 ;; esac
      done
    fi
  elif [ "\$1" = test ] && [ "\$PWD" = '${root.path}/plugins/diff_viewer/packages/frontend' ]; then
    test -z "\$FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR" || exit 94
  elif [ "\$1" = test ] && [ "\$PWD" = '${root.path}/plugins/git/packages/desktop_tests' ]; then
    test -z "\$FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR" || exit 94
    printf '%s\n' "\$@" > '${gitHostedArguments.path}'
    if [ "\$ADELE_TEST_FAIL_GIT_HOSTED" = 1 ]; then exit 38; fi
  fi
  printf '%s|flutter|%s\n' "\$1" "\$PWD" >> '${commands.path}'
elif [ "\$1" = test ]; then
  test -f '${generatedContract.path}' || exit 95
  test "\$PWD" = '${root.path}/app' || exit 98
  test "\$#" = 5 && test "\$2" = --no-pub && test "\$3" = --concurrency && test "\$4" = 1 || exit 97
  test -f "\$5" || exit 96
  test "\$ADELE_REPOSITORY_ROOT" = '${root.path}' || exit 95
  if [ "\$5" = '$frontendHarness' ]; then
    kind=chat
    output="\$ADELE_CHAT_FRONTEND_OUTPUT"
    label='$frontendHarness'
    printf '%s\n' "\$@" > '${frontendArguments.path}'
    printf '%s\n' "\$ADELE_REPOSITORY_ROOT" "\$output" > '${frontendEnvironment.path}'
  elif [ "\$5" = '$openaiFrontendHarness' ]; then
    kind=openai
    output="\$ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT"
    label='$openaiFrontendHarness'
  elif [ "\$5" = '$agentConfigurationFrontendHarness' ]; then
    kind=agent-configuration
    output="\$ADELE_AGENT_CONFIGURATION_FRONTEND_OUTPUT"
    label='$agentConfigurationFrontendHarness'
  elif [ "\$5" = '$modelConfigurationFrontendHarness' ]; then
    kind=model-configuration
    output="\$ADELE_MODEL_CONFIGURATION_FRONTEND_OUTPUT"
    label='$modelConfigurationFrontendHarness'
  elif [ "\$5" = '$localDirectoryProjectFrontendHarness' ]; then
    kind=local-directory-project
    output="\$ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT"
    label='$localDirectoryProjectFrontendHarness'
  elif [ "\$5" = '$sessionEvaluatorFrontendHarness' ]; then
    kind=session-evaluator
    output="\$ADELE_SESSION_EVALUATOR_FRONTEND_OUTPUT"
    label='$sessionEvaluatorFrontendHarness'
  elif [ "\$5" = '$taskBrowserFrontendHarness' ]; then
    kind=task-browser
    output="\$ADELE_TASK_BROWSER_FRONTEND_OUTPUT"
    label='$taskBrowserFrontendHarness'
  elif [ "\$5" = '$terminalFrontendHarness' ]; then
    kind=terminal
    output="\$ADELE_TERMINAL_FRONTEND_OUTPUT"
    label='$terminalFrontendHarness'
  elif [ "\$5" = '$sourceEditorFrontendHarness' ]; then
    kind=source-editor
    output="\$ADELE_SOURCE_EDITOR_FRONTEND_OUTPUT"
    label='$sourceEditorFrontendHarness'
  elif [ "\$5" = '$diffViewerFrontendHarness' ]; then
    kind=diff-viewer
    output="\$ADELE_DIFF_VIEWER_FRONTEND_OUTPUT"
    label='$diffViewerFrontendHarness'
  else
    test "\$5" = '$toolFrontendHarness' || exit 92
    kind="\$ADELE_TOOL_INSPECTION_FRONTEND"
    output="\$ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT"
    label="$toolFrontendHarness|\$kind"
  fi
  case "\$output" in /*) ;; *) exit 94 ;; esac
  test ! -e "\$output" || exit 93
  for manifest in "\$(dirname "\$(dirname "\$output")")"/*/adele_plugin.installation.json; do
    test ! -e "\$manifest" || exit 91
  done
  printf 'compile|%s\n' "\$label" >> '${commands.path}'
  failure=''
  fail_exit=''
  if [ "\$kind" = "\${ADELE_TEST_FRONTEND_TARGET:-chat}" ]; then
    failure="\$ADELE_TEST_FRONTEND_ARTIFACT"
    fail_exit="\$ADELE_TEST_FAIL_FRONTEND"
  fi
  if [ "\$failure" != missing ]; then
    if [ "\$failure" = empty ]; then
      : > "\$output"
    else
      printf 'frontend bytecode\n' > "\$output"
    fi
  fi
  if [ "\$fail_exit" = 1 ]; then
    printf 'frontend compiler failed' >&2
    exit 23
  fi
  printf 'compiled|%s\n' "\$label" >> '${commands.path}'
  printf 'frontend compiler output\n'
else
  test -f '${generatedContract.path}' || exit 95
  test "\$PWD" = '${root.path}/app' || exit 98
  printf 'flutter-launch\n' >> '${commands.path}'
  printf '%s\n' "\$@" > '${launchArguments.path}'
fi
''');
    writeExecutableScript(File('${bin.path}/dart'), '''
${generatorScript('path')}
if [ "\$1" = pub ]; then
  test "\$PWD" = '${root.path}' || exit 98
  test "\$#" = 3 && test "\$2" = workspace && test "\$3" = list || exit 97
  printf 'workspace-list\n' >> '${commands.path}'
  if [ "\$ADELE_TEST_FAIL_DEPENDENCY" = workspace-list ]; then exit 19; fi
elif [ "\$1" = format ]; then
  test "\$#" = 4 && test "\$2" = --output=none && test "\$3" = --set-exit-if-changed && test "\$4" = . || exit 97
  printf 'format-check\n' >> '${commands.path}'
elif [ "\$1" = analyze ] || [ "\$1" = test ]; then
  test -f '${generatedContract.path}' || exit 95
  printf '%s|dart|%s\n' "\$1" "\$PWD" >> '${commands.path}'
elif [ "\$1" = tools/adele.dart ] && [ "\$2" = test-credential-store-native ]; then
  test "\$#" = 2 || exit 97
  test "\$PWD" = '${root.path}' || exit 98
  test -f '${generatedContract.path}' || exit 95
  printf 'test|dart|%s|%s %s\n' "\$PWD" "\$1" "\$2" >> '${commands.path}'
  if [ "\$ADELE_TEST_FAIL_CREDENTIAL_NATIVE" = 1 ]; then exit 37; fi
else
  exit 99
fi
''');
    writeExecutableScript(File('${bin.path}/rustup'), '''
test "\$1" = run && test "\$2" = 1.93.0 && test "\$3" = cargo || exit 98
test "\$4" = build && test "\$5" = --locked && test "\$6" = --release || exit 97
test "\$7" = --manifest-path && test "\$9" = --target-dir || exit 96
test "\${11}" = --target && test "\${12}" = x86_64-unknown-linux-gnu || exit 96
if [ "\$ADELE_TEST_FAIL_CODEFORGE_NATIVE" = 1 ]; then exit 35; fi
mkdir -p "\${10}/\${12}/release"
printf 'native fixture' > "\${10}/\${12}/release/libcode_forge.so"
printf '%s\n' "\${10}/\${12}/release" > '${logs.path}/codeforge-build-dir'
''');
    writeExecutableScript(File('${bin.path}/dartaotruntime'), 'exit 99');
    writeExecutableScript(File('${sdkBin.path}/dartaotruntime'), '''
test "\$PWD" = '${root.path}' || exit 98
printf '%s\n' "\$1" >> '${logs.path}/aot-executions.txt'
test -f "\$1" || exit 96
snapshot="\$1"
kind=\$(cat "\$snapshot")
shift
if [ "\$kind" = 'snapshot $workerEntrypoint' ]; then
  test "\$#" = 1 && test "\$1" = '${root.path}' || exit 97
  test -f '${generatedContract.path}' || exit 95
  printf 'discover|aot\n' >> '${logs.path}/discovery.txt'
  printf '%s\n' "\$snapshot" "\$@" >> '${logs.path}/discovery-arguments.txt'
  if [ "\$ADELE_TEST_FAIL_DISCOVERY" = 1 ]; then
    printf 'discovery worker failed\n' >&2
    exit 41
  fi
  if [ "\$(wc -l < '${logs.path}/discovery.txt')" -eq 2 ]; then
    if [ -n "\$ADELE_TEST_MUTATE_TOOL_DURING_DISCOVERY" ]; then
      printf '\n// changed during discovery\n' >> "\$ADELE_TEST_MUTATE_TOOL_DURING_DISCOVERY"
    fi
    if [ -n "\$ADELE_TEST_FINAL_DISCOVERY_HOOK" ]; then
      "\$ADELE_TEST_FINAL_DISCOVERY_HOOK" || exit \$?
    fi
  fi
  cat '${buildInputs.path}'
  exit 0
fi
test "\$kind" = 'snapshot $codegenEntrypoint' || exit 94
set -- run '$codegenEntrypoint' "\$@"
${generatorScript('aot', aot: true)}
exit 99
''');
    writeExecutableScript(File('${bin.path}/cc'), '''
test "\$PWD" = '${root.path}' || exit 98
if [ "\$1" = --version ]; then
  if [ "\$ADELE_TEST_FAIL_NATIVE_INSPECTION" = 1 ]; then
    printf 'native probe stdout\n'
    printf 'native probe stderr\n' >&2
    exit 43
  fi
  printf 'fixture cc version 1\n'
  exit 0
fi
case "\$1" in
  -print-prog-name=*) printf '%s\n' '${root.path}/native/ld'; exit 0 ;;
  -print-file-name=libc.so) printf '%s\n' '${root.path}/native/libc.so'; exit 0 ;;
  -print-file-name=*) printf '%s\n' "\${1#*=}"; exit 0 ;;
esac
if [ "\$1" = -E ]; then
  test "\$#" = 7 && test -f "\$7" || exit 97
  printf '# 1 %s\n' '${jsonEncode('${root.path}/$nativeHeader')}'
  cat "\$7" '${root.path}/$nativeHeader'
  exit 0
fi
test "\$#" = 9 && test "\$7" = -o && test "\$9" = -lutil || exit 97
test -f "\$6" || exit 96
printf 'compile|git-pty-helper\n' >> '${commands.path}'
if [ "\$ADELE_TEST_FAIL_PTY" = 1 ]; then
  printf 'native compiler failed' >&2
  exit 37
fi
if [ "\$ADELE_TEST_PTY_ARTIFACT" != missing ]; then
  if [ "\$ADELE_TEST_PTY_ARTIFACT" = empty ]; then
    : > "\$8"
  else
    printf 'prepared native helper\n' > "\$8"
    chmod +x "\$8"
  fi
fi
''');
    const escapeDepfile = r'''
depfile_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/ /\\ /g'; }
''';
    writeExecutableScript(File('${sdkBin.path}/dart'), '''
$escapeDepfile
test "\$PWD" = '${root.path}' || exit 98
test "\$1" = compile && test "\$2" = aot-snapshot && test "\$4" = -o || exit 97
test -f "\$3" || exit 96
entrypoint="\${3#${root.path}/}"
tool=0
case "\$entrypoint" in
  '$codegenEntrypoint'|'$workerEntrypoint')
    tool=1
    test "\$#" = 9 && test "\$6" = --depfile || exit 97
    test "\$8" = --packages && test "\$9" = '${packageConfig.path}' || exit 97
    test "\$(dirname "\$5")" != "\$(dirname "\$7")" || exit 94
    ;;
  *) test "\$#" = 5 && test -f '${generatedContract.path}' || exit 95 ;;
esac
printf 'compile|%s\n' "\$entrypoint" >> '${commands.path}'
if [ "\$ADELE_TEST_PAUSE_ENTRYPOINT" = "\$entrypoint" ]; then
  touch '${logs.path}/compiler-ready'
  attempts=0
  while [ ! -f '${logs.path}/compiler-release' ]; do
    attempts=\$((attempts + 1))
    test "\$attempts" -lt 1000 || exit 90
    sleep 0.02
  done
fi
if [ "\$tool" = 0 ] && [ -n "\$ADELE_TEST_MUTATE_SOURCE" ]; then
  printf '\n// changed during compilation\n' >> "\$ADELE_TEST_MUTATE_SOURCE"
fi
if [ "\$tool" = 0 ] && [ -n "\$ADELE_TEST_COMPILE_HOOK" ]; then
  "\$ADELE_TEST_COMPILE_HOOK" || exit \$?
fi
if [ "\$ADELE_TEST_FAIL_ENTRYPOINT" = "\$entrypoint" ]; then
  printf 'snapshot compiler failed' >&2
  exit 17
fi
if [ "\$ADELE_TEST_OMIT_ARTIFACT" != "\$entrypoint" ]; then
  if [ "\$ADELE_TEST_EMPTY_ARTIFACT" = "\$entrypoint" ]; then
    : > "\$5"
  else
    printf 'snapshot %s\n' "\$entrypoint" > "\$5"
  fi
fi
if [ "\$tool" = 1 ] && [ "\$ADELE_TEST_TOOL_DEPFILE" != missing ]; then
  if [ "\$ADELE_TEST_TOOL_DEPFILE" = empty ]; then
    : > "\$7"
  else
    depfile_escape "\$5" > "\$7"
    printf ': ' >> "\$7"
    if [ "\$entrypoint" = '$codegenEntrypoint' ]; then
      printf '%s' '${_depfileEscape('${root.path}/$codegenEntrypoint')}' >> "\$7"
    else
      printf '%s' '${_depfileEscape('${root.path}/$workerEntrypoint')}' >> "\$7"
    fi
    printf ' %s %s\n' '${_depfileEscape(packageConfig.path)}' '${_depfileEscape('${root.path}/$analyzerSource')}' >> "\$7"
    if [ "\$ADELE_TEST_TOOL_DEPFILE" = undeclared ]; then
      printf ' %s\n' '${_depfileEscape('${root.path}/$unusedDevSource')}' >> "\$7"
    fi
  fi
fi
printf 'compiled|%s\n' "\$entrypoint" >> '${commands.path}'
''');
  }

  Future<ProcessResult> invoke(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    <String>['tools/adele.dart', ...arguments],
    workingDirectory: root.path,
    environment: environment,
  );

  List<List<String>> appTestInvocations() => [
    for (final log in _appTestInvocations.listSync().whereType<File>())
      log.readAsLinesSync(),
  ];

  void expectGenerationArguments([
    List<String> options = const [],
    bool aot = false,
  ]) {
    if (aot) {
      final arguments = generationArguments.readAsLinesSync();
      expect(arguments, hasLength(1 + options.length));
      expect(
        arguments.first,
        startsWith('${root.path}/.dart_tool/adele/desktop-plugins/'),
      );
      expect(arguments.first, endsWith('/tool.aot'));
      expect(arguments.skip(1), options);
      return;
    }
    expect(generationArguments.readAsLinesSync(), [
      'run',
      codegenEntrypoint,
      ...options,
    ]);
  }

  String readStartupArguments() {
    const prefix = '--dart-define=ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE=';
    final argument = launchArguments.readAsLinesSync().singleWhere(
      (value) => value.startsWith(prefix),
    );
    return File(argument.substring(prefix.length)).readAsStringSync();
  }

  List<String> gitStartupArguments() {
    const prefix = '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=';
    final argument = launchArguments.readAsLinesSync().singleWhere(
      (value) => value.startsWith(prefix),
    );
    final helper = File.fromUri(
      Directory(
        argument.substring(prefix.length),
      ).uri.resolve('git/pty-helper'),
    );
    return ['--pty-helper=${helper.path}'];
  }

  void expectNoPublishedInstallations() {
    final output = Directory('${root.path}/.dart_tool/adele/desktop-plugins');
    if (!output.existsSync()) return;
    expect(
      output
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => !file.path.contains('/.staging/'))
          .where(
            (file) =>
                file.path.endsWith('adele_plugin.installation.json') ||
                file.path.endsWith('startup-arguments.json'),
          ),
      isEmpty,
    );
  }

  Map<String, String> launchDefines() => {
    for (final argument in launchArguments.readAsLinesSync())
      if (argument.startsWith('--dart-define='))
        argument.substring('--dart-define='.length).split('=').first: argument
            .substring(argument.indexOf('=', '--dart-define='.length) + 1),
  };

  List<String> compilations() => commands
      .readAsLinesSync()
      .where((line) => line.startsWith('compile|'))
      .map((line) => line.substring('compile|'.length))
      .where((entrypoint) => !toolStages.containsValue(entrypoint))
      .toList();

  List<String> toolCompilations() => commands
      .readAsLinesSync()
      .where((line) => line.startsWith('compile|'))
      .map((line) => line.substring('compile|'.length))
      .where(toolStages.containsValue)
      .toList();

  void removeBootstrapMetadata() {
    Directory('${root.path}/.dart_tool').deleteSync(recursive: true);
    File('${root.path}/pubspec.yaml').deleteSync();
    File('${root.path}/pubspec.lock').deleteSync();
  }

  void changeSource(String path) => File(
    '${root.path}/$path',
  ).writeAsStringSync('\n// changed input\n', mode: FileMode.append);

  Future<Map<String, String>> prepare([
    List<String> arguments = const ['run', 'linux'],
  ]) async {
    if (commands.existsSync()) commands.deleteSync();
    final result = await invoke(arguments);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return launchDefines();
  }

  List<File> publishedFiles() {
    final cache = Directory('${root.path}/.dart_tool/adele/desktop-plugins');
    return cache
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              !file.path.contains('/.staging/') &&
              file.path.contains('/entry-'),
        )
        .toList();
  }

  Map<String, List<int>> retainedFiles() => {
    for (final file in publishedFiles()) file.path: file.readAsBytesSync(),
  };

  void expectRetained(Map<String, List<int>> retained) {
    for (final file in retained.entries) {
      expect(File(file.key).readAsBytesSync(), file.value, reason: file.key);
    }
  }

  File componentArtifact(String stage) => publishedFiles().singleWhere(
    (file) =>
        file.path.contains('/components/$stage/') &&
        file.uri.pathSegments.last != 'receipt.json',
  );
}

void writeExecutableScript(File file, String body) {
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
}

String _depfileEscape(String path) =>
    path.replaceAll(r'\', r'\\').replaceAll(' ', r'\ ');
