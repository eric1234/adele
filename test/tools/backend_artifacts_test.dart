import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../../packages/plugin_builder/lib/plugin_builder.dart';
// ignore: avoid_relative_lib_imports
import '../../packages/plugin_runtime/lib/plugin_runtime.dart';
import '../../tools/adele.dart' as tooling;
import '../../tools/backend_artifacts.dart';
import '../../tools/contract_artifacts.dart';
import '../../tools/stock_frontend_descriptors.dart';
import 'code_editor_dependency_test.dart'
    show createCodeEditorDependencyFixture;

const String _codegenEntrypoint =
    'packages/contract_codegen/bin/contract_codegen.dart';
const String _workerEntrypoint = 'tools/desktop_build_inputs_worker.dart';
const _toolStages = {
  'contract-codegen-compilation': _codegenEntrypoint,
  'desktop-inputs-compilation': _workerEntrypoint,
};
final _toolCompilationEvents = [
  for (final entrypoint in [_codegenEntrypoint, _workerEntrypoint]) ...[
    'compile|$entrypoint',
    'compiled|$entrypoint',
  ],
];
const _generatorSource = 'packages/contract_codegen/lib/generator.dart';
const _analyzerSource =
    r'external packages/analyzer/custom lib/escaped\ file.dart';
const _yamlSource = 'external packages/yaml/lib/yaml.dart';
const _transitiveSource = 'external packages/collection/lib/collection.dart';
const _unusedDevSource = 'external packages/unused_test/lib/test.dart';
const String _hostEntrypoint =
    'packages/plugin_backend_host/bin/adele_backend_host.dart';
const String _gitEntrypoint =
    'plugins/git/packages/backend/bin/git_backend.dart';
const String _openaiEntrypoint =
    'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart';
const String _agentsMdEntrypoint =
    'plugins/agents_md/packages/backend/bin/agents_md_backend.dart';
const String _searchToolsEntrypoint =
    'plugins/search_tools/packages/backend/bin/search_tools_backend.dart';
const String _filesystemToolsEntrypoint =
    'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart';
const String _commandToolsEntrypoint =
    'plugins/command_tools/packages/backend/bin/command_tools_backend.dart';
const String _chatEntrypoint =
    'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart';
const String _localDirectoryProjectEntrypoint =
    'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart';
const String _sessionEvaluatorEntrypoint =
    'plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart';
const String _diffViewerEntrypoint =
    'plugins/diff_viewer/packages/backend/bin/diff_viewer_backend.dart';
const _backendEntrypoints = [
  _hostEntrypoint,
  _gitEntrypoint,
  _openaiEntrypoint,
  _agentsMdEntrypoint,
  _searchToolsEntrypoint,
  _filesystemToolsEntrypoint,
  _commandToolsEntrypoint,
  _chatEntrypoint,
  _localDirectoryProjectEntrypoint,
  _sessionEvaluatorEntrypoint,
  _diffViewerEntrypoint,
];
const String _frontendHarness = 'tool/compile_chat_frontend.dart';
const String _toolFrontendHarness =
    'tool/compile_tool_inspection_frontends.dart';
const String _openaiFrontendHarness =
    'tool/compile_openai_activity_frontend.dart';
const String _localDirectoryProjectFrontendHarness =
    'tool/compile_local_directory_project_frontend.dart';
const String _taskBrowserFrontendHarness =
    'tool/compile_task_browser_frontend.dart';
const String _terminalFrontendHarness = 'tool/compile_terminal_frontend.dart';
const String _sourceEditorFrontendHarness =
    'tool/compile_source_editor_frontend.dart';
const String _diffViewerFrontendHarness =
    'tool/compile_diff_viewer_frontend.dart';
const _backendStages = {
  'backend-host-compilation': _hostEntrypoint,
  'git-compilation': _gitEntrypoint,
  'openai-compilation': _openaiEntrypoint,
  'agents-md-compilation': _agentsMdEntrypoint,
  'search-tools-compilation': _searchToolsEntrypoint,
  'filesystem-tools-compilation': _filesystemToolsEntrypoint,
  'command-tools-compilation': _commandToolsEntrypoint,
  'chat-strategy-compilation': _chatEntrypoint,
  'local-directory-project-compilation': _localDirectoryProjectEntrypoint,
  'session-evaluator-compilation': _sessionEvaluatorEntrypoint,
  'diff-viewer-compilation': _diffViewerEntrypoint,
};
const _frontendCompilations = {
  'chat': _frontendHarness,
  'filesystem': '$_toolFrontendHarness|filesystem',
  'command': '$_toolFrontendHarness|command',
  'openai': _openaiFrontendHarness,
  'local-directory-project': _localDirectoryProjectFrontendHarness,
  'task-browser': _taskBrowserFrontendHarness,
  'terminal': _terminalFrontendHarness,
  'source-editor': _sourceEditorFrontendHarness,
  'diff-viewer': _diffViewerFrontendHarness,
};
const _sharedSource = 'packages/plugin_api/lib/shared.dart';
const _frontendBridge = 'packages/ui/lib/fixture_bridge.dart';
const _chatSource =
    'plugins/chat_strategy/packages/frontend/lib/chat_strategy_frontend.dart';
const _chatCompiler = 'app/tool/chat_frontend_compiler.dart';
const _nativeSource = 'plugins/git/packages/backend/native/git_pty_helper.c';
const _nativeHeader = 'native/include/fixture.h';

