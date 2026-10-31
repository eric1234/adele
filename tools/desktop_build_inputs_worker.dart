// The pinned analyzer has no public directive-only parser. Its scanner/parser
// avoids loading analysis contexts and constructing full ASTs for every input.
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/dart/scanner/reader.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/string_source.dart';
import 'package:yaml/yaml.dart';

// Invoked with the selected SDK only after bootstrap and contract generation.
// Stdout is exclusively the complete JSON result, never a partial discovery.
void main(List<String> arguments) {
  try {
    if (arguments.length != 1) {
      throw ArgumentError('Expected the repository root as the sole argument.');
    }
    stdout.writeln(
      jsonEncode(collectDesktopBuildInputs(Directory(arguments.single))),
    );
  } catch (error) {
    stderr.writeln('Desktop build input discovery failed: $error');
    exitCode = 1;
  }
}

/// Worker implementation, separate from the SDK-only launcher entrypoint.
Map<String, List<String>> collectDesktopBuildInputs(Directory repositoryRoot) =>
    _Discovery(repositoryRoot.absolute).discover();

const _backends = <String, String>{
  'backend-host-compilation':
      'packages/plugin_backend_host/bin/adele_backend_host.dart',
  'git-compilation': 'plugins/git/packages/backend/bin/git_backend.dart',
  'openai-compilation':
      'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
  'agents-md-compilation':
      'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
  'search-tools-compilation':
      'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
  'filesystem-tools-compilation':
      'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
  'command-tools-compilation':
      'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
  'chat-strategy-compilation':
      'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
  'local-directory-project-compilation':
      'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
  'session-evaluator-compilation':
      'plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart',
  'diff-viewer-compilation':
      'plugins/diff_viewer/packages/backend/bin/diff_viewer_backend.dart',
};

// Stock compiler source-map inputs are dynamic File reads, not Dart imports.
// Keep these paired with the corresponding app/tool compiler helpers. Own lib
// trees below include every frontend source, including Source Editor membership.
const _frontends =
    <
      String,
      ({
        String plugin,
        String harness,
        List<String> sources,
        List<String> ui,
        String? contract,
      })
    >{
      'chat': (
        plugin: 'chat_strategy',
        harness: 'compile_chat_frontend.dart',
        sources: ['chat_strategy_frontend.dart'],
        ui: [
          'main_content_bridge.dart',
          'owning_backend_bridge.dart',
          'rich_document_editor_bridge.dart',
          'session_content_inspection_bridge.dart',
          'session_execution_bridge.dart',
          'session_presentation_lifecycle_bridge.dart',
          'inspection_display.dart',
        ],
        contract: 'chat_strategy',
      ),
      'filesystem': (
        plugin: 'filesystem_tools',
        harness: 'compile_tool_inspection_frontends.dart',
        sources: ['filesystem_tools_frontend.dart'],
        ui: ['tool_activity_inspection_bridge.dart', 'inspection_display.dart'],
        contract: null,
      ),
      'command': (
        plugin: 'command_tools',
        harness: 'compile_tool_inspection_frontends.dart',
        sources: ['command_tools_frontend.dart', 'command_output_view.dart'],
        ui: [
          'tool_activity_inspection_bridge.dart',
          'inspection_display.dart',
          'owning_backend_bridge.dart',
          'console_bridge.dart',
          'terminal_projection_bridge.dart',
        ],
        contract: 'command_tools',
      ),
      'openai': (
        plugin: 'openai',
        harness: 'compile_openai_activity_frontend.dart',
        sources: ['openai_frontend.dart'],
        ui: ['model_native_activity_bridge.dart', 'inspection_display.dart'],
        contract: null,
      ),
      'local-directory-project': (
        plugin: 'local_directory_project',
        harness: 'compile_local_directory_project_frontend.dart',
        sources: ['local_directory_project_frontend.dart'],
        ui: ['directory_picker_bridge.dart'],
        contract: null,
      ),
      'task-browser': (
        plugin: 'task_browser',
        harness: 'compile_task_browser_frontend.dart',
        sources: ['task_browser_frontend.dart'],
        ui: ['task_browser_bridge.dart'],
        contract: null,
      ),
      'terminal': (
        plugin: 'terminal',
        harness: 'compile_terminal_frontend.dart',
        sources: ['terminal_frontend.dart'],
        ui: [
          'environment_terminal_bridge.dart',
          'terminal_surface_bridge.dart',
        ],
        contract: null,
      ),
      'source-editor': (
        plugin: 'source_editor',
        harness: 'compile_source_editor_frontend.dart',
        sources: ['main.dart', 'source_documents.dart'],
        ui: [
          'main_content_bridge.dart',
          'code_editor_bridge.dart',
          'contribution_bridge.dart',
          'environment_access_bridge.dart',
        ],
        contract: null,
      ),
      'diff-viewer': (
        plugin: 'diff_viewer',
        harness: 'compile_diff_viewer_frontend.dart',
        sources: ['main.dart'],
        ui: [
          'environment_capability_bridge.dart',
          'main_content_bridge.dart',
          'owning_backend_bridge.dart',
          'session_presentation_lifecycle_bridge.dart',
          'session_feedback_bridge.dart',
        ],
        contract: 'diff_viewer',
      ),
    };

