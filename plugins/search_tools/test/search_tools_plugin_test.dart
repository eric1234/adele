import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  group('activation and contract', () {
    test('contributes one independently bound search tool', () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionRegistration generationA = const SearchToolsPlugin()
          .activate(extensions);
      final ExtensionBinding<ModelToolContribution> bindingA = extensions
          .discover(modelToolContributions)
          .single;
      final ToolRegistration tool = (await bindingA.value.materialize(
        _Context(_FileSystem()),
      )).single;

      expect(tool.definition.id.value, 'dev.adele.plugin.search-tools.search');
      expect(tool.modelDefinition.alias, 'search');
      expect(tool.modelDefinition.argumentsSchema['required'], const <Object?>[
        'query',
      ]);

      await generationA.close();
      final ExtensionRegistration generationB = const SearchToolsPlugin()
          .activate(extensions);
      final ExtensionBinding<ModelToolContribution> bindingB = extensions
          .discover(modelToolContributions)
          .single;
      expect(() => bindingA.value, throwsA(isA<StaleExtensionBinding>()));
      expect(bindingB.value, isA<ModelToolContribution>());
      await generationB.close();
    });

    test('validates the exact literal query contract', () async {
      final ToolExecutable tool = await _search(_FileSystem());
      for (final Map<String, Object?> invalid in <Map<String, Object?>>[
        const <String, Object?>{},
        const <String, Object?>{'query': ''},
        const <String, Object?>{'query': 'a\nb'},
        const <String, Object?>{'query': 'a\u0000b'},
        <String, Object?>{'query': 'x' * 257},
        const <String, Object?>{'query': 'x', 'path': 'forbidden'},
      ]) {
        expect(
          () => tool.validateAndNormalize(invalid),
          throwsA(isA<ToolArgumentValidationException>()),
        );
      }
      expect(
        tool.validateAndNormalize(const <String, Object?>{
          'query': r'a.*[literal]',
        }).snapshot,
        const <String, Object?>{'query': r'a.*[literal]'},
      );
    });

    test('describes a source read against the Environment root', () async {
      final _FileSystem fileSystem = _FileSystem();
      final ToolExecutable tool = await _search(fileSystem);
      final CanonicalToolArguments arguments = _arguments(tool, 'needle');
      final EffectDescription description = await tool.describe(
        arguments,
        _execution(fileSystem.sessionId),
      );

      expect(description.effects, <ToolEffect>{ToolEffect.sourceRead});
      expect(
        description.targets.single.uri.toString(),
        'adele-environment:/environment-1/',
      );
      await expectLater(
        tool.describe(arguments, _execution(SessionId('other-session'))),
        throwsA(isA<Exception>()),
      );
      expect(
        (await _execute(
          tool,
          arguments,
          SessionId('other-session'),
        )).failureKind,
        ToolFailureKind.infrastructure,
      );
    });
  });

  group('search algorithm', () {
    test(
      'recurses lexically, searches literally, and reports once per line',
      () async {
        final _FileSystem fileSystem = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[
              _directory('z', 'z'),
              _file('b.txt'),
              _file('a.txt'),
            ],
            'z': <EnvironmentDirectoryEntry>[_file('z/c.txt')],
          },
          files: <String, String>{
            'a.txt': 'a.*[x] and a.*[x]\nnone',
            'b.txt': 'aZZ[x]\na.*[x]',
            'z/c.txt': 'a.*[x]',
          },
        );

        final ToolOutcome outcome = await _run(fileSystem, r'a.*[x]');
        expect(outcome.disposition, ToolOutcomeDisposition.success);
        expect(_matchLocations(outcome), <String>[
          'a.txt:1',
          'b.txt:2',
          'z/c.txt:1',
        ]);
        expect(fileSystem.directoryReads, <String>['', 'z']);
        expect(fileSystem.fileReads, <String>['a.txt', 'b.txt', 'z/c.txt']);
        expect(outcome.hostData['query'], r'a.*[x]');
        expect(outcome.hostData['environmentId'], 'environment-1');
        expect(outcome.hostData['truncated'], isFalse);
      },
    );

    test('excludes named directories and ignores other entry kinds', () async {
      final List<EnvironmentDirectoryEntry> root = <EnvironmentDirectoryEntry>[
        for (final String name in <String>[
          '.git',
          '.dart_tool',
          'build',
          'node_modules',
        ])
          _directory(name, name),
        const EnvironmentDirectoryEntry(
          name: 'link',
          relativePath: 'link',
          kind: EnvironmentDirectoryEntryKind.other,
        ),
        _file('visible.txt'),
      ];
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{'': root},
        files: <String, String>{'visible.txt': 'needle'},
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(_matchLocations(outcome), <String>['visible.txt:1']);
      expect(fileSystem.directoryReads, <String>['']);
    });

    test('skips per-file and nested-directory domain failures', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[
            _directory('broken', 'broken'),
            _file('broken.txt'),
            _file('good.txt'),
          ],
        },
        files: <String, String>{'good.txt': 'needle'},
        directoryErrors: <String, Object>{'broken': _environmentFailure},
        fileErrors: <String, Object>{'broken.txt': _environmentFailure},
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(_matchLocations(outcome), <String>['good.txt:1']);
    });

    test('reports no matches predictably', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[_file('source.txt')],
        },
        files: <String, String>{'source.txt': 'haystack'},
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(outcome.modelContent, 'Search results:\nNo matches.');
      expect(outcome.hostData['matches'], isEmpty);
      expect(outcome.hostData['truncated'], isFalse);
    });

    test('root directory domain failure fails the search', () async {
      final _FileSystem fileSystem = _FileSystem(
        directoryErrors: <String, Object>{'': _environmentFailure},
      );
      final ToolOutcome outcome = await _run(fileSystem, 'needle');

      expect(outcome.disposition, ToolOutcomeDisposition.failure);
      expect(outcome.failureKind, ToolFailureKind.domain);
      expect(outcome.hostData['code'], 'denied');
    });

    test(
      'binding failures abort from nested directory and file reads',
      () async {
        final _FileSystem nestedStale = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[_directory('nested', 'nested')],
          },
          directoryErrors: <String, Object>{
            'nested': const AuthorizedEnvironmentBindingStale('old generation'),
          },
        );
        expect(
          (await _run(nestedStale, 'needle')).failureKind,
          ToolFailureKind.staleBinding,
        );
        expect(
          (await _run(nestedStale, 'needle')).effectCertainty,
          EffectCertainty.knownOccurred,
        );

        final _FileSystem fileUnavailable = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[_file('source.txt')],
          },
          fileErrors: <String, Object>{
            'source.txt': const AuthorizedEnvironmentBindingUnavailable('down'),
          },
        );
        expect(
          (await _run(fileUnavailable, 'needle')).failureKind,
          ToolFailureKind.infrastructure,
        );
      },
    );

    test('limits matches to 100 and marks the result truncated', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[_file('many.txt')],
        },
        files: <String, String>{'many.txt': List.filled(101, 'hit').join('\n')},
      );
      final ToolOutcome outcome = await _run(fileSystem, 'hit');

      expect((outcome.hostData['matches']! as List<Object?>), hasLength(100));
      expect(outcome.hostData['truncated'], isTrue);
    });

    test('limits traversed entries to 10000', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[
            for (int index = 0; index < 10001; index++)
              EnvironmentDirectoryEntry(
                name: 'other-${index.toString().padLeft(5, '0')}',
                relativePath: 'other-${index.toString().padLeft(5, '0')}',
                kind: EnvironmentDirectoryEntryKind.other,
              ),
          ],
        },
      );
      final ToolOutcome outcome = await _run(fileSystem, 'hit');

      expect(outcome.hostData['matches'], isEmpty);
      expect(outcome.hostData['truncated'], isTrue);
    });

    test(
      'limits searched bytes to 16 MiB and keeps accumulated matches',
      () async {
        final _FileSystem fileSystem = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[_file('a.txt'), _file('b.txt')],
          },
          files: <String, String>{'a.txt': 'hit', 'b.txt': 'hit'},
          sizes: <String, int>{'a.txt': 16 * 1024 * 1024, 'b.txt': 1},
        );
        final ToolOutcome outcome = await _run(fileSystem, 'hit');

        expect(_matchLocations(outcome), <String>['a.txt:1']);
        expect(outcome.hostData['truncated'], isTrue);
      },
    );

    test(
      'bounds snippets around matches without splitting surrogate pairs',
      () async {
        final String startBoundaryLine =
            '${'x' * 152}\u{1f600}${'x' * 246}needle${'x' * 300}';
        final String endBoundaryLine =
            '${'x' * 100}needle${'x' * 393}\u{1f600}${'x' * 100}';
        final _FileSystem fileSystem = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[
              _file('end-boundary.txt'),
              _file('start-boundary.txt'),
            ],
          },
          files: <String, String>{
            'end-boundary.txt': endBoundaryLine,
            'start-boundary.txt': startBoundaryLine,
          },
        );
        final ToolOutcome outcome = await _run(fileSystem, 'needle');
        final List<String> snippets = <String>[
          for (final Object? value
              in outcome.hostData['matches']! as List<Object?>)
            (value! as Map<String, Object?>)['snippet']! as String,
        ];

        expect(snippets, hasLength(2));
        for (final String snippet in snippets) {
          expect(snippet.length, 499);
          expect(snippet, contains('needle'));
          expect(
            snippet.codeUnitAt(0),
            isNot(inInclusiveRange(0xdc00, 0xdfff)),
          );
          expect(
            snippet.codeUnitAt(snippet.length - 1),
            isNot(inInclusiveRange(0xd800, 0xdbff)),
          );
        }
      },
    );
  });
}