void main() {
  late Directory root;
  late Directory sdkBin;
  late File commands;
  late File generationArguments;
  late File generatedContract;
  late File contractSource;
  late File buildInputs;
  late File sdkVersion;
  late File launchArguments;
  late File frontendArguments;
  late File frontendEnvironment;
  late Map<String, String> environment;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('adele launcher ');
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
      'tools/code_editor_smoke.dart',
      'tools/code_editor_smoke_support.dart',
      'tools/contract_artifacts.dart',
      'tools/frontend_artifacts.dart',
      'tools/git_pty_artifact.dart',
      'tools/stock_frontend_descriptors.dart',
      'tools/test_runner.dart',
      'packages/plugin_builder/lib/plugin_builder.dart',
      'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      'plugins/git/packages/backend/native/git_pty_helper.c',
      'plugins/openai/records.schema.json',
      'plugins/source_editor/settings.schema.json',
    ]) {
      final File destination = File('${root.path}/$path');
      destination.parent.createSync(recursive: true);
      File(path).copySync(destination.path);
    }
    await createCodeEditorDependencyFixture(root);
    Directory('${root.path}/app').createSync();
    final File harness = File('${root.path}/app/$_frontendHarness');
    harness.parent.createSync();
    harness.writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_toolFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_openaiFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_localDirectoryProjectFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_taskBrowserFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_terminalFrontendHarness',
    ).writeAsStringSync('void main() {}');
    File(
      '${root.path}/app/$_sourceEditorFrontendHarness',
    ).writeAsStringSync('void main() {}');
    final diffHarness = File('${root.path}/app/$_diffViewerFrontendHarness');
    diffHarness.parent.createSync(recursive: true);
    diffHarness.writeAsStringSync('void main() {}');
    for (final String entrypoint in <String>[
      _codegenEntrypoint,
      ..._backendEntrypoints,
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
      _generatorSource,
      _analyzerSource,
      _yamlSource,
      _transitiveSource,
      _unusedDevSource,
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
      _sharedSource,
      _frontendBridge,
      _chatSource,
      _chatCompiler,
      _nativeHeader,
      'native/ld',
      'native/libc.so',
      for (final kind in _frontendCompilations.keys)
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
          for (final backend in _backendStages.entries)
            backend.key: <String>[
              '${root.path}/${backend.value}',
              '${root.path}/$_sharedSource',
              generatedContract.path,
              '${root.path}/tools/desktop_build_inputs.dart',
              '${root.path}/tools/desktop_build_inputs_worker.dart',
            ]..sort(),
          for (final frontend in _frontendCompilations.entries)
            '${frontend.key}-frontend-compilation': <String>[
              '${root.path}/app/${frontend.value.split('|').first}',
              '${root.path}/plugins/${frontend.key.replaceAll('-', '_')}/packages/frontend/lib/fixture.dart',
              '${root.path}/$_sharedSource',
              '${root.path}/$_frontendBridge',
              '${root.path}/tools/desktop_build_inputs.dart',
              '${root.path}/tools/desktop_build_inputs_worker.dart',
              if (frontend.key == 'chat') ...[
                '${root.path}/$_chatSource',
                '${root.path}/$_chatCompiler',
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
    frontendArguments = File('${logs.path}/frontend-arguments.txt');
    frontendEnvironment = File('${logs.path}/frontend-environment.txt');
    environment = <String, String>{
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
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
    String generatorScript(String sdk, {bool aot = false}) =>
        '''
if [ "\$1" = run ]; then
  test "\$PWD" = '${root.path}' || exit 98
  test "\$2" = '$_codegenEntrypoint' && test -f "\$2" || exit 97
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
    _script(File('${bin.path}/flutter'), '''
if [ "\$1" = "--version" ]; then
  printf 'inspect-sdk\n' >> '${commands.path}'
  cat '${sdkVersion.path}'
elif [ "\$1" = pub ]; then
  test "\$PWD" = '${root.path}' || exit 98
  test -f '${root.path}/.adele/dependencies/code_forge/lib/code.dart' || exit 94
  test "\$#" = 2 && test "\$2" = get || exit 97
  printf 'pub-get\n' >> '${commands.path}'
  if [ "\$ADELE_TEST_FAIL_DEPENDENCY" = pub-get ]; then exit 19; fi
elif [ "\$1" = analyze ] || { [ "\$1" = test ] && [ "\$2" != --no-pub ]; }; then
  test -f '${generatedContract.path}' || exit 95
  if [ "\$1" = test ] && [ "\$PWD" = '${root.path}/app' ]; then
    test -f "\$FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR/libcode_forge.so" || exit 94
  fi
  printf '%s|flutter|%s\n' "\$1" "\$PWD" >> '${commands.path}'
elif [ "\$1" = test ]; then
  test -f '${generatedContract.path}' || exit 95
  test "\$PWD" = '${root.path}/app' || exit 98
  test "\$#" = 5 && test "\$2" = --no-pub && test "\$3" = --concurrency && test "\$4" = 1 || exit 97
  test -f "\$5" || exit 96
  test "\$ADELE_REPOSITORY_ROOT" = '${root.path}' || exit 95
  if [ "\$5" = '$_frontendHarness' ]; then
    kind=chat
    output="\$ADELE_CHAT_FRONTEND_OUTPUT"
    label='$_frontendHarness'
    printf '%s\n' "\$@" > '${frontendArguments.path}'
    printf '%s\n' "\$ADELE_REPOSITORY_ROOT" "\$output" > '${frontendEnvironment.path}'
  elif [ "\$5" = '$_openaiFrontendHarness' ]; then
    kind=openai
    output="\$ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT"
    label='$_openaiFrontendHarness'
  elif [ "\$5" = '$_localDirectoryProjectFrontendHarness' ]; then
    kind=local-directory-project
    output="\$ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT"
    label='$_localDirectoryProjectFrontendHarness'
  elif [ "\$5" = '$_taskBrowserFrontendHarness' ]; then
    kind=task-browser
    output="\$ADELE_TASK_BROWSER_FRONTEND_OUTPUT"
    label='$_taskBrowserFrontendHarness'
  elif [ "\$5" = '$_terminalFrontendHarness' ]; then
    kind=terminal
    output="\$ADELE_TERMINAL_FRONTEND_OUTPUT"
    label='$_terminalFrontendHarness'
  elif [ "\$5" = '$_sourceEditorFrontendHarness' ]; then
    kind=source-editor
    output="\$ADELE_SOURCE_EDITOR_FRONTEND_OUTPUT"
    label='$_sourceEditorFrontendHarness'
  elif [ "\$5" = '$_diffViewerFrontendHarness' ]; then
    kind=diff-viewer
    output="\$ADELE_DIFF_VIEWER_FRONTEND_OUTPUT"
    label='$_diffViewerFrontendHarness'
  else
    test "\$5" = '$_toolFrontendHarness' || exit 92
    kind="\$ADELE_TOOL_INSPECTION_FRONTEND"
    output="\$ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT"
    label="$_toolFrontendHarness|\$kind"
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
    _script(File('${bin.path}/dart'), '''
${generatorScript('path')}
if [ "\$1" = pub ]; then
  test "\$PWD" = '${root.path}' || exit 98
  test "\$#" = 3 && test "\$2" = workspace && test "\$3" = list || exit 97
  printf 'workspace-list\n' >> '${commands.path}'
  if [ "\$ADELE_TEST_FAIL_DEPENDENCY" = workspace-list ]; then exit 19; fi
elif [ "\$1" = analyze ] || [ "\$1" = test ]; then
  test -f '${generatedContract.path}' || exit 95
  printf '%s|dart|%s\n' "\$1" "\$PWD" >> '${commands.path}'
else
  exit 99
fi
''');
    _script(File('${bin.path}/rustup'), '''
test "\$1" = run && test "\$2" = 1.93.0 && test "\$3" = cargo || exit 98
test "\$4" = build && test "\$5" = --locked && test "\$6" = --release || exit 97
test "\$7" = --manifest-path && test "\$9" = --target-dir || exit 96
test "\${11}" = --target && test "\${12}" = x86_64-unknown-linux-gnu || exit 96
if [ "\$ADELE_TEST_FAIL_CODEFORGE_NATIVE" = 1 ]; then exit 35; fi
mkdir -p "\${10}/\${12}/release"
printf 'native fixture' > "\${10}/\${12}/release/libcode_forge.so"
''');
    _script(File('${bin.path}/dartaotruntime'), 'exit 99');
    _script(File('${sdkBin.path}/dartaotruntime'), '''
test "\$PWD" = '${root.path}' || exit 98
printf '%s\n' "\$1" >> '${logs.path}/aot-executions.txt'
test -f "\$1" || exit 96
snapshot="\$1"
kind=\$(cat "\$snapshot")
shift
if [ "\$kind" = 'snapshot $_workerEntrypoint' ]; then
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
test "\$kind" = 'snapshot $_codegenEntrypoint' || exit 94
set -- run '$_codegenEntrypoint' "\$@"
${generatorScript('aot', aot: true)}
exit 99
''');
    _script(File('${bin.path}/cc'), '''
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
  printf '# 1 %s\n' '${jsonEncode('${root.path}/$_nativeHeader')}'
  cat "\$7" '${root.path}/$_nativeHeader'
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
    _script(File('${sdkBin.path}/dart'), '''
$escapeDepfile
test "\$PWD" = '${root.path}' || exit 98
test "\$1" = compile && test "\$2" = aot-snapshot && test "\$4" = -o || exit 97
test -f "\$3" || exit 96
entrypoint="\${3#${root.path}/}"
tool=0
case "\$entrypoint" in
  '$_codegenEntrypoint'|'$_workerEntrypoint')
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
    if [ "\$entrypoint" = '$_codegenEntrypoint' ]; then
      printf '%s' '${_depfileEscape('${root.path}/$_codegenEntrypoint')}' >> "\$7"
    else
      printf '%s' '${_depfileEscape('${root.path}/$_workerEntrypoint')}' >> "\$7"
    fi
    printf ' %s %s\n' '${_depfileEscape(packageConfig.path)}' '${_depfileEscape('${root.path}/$_analyzerSource')}' >> "\$7"
    if [ "\$ADELE_TEST_TOOL_DEPFILE" = undeclared ]; then
      printf ' %s\n' '${_depfileEscape('${root.path}/$_unusedDevSource')}' >> "\$7"
    fi
  fi
fi
printf 'compiled|%s\n' "\$entrypoint" >> '${commands.path}'
''');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> invoke(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    <String>['tools/adele.dart', ...arguments],
    workingDirectory: root.path,
    environment: environment,
  );

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
      _codegenEntrypoint,
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
      .where((entrypoint) => !_toolStages.containsValue(entrypoint))
      .toList();

  List<String> toolCompilations() => commands
      .readAsLinesSync()
      .where((line) => line.startsWith('compile|'))
      .map((line) => line.substring('compile|'.length))
      .where(_toolStages.containsValue)
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

  test(
    'cold and warm desktop runs execute incremental AOT generation once and discovery twice',
    () async {
      Map<String, String>? before;
      for (final cold in [true, false]) {
        final after = await prepare();
        expect(toolCompilations(), cold ? _toolStages.values : isEmpty);
        expect(compilations(), hasLength(cold ? 21 : 0));
        expect(
          commands.readAsLinesSync().where(
            (line) => line.startsWith('generate|'),
          ),
          ['generate|aot|--incremental'],
        );
        expectGenerationArguments(['--incremental'], true);
        expect(
          File('${root.path}/logs/discovery.txt').readAsLinesSync(),
          List.filled(cold ? 2 : 4, 'discover|aot'),
        );
        final discoveryArguments = File(
          '${root.path}/logs/discovery-arguments.txt',
        ).readAsLinesSync();
        for (var index = 0; index < discoveryArguments.length; index += 2) {
          expect(
            discoveryArguments[index],
            startsWith('${root.path}/.dart_tool/adele/desktop-plugins/'),
          );
          expect(discoveryArguments[index], endsWith('/tool.aot'));
          expect(discoveryArguments[index + 1], root.path);
        }
        for (final stage in _toolStages.keys) {
          final artifact = componentArtifact(stage);
          expect(artifact.uri.pathSegments.last, 'tool.aot');
          expect(
            artifact.parent.listSync().map(
              (file) => file.uri.pathSegments.last,
            ),
            unorderedEquals(['tool.aot', 'receipt.json']),
          );
        }
        if (before != null) expect(after, before);
        before = after;
      }
    },
  );

  test('desktop preparation defaults to full AOT generation', () async {
    final entrypoint = File('${root.path}/tools/prepare-default.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'backend_artifacts.dart';

Future<void> main() async {
  await prepareDesktopPluginDefines(
    repositoryRoot: Directory.current,
    flutterExecutable: '${root.path}/bin/flutter',
  );
}
''');
    final result = await Process.run(
      Platform.resolvedExecutable,
      [entrypoint.path],
      workingDirectory: root.path,
      environment: environment,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      commands.readAsLinesSync().where((line) => line.startsWith('generate|')),
      ['generate|aot'],
    );
    expectGenerationArguments([], true);
    expect(File('${root.path}/logs/discovery.txt').readAsLinesSync(), [
      'discover|aot',
      'discover|aot',
    ]);
    expect(launchArguments.existsSync(), isFalse);
  });

  for (final mutation in [
    (path: _generatorSource, expected: _codegenEntrypoint),
    (path: 'tools/test_runner.dart', expected: _workerEntrypoint),
  ]) {
    test(
      'tool-only ${mutation.path} change preserves plugin installations',
      () async {
        final before = await prepare();
        final retained = retainedFiles();
        changeSource(mutation.path);
        expect(await prepare(), before);
        expect(toolCompilations(), [mutation.expected]);
        expect(compilations(), isEmpty);
        expectRetained(retained);
        expect(await prepare(), before);
        expect(toolCompilations(), isEmpty);
        expect(compilations(), isEmpty);
      },
    );
  }

  for (final tool in _toolStages.entries) {
    for (final damage in [
      'missing-artifact',
      'corrupt-artifact',
      'missing-receipt',
      'corrupt-receipt',
    ]) {
      test(
        '$damage ${tool.key} is repaired without replacing installations',
        () async {
          final before = await prepare();
          final old = componentArtifact(tool.key);
          final damaged = damage.endsWith('receipt')
              ? File('${old.parent.path}/receipt.json')
              : old;
          if (damage.startsWith('missing')) {
            damaged.deleteSync();
          } else {
            damaged.writeAsStringSync('corrupt cached tool');
          }
          final retained = retainedFiles();
          expect(await prepare(), before);
          expect(toolCompilations(), [tool.value]);
          expect(compilations(), isEmpty);
          expectRetained(retained);
          final replacements = publishedFiles().where(
            (file) =>
                file.path.contains('/components/${tool.key}/') &&
                file.uri.pathSegments.last == 'tool.aot' &&
                file.path != old.path,
          );
          expect(replacements, hasLength(1));
          expect(
            replacements.single.readAsStringSync(),
            'snapshot ${tool.value}\n',
          );
          expect(await prepare(), before);
          expect(toolCompilations(), isEmpty);
          expect(compilations(), isEmpty);
        },
      );
    }

    for (final failure in ['exit', 'missing', 'empty']) {
      test(
        '${tool.key} $failure compile failure prevents generation and publication',
        () async {
          environment[switch (failure) {
                'exit' => 'ADELE_TEST_FAIL_ENTRYPOINT',
                'missing' => 'ADELE_TEST_OMIT_ARTIFACT',
                _ => 'ADELE_TEST_EMPTY_ARTIFACT',
              }] =
              tool.value;
          final result = await invoke(['run', 'linux']);
          expect(result.exitCode, failure == 'exit' ? 17 : 1);
          expect(result.stderr, contains(tool.key));
          expect(
            result.stderr,
            contains(
              failure == 'exit' ? 'snapshot compiler failed' : 'produced no',
            ),
          );
          expect(compilations(), isEmpty);
          expect(generationArguments.existsSync(), isFalse);
          expect(launchArguments.existsSync(), isFalse);
          expect(publishedFiles(), isEmpty);
        },
      );
    }

    for (final invalidation in ['source', 'receipt']) {
      test(
        '${tool.key} failed $invalidation rebuild never falls back to retained AOT',
        () async {
          final before = await prepare();
          if (invalidation == 'source') {
            changeSource(
              tool.value == _codegenEntrypoint
                  ? _generatorSource
                  : 'tools/test_runner.dart',
            );
          } else {
            File(
              '${componentArtifact(tool.key).parent.path}/receipt.json',
            ).writeAsStringSync('{invalid');
          }
          final retained = retainedFiles();
          environment['ADELE_TEST_FAIL_ENTRYPOINT'] = tool.value;
          commands.deleteSync();
          launchArguments.deleteSync();
          final failed = await invoke(['run', 'linux']);
          expect(failed.exitCode, 17);
          expect(toolCompilations(), [tool.value]);
          expect(compilations(), isEmpty);
          expect(
            commands.readAsLinesSync().where(
              (line) => line.startsWith('generate|'),
            ),
            isEmpty,
          );
          expect(launchArguments.existsSync(), isFalse);
          expectRetained(retained);
          expect(
            publishedFiles().map((file) => file.path),
            unorderedEquals(retained.keys),
          );
          environment.remove('ADELE_TEST_FAIL_ENTRYPOINT');
          expect(await prepare(), before);
          expect(toolCompilations(), [tool.value]);
          expect(compilations(), isEmpty);
        },
      );
    }
  }

  for (final failure in ['missing', 'empty', 'undeclared']) {
    test('$failure tool compiler depfile blocks publication', () async {
      environment['ADELE_TEST_TOOL_DEPFILE'] = failure;
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains(
          failure == 'undeclared'
              ? 'Uncovered build tool compiler input'
              : failure == 'empty'
              ? 'Invalid build tool compiler depfile'
              : 'tool.d',
        ),
      );
      expect(toolCompilations(), [_codegenEntrypoint]);
      expect(compilations(), isEmpty);
      expect(generationArguments.existsSync(), isFalse);
      expect(launchArguments.existsSync(), isFalse);
      expect(publishedFiles(), isEmpty);
    });
  }

  for (final phase in ['plugin compilation', 'final discovery']) {
    test('tool source mutation during $phase blocks all publication', () async {
      environment[phase == 'plugin compilation'
              ? 'ADELE_TEST_MUTATE_SOURCE'
              : 'ADELE_TEST_MUTATE_TOOL_DURING_DISCOVERY'] =
          '${root.path}/$_generatorSource';
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'Build tool inputs or artifacts changed during desktop preparation',
        ),
      );
      expect(launchArguments.existsSync(), isFalse);
      expect(publishedFiles(), isEmpty);
    });
  }

  for (final mutation in [
    'tool source edit-restore',
    'new tool file in empty directory',
    'tool source removal',
    'watched empty directory removal',
    'optional override create-delete',
    'optional override removal',
    'package configuration edit',
    'generated output edit',
    'native header edit',
    'shared input edit-restore',
    'shared input removal',
  ]) {
    test(
      'final discovery $mutation rejects warm preparation without publication',
      () async {
        final source = File(
          '${root.path}/${mutation == 'shared input edit-restore' ? _sharedSource : _generatorSource}',
        );
        final empty = Directory('${source.parent.path}/empty')..createSync();
        final added = File('${empty.path}/new.dart');
        final override = File(
          '${root.path}/packages/contract_codegen/pubspec_overrides.yaml',
        );
        if (mutation == 'optional override removal') {
          override.writeAsStringSync('dependency_overrides: {}\n');
        }
        await prepare();
        final retained = retainedFiles();
        final original = source.readAsBytesSync();
        final hook = File('${root.path}/logs/final-discovery-hook');
        final mutationScript = switch (mutation) {
          'tool source edit-restore' || 'shared input edit-restore' =>
            '''
cp '${source.path}' '${root.path}/logs/original-source'
printf '\\n// transient edit\\n' >> '${source.path}'
cp '${root.path}/logs/original-source' '${source.path}'
TZ=UTC touch -m -t 200001010000 '${source.path}'
''',
          'new tool file in empty directory' =>
            "printf '// new tool input\\n' > '${added.path}'",
          'tool source removal' => "rm '${source.path}'",
          'watched empty directory removal' => "rmdir '${empty.path}'",
          'optional override create-delete' =>
            '''
printf 'dependency_overrides: {}\\n' > '${override.path}'
rm '${override.path}'
TZ=UTC touch -m -t 200001010000 '${override.parent.path}'
''',
          'optional override removal' => "rm '${override.path}'",
          'package configuration edit' =>
            "printf '\\n' >> '${root.path}/.dart_tool/package_config.json'",
          'generated output edit' =>
            "printf '// changed output\\n' >> '${generatedContract.path}'",
          'shared input removal' => "rm '${root.path}/$_sharedSource'",
          _ => "printf '// changed header\\n' >> '${root.path}/$_nativeHeader'",
        };
        _script(hook, 'set -e\n$mutationScript');
        environment['ADELE_TEST_FINAL_DISCOVERY_HOOK'] = hook.path;
        final discoveries = File('${root.path}/logs/discovery.txt')
          ..writeAsStringSync('');
        commands.deleteSync();
        launchArguments.deleteSync();

        final result = await invoke(['run', 'linux']);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains(switch (mutation) {
            'shared input removal' =>
              'Desktop build input must be an existing absolute file',
            'generated output edit' ||
            'native header edit' ||
            'shared input edit-restore' =>
              'Build inputs changed during desktop preparation',
            _ =>
              'Build tool inputs or artifacts changed during desktop preparation',
          }),
        );
        expect(discoveries.readAsLinesSync(), ['discover|aot', 'discover|aot']);
        expect(toolCompilations(), isEmpty);
        expect(compilations(), isEmpty);
        expect(commands.readAsLinesSync(), isNot(contains('flutter-launch')));
        expect(launchArguments.existsSync(), isFalse);
        expectRetained(retained);
        expect(
          publishedFiles().map((file) => file.path),
          unorderedEquals(retained.keys),
        );
        if (mutation.endsWith('edit-restore')) {
          expect(source.readAsBytesSync(), original);
          expect(source.lastModifiedSync().toUtc(), DateTime.utc(2000));
        } else if (mutation == 'optional override create-delete') {
          expect(override.existsSync(), isFalse);
          expect(
            override.parent.statSync().modified.toUtc(),
            DateTime.utc(2000),
          );
        }
      },
    );
  }

  for (final damage in ['corrupt', 'missing']) {
    test(
      '$damage selected discovery artifact during compilation is rejected before second execution',
      () async {
        await prepare();
        final discovery = componentArtifact('desktop-inputs-compilation');
        final generator = componentArtifact('contract-codegen-compilation');
        final retained = retainedFiles()..remove(discovery.path);
        changeSource(_gitEntrypoint);
        final hook = File('${root.path}/logs/compile-hook');
        _script(
          hook,
          damage == 'missing'
              ? "rm '${discovery.path}'"
              : "printf 'corrupt selected AOT\\n' > '${discovery.path}'",
        );
        environment['ADELE_TEST_COMPILE_HOOK'] = hook.path;
        final executions = File('${root.path}/logs/aot-executions.txt')
          ..writeAsStringSync('');
        final discoveries = File('${root.path}/logs/discovery.txt')
          ..writeAsStringSync('');
        commands.deleteSync();
        launchArguments.deleteSync();

        final result = await invoke(['run', 'linux']);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains(
            damage == 'missing'
                ? 'Unable to fingerprint build inputs'
                : 'Build tool inputs or artifacts changed during desktop preparation',
          ),
        );
        // Record runtime entry before it can reject missing/corrupt snapshots.
        expect(executions.readAsLinesSync(), [generator.path, discovery.path]);
        expect(discoveries.readAsLinesSync(), ['discover|aot']);
        expect(toolCompilations(), isEmpty);
        expect(compilations(), [_gitEntrypoint]);
        expect(commands.readAsLinesSync(), isNot(contains('flutter-launch')));
        expect(launchArguments.existsSync(), isFalse);
        expectRetained(retained);
        expect(
          publishedFiles().map((file) => file.path),
          unorderedEquals([
            ...retained.keys,
            if (damage != 'missing') discovery.path,
          ]),
        );
      },
    );
  }

  for (final change in ['added', 'removed']) {
    test(
      'final discovery rejects $change graph inputs even when files are unchanged',
      () async {
        final extra = File('${root.path}/plugins/source_editor/extra.dart')
          ..writeAsStringSync('// additional graph input\n');
        await prepare();
        final retained = retainedFiles();
        final inputs =
            (jsonDecode(buildInputs.readAsStringSync()) as Map<String, dynamic>)
                .map(
                  (key, value) => MapEntry(key, (value as List).cast<String>()),
                );
        final paths = inputs['source-editor-frontend-compilation']!;
        if (change == 'added') {
          paths.add(extra.path);
          paths.sort();
        } else {
          expect(paths.remove('${root.path}/$_sharedSource'), isTrue);
        }
        final finalInputs = File('${root.path}/logs/final-build-inputs.json')
          ..writeAsStringSync(jsonEncode(inputs));
        final hook = File('${root.path}/logs/final-discovery-hook');
        _script(hook, "cp '${finalInputs.path}' '${buildInputs.path}'");
        environment['ADELE_TEST_FINAL_DISCOVERY_HOOK'] = hook.path;
        final discoveries = File('${root.path}/logs/discovery.txt')
          ..writeAsStringSync('');
        commands.deleteSync();
        launchArguments.deleteSync();

        final result = await invoke(['run', 'linux']);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains('Build inputs changed during desktop preparation'),
        );
        expect(discoveries.readAsLinesSync(), ['discover|aot', 'discover|aot']);
        expect(toolCompilations(), isEmpty);
        expect(compilations(), isEmpty);
        expect(commands.readAsLinesSync(), isNot(contains('flutter-launch')));
        expect(launchArguments.existsSync(), isFalse);
        expectRetained(retained);
        expect(
          publishedFiles().map((file) => file.path),
          unorderedEquals(retained.keys),
        );
      },
    );
  }

  test(
    'changed selected runtime is rejected before final discovery execution',
    () async {
      await prepare();
      final retained = retainedFiles();
      changeSource(_gitEntrypoint);
      final marker = File('${root.path}/logs/changed-runtime-executed');
      final replacement = File('${root.path}/logs/replacement-runtime');
      _script(replacement, "touch '${marker.path}'\nexit 97");
      final hook = File('${root.path}/logs/compile-hook');
      _script(hook, "cp '${replacement.path}' '${sdkBin.path}/dartaotruntime'");
      environment['ADELE_TEST_COMPILE_HOOK'] = hook.path;
      final discoveries = File('${root.path}/logs/discovery.txt')
        ..writeAsStringSync('');
      commands.deleteSync();
      launchArguments.deleteSync();

      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains(
          'Build tool inputs or artifacts changed during desktop preparation',
        ),
      );
      expect(marker.existsSync(), isFalse);
      expect(discoveries.readAsLinesSync(), ['discover|aot']);
      expect(toolCompilations(), isEmpty);
      expect(compilations(), [_gitEntrypoint]);
      expect(launchArguments.existsSync(), isFalse);
      expectRetained(retained);
      expect(
        publishedFiles().map((file) => file.path),
        unorderedEquals(retained.keys),
      );
    },
  );

  test(
    'test-plan runs pre-bootstrap without generating, inspecting or compiling',
    () async {
      removeBootstrapMetadata();
      final ProcessResult result = await invoke(<String>[
        'test-plan',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final Map<String, Object?> plan =
          jsonDecode(result.stdout.toString()) as Map<String, Object?>;
      expect(
        (plan['include']! as List<Object?>).cast<Map<String, Object?>>().map(
          (Map<String, Object?> item) => item['name'],
        ),
        containsAll([
          'adele_ui',
          'plugin_runtime',
          'adele_tools',
          'adele_plugin_backend_support',
          'agents_md_backend',
          'search_tools_backend',
          'filesystem_tools_backend',
          'command_tools_backend',
          'local_directory_project_backend',
          'local_directory_project_frontend',
          'task_browser_frontend',
          'terminal_frontend',
          'source_editor_frontend',
        ]),
      );
      expect(commands.existsSync(), isFalse);
      expect(generatedContract.existsSync(), isFalse);
      expect(Directory('${root.path}/.dart_tool').existsSync(), isFalse);
    },
  );

  test('invalid test target fails before generation or workers', () async {
    final result = await invoke(['test', '--target', 'not-a-target']);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('Unknown test target: not-a-target'));
    expect(commands.existsSync(), isFalse);
    expect(generatedContract.existsSync(), isFalse);
    expect(result.stdout, isNot(contains('START test:')));
  });

  test('unknown commands remain SDK-only', () async {
    removeBootstrapMetadata();
    // Unknown commands must not prepare dependencies or invoke external tools.
    environment['PATH'] = '${root.path}/no-external-tools';
    final unknown = await invoke(['not-a-command']);
    expect(unknown.exitCode, 64);
    expect(unknown.stderr, isEmpty);
    final retired = await invoke(['probe-code-editor']);
    expect(retired.exitCode, unknown.exitCode);
    expect(retired.stdout, unknown.stdout);
    expect(retired.stderr, unknown.stderr);
    expect(retired.stdout, isNot(contains('probe-code-editor')));
    expect(commands.existsSync(), isFalse);
    expect(generatedContract.existsSync(), isFalse);
    expect(Directory('${root.path}/.adele').existsSync(), isFalse);
    expect(Directory('${root.path}/.dart_tool').existsSync(), isFalse);
    expect(File('${root.path}/pubspec.yaml').existsSync(), isFalse);
  });

  for (final arguments in [
    ['help'],
    ['--help'],
    ['prepare-code-editor', '--invalid'],
    ['build-code-editor-tests', '--invalid'],
    ['editor-smoke'],
    ['editor-smoke', 'linux', '--invalid'],
    ['bootstrap', '--invalid'],
    ['analyze', '--invalid'],
    ['build', 'linux', '--invalid'],
    ['test', '--jobs', '0'],
  ]) {
    test(
      '${arguments.join(' ')} never prepares source or invokes tools',
      () async {
        final result = await invoke(arguments);
        expect(result.exitCode, arguments.first.contains('help') ? 0 : 64);
        expect(commands.existsSync(), isFalse);
        expect(Directory('${root.path}/.adele').existsSync(), isFalse);
      },
    );
  }

  for (final arguments in [
    ['bootstrap'],
    ['analyze'],
    ['test', '--target', 'adele_tools'],
    ['build', 'linux'],
    ['run', 'linux'],
  ]) {
    test(
      '${arguments.join(' ')} refuses altered source before consumers',
      () async {
        final prepared = await invoke(['prepare-code-editor']);
        expect(prepared.exitCode, 0, reason: '${prepared.stderr}');
        File(
          '${root.path}/.adele/dependencies/code_forge/lib/code.dart',
        ).writeAsStringSync('tampered');
        final result = await invoke(arguments);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('Stale or altered'));
        expect(commands.existsSync(), isFalse);
      },
    );
  }

  test(
    'failed native build prevents desktop test workers and any fallback',
    () async {
      environment['ADELE_TEST_FAIL_CODEFORGE_NATIVE'] = '1';
      final result = await invoke(['test', '--target', 'adele_desktop']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('CodeForge rustup failed (35)'));
      expect(commands.readAsLinesSync(), ['generate|path']);
      expect(result.stdout, isNot(contains('START test:')));
    },
  );

  test('bootstrap generates once after both dependency commands', () async {
    final result = await invoke(['bootstrap']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(commands.readAsLinesSync(), [
      'pub-get',
      'workspace-list',
      'generate|path',
    ]);
    expectGenerationArguments();
    expect(generatedContract.readAsStringSync(), 'generated contracts\n');
  });

  for (final dependency in ['pub-get', 'workspace-list']) {
    test('bootstrap $dependency failure prevents generation', () async {
      environment['ADELE_TEST_FAIL_DEPENDENCY'] = dependency;
      final result = await invoke(['bootstrap']);
      expect(result.exitCode, 19);
      expect(commands.readAsLinesSync(), [
        'pub-get',
        if (dependency == 'workspace-list') 'workspace-list',
      ]);
      expect(generationArguments.existsSync(), isFalse);
      expect(generatedContract.existsSync(), isFalse);
    });
  }

  test('analyze generates once before every analysis subprocess', () async {
    final result = await invoke(['analyze']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(commands.readAsLinesSync(), [
      'generate|path',
      'analyze|dart|${root.path}',
      'analyze|dart|${root.path}',
      for (final target in tooling.analysisTargets)
        'analyze|${target.flutter ? 'flutter' : 'dart'}|${root.path}/${target.path}',
    ]);
    expectGenerationArguments();
  });

  for (final targetName in ['adele_tools', 'adele_desktop', null]) {
    test('test ${targetName ?? 'all'} generates once before workers', () async {
      final result = await invoke([
        'test',
        if (targetName != null) ...[
          '--target',
          targetName,
        ] else ...[
          '--jobs',
          '2',
        ],
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final targets = targetName == null
          ? tooling.testTargets
          : [tooling.lookupTestTarget(targetName)];
      final recorded = commands.readAsLinesSync();
      expect(recorded.first, 'generate|path');
      expect(
        recorded.skip(1),
        unorderedEquals([
          for (final target in targets)
            'test|${target.executable}|${root.path}${target.path == '.' ? '' : '/${target.path}'}',
        ]),
      );
      expectGenerationArguments();
    });
  }

  test(
    'generate materializes and --check verifies without rewriting',
    () async {
      final result = await invoke(['generate']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(commands.readAsLinesSync(), ['generate|path']);
      expectGenerationArguments();
      expect(generatedContract.readAsStringSync(), 'generated contracts\n');
      generatedContract.setLastModifiedSync(DateTime.utc(2000));
      final modified = generatedContract.lastModifiedSync();

      final checked = await invoke(['generate', '--check']);
      expect(checked.exitCode, 0, reason: checked.stderr.toString());
      expect(commands.readAsLinesSync(), [
        'generate|path',
        'generate|path|--check',
      ]);
      expectGenerationArguments(['--check']);
      expect(generatedContract.readAsStringSync(), 'generated contracts\n');
      expect(generatedContract.lastModifiedSync(), modified);
    },
  );

  for (final command in [
    <String>['generate', '--check'],
    <String>['check'],
  ]) {
    for (final stale in [false, true]) {
      test(
        '${command.join(' ')} does not repair ${stale ? 'stale' : 'missing'} outputs',
        () async {
          if (stale) generatedContract.writeAsStringSync('stale contract');
          final result = await invoke(command);
          expect(result.exitCode, 31);
          expect(
            result.stderr,
            contains('contract outputs are missing or stale'),
          );
          expect(commands.readAsLinesSync(), ['generate|path|--check']);
          expectGenerationArguments(['--check']);
          if (stale) {
            expect(generatedContract.readAsStringSync(), 'stale contract');
          } else {
            expect(generatedContract.existsSync(), isFalse);
          }
        },
      );
    }
  }

  test(
    'clean-contracts forwards only --clean without generating first',
    () async {
      generatedContract.writeAsStringSync('stale contract');
      final result = await invoke(['clean-contracts']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(commands.readAsLinesSync(), ['generate|path|--clean']);
      expectGenerationArguments(['--clean']);
      expect(generatedContract.existsSync(), isFalse);
    },
  );

  for (final target in ['macos', 'windows']) {
    for (final command in ['run', 'build']) {
      test('$command $target generates once on PATH before Flutter', () async {
        final result = await invoke([command, target]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(commands.readAsLinesSync(), ['generate|path', 'flutter-launch']);
        expectGenerationArguments();
        expect(launchArguments.readAsLinesSync(), [
          command,
          if (command == 'run') '-d',
          target,
          '--debug',
        ]);
      });
    }
  }

  for (final arguments in <List<String>>[
    ['bootstrap'],
    ['analyze'],
    ['test', '--target', 'adele_tools'],
    ['test', '--jobs', '2'],
    ['run', 'linux'],
    ['build', 'linux'],
    ['run', 'macos'],
    ['build', 'windows'],
    ['smoke', 'linux'],
  ]) {
    test(
      '${arguments.join(' ')} stops consumers on generation failure',
      () async {
        final incremental =
            arguments.contains('linux') && arguments.first != 'smoke';
        environment['ADELE_TEST_FAIL_GENERATION'] = '1';
        // Even retained output must not let consumers bypass failed generation.
        generatedContract.writeAsStringSync('retained contract');
        if (arguments.first == 'smoke') {
          environment.addAll({
            'ADELE_DEVELOPMENT_REPOSITORY_ROOT': root.path,
            'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY':
                '${root.path}/plugins/workspace_demo',
            'ADELE_DEVELOPMENT_DIRECTORY': '${root.path}/development',
          });
        }
        final result = await invoke(arguments);
        expect(result.exitCode, 29);
        expect(result.stdout, contains('contract generator output'));
        expect(result.stderr, contains('contract generator failed'));
        expect(
          result.stderr,
          contains('contract-generation failed with exit code 29'),
        );
        expect(commands.readAsLinesSync(), [
          if (arguments.first == 'bootstrap') ...['pub-get', 'workspace-list'],
          if (arguments.contains('linux')) 'inspect-sdk',
          if (incremental) ..._toolCompilationEvents,
          incremental ? 'generate|aot|--incremental' : 'generate|path',
        ]);
        expectGenerationArguments([
          if (incremental) '--incremental',
        ], incremental);
        expect(result.stdout, isNot(contains('START test:')));
        expect(generatedContract.readAsStringSync(), 'retained contract');
        expect(launchArguments.existsSync(), isFalse);
        expect(frontendArguments.existsSync(), isFalse);
        expectNoPublishedInstallations();
      },
    );
  }

  test('generation failure retains structured process diagnostics', () async {
    final dart = File('${root.path}/bin/failing-dart');
    _script(dart, '''
printf 'generator stdout'
printf 'generator stderr' >&2
exit 27
''');
    try {
      await runContractCodegen(
        repositoryRoot: root,
        dartExecutable: dart.path,
        options: ['--check'],
      );
      fail('Expected generation to fail.');
    } on PluginBuildFailure catch (failure) {
      expect(
        failure.message,
        contains('contract-generation failed with exit code 27'),
      );
      final diagnostic = failure.diagnostic!;
      expect(diagnostic.stage, 'contract-generation');
      expect(diagnostic.command, [
        dart.path,
        'run',
        _codegenEntrypoint,
        '--check',
      ]);
      expect(diagnostic.workingDirectory, root.path);
      expect(diagnostic.exitCode, 27);
      expect(diagnostic.stdoutText, 'generator stdout');
      expect(diagnostic.stderrText, 'generator stderr');
    }
  });

  test('generation process start failure is a PluginBuildFailure', () async {
    await expectLater(
      runContractCodegen(
        repositoryRoot: root,
        dartExecutable: '${root.path}/missing-dart',
      ),
      throwsA(
        isA<PluginBuildFailure>().having(
          (failure) => failure.message,
          'message',
          contains('contract-generation could not start'),
        ),
      ),
    );
    expect(commands.existsSync(), isFalse);
  });

  test(
    'Linux smoke builds the tool entrypoint and runs the matching bundle',
    () async {
      final developmentEnvironment = <String, String>{
        'ADELE_DEVELOPMENT_REPOSITORY_ROOT': root.path,
        'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY':
            '${root.path}/plugins/workspace_demo',
        'ADELE_DEVELOPMENT_DIRECTORY': '${root.path}/development',
      };
      environment.addAll(developmentEnvironment);
      for (final (flag, mode) in [
        (null, 'profile'),
        ('--debug', 'profile'),
        ('--profile', 'profile'),
        ('--release', 'release'),
      ]) {
        final executable = File(
          '${root.path}/app/build/linux/x64/$mode/bundle/adele_desktop',
        );
        executable.parent.createSync(recursive: true);
        _script(executable, '''
test "\$PWD" = '${root.path}' || exit 98
test "\$#" = 0 || exit 97
printf 'smoke-runtime|$mode\n' >> '${commands.path}'
''');
        final result = await invoke(['smoke', 'linux', ?flag]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(commands.readAsLinesSync(), [
          'inspect-sdk',
          'generate|path',
          'flutter-launch',
          'smoke-runtime|$mode',
        ]);
        expectGenerationArguments();
        expect(launchArguments.readAsLinesSync(), [
          'build',
          'linux',
          '--$mode',
          '--target=tool/development_runtime_smoke/main.dart',
          for (final entry in developmentEnvironment.entries)
            '--dart-define=${entry.key}=${entry.value}',
          '--dart-define=ADELE_DEVELOPMENT_DART_EXECUTABLE=${root.path}/bin/dart',
          '--dart-define=ADELE_DEVELOPMENT_DARTAOTRUNTIME_EXECUTABLE=${sdkBin.path}/dartaotruntime',
          '--dart-define=ADELE_DEVELOPMENT_FLUTTER_EXECUTABLE=${root.path}/bin/flutter',
        ]);
        commands.deleteSync();
      }
    },
  );

  test(
    'stock OpenAI records are discoverable without executable components or auth',
    () async {
      final installations = Directory('${root.path}/published');
      final directory = Directory.fromUri(installations.uri.resolve('openai/'));
      await publishStockPluginInstallation(
        repositoryRoot: root,
        installationDirectory: directory,
        pluginId: 'dev.adele.openai',
        displayName: 'OpenAI',
      );
      expect(commands.existsSync(), isFalse);
      expect(directory.listSync(), hasLength(2));
      expect(
        jsonDecode(
          File.fromUri(
            directory.uri.resolve('adele_plugin.installation.json'),
          ).readAsStringSync(),
        ),
        {
          'manifestVersion': 1,
          'metadata': {
            'id': 'dev.adele.openai',
            'version': '0.1.0',
            'displayName': 'OpenAI',
          },
          'recordsSchema': 'records.schema.json',
          'components': <String, Object?>{},
        },
      );
      final schemaFile = File.fromUri(
        directory.uri.resolve('records.schema.json'),
      );
      expect(
        schemaFile.readAsBytesSync(),
        File('plugins/openai/records.schema.json').readAsBytesSync(),
      );
      expect(jsonDecode(schemaFile.readAsStringSync()), {
        'schemaVersion': 1,
        'recordTypes': [
          {
            'id': 'dev.adele.openai.api-key',
            'collection': 'providers',
            'collectionLabel': 'Providers',
            'label': 'OpenAI API',
            'description': 'An OpenAI API-key provider configuration.',
            'displayField': 'display-name',
            'fields': [
              {
                'id': 'display-name',
                'label': 'Name',
                'type': 'string',
                'required': true,
              },
              {
                'id': 'endpoint',
                'label': 'API endpoint',
                'type': 'string',
                'required': false,
              },
            ],
          },
        ],
      });

      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      expect(installation.frontend, isNull);
      expect(installation.settingsSchema, isNull);
      expect(catalog.settings.definitions, isEmpty);
      final schema = installation.recordsSchema!;
      expect(schema.artifactUri, schemaFile.uri);
      final type = schema.definitions.single;
      expect(catalog.records.definitions, [type]);
      expect(type.id.value, 'dev.adele.openai.api-key');
      expect(type.owner.value, installation.metadata.id.value);
      expect(type.collection.value, 'providers');
      expect(type.collectionLabel, 'Providers');
      expect(type.label, 'OpenAI API');
      expect(type.description, 'An OpenAI API-key provider configuration.');
      expect(type.displayField?.value, 'display-name');
      expect(type.fields.map((field) => field.id.value), [
        'display-name',
        'endpoint',
      ]);
      expect(type.fields.map((field) => field.label), ['Name', 'API endpoint']);
      expect(type.fields.map((field) => field.required), [true, false]);
      expect(type.fields.map((field) => field.description), [null, null]);
      expect(commands.existsSync(), isFalse);
    },
  );

  test(
    'stock catalog without OpenAI keeps records absent and settings intact',
    () async {
      final installations = Directory('${root.path}/published');
      for (final plugin in [
        (
          directory: 'source-editor',
          id: 'dev.adele.source-editor',
          name: 'Source',
        ),
        (
          directory: 'session-evaluator',
          id: 'dev.adele.plugin.session-evaluator',
          name: 'Session Evaluator',
        ),
      ]) {
        final directory = Directory.fromUri(
          installations.uri.resolve('${plugin.directory}/'),
        );
        await publishStockPluginInstallation(
          repositoryRoot: root,
          installationDirectory: directory,
          pluginId: plugin.id,
          displayName: plugin.name,
        );
        final manifest =
            jsonDecode(
                  File.fromUri(
                    directory.uri.resolve('adele_plugin.installation.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(manifest.containsKey('recordsSchema'), isFalse);
        expect(
          File.fromUri(
            directory.uri.resolve('records.schema.json'),
          ).existsSync(),
          isFalse,
        );
      }
      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations, hasLength(2));
      expect(catalog.records.definitions, isEmpty);
      expect(catalog.installations.map((item) => item.recordsSchema), [
        null,
        null,
      ]);
      final setting = catalog.settings.definitions.single;
      expect(setting.id.value, 'dev.adele.source-editor.enable-folding');
      expect(catalog.settings.resolve(setting.id).value, isFalse);
      expect(commands.existsSync(), isFalse);
    },
  );

  test(
    'Linux development launcher prepares evaluator and existing stock catalog without opt-in',
    () async {
      for (final path in [
        _sessionEvaluatorEntrypoint,
        _diffViewerEntrypoint,
        _localDirectoryProjectEntrypoint,
        'plugins/local_directory_project/packages/backend/lib/local_directory_project_backend.dart',
        'plugins/local_directory_project/packages/frontend/lib/local_directory_project_frontend.dart',
        'app/$_localDirectoryProjectFrontendHarness',
        'app/tool/local_directory_project_frontend_compiler.dart',
        'app/$_taskBrowserFrontendHarness',
        'app/tool/task_browser_frontend_compiler.dart',
        'plugins/task_browser/packages/frontend/lib/task_browser_frontend.dart',
        'app/$_terminalFrontendHarness',
        'app/tool/terminal_frontend_compiler.dart',
        'plugins/terminal/packages/frontend/lib/terminal_frontend.dart',
        'app/$_sourceEditorFrontendHarness',
        'app/tool/source_editor_frontend_compiler.dart',
        'plugins/source_editor/packages/frontend/lib/main.dart',
        'app/$_diffViewerFrontendHarness',
        'app/tool/diff_viewer_frontend_compiler.dart',
        'plugins/diff_viewer/packages/frontend/lib/main.dart',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      final Set<String> outputDirectories = <String>{};
      final Map<String, String> retainedArtifacts = <String, String>{};
      Map<String, String>? firstDefines;
      // Preparation must replace inherited inputs with this checkout's paths.
      environment['ADELE_REPOSITORY_ROOT'] = '/wrong-repository';
      environment['ADELE_CHAT_FRONTEND_OUTPUT'] = '/wrong-output';
      environment['ADELE_TASK_BROWSER_FRONTEND_OUTPUT'] = '/wrong-task-browser';
      environment['ADELE_TERMINAL_FRONTEND_OUTPUT'] = '/wrong-terminal';
      environment['ADELE_SOURCE_EDITOR_FRONTEND_OUTPUT'] =
          '/wrong-source-editor';
      environment['ADELE_DIFF_VIEWER_FRONTEND_OUTPUT'] = '/wrong-diff-viewer';
      environment['ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT'] =
          '/wrong-tool-output';
      environment['ADELE_TOOL_INSPECTION_FRONTEND'] = 'wrong-tool';
      environment['ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT'] = '/wrong-openai';
      environment['ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT'] =
          '/wrong-local-directory-project';
      for (final List<String> arguments in <List<String>>[
        <String>['run', 'linux'],
        <String>['build', 'linux'],
        <String>['build', 'linux', '--profile'],
      ]) {
        final cold = outputDirectories.isEmpty;
        final ProcessResult result = await invoke(arguments);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          if (cold) ..._toolCompilationEvents,
          'generate|aot|--incremental',
          if (cold) ...[
            'compile|$_hostEntrypoint',
            'compiled|$_hostEntrypoint',
            'compile|$_gitEntrypoint',
            'compiled|$_gitEntrypoint',
            'compile|$_openaiEntrypoint',
            'compiled|$_openaiEntrypoint',
            'compile|$_agentsMdEntrypoint',
            'compiled|$_agentsMdEntrypoint',
            'compile|$_searchToolsEntrypoint',
            'compiled|$_searchToolsEntrypoint',
            'compile|$_filesystemToolsEntrypoint',
            'compiled|$_filesystemToolsEntrypoint',
            'compile|$_commandToolsEntrypoint',
            'compiled|$_commandToolsEntrypoint',
            'compile|$_chatEntrypoint',
            'compiled|$_chatEntrypoint',
            'compile|$_localDirectoryProjectEntrypoint',
            'compiled|$_localDirectoryProjectEntrypoint',
            'compile|$_sessionEvaluatorEntrypoint',
            'compiled|$_sessionEvaluatorEntrypoint',
            'compile|$_diffViewerEntrypoint',
            'compiled|$_diffViewerEntrypoint',
            'compile|git-pty-helper',
            'compile|$_frontendHarness',
            'compiled|$_frontendHarness',
            'compile|$_toolFrontendHarness|filesystem',
            'compiled|$_toolFrontendHarness|filesystem',
            'compile|$_toolFrontendHarness|command',
            'compiled|$_toolFrontendHarness|command',
            'compile|$_openaiFrontendHarness',
            'compiled|$_openaiFrontendHarness',
            'compile|$_localDirectoryProjectFrontendHarness',
            'compiled|$_localDirectoryProjectFrontendHarness',
            'compile|$_taskBrowserFrontendHarness',
            'compiled|$_taskBrowserFrontendHarness',
            'compile|$_terminalFrontendHarness',
            'compiled|$_terminalFrontendHarness',
            'compile|$_sourceEditorFrontendHarness',
            'compiled|$_sourceEditorFrontendHarness',
            'compile|$_diffViewerFrontendHarness',
            'compiled|$_diffViewerFrontendHarness',
          ],
          'flutter-launch',
        ]);
        if (cold) expect(result.stdout, contains('frontend compiler output'));
        expectGenerationArguments(['--incremental'], true);
        expect(frontendArguments.readAsLinesSync(), <String>[
          'test',
          '--no-pub',
          '--concurrency',
          '1',
          _frontendHarness,
        ]);
        final List<String> launched = launchArguments.readAsLinesSync();
        final bool run = arguments.first == 'run';
        expect(launched.take(run ? 5 : 4), <String>[
          arguments.first,
          if (run) '-d',
          'linux',
          arguments.length == 3 ? arguments.last : '--debug',
          '--target=tool/development_main.dart',
        ]);
        final Map<String, String> defines = <String, String>{};
        for (final String argument in launched.skip(run ? 5 : 4)) {
          expect(argument, startsWith('--dart-define='));
          final String define = argument.substring('--dart-define='.length);
          final int separator = define.indexOf('=');
          defines[define.substring(0, separator)] = define.substring(
            separator + 1,
          );
        }
        expect(launched, hasLength(run ? 9 : 8));
        if (firstDefines == null) {
          firstDefines = defines;
        } else {
          expect(defines, firstDefines);
        }
        expect(
          defines.keys,
          unorderedEquals(<String>[
            'ADELE_DARTAOTRUNTIME_EXECUTABLE',
            'ADELE_BACKEND_HOST_ARTIFACT',
            'ADELE_PLUGIN_INSTALLATION_ROOT',
            'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE',
          ]),
        );
        expect(
          defines['ADELE_DARTAOTRUNTIME_EXECUTABLE'],
          '${sdkBin.path}/dartaotruntime',
        );
        final File host = File(defines['ADELE_BACKEND_HOST_ARTIFACT']!);
        final Directory installations = Directory(
          defines['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        final File startupArguments = File(
          defines['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']!,
        );
        final File git = File.fromUri(
          installations.uri.resolve('git/backend.aot'),
        );
        final File openai = File.fromUri(
          installations.uri.resolve('openai/backend.aot'),
        );
        final File agentsMd = File.fromUri(
          installations.uri.resolve('agents-md/backend.aot'),
        );
        final File searchTools = File.fromUri(
          installations.uri.resolve('search-tools/backend.aot'),
        );
        final File filesystemTools = File.fromUri(
          installations.uri.resolve('filesystem-tools/backend.aot'),
        );
        final File commandTools = File.fromUri(
          installations.uri.resolve('command-tools/backend.aot'),
        );
        final File frontend = File.fromUri(
          installations.uri.resolve('chat-strategy/frontend.evc'),
        );
        final File chat = File.fromUri(
          installations.uri.resolve('chat-strategy/backend.aot'),
        );
        final File localDirectoryProject = File.fromUri(
          installations.uri.resolve('local-directory-project/backend.aot'),
        );
        expect(host.uri.isAbsolute, isTrue);
        expect(git.uri.isAbsolute, isTrue);
        expect(openai.uri.isAbsolute, isTrue);
        expect(agentsMd.uri.isAbsolute, isTrue);
        expect(searchTools.uri.isAbsolute, isTrue);
        expect(filesystemTools.uri.isAbsolute, isTrue);
        expect(commandTools.uri.isAbsolute, isTrue);
        expect(frontend.uri.isAbsolute, isTrue);
        expect(host.path, endsWith('/host.aot'));
        expect(git.path, endsWith('/git/backend.aot'));
        expect(openai.path, endsWith('/openai/backend.aot'));
        expect(agentsMd.path, endsWith('/agents-md/backend.aot'));
        expect(searchTools.path, endsWith('/search-tools/backend.aot'));
        expect(filesystemTools.path, endsWith('/filesystem-tools/backend.aot'));
        expect(commandTools.path, endsWith('/command-tools/backend.aot'));
        expect(frontend.path, endsWith('/chat-strategy/frontend.evc'));
        final compileEnvironment = frontendEnvironment.readAsLinesSync();
        expect(compileEnvironment.first, root.path);
        expect(compileEnvironment.last, contains('/.staging/'));
        expect(compileEnvironment.last, isNot(frontend.path));
        expect(File(compileEnvironment.last).existsSync(), isFalse);
        expect(installations.uri.isAbsolute, isTrue);
        expect(installations.path, contains('/installations/'));
        expect(startupArguments.uri.isAbsolute, isTrue);
        expect(startupArguments.path, contains('/startup/'));
        expect(startupArguments.parent.path, isNot(host.parent.path));
        expect(jsonDecode(startupArguments.readAsStringSync()), {
          'dev.adele.openai': ['--chatgpt-only'],
          'dev.adele.plugin.git': gitStartupArguments(),
        });
        expect(
          installations.listSync().whereType<Directory>().map(
            (entry) =>
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
          ),
          unorderedEquals([
            'git',
            'openai',
            'agents-md',
            'search-tools',
            'chat-strategy',
            'filesystem-tools',
            'command-tools',
            'local-directory-project',
            'task-browser',
            'terminal',
            'source-editor',
            'diff-viewer',
            'session-evaluator',
          ]),
        );
        final installedIds = <String>{};
        for (final plugin in [
          (
            directory: 'git',
            id: 'dev.adele.plugin.git',
            name: 'Git',
            backend: true,
          ),
          (
            directory: 'openai',
            id: 'dev.adele.openai',
            name: 'OpenAI',
            backend: true,
          ),
          (
            directory: 'agents-md',
            id: 'dev.adele.plugin.agents-md',
            name: 'AGENTS.md',
            backend: true,
          ),
          (
            directory: 'search-tools',
            id: 'dev.adele.plugin.search-tools',
            name: 'Search Tools',
            backend: true,
          ),
          (
            directory: 'chat-strategy',
            id: 'dev.adele.plugin.chat-strategy',
            name: 'Chat',
            backend: true,
          ),
          (
            directory: 'filesystem-tools',
            id: 'dev.adele.plugin.filesystem-tools',
            name: 'Filesystem Tools',
            backend: true,
          ),
          (
            directory: 'command-tools',
            id: 'dev.adele.plugin.command-tools',
            name: 'Command Tools',
            backend: true,
          ),
          (
            directory: 'local-directory-project',
            id: 'dev.adele.plugin.local-directory-project',
            name: 'Local Directory Project',
            backend: true,
          ),
          (
            directory: 'task-browser',
            id: 'dev.adele.plugin.task-browser',
            name: 'Task Browser',
            backend: false,
          ),
          (
            directory: 'terminal',
            id: 'dev.adele.plugin.terminal',
            name: 'Terminal',
            backend: false,
          ),
          (
            directory: 'source-editor',
            id: 'dev.adele.source-editor',
            name: 'Source',
            backend: false,
          ),
          (
            directory: 'diff-viewer',
            id: 'dev.adele.diff-viewer',
            name: 'Diff',
            backend: true,
          ),
          (
            directory: 'session-evaluator',
            id: 'dev.adele.plugin.session-evaluator',
            name: 'Session Evaluator',
            backend: true,
          ),
        ]) {
          final directory = Directory.fromUri(
            installations.uri.resolve('${plugin.directory}/'),
          );
          final presentations = stockFrontendDescriptors[plugin.id];
          final extensions = stockFrontendExtensionDescriptors[plugin.id];
          final hasFrontend = presentations != null || extensions != null;
          final manifest = File.fromUri(
            directory.uri.resolve('adele_plugin.installation.json'),
          );
          final decoded =
              jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
          expect(
            installedIds.add(
              (decoded['metadata'] as Map<String, dynamic>)['id'] as String,
            ),
            isTrue,
          );
          expect(decoded, {
            'manifestVersion': 1,
            'metadata': {
              'id': plugin.id,
              'version': '0.1.0',
              'displayName': plugin.name,
            },
            if (plugin.directory == 'source-editor')
              'settingsSchema': 'settings.schema.json',
            if (plugin.directory == 'openai')
              'recordsSchema': 'records.schema.json',
            'components': {
              if (plugin.backend) 'backend': {'artifact': 'backend.aot'},
              if (hasFrontend)
                'frontend': {
                  'artifact': 'frontend.evc',
                  'presentations': presentations ?? [],
                  'extensions': ?extensions,
                },
            },
          });
          expect(
            directory.listSync(),
            hasLength(
              1 +
                  (plugin.backend ? 1 : 0) +
                  (hasFrontend ? 1 : 0) +
                  (plugin.directory == 'source-editor' ? 1 : 0) +
                  (plugin.directory == 'openai' ? 1 : 0) +
                  (plugin.directory == 'git' ? 1 : 0),
            ),
          );
          if (hasFrontend) {
            final artifact = File.fromUri(
              directory.uri.resolve('frontend.evc'),
            );
            expect(artifact.readAsStringSync(), 'frontend bytecode\n');
          }
          for (final file in directory.listSync().cast<File>()) {
            retainedArtifacts[file.path] = file.readAsStringSync();
          }
        }
        expect(installedIds, hasLength(13));
        final catalog = await PreparedPluginCatalog.discover(
          installations.path,
        );
        expect(catalog.issues, isEmpty);
        expect(
          catalog.installations.map(
            (installation) => installation.metadata.id.value,
          ),
          unorderedEquals(installedIds),
        );
        expect(
          catalog.installations.where(
            (installation) => installation.backendArtifactUri != null,
          ),
          hasLength(10),
        );
        expect(
          catalog.installations.where(
            (installation) => installation.frontend != null,
          ),
          hasLength(9),
        );
        final recordsInstallation = catalog.installations.singleWhere(
          (installation) => installation.recordsSchema != null,
        );
        expect(recordsInstallation.metadata.id.value, 'dev.adele.openai');
        final recordsSchema = recordsInstallation.recordsSchema!;
        expect(
          recordsSchema.artifactUri,
          installations.uri.resolve('openai/records.schema.json'),
        );
        expect(
          File.fromUri(recordsSchema.artifactUri).readAsBytesSync(),
          File('plugins/openai/records.schema.json').readAsBytesSync(),
        );
        expect(catalog.records.definitions, recordsSchema.definitions);
        expect(
          catalog.records.definitions.single.id.value,
          'dev.adele.openai.api-key',
        );
        final evaluator = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value ==
              'dev.adele.plugin.session-evaluator',
        );
        expect(evaluator.frontend, isNull);
        expect(evaluator.settingsSchema, isNull);
        expect(evaluator.backendConsumedCapabilities, isEmpty);
        expect(
          evaluator.backendArtifactUri,
          installations.uri.resolve('session-evaluator/backend.aot'),
        );
        expect(
          File.fromUri(evaluator.backendArtifactUri!).readAsStringSync(),
          'snapshot $_sessionEvaluatorEntrypoint\n',
        );
        final diff = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.diff-viewer',
        );
        expect(
          diff.backendArtifactUri,
          installations.uri.resolve('diff-viewer/backend.aot'),
        );
        expect(
          File.fromUri(diff.backendArtifactUri!).readAsStringSync(),
          'snapshot $_diffViewerEntrypoint\n',
        );
        expect(diff.backendConsumedCapabilities, isEmpty);
        expect(diff.frontend!.extensions, isEmpty);
        expect(
          diff.frontend!.artifactUri,
          installations.uri.resolve('diff-viewer/frontend.evc'),
        );
        final diffDescriptor =
            diff.frontend!.presentations.single
                as PreparedMainContentPresentation;
        expect(diffDescriptor.canRequestSourceDisplay, isTrue);
        expect(
          catalog.installations
              .where(
                (installation) =>
                    installation.frontend?.presentations
                        .whereType<PreparedMainContentPresentation>()
                        .any(
                          (descriptor) => descriptor.canRequestSourceDisplay,
                        ) ??
                    false,
              )
              .map((installation) => installation.metadata.id.value),
          ['dev.adele.diff-viewer'],
        );
        expect(diffDescriptor.toJson(), {
          ...stockFrontendDescriptors['dev.adele.diff-viewer']!.single,
          'sessionExecution': false,
          'backendServices': <String>[],
          'capabilities': <Object?>[],
          'environmentReadCapabilities': <Object?>[],
          'strategyAffinity': 'independent',
          'actions': <Object?>[],
          'operations': <String, Object?>{},
          'retainedData': false,
          'nativeCodeEditor': false,
          'environmentTextFiles': false,
        });
        final source = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.source-editor',
        );
        expect(source.backendArtifactUri, isNull);
        final schema = source.settingsSchema!;
        expect(
          schema.artifactUri,
          installations.uri.resolve('source-editor/settings.schema.json'),
        );
        expect(
          File.fromUri(schema.artifactUri).readAsBytesSync(),
          File('plugins/source_editor/settings.schema.json').readAsBytesSync(),
        );
        expect(
          jsonDecode(File.fromUri(schema.artifactUri).readAsStringSync()),
          {
            'schemaVersion': 1,
            'definitions': [
              {
                'id': 'dev.adele.source-editor.enable-folding',
                'type': 'boolean',
                'default': false,
                'label': 'Enable Code Folding',
                'category': 'Editor',
                'section': 'Display',
              },
            ],
          },
        );
        final setting = schema.definitions.single;
        expect(setting.id.value, 'dev.adele.source-editor.enable-folding');
        expect(setting.owner.value, source.metadata.id.value);
        expect(setting.defaultValue, isFalse);
        expect(setting.label, 'Enable Code Folding');
        expect(setting.category, 'Editor');
        expect(setting.section, 'Display');
        expect(setting.description, isNull);
        expect(setting.validate(true), isTrue);
        expect(() => setting.validate('true'), throwsException);
        expect(() => setting.validate(1), throwsException);
        expect(catalog.settings.definitions, [setting]);
        expect(catalog.settings.resolve(setting.id).value, isFalse);
        final sourceCommand =
            source.frontend!.extensions.single
                as PreparedMainContentActionCommandExtension;
        expect(sourceCommand.toJson(), {
          'kind': 'mainContentActionCommand',
          'extensionId': 'dev.adele.source-editor.command.open-source',
          'commandId': 'dev.adele.source-editor.open-source',
          'mainContentExtensionId': 'dev.adele.source-editor.main-content',
          'actionId': 'open',
        });
        expect(
          source.frontend!.artifactUri,
          installations.uri.resolve('source-editor/frontend.evc'),
        );
        final sourceDescriptor =
            source.frontend!.presentations.single
                as PreparedMainContentPresentation;
        expect(
          sourceDescriptor.extensionId.value,
          'dev.adele.source-editor.main-content',
        );
        expect(
          sourceDescriptor.library,
          'package:source_editor_frontend/main.dart',
        );
        expect(sourceDescriptor.initialize, 'initializeSource');
        expect(sourceDescriptor.entrypoint, 'sourcePane');
        expect(sourceDescriptor.order, 300);
        expect(sourceDescriptor.actions.single.id, 'open');
        expect(sourceDescriptor.actions.single.label, 'Open Source...');
        expect(sourceDescriptor.actions.single.entrypoint, 'openSourceInput');
        expect(
          sourceCommand.mainContentExtensionId,
          sourceDescriptor.extensionId,
        );
        expect(sourceCommand.actionId, sourceDescriptor.actions.single.id);
        expect(sourceDescriptor.operations, {
          'display': 'displaySource',
          'save': 'saveSource',
          'close': 'closeSource',
          'exit': 'closeSources',
        });
        expect(sourceDescriptor.closeOperation, 'close');
        expect(sourceDescriptor.exitOperation, 'exit');
        expect(sourceDescriptor.displaySourceFileOperation, 'display');
        expect(sourceDescriptor.retainedData, isTrue);
        expect(sourceDescriptor.nativeCodeEditor, isTrue);
        expect(sourceDescriptor.environmentTextFiles, isTrue);
        expect(sourceDescriptor.backendServices, isEmpty);
        expect(sourceDescriptor.sessionExecution, isFalse);
        expect(
          sourceDescriptor.strategyAffinity,
          PreparedStrategyAffinity.independent,
        );
        final terminal = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.plugin.terminal',
        );
        expect(terminal.backendArtifactUri, isNull);
        final terminalCommand =
            terminal.frontend!.extensions.single
                as PreparedConsoleActionCommandExtension;
        expect(
          terminalCommand.extensionId.value,
          'dev.adele.plugin.terminal.command.new-terminal',
        );
        expect(
          terminalCommand.commandId.value,
          'dev.adele.plugin.terminal.new-terminal',
        );
        expect(terminalCommand.toJson(), {
          'kind': 'consoleActionCommand',
          'extensionId': 'dev.adele.plugin.terminal.command.new-terminal',
          'commandId': 'dev.adele.plugin.terminal.new-terminal',
          'consoleExtensionId': 'dev.adele.plugin.terminal.console',
          'actionId': 'new-terminal',
        });
        expect(
          terminal.frontend!.artifactUri,
          installations.uri.resolve('terminal/frontend.evc'),
        );
        final console =
            terminal.frontend!.presentations.single
                as PreparedConsolePresentation;
        expect(console.extensionId.value, 'dev.adele.plugin.terminal.console');
        expect(
          console.library,
          'package:terminal_frontend/terminal_frontend.dart',
        );
        expect(console.entrypoint, 'buildTerminal');
        expect(console.keepAlive, isFalse);
        expect(console.actions.single.id, 'new-terminal');
        expect(console.actions.single.label, 'New Terminal');
        expect(console.actions.single.entrypoint, 'newTerminal');
        expect(terminalCommand.consoleExtensionId, console.extensionId);
        expect(terminalCommand.actionId, console.actions.single.id);
        final commandOutput = catalog.installations
            .singleWhere(
              (installation) =>
                  installation.metadata.id.value ==
                  'dev.adele.plugin.command-tools',
            )
            .frontend!
            .presentations
            .whereType<PreparedConsolePresentation>()
            .single;
        expect(commandOutput.keepAlive, isTrue);
        expect(commandOutput.readOnly, isTrue);
        expect(commandOutput.backendServices, ['command.output']);
        final localDirectoryProjectInstallation = catalog.installations
            .singleWhere(
              (installation) =>
                  installation.metadata.id.value ==
                  'dev.adele.plugin.local-directory-project',
            );
        expect(
          localDirectoryProjectInstallation.backendArtifactUri,
          localDirectoryProject.uri,
        );
        expect(
          localDirectoryProjectInstallation.frontend!.artifactUri,
          installations.uri.resolve('local-directory-project/frontend.evc'),
        );
        expect(
          localDirectoryProjectInstallation.frontend!.extensions.single
              .toJson(),
          {
            'kind': 'projectSelector',
            'extensionId':
                'dev.adele.plugin.local-directory-project.project-selector',
            'projectProviderId': 'dev.adele.project.local-directory',
            'displayName': 'Open Local Directory...',
            'library':
                'package:local_directory_project_frontend/local_directory_project_frontend.dart',
            'entrypoint': 'selectProject',
          },
        );
        for (final installation in catalog.installations) {
          final descriptors =
              stockFrontendDescriptors[installation.metadata.id.value];
          expect(
            installation.frontend?.presentations.length,
            installation.frontend == null ? null : descriptors?.length ?? 0,
          );
          expect(
            installation.frontend?.extensions.map(
              (extension) => extension.toJson(),
            ),
            installation.frontend == null
                ? null
                : stockFrontendExtensionDescriptors[installation
                          .metadata
                          .id
                          .value] ??
                      [],
          );
        }
        retainedArtifacts[startupArguments.path] = startupArguments
            .readAsStringSync();
        expect(
          host.parent.path,
          startsWith(
            '${root.path}/.dart_tool/adele/desktop-plugins/snapshots/',
          ),
        );
        expect(outputDirectories.add(host.parent.path), cold);
        expect(
          host.parent.listSync().map(
            (entry) =>
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
          ),
          unorderedEquals(['host.aot', 'installations', 'receipt.json']),
        );
        expect(host.readAsStringSync(), 'snapshot $_hostEntrypoint\n');
        expect(git.readAsStringSync(), 'snapshot $_gitEntrypoint\n');
        expect(openai.readAsStringSync(), 'snapshot $_openaiEntrypoint\n');
        expect(agentsMd.readAsStringSync(), 'snapshot $_agentsMdEntrypoint\n');
        expect(
          searchTools.readAsStringSync(),
          'snapshot $_searchToolsEntrypoint\n',
        );
        expect(
          filesystemTools.readAsStringSync(),
          'snapshot $_filesystemToolsEntrypoint\n',
        );
        expect(
          commandTools.readAsStringSync(),
          'snapshot $_commandToolsEntrypoint\n',
        );
        expect(frontend.readAsStringSync(), 'frontend bytecode\n');
        expect(chat.readAsStringSync(), 'snapshot $_chatEntrypoint\n');
        expect(
          localDirectoryProject.readAsStringSync(),
          'snapshot $_localDirectoryProjectEntrypoint\n',
        );
        retainedArtifacts[host.path] = host.readAsStringSync();
        for (final MapEntry<String, String> artifact
            in retainedArtifacts.entries) {
          expect(File(artifact.key).readAsStringSync(), artifact.value);
        }
        commands.deleteSync();
      }
    },
  );

  for (final arguments in [
    ['run', 'linux', '--profile'],
    ['run', 'linux', '--release'],
    ['build', 'linux', '--release'],
  ]) {
    test('${arguments.join(' ')} selects the development entrypoint', () async {
      final result = await invoke(arguments);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final run = arguments.first == 'run';
      expect(launchArguments.readAsLinesSync().take(run ? 5 : 4), [
        arguments.first,
        if (run) '-d',
        'linux',
        arguments.last,
        '--target=tool/development_main.dart',
      ]);
      expect(
        commands.readAsLinesSync(),
        contains('compiled|$_sessionEvaluatorEntrypoint'),
      );
    });
  }

  for (final failure in ['exit', 'missing', 'empty']) {
    test(
      'native helper $failure failure prevents runtime activation',
      () async {
        if (failure == 'exit') {
          environment['ADELE_TEST_FAIL_PTY'] = '1';
        } else {
          environment['ADELE_TEST_PTY_ARTIFACT'] = failure;
        }
        final result = await invoke(['build', 'linux']);
        expect(result.exitCode, failure == 'exit' ? 37 : 1);
        expect(result.stderr, contains('git-pty-helper-compilation'));
        expect(launchArguments.existsSync(), isFalse);
        expect(frontendArguments.existsSync(), isFalse);
        expectNoPublishedInstallations();
      },
    );
  }

  for (final missing in PreparedPluginComponent.values) {
    test(
      'Command missing ${missing.name} retains its installed sibling',
      () async {
        final result = await invoke(['run', 'linux']);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        const prefix = '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=';
        final rootPath = launchArguments
            .readAsLinesSync()
            .singleWhere((argument) => argument.startsWith(prefix))
            .substring(prefix.length);
        await File(
          '$rootPath/command-tools/${missing == PreparedPluginComponent.backend ? 'backend.aot' : 'frontend.evc'}',
        ).delete();

        final catalog = await PreparedPluginCatalog.discover(rootPath);
        expect(catalog.installations, hasLength(13));
        expect(catalog.issues.single.component, missing);
        final command = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value ==
              'dev.adele.plugin.command-tools',
        );
        expect(
          command.backendArtifactUri,
          missing == PreparedPluginComponent.backend ? isNull : isNotNull,
        );
        expect(
          command.frontend,
          missing == PreparedPluginComponent.frontend ? isNull : isNotNull,
        );
        expect(
          catalog.installations.where(
            (installation) => installation.backendArtifactUri != null,
          ),
          hasLength(missing == PreparedPluginComponent.backend ? 9 : 10),
        );
        expect(
          catalog.installations.where(
            (installation) => installation.frontend != null,
          ),
          hasLength(missing == PreparedPluginComponent.frontend ? 8 : 9),
        );
      },
    );
  }

  test('missing selector EVC retains its owning backend', () async {
    final result = await invoke(['run', 'linux']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    const prefix = '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=';
    final rootPath = launchArguments
        .readAsLinesSync()
        .singleWhere((argument) => argument.startsWith(prefix))
        .substring(prefix.length);
    await File('$rootPath/local-directory-project/frontend.evc').delete();

    final catalog = await PreparedPluginCatalog.discover(rootPath);
    expect(catalog.installations, hasLength(13));
    expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    final localDirectoryProject = catalog.installations.singleWhere(
      (installation) =>
          installation.metadata.id.value ==
          'dev.adele.plugin.local-directory-project',
    );
    expect(localDirectoryProject.backendArtifactUri, isNotNull);
    expect(localDirectoryProject.frontend, isNull);
    expect(
      catalog.installations.where(
        (installation) => installation.frontend != null,
      ),
      hasLength(8),
    );
  });

  for (final explicitClient in [false, true]) {
    test(
      'writes only public OpenAI startup config, explicit client=$explicitClient',
      () async {
        final credentials = File('${root.path}/credentials.json')
          ..writeAsStringSync(
            jsonEncode({
              'accessToken': 'secret-access-token',
              'refreshToken': 'secret-refresh-token',
            }),
          );
        environment.addAll({
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': explicitClient
              ? 'public-client'
              : '  ',
          'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'work-instance',
          'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://issuer.example.com',
          'ADELE_OPENAI_CHATGPT_REDIRECT_URI': 'http://localhost:1455/callback',
          'ADELE_OPENAI_CHATGPT_ENDPOINT':
              'https://model.example.com/responses',
          'ADELE_OPENAI_CHATGPT_MODEL': 'app-model-not-backend-config',
          'ADELE_OPENAI_CHATGPT_ACCESS_TOKEN': 'secret-env-access-token',
          'ADELE_OPENAI_CHATGPT_REFRESH_TOKEN': 'secret-env-refresh-token',
          'OPENAI_API_KEY': 'secret-api-key',
        });
        final result = await invoke(['run', 'linux']);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final serialized = readStartupArguments();
        final arguments = jsonDecode(serialized) as Map<String, Object?>;
        expect(arguments.keys, ['dev.adele.openai', 'dev.adele.plugin.git']);
        expect(arguments['dev.adele.plugin.git'], gitStartupArguments());
        final openai = (arguments['dev.adele.openai']! as List<Object?>)
            .cast<String>();
        expect(openai, hasLength(2));
        expect(openai.first, '--chatgpt-only');
        expect(jsonDecode(openai.last), {
          'credentialFile': credentials.path,
          if (explicitClient)
            'clientId': 'public-client'
          else
            'experimentalCodexClient': true,
          'instanceId': 'work-instance',
          'issuer': 'https://issuer.example.com',
          'redirectUri': 'http://localhost:1455/callback',
          'endpoint': 'https://model.example.com/responses',
        });
        for (final forbidden in ['secret-', 'app-model-not-backend-config']) {
          expect(serialized, isNot(contains(forbidden)));
          expect(
            launchArguments.readAsStringSync(),
            isNot(contains(forbidden)),
          );
        }
        final output = Directory(
          '${root.path}/.dart_tool/adele/desktop-plugins',
        );
        final manifests = output
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) => file.path.endsWith('adele_plugin.installation.json'),
            );
        expect(manifests, hasLength(13));
        for (final manifest in manifests) {
          for (final forbidden in [
            'secret-',
            credentials.path,
            'public-client',
            'work-instance',
            'issuer.example.com',
            'localhost:1455',
            'model.example.com',
            'app-model-not-backend-config',
            '--chatgpt-only',
          ]) {
            expect(manifest.readAsStringSync(), isNot(contains(forbidden)));
            expect(result.stdout, isNot(contains(forbidden)));
            expect(result.stderr, isNot(contains(forbidden)));
            expect(
              launchArguments.readAsStringSync(),
              isNot(contains(forbidden)),
            );
          }
        }
      },
    );
  }

  test(
    'credential references need not exist and blank public overrides are omitted',
    () async {
      final credentialPath = '${root.path}/not-created.json';
      environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'] = credentialPath;
      environment['ADELE_OPENAI_CHATGPT_INSTANCE_ID'] = '  ';
      environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'] = '  ';
      final result = await invoke(['build', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final serialized = readStartupArguments();
      expect(jsonDecode(serialized), {
        'dev.adele.plugin.git': gitStartupArguments(),
        'dev.adele.openai': [
          '--chatgpt-only',
          jsonEncode({
            'credentialFile': credentialPath,
            'experimentalCodexClient': true,
          }),
        ],
      });
      expect(File(credentialPath).existsSync(), isFalse);
    },
  );

  test(
    'without credentials OpenAI stays chatgpt-only and ignores other config',
    () async {
      environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '  ',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'unused-client',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid',
        'OPENAI_API_KEY': 'must-not-enable-api-key-context',
      });
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final serialized = readStartupArguments();
      expect(jsonDecode(serialized), {
        'dev.adele.openai': ['--chatgpt-only'],
        'dev.adele.plugin.git': gitStartupArguments(),
      });
    },
  );

  test(
    'invalid public URI is forwarded for backend-local validation',
    () async {
      environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '/not-read.json',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid-private-value',
      });
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final arguments =
          jsonDecode(readStartupArguments()) as Map<String, dynamic>;
      final openai = arguments['dev.adele.openai'] as List<dynamic>;
      expect(jsonDecode(openai[1] as String), {
        'credentialFile': '/not-read.json',
        'experimentalCodexClient': true,
        'issuer': 'https://[invalid-private-value',
      });
      expect(result.stderr, isNot(contains('invalid-private-value')));
      expect(launchArguments.existsSync(), isTrue);
    },
  );

  for (final declaration in [
    (kind: 'settings', source: 'source_editor', installation: 'source-editor'),
    (kind: 'records', source: 'openai', installation: 'openai'),
  ]) {
    for (final failure in ['missing', 'empty', 'directory']) {
      test(
        'stock ${declaration.kind} schema $failure prevents ${declaration.installation} publication and launch',
        () async {
          final filename = '${declaration.kind}.schema.json';
          final schema = File(
            '${root.path}/plugins/${declaration.source}/$filename',
          );
          if (failure == 'empty') {
            schema.writeAsBytesSync([]);
          } else {
            schema.deleteSync();
            if (failure == 'directory') Directory(schema.path).createSync();
          }
          final result = await invoke(['run', 'linux']);
          expect(result.exitCode, 1);
          expect(result.stderr, contains('${declaration.kind} schema'));
          expect(result.stderr, contains(filename));
          expect(launchArguments.existsSync(), isFalse);
          expect(commands.readAsLinesSync(), isNot(contains('flutter-launch')));
          expectNoPublishedInstallations();
        },
      );
    }
  }

  for (final String failedEntrypoint in _backendEntrypoints) {
    for (final String command in <String>['run', 'build']) {
      test('$command never launches after $failedEntrypoint fails', () async {
        environment['ADELE_TEST_FAIL_ENTRYPOINT'] = failedEntrypoint;
        final ProcessResult result = await invoke(<String>[
          command,
          'linux',
          '--profile',
        ]);
        expect(result.exitCode, 17);
        expect(result.stderr, contains('snapshot compiler failed'));
        expect(result.stderr, contains('failed with exit code 17'));
        if (failedEntrypoint == _localDirectoryProjectEntrypoint) {
          expect(
            result.stderr,
            contains(
              'local-directory-project-compilation failed with exit code 17',
            ),
          );
        }
        if (failedEntrypoint == _sessionEvaluatorEntrypoint) {
          expect(
            result.stderr,
            contains('session-evaluator-compilation failed with exit code 17'),
          );
        }
        expect(commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          ..._toolCompilationEvents,
          'generate|aot|--incremental',
          for (final entrypoint in _backendEntrypoints.take(
            _backendEntrypoints.indexOf(failedEntrypoint) + 1,
          )) ...[
            'compile|$entrypoint',
            if (entrypoint != failedEntrypoint) 'compiled|$entrypoint',
          ],
        ]);
        expect(launchArguments.existsSync(), isFalse);
        expectNoPublishedInstallations();
      });
    }
  }

  for (final String command in <String>['run', 'build']) {
    for (final kind in _frontendCompilations.keys) {
      for (final String failure in <String>['exit', 'missing', 'empty']) {
        test(
          '$command never launches after $kind frontend $failure failure',
          () async {
            environment['ADELE_TEST_FRONTEND_TARGET'] = kind;
            if (failure == 'exit') {
              environment['ADELE_TEST_FAIL_FRONTEND'] = '1';
            } else {
              environment['ADELE_TEST_FRONTEND_ARTIFACT'] = failure;
            }
            final ProcessResult result = await invoke(<String>[
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
                frontendEnvironment.readAsLinesSync()[1],
                contains('/.staging/'),
              );
            } else {
              expect(result.stderr, contains('produced no non-empty artifact'));
            }
            expect(commands.readAsLinesSync(), <String>[
              'inspect-sdk',
              ..._toolCompilationEvents,
              'generate|aot|--incremental',
              'compile|$_hostEntrypoint',
              'compiled|$_hostEntrypoint',
              'compile|$_gitEntrypoint',
              'compiled|$_gitEntrypoint',
              'compile|$_openaiEntrypoint',
              'compiled|$_openaiEntrypoint',
              'compile|$_agentsMdEntrypoint',
              'compiled|$_agentsMdEntrypoint',
              'compile|$_searchToolsEntrypoint',
              'compiled|$_searchToolsEntrypoint',
              'compile|$_filesystemToolsEntrypoint',
              'compiled|$_filesystemToolsEntrypoint',
              'compile|$_commandToolsEntrypoint',
              'compiled|$_commandToolsEntrypoint',
              'compile|$_chatEntrypoint',
              'compiled|$_chatEntrypoint',
              'compile|$_localDirectoryProjectEntrypoint',
              'compiled|$_localDirectoryProjectEntrypoint',
              'compile|$_sessionEvaluatorEntrypoint',
              'compiled|$_sessionEvaluatorEntrypoint',
              'compile|$_diffViewerEntrypoint',
              'compiled|$_diffViewerEntrypoint',
              'compile|git-pty-helper',
              for (final frontend in _frontendCompilations.entries.take(
                _frontendCompilations.keys.toList().indexOf(kind) + 1,
              )) ...[
                'compile|${frontend.value}',
                if (frontend.key != kind || failure != 'exit')
                  'compiled|${frontend.value}',
              ],
            ]);
            expect(launchArguments.existsSync(), isFalse);
            expectNoPublishedInstallations();
          },
        );
      }
    }
  }

  test('frontend failure never reuses a retained successful artifact', () async {
    final ProcessResult first = await invoke(<String>['build', 'linux']);
    expect(first.exitCode, 0, reason: first.stderr.toString());
    final File previous = File(
      '${launchDefines()['ADELE_PLUGIN_INSTALLATION_ROOT']}/chat-strategy/frontend.evc',
    );
    changeSource(_chatSource);
    launchArguments.deleteSync();
    commands.deleteSync();

    environment['ADELE_TEST_FRONTEND_ARTIFACT'] = 'missing';
    final ProcessResult second = await invoke(<String>['run', 'linux']);
    expect(second.exitCode, 1);
    expect(second.stderr, contains('produced no non-empty artifact'));
    expect(previous.readAsStringSync(), 'frontend bytecode\n');
    expect(frontendEnvironment.readAsLinesSync()[1], isNot(previous.path));
    expect(commands.readAsLinesSync(), isNot(contains('flutter-launch')));
    expect(launchArguments.existsSync(), isFalse);
  });

  for (final mutation in [
    (path: _gitEntrypoint, expected: [_gitEntrypoint]),
    (path: _chatSource, expected: [_frontendHarness]),
    (path: _chatCompiler, expected: [_frontendHarness]),
    (path: _frontendBridge, expected: _frontendCompilations.values.toList()),
    (
      path: _sharedSource,
      expected: [..._backendEntrypoints, ..._frontendCompilations.values],
    ),
    (
      path: 'contract.dart',
      expected: [..._backendEntrypoints, _frontendHarness],
    ),
    (path: _nativeSource, expected: ['git-pty-helper']),
    (path: _nativeHeader, expected: ['git-pty-helper']),
    (path: 'native/ld', expected: ['git-pty-helper']),
    (path: 'native/libc.so', expected: ['git-pty-helper']),
    (path: 'tools/git_pty_artifact.dart', expected: ['git-pty-helper']),
    (
      path: 'tools/frontend_artifacts.dart',
      expected: _frontendCompilations.values.toList(),
    ),
    (
      path: 'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      expected: _backendEntrypoints,
    ),
    (
      path: 'tools/desktop_build_inputs_worker.dart',
      expected: [..._backendEntrypoints, ..._frontendCompilations.values],
    ),
  ]) {
    test(
      'incremental preparation rebuilds only consumers of ${mutation.path}',
      () async {
        final before = await prepare();
        expect(compilations(), hasLength(21));
        expect(toolCompilations(), _toolStages.values);
        final retained = retainedFiles();
        changeSource(mutation.path);
        final after = await prepare(['build', 'linux', '--release']);
        expect(compilations(), unorderedEquals(mutation.expected));
        expect(
          toolCompilations(),
          mutation.path.startsWith('tools/')
              ? [_workerEntrypoint]
              : mutation.path ==
                    'packages/plugin_builder/lib/src/development_plugin_builder.dart'
              ? _toolStages.values
              : isEmpty,
        );
        expect(
          after['ADELE_PLUGIN_INSTALLATION_ROOT'],
          isNot(before['ADELE_PLUGIN_INSTALLATION_ROOT']),
        );
        expectRetained(retained);
        final warm = await prepare();
        expect(compilations(), isEmpty);
        expect(toolCompilations(), isEmpty);
        expect(warm, after);
        expectRetained(retained);
      },
    );
  }

  test('touches and unrelated files retain all cached paths', () async {
    final before = await prepare();
    final retained = retainedFiles();
    for (final path in [
      _gitEntrypoint,
      _chatSource,
      _sharedSource,
      _frontendBridge,
      _nativeSource,
      _generatorSource,
      _analyzerSource,
      _workerEntrypoint,
    ]) {
      File('${root.path}/$path').setLastModifiedSync(DateTime.utc(2000));
    }
    generatedContract.setLastModifiedSync(DateTime.utc(2000));
    File('${sdkBin.path}/dart').setLastModifiedSync(DateTime.utc(2000));
    File(
      '${root.path}/unrelated.txt',
    ).writeAsStringSync('not a compiler input');
    File(
      '${root.path}/app/unrelated.dart',
    ).writeAsStringSync('// not in discovery');
    expect(await prepare(['build', 'linux', '--profile']), before);
    expect(compilations(), isEmpty);
    expect(toolCompilations(), isEmpty);
    expectRetained(retained);
  });

  test(
    'discovered source additions and removals invalidate their component',
    () async {
      final before = await prepare();
      final retained = retainedFiles();
      final added = File(
        '${root.path}/plugins/source_editor/packages/frontend/lib/new_part.dart',
      )..writeAsStringSync('const added = 1;\n');
      final inputs =
          (jsonDecode(buildInputs.readAsStringSync()) as Map<String, dynamic>)
              .map(
                (key, value) => MapEntry(key, (value as List).cast<String>()),
              );
      const stage = 'source-editor-frontend-compilation';
      inputs[stage]!.add(added.path);
      inputs[stage]!.sort();
      buildInputs.writeAsStringSync(jsonEncode(inputs));
      final withAddition = await prepare();
      expect(compilations(), [_sourceEditorFrontendHarness]);
      expect(toolCompilations(), isEmpty);
      expect(withAddition, isNot(before));
      final removed = inputs[stage]!.firstWhere(
        (path) => path.endsWith('/fixture.dart'),
      );
      inputs[stage]!.remove(removed);
      File(removed).deleteSync();
      buildInputs.writeAsStringSync(jsonEncode(inputs));
      final withRemoval = await prepare();
      expect(compilations(), [_sourceEditorFrontendHarness]);
      expect(toolCompilations(), isEmpty);
      expect(withRemoval, isNot(withAddition));
      expectRetained(retained);
    },
  );

  for (final toolchain in [
    'dart',
    'dartaotruntime',
    'machine',
    'cc',
    'dart-compiler',
    'flutter-compiler',
    'platform',
    'platform-product',
    'platform-jit',
  ]) {
    test(
      '$toolchain identity changes invalidate matching cached artifacts',
      () async {
        await prepare();
        final retained = retainedFiles();
        if (toolchain == 'machine') {
          final version =
              jsonDecode(sdkVersion.readAsStringSync()) as Map<String, dynamic>;
          version['engineRevision'] = 'fixture-engine-2';
          sdkVersion.writeAsStringSync(jsonEncode(version));
        } else {
          final executable = File(switch (toolchain) {
            'cc' => '${root.path}/bin/cc',
            'dart-compiler' =>
              '${sdkBin.path}/snapshots/gen_kernel_aot.dart.snapshot',
            'flutter-compiler' =>
              '${root.path}/flutter sdk/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot',
            'platform' =>
              '${sdkBin.parent.path}/lib/_internal/vm_platform_strong.dill',
            'platform-product' =>
              '${sdkBin.parent.path}/lib/_internal/vm_platform_product.dill',
            'platform-jit' =>
              '${sdkBin.parent.path}/lib/_internal/vm_platform.dill',
            _ => '${sdkBin.path}/$toolchain',
          });
          executable.writeAsStringSync(
            '\n# toolchain revision 2\n',
            mode: FileMode.append,
          );
        }
        await prepare();
        expect(
          compilations(),
          unorderedEquals(
            toolchain == 'cc'
                ? ['git-pty-helper']
                : [..._backendEntrypoints, ..._frontendCompilations.values],
          ),
        );
        expect(
          toolCompilations(),
          toolchain == 'cc' ? isEmpty : _toolStages.values,
        );
        expectRetained(retained);
      },
    );
  }

  test(
    'startup configuration changes neither compile nor replace snapshots',
    () async {
      final before = await prepare();
      final retained = retainedFiles();
      environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
            '${root.path}/credential-reference.json',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'different-public-client',
      });
      final configured = await prepare();
      expect(compilations(), isEmpty);
      for (final key in [
        'ADELE_BACKEND_HOST_ARTIFACT',
        'ADELE_PLUGIN_INSTALLATION_ROOT',
        'ADELE_DARTAOTRUNTIME_EXECUTABLE',
      ]) {
        expect(configured[key], before[key]);
      }
      expect(
        configured['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE'],
        isNot(before['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']),
      );
      expect(readStartupArguments(), contains('different-public-client'));
      expectRetained(retained);
      final credential = File(
        environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE']!,
      )..writeAsStringSync('secret-rotated-credential');
      environment['ADELE_OPENAI_CHATGPT_MODEL'] = 'not-a-build-input';
      expect(await prepare(), configured);
      expect(compilations(), isEmpty);
      expect(
        readStartupArguments(),
        isNot(contains(credential.readAsStringSync())),
      );
      environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'] = '';
      expect(await prepare(), before);
      expect(compilations(), isEmpty);
    },
  );

  for (final metadata in ['settings', 'records', 'descriptors']) {
    test(
      '$metadata changes republish metadata without plugin compilation',
      () async {
        final before = await prepare();
        final retained = retainedFiles();
        final file = File(
          '${root.path}/${switch (metadata) {
            'settings' => 'plugins/source_editor/settings.schema.json',
            'records' => 'plugins/openai/records.schema.json',
            _ => 'tools/stock_frontend_descriptors.dart',
          }}',
        );
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(switch (metadata) {
            'settings' => 'Enable Code Folding',
            'records' => 'OpenAI API',
            _ => 'Open Source...',
          }, 'Revised metadata label'),
        );
        final after = await prepare();
        expect(compilations(), isEmpty);
        expect(
          toolCompilations(),
          metadata == 'descriptors' ? [_workerEntrypoint] : isEmpty,
        );
        expect(
          after['ADELE_PLUGIN_INSTALLATION_ROOT'],
          isNot(before['ADELE_PLUGIN_INSTALLATION_ROOT']),
        );
        final catalog = await PreparedPluginCatalog.discover(
          after['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        expect(catalog.issues, isEmpty);
        final content = Directory(after['ADELE_PLUGIN_INSTALLATION_ROOT']!)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .map((file) => file.readAsStringSync())
            .join();
        expect(content, contains('Revised metadata label'));
        expectRetained(retained);
      },
    );
  }

  for (final damage in ['missing', 'empty', 'corrupt']) {
    test(
      '$damage cached component is repaired in a new retained entry',
      () async {
        await prepare();
        final old = componentArtifact('git-compilation');
        if (damage == 'missing') {
          old.deleteSync();
        } else {
          old.writeAsStringSync(
            damage == 'empty' ? '' : 'corrupt cached bytes',
          );
        }
        final retained = retainedFiles();
        await prepare();
        expect(compilations(), [_gitEntrypoint]);
        final replacements = publishedFiles().where(
          (file) =>
              file.path.contains('/components/git-compilation/') &&
              file.uri.pathSegments.last == 'backend.aot' &&
              file.path != old.path,
        );
        expect(replacements, hasLength(1));
        expect(
          replacements.single.readAsStringSync(),
          'snapshot $_gitEntrypoint\n',
        );
        expect(old.existsSync(), damage != 'missing');
        expectRetained(retained);
        await prepare();
        expect(compilations(), isEmpty);
      },
    );
  }

  for (final damage in [
    'missing-receipt',
    'corrupt-receipt',
    'wrong-digest',
    'unlisted-output',
  ]) {
    test('$damage makes a component receipt non-reusable', () async {
      await prepare();
      final old = componentArtifact('chat-frontend-compilation');
      final receipt = File('${old.parent.path}/receipt.json');
      switch (damage) {
        case 'missing-receipt':
          receipt.deleteSync();
        case 'corrupt-receipt':
          receipt.writeAsStringSync('{incomplete');
        case 'wrong-digest':
          final data =
              jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
          (data['files'] as Map<String, dynamic>)['frontend.evc'] = {
            'sha256': '0' * 64,
            'executable': 0,
          };
          receipt.writeAsStringSync(jsonEncode(data));
        case 'unlisted-output':
          File(
            '${old.parent.path}/unlisted',
          ).writeAsStringSync('not inventoried');
      }
      final retained = retainedFiles();
      await prepare();
      expect(compilations(), [_frontendHarness]);
      expectRetained(retained);
      expect(
        publishedFiles().where(
          (file) =>
              file.path.contains('/components/chat-frontend-compilation/') &&
              file.uri.pathSegments.last == 'frontend.evc',
        ),
        hasLength(2),
      );
    });
  }

  for (final output in ['host', 'manifest', 'schema', 'startup']) {
    test(
      'corrupt $output republishes a complete entry without compiling',
      () async {
        final before = await prepare();
        final old = File(switch (output) {
          'host' => before['ADELE_BACKEND_HOST_ARTIFACT']!,
          'startup' => before['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']!,
          'schema' =>
            '${before['ADELE_PLUGIN_INSTALLATION_ROOT']}/openai/records.schema.json',
          _ =>
            '${before['ADELE_PLUGIN_INSTALLATION_ROOT']}/git/adele_plugin.installation.json',
        });
        old.writeAsStringSync('corrupt published output');
        final retained = retainedFiles();
        final after = await prepare();
        expect(compilations(), isEmpty);
        final key = output == 'startup'
            ? 'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE'
            : 'ADELE_PLUGIN_INSTALLATION_ROOT';
        expect(after[key], isNot(before[key]));
        final catalog = await PreparedPluginCatalog.discover(
          after['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        expect(catalog.issues, isEmpty);
        expect(jsonDecode(readStartupArguments()), isA<Map<String, dynamic>>());
        expectRetained(retained);
      },
    );
  }

  for (final output in ['snapshot', 'startup']) {
    test(
      'self-consistent incomplete $output receipt is not a cache hit',
      () async {
        final before = await prepare();
        final key = output == 'snapshot'
            ? 'ADELE_BACKEND_HOST_ARTIFACT'
            : 'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE';
        final artifact = File(before[key]!);
        final receipt = File('${artifact.parent.path}/receipt.json');
        final data =
            jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
        final files = data['files'] as Map<String, dynamic>;
        final removed = files.remove(artifact.uri.pathSegments.last);
        if (output == 'snapshot') {
          artifact.deleteSync();
        } else {
          artifact.renameSync('${artifact.parent.path}/unexpected.json');
          files['unexpected.json'] = removed;
        }
        receipt.writeAsStringSync(jsonEncode(data));
        final retained = retainedFiles();
        final after = await prepare();
        expect(compilations(), isEmpty);
        expect(after[key], isNot(artifact.path));
        expect(
          File(after['ADELE_BACKEND_HOST_ARTIFACT']!).readAsStringSync(),
          'snapshot $_hostEntrypoint\n',
        );
        expect(jsonDecode(readStartupArguments()), isA<Map<String, dynamic>>());
        expect(artifact.existsSync(), isFalse);
        expectRetained(retained);
      },
    );
  }

  test(
    'native executable mode damage rebuilds without overwriting old entry',
    () async {
      await prepare();
      final helper = componentArtifact('git-pty-helper-compilation');
      expect(Process.runSync('chmod', ['-x', helper.path]).exitCode, 0);
      final retained = retainedFiles();
      await prepare();
      expect(compilations(), ['git-pty-helper']);
      expect(helper.statSync().mode & 0x49, 0);
      final replacement = publishedFiles().singleWhere(
        (file) =>
            file.path.contains('/components/git-pty-helper-compilation/') &&
            file.uri.pathSegments.last == 'pty-helper' &&
            file.path != helper.path,
      );
      expect(replacement.statSync().mode & 0x49, isNot(0));
      expectRetained(retained);
    },
  );

  test(
    'published receipts inventory every file with its SHA256 digest',
    () async {
      await prepare();
      final files = publishedFiles();
      final receipts = files.where(
        (file) => file.uri.pathSegments.last == 'receipt.json',
      );
      expect(receipts, hasLength(25));
      for (final receipt in receipts) {
        final decoded =
            jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
        expect(decoded['version'], 1);
        expect(
          decoded['identity'],
          receipt.parent.parent.uri.pathSegments.lastWhere(
            (part) => part.isNotEmpty,
          ),
        );
        final inventory = decoded['files'] as Map<String, dynamic>;
        final artifacts = receipt.parent
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path != receipt.path)
            .toList();
        expect(
          inventory.keys,
          unorderedEquals(
            artifacts.map(
              (file) => file.path.substring(receipt.parent.path.length + 1),
            ),
          ),
        );
        final sums = Process.runSync('sha256sum', [
          '--zero',
          '--',
          ...artifacts.map((file) => file.path),
        ]);
        expect(sums.exitCode, 0, reason: '${sums.stderr}');
        final records = sums.stdout.toString().split('\u0000')..removeLast();
        for (var index = 0; index < artifacts.length; index++) {
          final relative = artifacts[index].path.substring(
            receipt.parent.path.length + 1,
          );
          expect(
            inventory[relative]['sha256'],
            records[index].substring(0, 64),
          );
          expect(artifacts[index].lengthSync(), greaterThan(0));
        }
      }
    },
  );

  test(
    'failed dirty backend rebuild cannot launch or mutate retained outputs',
    () async {
      final before = await prepare();
      final retained = retainedFiles();
      changeSource(_gitEntrypoint);
      environment['ADELE_TEST_FAIL_ENTRYPOINT'] = _gitEntrypoint;
      launchArguments.deleteSync();
      commands.deleteSync();
      final failed = await invoke(['run', 'linux']);
      expect(failed.exitCode, 17);
      expect(compilations(), [_gitEntrypoint]);
      expect(launchArguments.existsSync(), isFalse);
      expectRetained(retained);
      expect(
        publishedFiles().map((file) => file.path),
        unorderedEquals(retained.keys),
      );
      environment.remove('ADELE_TEST_FAIL_ENTRYPOINT');
      final recovered = await prepare();
      expect(compilations(), [_gitEntrypoint]);
      expect(recovered, isNot(before));
      expectRetained(retained);
    },
  );

  test('warm cache never masks native toolchain probe failures', () async {
    await prepare();
    final retained = retainedFiles();
    environment['ADELE_TEST_FAIL_NATIVE_INSPECTION'] = '1';
    launchArguments.deleteSync();
    commands.deleteSync();
    final failed = await invoke(['run', 'linux']);
    expect(failed.exitCode, 43);
    expect(failed.stdout, contains('native probe stdout'));
    expect(failed.stderr, contains('native probe stderr'));
    expect(
      failed.stderr,
      contains('toolchain inspection failed with exit code 43'),
    );
    expect(compilations(), isEmpty);
    expect(launchArguments.existsSync(), isFalse);
    expectRetained(retained);
  });

  for (final command in ['run', 'build']) {
    test(
      '$command warm cache never masks incremental generation or discovery failures',
      () async {
        await prepare();
        final retained = retainedFiles();
        final discoveries = File('${root.path}/logs/discovery.txt');
        frontendArguments.deleteSync();
        for (final failure in ['GENERATION', 'DISCOVERY']) {
          final previousDiscoveries = discoveries.readAsLinesSync();
          environment['ADELE_TEST_FAIL_$failure'] = '1';
          if (launchArguments.existsSync()) launchArguments.deleteSync();
          commands.deleteSync();
          final result = await invoke([command, 'linux']);
          expect(result.exitCode, failure == 'GENERATION' ? 29 : 1);
          expect(
            result.stderr,
            contains(
              failure == 'GENERATION'
                  ? 'contract generator failed'
                  : 'discovery worker failed',
            ),
          );
          expect(compilations(), isEmpty);
          expect(toolCompilations(), isEmpty);
          expect(commands.readAsLinesSync(), [
            'inspect-sdk',
            'generate|aot|--incremental',
          ]);
          expectGenerationArguments(['--incremental'], true);
          expect(discoveries.readAsLinesSync(), [
            ...previousDiscoveries,
            if (failure == 'DISCOVERY') 'discover|aot',
          ]);
          expect(launchArguments.existsSync(), isFalse);
          expect(frontendArguments.existsSync(), isFalse);
          expectRetained(retained);
          expect(
            publishedFiles().map((file) => file.path),
            unorderedEquals(retained.keys),
          );
          environment.remove('ADELE_TEST_FAIL_$failure');
        }
        await prepare([command, 'linux']);
        expect(compilations(), isEmpty);
        expect(toolCompilations(), isEmpty);
      },
    );
  }

  test(
    'source mutation during compilation prevents publication and launch',
    () async {
      environment['ADELE_TEST_MUTATE_SOURCE'] = '${root.path}/$_sharedSource';
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Build inputs changed during desktop preparation'),
      );
      expect(launchArguments.existsSync(), isFalse);
      expect(publishedFiles(), isEmpty);
      environment.remove('ADELE_TEST_MUTATE_SOURCE');
      await prepare();
      expect(compilations(), hasLength(21));
    },
  );

  test(
    'tool mutation during generation cannot cache the already-loaded implementation',
    () async {
      environment['ADELE_TEST_MUTATE_TOOL_DURING_GENERATION'] =
          '${root.path}/packages/plugin_builder/lib/src/development_plugin_builder.dart';
      final result = await invoke(['run', 'linux']);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Build inputs changed during desktop preparation'),
      );
      expect(launchArguments.existsSync(), isFalse);
      expect(publishedFiles(), isEmpty);
    },
  );

  test(
    'overlapping preparations serialize or reject without partial publication',
    () async {
      environment['ADELE_TEST_PAUSE_ENTRYPOINT'] = _codegenEntrypoint;
      final first = invoke(['run', 'linux']);
      final ready = File('${root.path}/logs/compiler-ready');
      final release = File('${root.path}/logs/compiler-release');
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          ready.existsSync(),
          isTrue,
          reason: 'First compiler did not reach barrier.',
        );
        expect(launchArguments.existsSync(), isFalse);
        expect(publishedFiles(), isEmpty);
        expect(toolCompilations(), [_codegenEntrypoint]);
        expect(compilations(), isEmpty);
        environment.remove('ADELE_TEST_PAUSE_ENTRYPOINT');
        final second = invoke(['build', 'linux']);
        await Future.any<void>([
          second.then((_) {}),
          Future<void>.delayed(const Duration(seconds: 3)),
        ]);
        expect(launchArguments.existsSync(), isFalse);
        expect(publishedFiles(), isEmpty);
        expect(toolCompilations(), [_codegenEntrypoint]);
        release.writeAsStringSync('release');
        final results = await Future.wait([first, second]);
        expect(results.first.exitCode, 0, reason: '${results.first.stderr}');
        if (results.last.exitCode != 0) {
          expect(
            results.last.stderr.toString().toLowerCase(),
            anyOf(
              contains('lease'),
              contains('lock'),
              contains('active'),
              contains('busy'),
            ),
          );
        }
        expect(compilations(), hasLength(21));
        expect(toolCompilations(), _toolStages.values);
        final catalog = await PreparedPluginCatalog.discover(
          launchDefines()['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        expect(catalog.issues, isEmpty);
        expect(catalog.installations, hasLength(13));
        final stable = launchDefines();
        expect(await prepare(), stable);
        expect(compilations(), isEmpty);
        expect(toolCompilations(), isEmpty);
      } finally {
        release.writeAsStringSync('release');
        await first;
      }
    },
  );

  test('missing matched runtime fails before compiling or launching', () async {
    File('${sdkBin.path}/dartaotruntime').deleteSync();
    final ProcessResult result = await invoke(<String>['run', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('Required SDK executable is missing'));
    expect(commands.readAsLinesSync(), <String>['inspect-sdk']);
    expect(launchArguments.existsSync(), isFalse);
    expectNoPublishedInstallations();
  });

  for (final entrypoint in [_hostEntrypoint, _sessionEvaluatorEntrypoint]) {
    test(
      'compiler success with empty $entrypoint artifact blocks launch',
      () async {
        environment['ADELE_TEST_EMPTY_ARTIFACT'] = entrypoint;
        final result = await invoke(['run', 'linux']);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('produced no non-empty artifact'));
        expect(launchArguments.existsSync(), isFalse);
        expectNoPublishedInstallations();
      },
    );
    test(
      'compiler success without $entrypoint artifact blocks launch',
      () async {
        environment['ADELE_TEST_OMIT_ARTIFACT'] = entrypoint;
        final ProcessResult result = await invoke(<String>['run', 'linux']);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('produced no artifact'));
        expect(commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          ..._toolCompilationEvents,
          'generate|aot|--incremental',
          for (final compiled in _backendEntrypoints.take(
            _backendEntrypoints.indexOf(entrypoint) + 1,
          )) ...['compile|$compiled', 'compiled|$compiled'],
        ]);
        expect(launchArguments.existsSync(), isFalse);
        expectNoPublishedInstallations();
      },
    );
  }
}

void _script(File file, String body) {
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
}

String _depfileEscape(String path) =>
    path.replaceAll(r'\', r'\\').replaceAll(' ', r'\ ');
