import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

import '../../tools/desktop_build_inputs.dart';
import '../../tools/desktop_build_inputs_worker.dart' as discovery;

const _backends = {
  'backend-host': 'packages/plugin_backend_host/bin/adele_backend_host.dart',
  'git': 'plugins/git/packages/backend/bin/git_backend.dart',
  'openai':
      'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
  'agents-md': 'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
  'search-tools':
      'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
  'filesystem-tools':
      'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
  'command-tools':
      'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
  'chat-strategy':
      'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
  'local-directory-project':
      'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
  'session-evaluator':
      'plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart',
  'diff-viewer':
      'plugins/diff_viewer/packages/backend/bin/diff_viewer_backend.dart',
};

const _frontends = {
  'chat': ('chat_strategy', 'compile_chat_frontend.dart'),
  'filesystem': ('filesystem_tools', 'compile_tool_inspection_frontends.dart'),
  'command': ('command_tools', 'compile_tool_inspection_frontends.dart'),
  'openai': ('openai', 'compile_openai_activity_frontend.dart'),
  'local-directory-project': (
    'local_directory_project',
    'compile_local_directory_project_frontend.dart',
  ),
  'task-browser': ('task_browser', 'compile_task_browser_frontend.dart'),
  'terminal': ('terminal', 'compile_terminal_frontend.dart'),
  'source-editor': ('source_editor', 'compile_source_editor_frontend.dart'),
  'diff-viewer': ('diff_viewer', 'compile_diff_viewer_frontend.dart'),
};