const EnvironmentFailure _environmentFailure = EnvironmentFailure(
  code: 'denied',
  message: 'Denied.',
  details: <String, Object?>{},
);

EnvironmentDirectoryEntry _file(String path) => EnvironmentDirectoryEntry(
  name: path.split('/').last,
  relativePath: path,
  kind: EnvironmentDirectoryEntryKind.file,
);

EnvironmentDirectoryEntry _directory(String name, String path) =>
    EnvironmentDirectoryEntry(
      name: name,
      relativePath: path,
      kind: EnvironmentDirectoryEntryKind.directory,
    );

Future<ToolExecutable> _search(_FileSystem fileSystem) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  const SearchToolsPlugin().activate(extensions);
  return (await extensions
          .discover(modelToolContributions)
          .single
          .value
          .materialize(_Context(fileSystem)))
      .single
      .executable;
}

CanonicalToolArguments _arguments(ToolExecutable tool, String query) =>
    tool.validateAndNormalize(<String, Object?>{'query': query});

ToolExecutionContext _execution(SessionId sessionId) =>
    ToolExecutionContext(runId: RunId('run-1'), sessionId: sessionId);

Future<ToolOutcome> _run(_FileSystem fileSystem, String query) async {
  final ToolExecutable tool = await _search(fileSystem);
  return _execute(tool, _arguments(tool, query), fileSystem.sessionId);
}