class _Discovery {
  _Discovery(this.root) {
    final config = _requiredFile(
      root.uri.resolve('.dart_tool/package_config.json'),
    );
    final Object? decoded = jsonDecode(config.readAsStringSync());
    if (decoded is! Map<String, dynamic> ||
        decoded['configVersion'] != 2 ||
        decoded['packages'] is! List) {
      throw FormatException('Invalid package configuration: ${config.path}');
    }
    for (final Object? entry in decoded['packages'] as List) {
      if (entry is! Map<String, dynamic> ||
          entry['name'] is! String ||
          entry['rootUri'] is! String ||
          (entry['packageUri'] != null && entry['packageUri'] is! String)) {
        throw FormatException('Invalid package entry in ${config.path}');
      }
      final name = entry['name'] as String;
      final packageRoot = config.uri.resolve(entry['rootUri'] as String);
      final packageUri = Uri.parse(entry['packageUri'] as String? ?? '');
      if (name.isEmpty ||
          packages.containsKey(name) ||
          packageRoot.scheme != 'file' ||
          packageRoot.hasQuery ||
          packageRoot.hasFragment ||
          packageUri.isAbsolute ||
          packageUri.hasAuthority ||
          packageUri.hasQuery ||
          packageUri.hasFragment ||
          packageUri.path.startsWith('/')) {
        throw FormatException('Invalid package location for $name');
      }
      packages[name] = Directory.fromUri(
        packageRoot,
      ).uri.resolveUri(packageUri);
    }
  }

  final Directory root;
  final packages = <String, Uri>{};
  final _imports = <String, List<File>>{};
  final _owners = <String, Directory>{};
  final _packageInputs = <String, List<File>>{};

  Map<String, List<String>> discover() {
    final common = [
      for (final path in [
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
        'contract_codegen.yaml',
        'tools/desktop_build_inputs.dart',
        'tools/desktop_build_inputs_worker.dart',
      ])
        _requiredFile(root.uri.resolve(path)),
      ..._configuration(root),
    ];
    final result = <String, List<String>>{};
    for (final backend in _backends.entries) {
      final entrypoint = _requiredFile(root.uri.resolve(backend.value));
      final component = entrypoint.parent.parent;
      result[backend.key] = _collect([
        entrypoint,
        ..._tree(Directory.fromUri(component.uri.resolve('bin/'))),
        ..._tree(Directory.fromUri(component.uri.resolve('lib/'))),
      ], common);
    }
    for (final frontend in _frontends.entries) {
      final spec = frontend.value;
      final harness = _requiredFile(
        root.uri.resolve('app/tool/${spec.harness}'),
      );
      final component = Directory.fromUri(
        root.uri.resolve('plugins/${spec.plugin}/packages/frontend/'),
      );
      result['${frontend.key}-frontend-compilation'] = _collect(
        [
          harness,
          ..._testConfiguration(harness),
          for (final source in spec.sources)
            _requiredFile(component.uri.resolve('lib/$source')),
          ..._tree(Directory.fromUri(component.uri.resolve('lib/'))),
          for (final bridge in spec.ui)
            _requiredFile(root.uri.resolve('packages/ui/lib/$bridge')),
          if (spec.contract case final contract?)
            _requiredFile(
              root.uri.resolve(
                'plugins/$contract/packages/contract/lib/${contract}_contract.dart',
              ),
            ),
        ],
        [
          ...common,
          ..._tree(
            Directory.fromUri(component.uri.resolve('assets/')),
            optional: true,
          ),
        ],
      );
    }
    return result;
  }