void main() {
  late Directory root;
  late String packageConfig;
  final worker = File('tools/desktop_build_inputs_worker.dart').absolute;

  File write(String path, [String content = '']) {
    final file = File.fromUri(root.uri.resolve(path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  String absolute(String path) => File.fromUri(root.uri.resolve(path)).path;

  Future<ProcessResult> runWorker() => Process.run(
    Platform.resolvedExecutable,
    ['--packages=$packageConfig', worker.path, root.path],
    workingDirectory: root.path,
  );

  Future<Map<String, List<String>>> discover() async =>
      discovery.collectDesktopBuildInputs(root);

  setUpAll(() async {
    packageConfig = (await Isolate.packageConfig)!.toFilePath();
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('desktop build inputs ');
    write('pubspec.yaml', 'name: fixture\n');
    write('pubspec.lock', '{}\n');
    write('contract_codegen.yaml', 'sources: []\n');
    write('build.yaml', 'targets: {}\n');
    write('analysis_options.yaml', 'analyzer: {}\n');
    write('tools/desktop_build_inputs.dart');
    write('tools/desktop_build_inputs_worker.dart');
    write('app/pubspec.yaml', 'name: app\n');
    write('app/tool/compiler.dart', "import 'package:compiler/native.dart';\n");
    write('packages/compiler/pubspec.yaml', 'name: compiler\n');
    write('packages/compiler/lib/native.dart');
    write('packages/ui/pubspec.yaml', 'name: adele_ui\n');
    for (final bridge in [
      'main_content',
      'owning_backend',
      'rich_document_editor',
      'session_execution',
      'session_feedback',
      'session_presentation_lifecycle',
      'tool_activity_inspection',
      'console',
      'terminal_projection',
      'model_native_activity',
      'directory_picker',
      'task_browser',
      'environment_terminal',
      'terminal_surface',
      'code_editor',
      'contribution',
      'environment_access',
      'environment_capability',
    ]) {
      write('packages/ui/lib/${bridge}_bridge.dart');
    }
    write('packages/ui/lib/inspection_display.dart');
    for (final entry in _backends.entries) {
      final source = write(
        entry.value,
        "import 'package:shared/public.dart';\n",
      );
      final component = source.parent.parent;
      File.fromUri(
        component.uri.resolve('pubspec.yaml'),
      ).writeAsStringSync('name: backend_${entry.key.replaceAll('-', '_')}\n');
      Directory.fromUri(component.uri.resolve('lib/')).createSync();
    }
    for (final frontend in _frontends.values) {
      final (plugin, harness) = frontend;
      final component = 'plugins/$plugin/packages/frontend';
      write('$component/pubspec.yaml', '''
name: ${plugin}_frontend
dev_dependencies:
  unrelated_backend: any
''');
      write(
        '$component/lib/${plugin == 'source_editor' || plugin == 'diff_viewer' ? 'main' : '${plugin}_frontend'}.dart',
      );
      write('app/tool/$harness', "import 'compiler.dart';\n");
    }
    write(
      'plugins/command_tools/packages/frontend/lib/command_output_view.dart',
    );
    write('plugins/source_editor/packages/frontend/lib/source_documents.dart');
    for (final plugin in ['chat_strategy', 'command_tools', 'diff_viewer']) {
      final component = 'plugins/$plugin/packages/contract';
      write('$component/pubspec.yaml', 'name: ${plugin}_contract\n');
      write('$component/lib/${plugin}_contract.dart');
    }
    write('packages/shared/pubspec.yaml', 'name: shared\n');
    write('packages/shared/lib/public.dart', '''
export 'default.dart'
  if (dart.library.io) 'io.dart'
  if (dart.library.html) 'web.dart';
part 'public.g.dart';
''');
    write('packages/shared/lib/default.dart', "import '' as self;\n");
    write(
      'packages/shared/lib/io.dart',
      "export 'package:second/leaf.dart';\n",
    );
    write('packages/shared/lib/web.dart');
    write('packages/shared/lib/public.g.dart', "part of 'public.dart';\n");
    write('external package/pubspec.yaml', 'name: second\n');
    write('external package/sources/leaf.dart');
    write('unrelated/pubspec.yaml', 'name: unrelated_backend\n');
    write('unrelated/lib/unrelated.dart');
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final package in ['compiler', 'shared'])
            {
              'name': package,
              'rootUri': '../packages/$package',
              'packageUri': 'lib/',
            },
          {
            'name': 'second',
            'rootUri': Directory(absolute('external package')).uri.toString(),
            'packageUri': 'sources/',
          },
          {
            'name': 'unrelated_backend',
            'rootUri': '../unrelated',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'worker CLI emits only the complete JSON stage map',
    () async {
      final result = await runWorker();
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stderr, isEmpty);
      expect(jsonDecode(result.stdout.toString()), await discover());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real AOT worker matches the in-process collector through the coordinator',
    () async {
      final output = File.fromUri(root.uri.resolve('discovery worker.aot'));
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$packageConfig',
        worker.path,
        '-o',
        output.path,
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout}\n${compilation.stderr}',
      );
      final runtime = File.fromUri(
        File(Platform.resolvedExecutable).parent.uri.resolve(
          Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
        ),
      );
      expect(
        await discoverDesktopBuildInputs(
          repositoryRoot: root,
          dartExecutable: runtime.path,
          snapshot: output,
        ),
        await discover(),
      );
      File(absolute('packages/shared/lib/public.g.dart')).deleteSync();
      await expectLater(
        discoverDesktopBuildInputs(
          repositoryRoot: root,
          dartExecutable: runtime.path,
          snapshot: output,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Missing build input file:'),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'maintained stock graph matches coordinator after bootstrap and generation',
    () async {
      final inputs = discovery.collectDesktopBuildInputs(Directory.current);
      expect(
        await discoverDesktopBuildInputs(
          repositoryRoot: Directory.current,
          dartExecutable: Platform.resolvedExecutable,
        ),
        inputs,
      );
      expect(inputs, hasLength(20));
      for (final entry in inputs.entries) {
        if (entry.key.contains('-frontend-')) {
          expect(
            entry.value.any((file) => file.contains('/packages/backend/')),
            isFalse,
            reason: entry.key,
          );
        }
        if (entry.key != 'openai-compilation') {
          expect(
            entry.value.any(
              (file) => file.contains('/openai/packages/backend/'),
            ),
            isFalse,
            reason: entry.key,
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'returns all 20 stages with sorted existing inputs and discovery identity',
    () async {
      final inputs = await discover();
      expect(
        inputs.keys,
        unorderedEquals([
          for (final name in _backends.keys) '$name-compilation',
          for (final name in _frontends.keys) '$name-frontend-compilation',
        ]),
      );
      for (final files in inputs.values) {
        expect(files, orderedEquals(files.toSet().toList()..sort()));
        expect(
          files.every(
            (file) => File(file).isAbsolute && File(file).existsSync(),
          ),
          isTrue,
        );
        expect(
          files,
          containsAll([
            for (final path in [
              'pubspec.yaml',
              'pubspec.lock',
              '.dart_tool/package_config.json',
              'contract_codegen.yaml',
              'build.yaml',
              'analysis_options.yaml',
              'tools/desktop_build_inputs.dart',
              'tools/desktop_build_inputs_worker.dart',
            ])
              absolute(path),
          ]),
        );
        expect(files.any((path) => path.contains('/unrelated/')), isFalse);
      }
    },
  );

  test(
    'follows AST imports, exports, conditional alternatives and generated parts',
    () async {
      write('plugins/git/packages/backend/lib/unreferenced.dart', """
import 'package:second/leaf.dart'
  if (dart.library.html) 'conditional.dart';
// import 'missing_comment.dart';
const text = '''
import 'missing_string.dart';
export 'missing_export.dart';
part 'missing_part.dart';
''';
""");
      write('plugins/git/packages/backend/lib/conditional.dart');
      final inputs = await discover();
      expect(
        inputs['git-compilation'],
        containsAll([
          for (final path in [
            'plugins/git/packages/backend/lib/unreferenced.dart',
            'plugins/git/packages/backend/lib/conditional.dart',
            'plugins/git/packages/backend/pubspec.yaml',
            'packages/shared/lib/public.dart',
            'packages/shared/lib/public.g.dart',
            'packages/shared/lib/default.dart',
            'packages/shared/lib/io.dart',
            'packages/shared/lib/web.dart',
            'packages/shared/pubspec.yaml',
            'external package/sources/leaf.dart',
            'external package/pubspec.yaml',
          ])
            absolute(path),
        ]),
      );
      expect(
        inputs['openai-compilation'],
        isNot(
          contains(
            absolute('plugins/git/packages/backend/lib/unreferenced.dart'),
          ),
        ),
      );
      expect(
        inputs['git-compilation']!.any((file) => file.contains('/app/')),
        isFalse,
      );
    },
  );

  test(
    'frontend roots include exact compiler and dynamic inputs, not other plugins',
    () async {
      final inputs = await discover();
      for (final entry in _frontends.entries) {
        final files = inputs['${entry.key}-frontend-compilation']!;
        expect(
          files,
          containsAll([
            absolute('app/tool/${entry.value.$2}'),
            absolute('app/tool/compiler.dart'),
            absolute('packages/compiler/lib/native.dart'),
            absolute('packages/compiler/pubspec.yaml'),
            absolute(
              'plugins/${entry.value.$1}/packages/frontend/pubspec.yaml',
            ),
          ]),
        );
        expect(
          files.any((file) => file.contains('/packages/backend/')),
          isFalse,
        );
        for (final other in _frontends.values) {
          if (other.$1 == entry.value.$1) continue;
          expect(
            files.any(
              (file) => file.contains('/${other.$1}/packages/frontend/'),
            ),
            isFalse,
          );
        }
      }
      final commandContract = absolute(
        'plugins/command_tools/packages/contract/lib/command_tools_contract.dart',
      );
      expect(inputs['command-frontend-compilation'], contains(commandContract));
      expect(
        inputs['chat-frontend-compilation'],
        contains(absolute('packages/ui/lib/rich_document_editor_bridge.dart')),
      );
      expect(
        inputs['filesystem-frontend-compilation'],
        isNot(contains(commandContract)),
      );
      expect(
        inputs['openai-frontend-compilation'],
        contains(absolute('packages/ui/lib/model_native_activity_bridge.dart')),
      );
      expect(
        inputs['source-editor-frontend-compilation'],
        containsAll([
          absolute('packages/ui/lib/code_editor_bridge.dart'),
          absolute(
            'plugins/source_editor/packages/frontend/lib/source_documents.dart',
          ),
        ]),
      );
    },
  );

  test(
    'own source and asset additions/removals change only owning stage lists',
    () async {
      final empty = Directory(
        absolute('plugins/git/packages/backend/lib/empty'),
      )..createSync();
      final before = await discover();
      final backend = write('plugins/git/packages/backend/bin/extra.dart');
      final nested = write('${empty.path}/nested/extra.dart');
      final frontend = write('plugins/openai/packages/frontend/lib/extra.dart');
      final asset = write(
        'plugins/openai/packages/frontend/assets/nested/icon.png',
        'PNG',
      );
      final after = await discover();
      for (final stage in before.keys) {
        final additions = switch (stage) {
          'git-compilation' => [backend.path, nested.path],
          'openai-frontend-compilation' => [frontend.path, asset.path],
          _ => <String>[],
        };
        expect(
          after[stage],
          unorderedEquals([...before[stage]!, ...additions]),
        );
      }
      backend.deleteSync();
      empty.deleteSync(recursive: true);
      frontend.deleteSync();
      asset.deleteSync();
      expect(await discover(), before);
    },
  );

  test('rediscovery follows new imports and optional configuration', () async {
    final before = await discover();
    final imported = write('external package/sources/added.dart');
    final config = write('plugins/git/packages/backend/build.yaml', '{}\n');
    write('external package/sources/leaf.dart', "import 'added.dart';\n");
    final after = await discover();
    expect(before['git-compilation'], isNot(contains(imported.path)));
    expect(after['git-compilation'], containsAll([imported.path, config.path]));
    config.deleteSync();
    write('external package/sources/leaf.dart');
    expect(await discover(), before);
  });

  test(
    'includes declared assets and fonts outside the conventional assets tree',
    () async {
      const component = 'plugins/openai/packages/frontend';
      write('$component/pubspec.yaml', '''
name: openai_frontend
flutter:
  assets:
    - pictures/
    - path: data/value.json
  shaders:
    - shaders/effect.frag
  fonts:
    - family: Test
      fonts:
        - asset: fonts/test.ttf
''');
      final paths = [
        for (final name in [
          'pictures/nested/image.png',
          'data/value.json',
          'shaders/effect.frag',
          'fonts/test.ttf',
        ])
          write('$component/$name', 'asset').path,
      ];
      expect(
        (await discover())['openai-frontend-compilation'],
        containsAll(paths),
      );
      File(paths.first).deleteSync();
      // A missing declared file must fail, whereas a removed directory member
      // naturally disappears from the list on the next discovery.
      File(paths.last).deleteSync();
      expect(
        () => discovery.collectDesktopBuildInputs(root),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('fonts/test.ttf'),
          ),
        ),
      );
    },
  );

  for (final broken in <String, void Function()>{
    'generated part': () =>
        File(absolute('packages/shared/lib/public.g.dart')).deleteSync(),
    'conditional export': () =>
        File(absolute('packages/shared/lib/web.dart')).deleteSync(),
    'dynamic bridge': () =>
        File(absolute('packages/ui/lib/inspection_display.dart')).deleteSync(),
    'dynamic entrypoint': () => File(
      absolute('plugins/source_editor/packages/frontend/lib/main.dart'),
    ).deleteSync(),
    'lockfile': () => File(absolute('pubspec.lock')).deleteSync(),
    'unresolved package': () => write(
      'packages/shared/lib/public.dart',
      "import 'package:missing/file.dart';\n",
    ),
    'malformed source': () =>
        write('packages/shared/lib/public.dart', "import 'unfinished"),
    'malformed pubspec': () =>
        write('packages/shared/pubspec.yaml', '[unterminated'),
  }.entries) {
    test('fails discovery for a missing or invalid ${broken.key}', () async {
      broken.value();
      await expectLater(discover(), throwsA(anything));
    });
  }

  test(
    'worker failure emits no partial JSON',
    () async {
      File(absolute('packages/shared/lib/public.g.dart')).deleteSync();
      final result = await runWorker();
      expect(result.exitCode, isNot(0));
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Missing build input file:'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Flutter test configuration follows harness ancestors up to its pubspec',
    () async {
      final config = write(
        'app/flutter_test_config.dart',
        "import 'config_support.dart';\n",
      );
      final support = write('app/config_support.dart');
      final unrelated = write('app/test/flutter_test_config.dart');
      final abovePackage = write('flutter_test_config.dart');
      final inputs = await discover();
      for (final entry in inputs.entries) {
        if (entry.key.contains('-frontend-')) {
          expect(entry.value, containsAll([config.path, support.path]));
        } else {
          expect(entry.value, isNot(contains(config.path)));
        }
        expect(entry.value, isNot(contains(unrelated.path)));
        expect(entry.value, isNot(contains(abovePackage.path)));
      }
    },
  );

  test(
    'SDK-only coordinator validates unique paths once per response, not across discoveries',
    () async {
      final first = absolute('pubspec.yaml');
      final second = absolute('pubspec.lock');
      final calls = absolute('calls.json');
      write('tools/desktop_build_inputs_worker.dart', '''
import 'dart:convert';
import 'dart:io';
void main(List<String> arguments) {
  File(${jsonEncode(calls)}).writeAsStringSync(
    jsonEncode({'arguments': arguments, 'cwd': Directory.current.path}) + '\\n',
    mode: FileMode.append,
  );
  stdout.write(${jsonEncode(jsonEncode({
        'stage': [first, second, first],
        'shared': [first, second],
      }))});
}
''');
      final checks = <String, int>{};
      final files = {
        for (final path in [
          first,
          second,
          absolute('tools/desktop_build_inputs_worker.dart'),
        ])
          path: File(path),
      };
      Future<Map<String, List<String>>> coordinated() => IOOverrides.runZoned(
        () => discoverDesktopBuildInputs(
          repositoryRoot: root,
          dartExecutable: Platform.resolvedExecutable,
        ),
        createFile: (path) => _CountingFile(files[path]!, checks),
      );
      final inputs = await coordinated();
      expect(inputs, {
        'stage': [second, first]..sort(),
        'shared': [second, first]..sort(),
      });
      expect(checks, {first: 1, second: 1});
      final invocations = File(calls).readAsLinesSync();
      expect(invocations, hasLength(1));
      expect(jsonDecode(invocations.single), {
        'arguments': [root.path],
        'cwd': root.path,
      });
      expect(await coordinated(), inputs);
      expect(checks, {first: 2, second: 2});
      File(second).deleteSync();
      await expectLater(coordinated(), throwsStateError);
      expect(checks, {first: 3, second: 3});
      for (final path in [
        'tools/desktop_build_inputs.dart',
        'tools/build_timing.dart',
      ]) {
        final unit = parseString(content: File(path).readAsStringSync()).unit;
        for (final directive
            in unit.directives.whereType<UriBasedDirective>()) {
          final uri = directive.uri.stringValue;
          if (path.endsWith('desktop_build_inputs.dart') &&
              uri == 'build_timing.dart') {
            continue;
          }
          expect(uri, startsWith('dart:'));
        }
      }
    },
  );

  for (final output in [
    'not json',
    '[]',
    '{}',
    '{"stage":[]}',
    '{"stage":[42]}',
    '{"stage":["relative.dart"]}',
    '{"stage":["/missing/build/input.dart"]}',
  ]) {
    test('coordinator rejects invalid worker response $output', () async {
      write('tools/desktop_build_inputs_worker.dart', '''
import 'dart:io';
void main() => stdout.write(${jsonEncode(output)});
''');
      await expectLater(
        discoverDesktopBuildInputs(
          repositoryRoot: root,
          dartExecutable: Platform.resolvedExecutable,
        ),
        throwsStateError,
      );
    });
  }

  test(
    'coordinator surfaces worker failure instead of accepting its JSON',
    () async {
      write('tools/desktop_build_inputs_worker.dart', '''
import 'dart:io';
void main() {
  stderr.write('broken discovery');
  stdout.write(${jsonEncode(jsonEncode({
        'stage': [absolute('pubspec.yaml')],
      }))});
  exitCode = 7;
}
''');
      await expectLater(
        discoverDesktopBuildInputs(
          repositoryRoot: root,
          dartExecutable: Platform.resolvedExecutable,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('broken discovery'),
          ),
        ),
      );
    },
  );
}

class _CountingFile implements File {
  _CountingFile(this.file, this.checks);

  final File file;
  final Map<String, int> checks;

  @override
  String get path => file.path;

  @override
  bool get isAbsolute => file.isAbsolute;

  @override
  Future<bool> exists() {
    checks.update(path, (count) => count + 1, ifAbsent: () => 1);
    return file.exists();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