Future<ToolOutcome> _execute(
  ToolExecutable tool,
  CanonicalToolArguments arguments,
  SessionId sessionId,
) async =>
    (await tool.execute(arguments, _execution(sessionId)).single
            as ToolExecutionTerminal)
        .outcome;

List<String> _matchLocations(ToolOutcome outcome) => <String>[
  for (final Object? value in outcome.hostData['matches']! as List<Object?>)
    _matchLocation(value! as Map<String, Object?>),
];

String _matchLocation(Map<String, Object?> match) =>
    '${match['relativePath']}:${match['lineNumber']}';

final class _Context implements ModelToolHostContext {
  const _Context(this.fileSystem);

  final _FileSystem fileSystem;

  @override
  SessionId get sessionId => fileSystem.sessionId;

  @override
  Future<T> requireHostService<T extends Object>() async => fileSystem as T;
}

final class _FileSystem implements AuthorizedEnvironmentFileSystem {
  _FileSystem({
    Map<String, List<EnvironmentDirectoryEntry>>? directories,
    Map<String, String>? files,
    Map<String, int>? sizes,
    Map<String, Object>? directoryErrors,
    Map<String, Object>? fileErrors,
  }) : directories =
           directories ??
           <String, List<EnvironmentDirectoryEntry>>{
             '': <EnvironmentDirectoryEntry>[],
           },
       files = files ?? <String, String>{},
       sizes = sizes ?? <String, int>{},
       directoryErrors = directoryErrors ?? <String, Object>{},
       fileErrors = fileErrors ?? <String, Object>{};

  final Map<String, List<EnvironmentDirectoryEntry>> directories;
  final Map<String, String> files;
  final Map<String, int> sizes;
  final Map<String, Object> directoryErrors;
  final Map<String, Object> fileErrors;
  final List<String> directoryReads = <String>[];
  final List<String> fileReads = <String>[];
  bool stale = false;
  bool available = true;

  @override
  final SessionId sessionId = SessionId('session-1');

  @override
  final EnvironmentId environmentId = EnvironmentId('environment-1');

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    validateBinding();
    directoryReads.add(relativePath);
    if (directoryErrors[relativePath] case final Object error) throw error;
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: directories[relativePath] ?? <EnvironmentDirectoryEntry>[],
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    validateBinding();
    fileReads.add(relativePath);
    if (fileErrors[relativePath] case final Object error) throw error;
    final String text = files[relativePath] ?? '';
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: sizes[relativePath] ?? utf8.encode(text).length,
    );
  }

  @override
  void validateBinding() {
    if (stale) {
      throw const AuthorizedEnvironmentBindingStale('stale generation');
    }
    if (!available) {
      throw const AuthorizedEnvironmentBindingUnavailable('unavailable');
    }
  }
}