  List<String> _collect(List<File> sources, List<File> identity) {
    final inputs = <String>{for (final file in identity) file.path};
    final visited = <String>{};
    final pending = [...sources];
    while (pending.isNotEmpty) {
      final source = pending.removeLast();
      if (!visited.add(source.path)) continue;
      inputs.add(source.path);
      inputs.addAll(_ownerInputs(source).map((file) => file.path));
      if (source.path.endsWith('.dart')) {
        pending.addAll(
          _imports.putIfAbsent(source.path, () {
            final content = source.readAsStringSync();
            final stringSource = StringSource(content, source.path);
            final diagnostics = RecordingDiagnosticListener();
            final features = FeatureSet.latestLanguageVersion();
            final scanner =
                Scanner(stringSource, CharSequenceReader(content), diagnostics)
                  ..configureFeatures(
                    featureSetForOverriding: features,
                    featureSet: features,
                  );
            final token = scanner.tokenize();
            final parsed = Parser(
              stringSource,
              diagnostics,
              featureSet: scanner.featureSet,
              languageVersion: LibraryLanguageVersion(
                package: ExperimentStatus.currentVersion,
                override: scanner.overrideVersion,
              ),
              lineInfo: LineInfo(scanner.lineStarts),
            ).parseDirectives(token);
            if (diagnostics.diagnostics.isNotEmpty) {
              throw FormatException(
                'Invalid build input directives in ${source.path}: '
                '${diagnostics.diagnostics.join('; ')}',
              );
            }
            final dependencies = <File>[];
            for (final directive in parsed.directives) {
              final uris = <StringLiteral>[
                if (directive is UriBasedDirective) directive.uri,
                if (directive is PartOfDirective && directive.uri != null)
                  directive.uri!,
                if (directive is NamespaceDirective)
                  for (final configuration in directive.configurations)
                    configuration.uri,
              ];
              for (final literal in uris) {
                final value = literal.stringValue;
                if (value == null) {
                  throw FormatException('Invalid directive in ${source.path}');
                }
                final uri = Uri.parse(value);
                if (uri.scheme == 'dart') {
                  continue; // Toolchain identity is separate.
                }
                dependencies.add(_requiredFile(_resolve(uri, source)));
              }
            }
            return dependencies;
          }),
        );
      }
    }
    return inputs.toList()..sort();
  }

  Uri _resolve(Uri uri, File source) {
    if (uri.hasQuery || uri.hasFragment) {
      throw FormatException('Unsupported input URI $uri in ${source.path}');
    }
    if (uri.scheme == 'package') {
      final segments = uri.pathSegments;
      final base = segments.isEmpty ? null : packages[segments.first];
      if (base == null ||
          segments.length < 2 ||
          segments.any((segment) => segment == '..' || segment.isEmpty)) {
        throw StateError('Unresolved package input $uri in ${source.path}');
      }
      return base.resolve(uri.path.substring(uri.path.indexOf('/') + 1));
    }
    final resolved = source.uri.resolveUri(uri);
    if (resolved.scheme != 'file') {
      throw StateError('Unsupported input URI $uri in ${source.path}');
    }
    return resolved;
  }

  List<File> _ownerInputs(File source) {
    final owner = _owner(source.parent);
    return _packageInputs.putIfAbsent(owner.path, () {
      final pubspec = _requiredFile(owner.uri.resolve('pubspec.yaml'));
      final Object? yaml = loadYaml(pubspec.readAsStringSync());
      if (yaml is! YamlMap) {
        throw FormatException('Invalid pubspec: ${pubspec.path}');
      }
      final inputs = [pubspec, ..._configuration(owner)];
      // Include authored assets, including declarations outside assets/. Do not
      // follow pubspec dependency lists: dev dependencies include other plugins.
      final Object? flutter = yaml['flutter'];
      if (flutter != null) {
        if (flutter is! YamlMap) {
          throw FormatException(
            'Invalid Flutter configuration: ${pubspec.path}',
          );
        }
        void asset(Object? value) {
          final Object? path = value is YamlMap ? value['path'] : value;
          if (path is! String || path.isEmpty) {
            throw FormatException('Invalid asset in ${pubspec.path}: $value');
          }
          final uri = owner.uri.resolve(path);
          if (Directory.fromUri(uri).existsSync()) {
            inputs.addAll(_tree(Directory.fromUri(uri)));
          } else {
            inputs.add(_requiredFile(uri));
          }
        }

        for (final key in ['assets', 'shaders']) {
          final Object? values = flutter[key];
          if (values == null) continue;
          if (values is! YamlList) {
            throw FormatException('Invalid $key in ${pubspec.path}');
          }
          values.forEach(asset);
        }
        final Object? fonts = flutter['fonts'];
        if (fonts != null) {
          if (fonts is! YamlList) {
            throw FormatException('Invalid fonts in ${pubspec.path}');
          }
          for (final Object? family in fonts) {
            if (family is! YamlMap || family['fonts'] is! YamlList) {
              throw FormatException('Invalid font family in ${pubspec.path}');
            }
            for (final Object? font in family['fonts'] as YamlList) {
              if (font is! YamlMap) {
                throw FormatException('Invalid font in ${pubspec.path}');
              }
              asset(font['asset']);
            }
          }
        }
      }
      return inputs;
    });
  }

  Directory _owner(Directory directory) {
    return _owners.putIfAbsent(directory.path, () {
      if (File.fromUri(directory.uri.resolve('pubspec.yaml')).existsSync()) {
        return directory;
      }
      if (directory.parent.path == directory.path) {
        throw StateError('No owning pubspec for ${directory.path}');
      }
      return _owner(directory.parent);
    });
  }

  List<File> _configuration(Directory directory) => [
    for (final name in [
      'pubspec.lock',
      'pubspec_overrides.yaml',
      'build.yaml',
      'analysis_options.yaml',
      'dart_test.yaml',
    ])
      if (FileSystemEntity.typeSync(
            directory.uri.resolve(name).toFilePath(),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound)
        _requiredFile(directory.uri.resolve(name)),
  ];

  List<File> _testConfiguration(File harness) {
    var directory = harness.parent;
    while (directory.path != directory.parent.path) {
      final config = directory.uri.resolve('flutter_test_config.dart');
      if (FileSystemEntity.typeSync(config.toFilePath(), followLinks: false) !=
          FileSystemEntityType.notFound) {
        return [_requiredFile(config)];
      }
      if (File.fromUri(directory.uri.resolve('pubspec.yaml')).existsSync()) {
        break;
      }
      directory = directory.parent;
    }
    return [];
  }

  File _requiredFile(Uri uri) {
    final file = File.fromUri(uri.normalizePath()).absolute;
    if (!file.existsSync()) {
      throw StateError('Missing build input file: ${file.path}');
    }
    return file;
  }

  List<File> _tree(
    Directory directory, {
    bool optional = false,
    Set<String> ancestors = const {},
  }) {
    if (optional &&
        FileSystemEntity.typeSync(directory.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
      return [];
    }
    if (!directory.existsSync()) {
      throw StateError('Missing build input directory: ${directory.path}');
    }
    final realPath = directory.resolveSymbolicLinksSync();
    if (ancestors.contains(realPath)) {
      throw StateError('Cyclic build input directory: ${directory.path}');
    }
    final files = <File>[];
    for (final entry in directory.listSync(followLinks: false)) {
      final type = FileSystemEntity.typeSync(entry.path);
      if (type == FileSystemEntityType.file) {
        files.add(_requiredFile(entry.uri));
      } else if (type == FileSystemEntityType.directory) {
        files.addAll(
          _tree(Directory(entry.path), ancestors: {...ancestors, realPath}),
        );
      } else {
        throw StateError('Unreadable build input: ${entry.path}');
      }
    }
    return files;
  }
}
