import 'dart:async';
import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  _globTests();
  group('activation and contract', () {
    test(
      'unbound executable shares metadata and validation, not authority',
      () async {
        const SearchExecutable unbound = SearchExecutable.unbound();
        final ToolRegistration bound = SearchExecutable(
          _FileSystem(),
        ).registration;
        expect(unbound.registration.definition.id, bound.definition.id);
        expect(
          unbound.registration.modelDefinition.argumentsSchema,
          bound.modelDefinition.argumentsSchema,
        );
        final CanonicalToolArguments arguments = unbound.validateAndNormalize({
          'pattern': 'needle',
          'path': './src//./',
        });
        expect(arguments.snapshot, {'pattern': 'needle', 'path': 'src'});
        expect(unbound.validateBinding, throwsStateError);
        await expectLater(
          unbound.describe(arguments, _execution(SessionId('session-1'))),
          throwsStateError,
        );
        await expectLater(
          unbound.execute(arguments, _execution(SessionId('session-1'))),
          emitsError(isStateError),
        );
      },
    );

    test('contributes Search and Glob in deterministic order', () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionRegistration generationA = const SearchToolsPlugin()
          .activate(extensions);
      final ExtensionBinding<ModelToolContribution> bindingA = extensions
          .discover(modelToolContributions)
          .single;
      final tools = (await bindingA.value.materialize(
        _Context(_FileSystem()),
      )).toList();
      expect(tools.map((tool) => tool.modelDefinition.alias), [
        'search',
        'glob',
      ]);
      expect(tools.last.definition.id, globToolId);
      final ToolRegistration tool = tools.first;

      expect(tool.definition.id.value, 'dev.adele.plugin.search-tools.search');
      expect(tool.modelDefinition.alias, 'search');
      expect(
        tool.modelDefinition.description,
        contains('stock search defaults'),
      );
      expect(
        tool.modelDefinition.description,
        contains('file or directory scope'),
      );
      expect(
        tool.modelDefinition.description,
        contains('case-sensitive regular-expression'),
      );
      expect(tool.modelDefinition.description, contains('.git'));
      expect(tool.modelDefinition.description, contains('node_modules'));
      expect(
        tool.modelDefinition.description,
        contains('case-insensitively on every Environment'),
      );
      expect(
        tool.modelDefinition.description,
        allOf(
          contains('narrowest useful known'),
          contains('Dart dart:core RegExp'),
          contains('truncation/incompleteness'),
        ),
      );
      expect(tool.modelDefinition.argumentsSchema['required'], const <Object?>[
        'pattern',
      ]);

      expect(tool.modelDefinition.argumentsSchema, <String, Object?>{
        'type': 'object',
        'required': <Object?>['pattern'],
        'properties': <String, Object?>{
          'pattern': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 256,
          },
          'path': <String, Object?>{'type': 'string'},
        },
        'additionalProperties': false,
      });
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

    test(
      'validates the exact regex pattern contract without authority',
      () async {
        const ToolExecutable tool = SearchExecutable.unbound();
        for (final Map<String, Object?> invalid in <Map<String, Object?>>[
          const <String, Object?>{},
          const <String, Object?>{'pattern': ''},
          const <String, Object?>{'query': 'needle'},
          const <String, Object?>{'pattern': 'needle', 'query': 'needle'},
          for (final pattern in [
            '[',
            '(',
            '*',
            r'\',
            'a\rb',
            'a\u2028b',
            'a\u2029b',
          ])
            <String, Object?>{'pattern': pattern},
          const <String, Object?>{'pattern': 'a\nb'},
          const <String, Object?>{'pattern': 'a\u0000b'},
          <String, Object?>{'pattern': 'x' * 257},
          const <String, Object?>{'pattern': 'x', 'unknown': 'forbidden'},
          const <String, Object?>{'pattern': 'x', 'path': null},
          const <String, Object?>{'pattern': 'x', 'path': 1},
          const <String, Object?>{'pattern': 'x', 'path': '/absolute'},
          const <String, Object?>{'pattern': 'x', 'path': 'a/../b'},
          const <String, Object?>{'pattern': 'x', 'path': 'a\u0000b'},
        ]) {
          await expectLater(
            () => tool.validateAndNormalize(invalid),
            throwsA(isA<ToolArgumentValidationException>()),
          );
        }
        expect(
          (await tool.validateAndNormalize(const <String, Object?>{
            'pattern': r'a.*[literal]',
          })).snapshot,
          const <String, Object?>{'pattern': r'a.*[literal]', 'path': ''},
        );
      },
    );

    test('describes a source read against the Environment root', () async {
      final _FileSystem fileSystem = _FileSystem();
      final ToolExecutable tool = await _search(fileSystem);
      final CanonicalToolArguments arguments = await _arguments(tool, 'needle');
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

  group('directory scope', () {
    test('rejects unpaired surrogates during argument validation', () async {
      final _FileSystem fs = _FileSystem();
      final ToolExecutable tool = await _search(fs);
      for (final String path in <String>[
        'bad\uD800name',
        'bad\uDC00name',
        'bad\uD800',
        '\uDC00',
        '\uD800\uD800',
        '\uDC00\uD800',
        './bad\uD800/./',
      ]) {
        // Validation itself must reject, without describe/execute or encoding.
        await expectLater(
          () => tool.validateAndNormalize(<String, Object?>{
            'pattern': 'needle',
            'path': path,
          }),
          throwsA(isA<ToolArgumentValidationException>()),
        );
      }
      expect(fs.directoryReads, isEmpty);
      expect(fs.fileReads, isEmpty);
    });

    test('omitted and empty scopes both read root', () async {
      for (final String? path in <String?>[null, '']) {
        final _FileSystem fs = _FileSystem();
        final ToolExecutable tool = await _search(fs);
        final ToolOutcome outcome = await _execute(
          tool,
          tool.validateAndNormalize(<String, Object?>{
            'pattern': 'needle',
            'path': ?path,
          }),
          fs.sessionId,
        );
        expect(outcome.hostData['path'], '');
        expect(fs.directoryReads, <String>['']);
      }
    });

    test(
      'canonical subtree identity preserves Unicode and backslashes',
      () async {
        for (final String scope in <String>[
          'src',
          r'odd\name',
          'café_日本語',
          'paired-\uD83D\uDE00',
          'bad\uFFFDname',
        ]) {
          final _FileSystem fs = _FileSystem(
            directories: <String, List<EnvironmentDirectoryEntry>>{
              scope: <EnvironmentDirectoryEntry>[
                _file('$scope/a.txt'),
                _directory('nested', '$scope/nested'),
                for (final String excluded in <String>[
                  '.git',
                  '.dart_tool',
                  'build',
                  'node_modules',
                ])
                  _directory(excluded, '$scope/$excluded'),
              ],
              '$scope/nested': <EnvironmentDirectoryEntry>[
                _file('$scope/nested/b.txt'),
              ],
            },
            files: <String, String>{
              '$scope/a.txt': 'needle',
              '$scope/nested/b.txt': 'Needle\nneedle',
            },
          );
          final ToolExecutable tool = await _search(fs);
          final CanonicalToolArguments args = await tool.validateAndNormalize(
            <String, Object?>{'pattern': 'needle', 'path': './$scope//./'},
          );
          expect(args.snapshot['path'], scope);
          final EffectDescription effect = await tool.describe(
            args,
            _execution(fs.sessionId),
          );
          expect(effect.effects, <ToolEffect>{ToolEffect.sourceRead});
          expect(effect.targets.single.uri.pathSegments, <String>[
            'environment-1',
            scope,
          ]);
          expect(effect.summary, contains(jsonEncode(scope)));
          final ToolOutcome outcome = await _execute(tool, args, fs.sessionId);
          expect(outcome.hostData['path'], scope);
          expect(outcome.modelContent, contains('Scope: ${jsonEncode(scope)}'));
          expect(_matchLocations(outcome), <String>[
            '$scope/a.txt:1',
            '$scope/nested/b.txt:2',
          ]);
          expect(fs.directoryReads, <String>[scope, '$scope/nested']);
          expect(fs.fileReads, <String>['$scope/a.txt', '$scope/nested/b.txt']);
          expect(outcome.hostData['incomplete'], false);
        }
      },
    );

    test('all resource budgets remain bounded within a scope', () async {
      final List<_FileSystem> fixtures = <_FileSystem>[
        _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            'src': <EnvironmentDirectoryEntry>[_file('src/many.txt')],
          },
          files: <String, String>{
            'src/many.txt': List.filled(101, '${'x' * 600}hit').join('\n'),
          },
        ),
        _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            'src': <EnvironmentDirectoryEntry>[
              for (int i = 0; i < 10001; i++)
                EnvironmentDirectoryEntry(
                  name: '$i',
                  relativePath: 'src/$i',
                  kind: EnvironmentDirectoryEntryKind.other,
                ),
            ],
          },
        ),
        _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            'src': <EnvironmentDirectoryEntry>[_file('src/a'), _file('src/b')],
          },
          files: <String, String>{'src/a': 'hit', 'src/b': 'hit'},
          sizes: <String, int>{'src/a': 16 * 1024 * 1024, 'src/b': 1},
        ),
        _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            'src': <EnvironmentDirectoryEntry>[
              for (int i = 0; i < 33; i++) _file('src/$i'),
            ],
          },
          fileErrors: <String, Object>{
            for (int i = 0; i < 33; i++) 'src/$i': _environmentFailure,
          },
        ),
      ];
      final List<ToolOutcome> outcomes = <ToolOutcome>[];
      for (final _FileSystem fs in fixtures) {
        final ToolOutcome outcome = await _run(fs, 'hit', path: 'src');
        outcomes.add(outcome);
        expect(outcome.disposition, ToolOutcomeDisposition.success);
        expect(outcome.hostData['path'], 'src');
        expect(outcome.hostData['truncated'], true);
        expect(fs.directoryReads, <String>['src']);
      }
      const List<String> reasons = <String>[
        'max_matches',
        'max_entries',
        'max_searched_bytes',
        'max_failed_file_reads',
      ];
      const List<int> limits = <int>[100, 10000, 16 * 1024 * 1024, 32];
      for (int i = 0; i < outcomes.length; i++) {
        expect(outcomes[i].hostData['stopReason'], reasons[i]);
        expect(outcomes[i].hostData['stopLimit'], limits[i]);
        expect(
          outcomes[i].modelContent,
          contains('${reasons[i]} limit (${limits[i]})'),
        );
      }
      expect(outcomes[1].hostData['entriesVisited'], 10000);
      expect(outcomes[2].hostData['searchedBytes'], 16 * 1024 * 1024);
      expect(outcomes[3].hostData['failedFileReads'], 32);
      final List<Object?> matches =
          outcomes[0].hostData['matches']! as List<Object?>;
      expect(matches, hasLength(100));
      for (final Object? match in matches) {
        expect(
          ((match! as Map<String, Object?>)['snippet']! as String).length,
          lessThanOrEqualTo(500),
        );
      }
      expect(_matchLocations(outcomes[2]), <String>['src/a:1']);
      expect(fixtures[3].fileReads, hasLength(32));
      expect(outcomes[3].hostData['incomplete'], true);
    });

    test('excluded segments ignore case without provider reads', () async {
      for (final String excluded in <String>[
        '.git',
        '.dart_tool',
        'build',
        'node_modules',
        '.GIT',
        '.Git',
        '.DART_TOOL',
        '.Dart_Tool',
        'BUILD',
        'Build',
        'NODE_MODULES',
        'Node_Modules',
      ]) {
        for (final String path in <String>[
          excluded,
          'src/$excluded/nested',
          'src/$excluded/file.txt',
        ]) {
          final _FileSystem fs = _FileSystem();
          final ToolOutcome outcome = await _run(fs, 'needle', path: path);
          expect(outcome.disposition, ToolOutcomeDisposition.failure);
          expect(outcome.failureKind, ToolFailureKind.domain);
          expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
          expect(outcome.hostDiagnostic, 'excluded_scope');
          expect(outcome.modelContent, contains('excluded'));
          expect(outcome.hostData['path'], path);
          expect(fs.directoryReads, isEmpty);
          expect(fs.fileReads, isEmpty);
        }
      }
    });

    test(
      'missing and denied scopes fail at the directory-read boundary',
      () async {
        for (final String code in <String>[
          'not_found',
          'denied',
          'unreadable',
        ]) {
          final _FileSystem fs = _FileSystem(
            directoryErrors: <String, Object>{
              'scope': EnvironmentFailure(
                code: code,
                message: code,
                details: const <String, Object?>{},
              ),
            },
          );
          final ToolOutcome outcome = await _run(fs, 'needle', path: 'scope');
          expect(outcome.failureKind, ToolFailureKind.domain);
          expect(outcome.effectCertainty, EffectCertainty.uncertain);
          expect(outcome.hostData['code'], code);
          expect(outcome.hostData['path'], 'scope');
          expect(fs.directoryReads, <String>['scope']);
          expect(fs.fileReads, isEmpty);
        }
      },
    );

    test(
      'file scope normalizes identity and supports escaped metacharacters',
      () async {
        final _FileSystem fs = _FileSystem(
          files: <String, String>{
            'src/café.txt': 'A.*[x]\na.*[x] twice a.*[x]\naZZ[x]',
            'other.txt': 'a.*[x]',
          },
        );
        final ToolExecutable tool = await _search(fs);
        final CanonicalToolArguments args = await tool.validateAndNormalize(
          <String, Object?>{
            'pattern': r'a\.\*\[x\]',
            'path': './src//café.txt',
          },
        );
        final EffectDescription effect = await tool.describe(
          args,
          _execution(fs.sessionId),
        );
        expect(effect.effects, <ToolEffect>{ToolEffect.sourceRead});
        expect(effect.targets.single.uri.pathSegments, <String>[
          'environment-1',
          'src',
          'café.txt',
        ]);
        final ToolOutcome outcome = await _execute(tool, args, fs.sessionId);
        expect(_matchLocations(outcome), <String>['src/café.txt:2']);
        expect(fs.directoryReads, <String>['src/café.txt']);
        expect(fs.fileReads, <String>['src/café.txt']);
        expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
        expect(outcome.hostData['stopReason'], isNull);
        expect(outcome.hostData['incomplete'], false);
      },
    );

    test(
      'explicit file read failures remain failures rather than skipped success',
      () async {
        for (final String code in <String>[
          'not_found',
          'not_regular_file',
          'invalid_utf8',
          'file_too_large',
          'denied',
        ]) {
          final _FileSystem fs = _FileSystem(
            directoryErrors: <String, Object>{
              'scope': const EnvironmentFailure(
                code: 'not_directory',
                message: 'kind mismatch',
                details: <String, Object?>{},
              ),
            },
            fileErrors: <String, Object>{
              'scope': EnvironmentFailure(
                code: code,
                message: code,
                details: const <String, Object?>{},
              ),
            },
          );
          final ToolOutcome outcome = await _run(fs, 'needle', path: 'scope');
          expect(outcome.failureKind, ToolFailureKind.domain);
          expect(outcome.hostData['code'], code);
          expect(fs.fileReads, <String>['scope']);
        }
      },
    );

    test(
      'scope infrastructure and stale errors never trigger file probing',
      () async {
        for (final Object error in <Object>[
          StateError('transport failed'),
          const AuthorizedEnvironmentBindingUnavailable('unavailable'),
          const AuthorizedEnvironmentBindingStale('stale'),
        ]) {
          final _FileSystem fs = _FileSystem(
            directoryErrors: <String, Object>{'scope': error},
          );
          final ToolOutcome outcome = await _run(fs, 'needle', path: 'scope');
          expect(outcome.disposition, ToolOutcomeDisposition.failure);
          expect(fs.fileReads, isEmpty);
        }
      },
    );

    test('file scope uses the same match budget', () async {
      final _FileSystem fs = _FileSystem(
        files: <String, String>{'many.txt': List.filled(101, 'hit').join('\n')},
      );
      final ToolOutcome outcome = await _run(fs, 'hit', path: 'many.txt');
      expect(outcome.hostData['truncated'], true);
      expect(outcome.hostData['stopReason'], 'max_matches');
      expect(outcome.hostData['matches'], hasLength(100));
    });

    test('scoped binding failures retain no-read certainty', () async {
      for (final bool stale in <bool>[true, false]) {
        final _FileSystem fs = _FileSystem()
          ..stale = stale
          ..available = stale;
        final ToolOutcome outcome = await _run(fs, 'needle', path: 'src');
        expect(
          outcome.failureKind,
          stale ? ToolFailureKind.staleBinding : ToolFailureKind.infrastructure,
        );
        expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
        expect(fs.directoryReads, isEmpty);
      }
    });
  });

  group('search algorithm', () {
    test('exclusions ignore case on every Environment, not patterns', () async {
      const List<String> excludedNames = <String>[
        '.GIT',
        '.DART_TOOL',
        'BUILD',
        'Build',
        'NODE_MODULES',
      ];
      for (final String scope in <String>['', 'Src']) {
        final String prefix = scope.isEmpty ? '' : '$scope/';
        final List<String> parents = <String>[prefix, '${prefix}nested/'];
        final _FileSystem fs = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            for (final String parent in parents)
              (parent == prefix
                  ? scope
                  : '${prefix}nested'): <EnvironmentDirectoryEntry>[
                for (final String name in excludedNames)
                  _directory(name, '$parent$name'),
                _file('${parent}visible.txt'),
                if (parent == prefix) _directory('nested', '${prefix}nested'),
              ],
            for (final String parent in parents)
              for (final String name in excludedNames)
                '$parent$name': <EnvironmentDirectoryEntry>[
                  _file('$parent$name/hidden.txt'),
                ],
          },
          files: <String, String>{
            for (final String parent in parents)
              '${parent}visible.txt': 'Needle\nneedle\nNEEDLE',
            for (final String parent in parents)
              for (final String name in excludedNames)
                '$parent$name/hidden.txt': 'needle',
          },
        );

        final ToolOutcome outcome = await _run(fs, 'needle', path: scope);
        expect(outcome.disposition, ToolOutcomeDisposition.success);
        expect(_matchLocations(outcome), <String>[
          '${prefix}nested/visible.txt:2',
          '${prefix}visible.txt:2',
        ]);
        expect(fs.directoryReads, <String>[scope, '${prefix}nested']);
        expect(fs.fileReads, <String>[
          '${prefix}nested/visible.txt',
          '${prefix}visible.txt',
        ]);
        expect(outcome.hostData['path'], scope);
        expect(outcome.hostData['pattern'], 'needle');
        expect(outcome.hostData['incomplete'], false);
        expect(outcome.hostData['truncated'], false);
      }
    });

    test(
      'recurses lexically, searches regex, and reports once per line',
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
          'b.txt:1',
          'b.txt:2',
          'z/c.txt:1',
        ]);
        expect(fileSystem.directoryReads, <String>['', 'z']);
        expect(fileSystem.fileReads, <String>['a.txt', 'b.txt', 'z/c.txt']);
        expect(outcome.hostData['pattern'], r'a.*[x]');
        expect(outcome.hostData['environmentId'], 'environment-1');
        expect(outcome.hostData['truncated'], isFalse);
        expect(outcome.hostData['incomplete'], isFalse);
      },
    );

    test(
      'regex syntax is case-sensitive and independently line-oriented',
      () async {
        final fs = _FileSystem(
          files: {'source.txt': 'foo\nbar42 bar7\nFoo\na.*[x]\n\nfoobar\nend'},
        );
        for (final entry in <String, List<int>>{
          'foo': [1, 6],
          r'foo|bar\d+': [1, 2, 6],
          r'^bar[0-9]+ bar[0-9]+$': [2],
          r'^foo$': [1],
          r'a\.\*\[x\]': [4],
          r'foo\nbar': [],
          r'^$': [5],
          r'(?=bar)': [2, 6],
          r'^': [1, 2, 3, 4, 5, 6, 7],
        }.entries) {
          final outcome = await _run(fs, entry.key, path: 'source.txt');
          expect(_matchLocations(outcome), [
            for (final line in entry.value) 'source.txt:$line',
          ], reason: entry.key);
        }
      },
    );

    test('first regex match span positions the bounded snippet', () async {
      final fs = _FileSystem(
        files: {'source.txt': '${'x' * 600}abc123${'y' * 600}abc456'},
      );
      final outcome = await _run(fs, r'abc\d+', path: 'source.txt');
      final match = (outcome.hostData['matches']! as List).single as Map;
      expect(match['snippet'], '${'x' * 247}abc123${'y' * 247}');
    });

    test(
      'oversized and zero-length regex spans stay bounded and Unicode-safe',
      () async {
        for (final entry in <String, String>{
          r'(?:😀)+': '😀' * 250,
          r'(?=😀)': '${'x' * 250}${'😀' * 125}',
          r'\uDE00.*': '😀' * 249,
        }.entries) {
          final fs = _FileSystem(
            files: {'source.txt': '${'x' * 601}${'😀' * 600}tail'},
          );
          final outcome = await _run(fs, entry.key, path: 'source.txt');
          final match = (outcome.hostData['matches']! as List).single as Map;
          final snippet = match['snippet'] as String;
          expect(snippet.length, lessThanOrEqualTo(500));
          expect(snippet, entry.value, reason: entry.key);
          expect(utf8.decode(utf8.encode(snippet)), snippet);
        }
      },
    );

    test('encodes unusual model-visible paths as one JSON record', () async {
      const String relativePath =
          'odd\ncarriage\rseparator\u2028paragraph\u2029"\\source.dart';
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[_file(relativePath)],
        },
        files: <String, String>{
          relativePath: r'needle with "quotes" and a \ backslash',
        },
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      final Map<String, Object?> hostMatch =
          (outcome.hostData['matches']! as List<Object?>).single!
              as Map<String, Object?>;
      final List<String> modelLines = outcome.modelContent.split('\n');
      final String encodedMatch = modelLines.singleWhere(
        (String line) => line.startsWith('{'),
      );
      final Map<String, Object?> decodedMatch =
          jsonDecode(encodedMatch) as Map<String, Object?>;

      expect(hostMatch['relativePath'], relativePath);
      expect(modelLines, hasLength(2));
      expect(encodedMatch, isNot(contains('\r')));
      expect(encodedMatch, isNot(contains('\u2028')));
      expect(encodedMatch, isNot(contains('\u2029')));
      expect(decodedMatch['relativePath'], relativePath);
      expect(
        decodedMatch['snippet'],
        r'needle with "quotes" and a \ backslash',
      );
    });

    test(
      'discloses intentional exclusions without marking incomplete',
      () async {
        final List<EnvironmentDirectoryEntry> root =
            <EnvironmentDirectoryEntry>[
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
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': root,
            for (final String name in <String>[
              '.git',
              '.dart_tool',
              'build',
              'node_modules',
            ])
              name: <EnvironmentDirectoryEntry>[_file('$name/hidden.txt')],
          },
          files: <String, String>{
            'visible.txt': 'haystack',
            for (final String name in <String>[
              '.git',
              '.dart_tool',
              'build',
              'node_modules',
            ])
              '$name/hidden.txt': 'needle',
          },
        );

        final ToolOutcome outcome = await _run(fileSystem, 'needle');
        expect(outcome.hostData['matches'], isEmpty);
        expect(fileSystem.directoryReads, <String>['']);
        expect(fileSystem.fileReads, <String>['visible.txt']);
        expect(outcome.hostData['incomplete'], isFalse);
        expect(outcome.hostData['truncated'], isFalse);
        expect(outcome.modelContent, contains('Scope note:'));
        expect(outcome.modelContent, contains('stock search defaults'));
      },
    );

    test(
      'marks nested failure incomplete and searches unaffected siblings',
      () async {
        final _FileSystem fileSystem = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[
              _directory('broken', 'broken'),
              _file('good.txt'),
            ],
          },
          files: <String, String>{'good.txt': 'needle'},
          directoryErrors: <String, Object>{'broken': _environmentFailure},
        );

        final ToolOutcome outcome = await _run(fileSystem, 'needle');
        expect(outcome.disposition, ToolOutcomeDisposition.success);
        expect(_matchLocations(outcome), <String>['good.txt:1']);
        expect(fileSystem.fileReads, <String>['good.txt']);
        expect(outcome.hostData['failedDirectoryReads'], 1);
        expect(outcome.hostData['failedFileReads'], 0);
        expect(outcome.hostData['stopReason'], isNull);
        expect(outcome.modelContent, contains('1 failed directory reads'));
        expect(outcome.modelContent, contains('Traversal completed'));
        expect(outcome.hostData['incomplete'], isTrue);
        expect(outcome.hostData['truncated'], isFalse);
        expect(outcome.modelContent, contains('files or directories'));
      },
    );

    test('marks a failed-only file search incomplete', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[_file('hidden.txt')],
        },
        fileErrors: <String, Object>{'hidden.txt': _environmentFailure},
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(fileSystem.fileReads, <String>['hidden.txt']);
      expect(outcome.hostData['matches'], isEmpty);
      expect(outcome.hostData['incomplete'], isTrue);
      expect(outcome.hostData['truncated'], isFalse);
      expect(outcome.modelContent, contains('No matches.'));
      expect(outcome.modelContent, contains('files or directories'));
      expect(outcome.modelContent, isNot('Search results:\nNo matches.'));
    });

    test('failed file does not stop unaffected sibling files', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[
            _file('broken.txt'),
            _file('good.txt'),
          ],
        },
        files: <String, String>{'good.txt': 'needle'},
        fileErrors: <String, Object>{'broken.txt': _environmentFailure},
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(fileSystem.fileReads, <String>['broken.txt', 'good.txt']);
      expect(_matchLocations(outcome), <String>['good.txt:1']);
      expect(outcome.hostData['incomplete'], isTrue);
      expect(outcome.hostData['truncated'], isFalse);
      expect(outcome.modelContent, contains('files or directories'));
    });

    test('exactly 32 failed file reads do not imply truncation', () async {
      final List<String> paths = <String>[
        for (int index = 0; index < 32; index++)
          'failed-${index.toString().padLeft(2, '0')}.txt',
      ];
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[
            for (final String path in paths) _file(path),
          ],
        },
        fileErrors: <String, Object>{
          for (final String path in paths) path: _environmentFailure,
        },
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(fileSystem.fileReads, paths);
      expect(outcome.hostData['failedFileReads'], 32);
      expect(outcome.hostData['failedDirectoryReads'], 0);
      expect(outcome.hostData['stopReason'], isNull);
      expect(outcome.modelContent, contains('32 failed file reads'));
      expect(outcome.modelContent, contains('Traversal completed'));
      expect(outcome.hostData['incomplete'], isTrue);
      expect(outcome.hostData['truncated'], isFalse);
    });

    test('failed file read limit prevents a 33rd attempt', () async {
      final List<String> failedPaths = <String>[
        for (int index = 0; index < 32; index++)
          'failed-${index.toString().padLeft(2, '0')}.txt',
      ];
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[
            for (final String path in failedPaths) _file(path),
            _file('z-next.txt'),
          ],
        },
        files: <String, String>{'z-next.txt': 'needle'},
        fileErrors: <String, Object>{
          for (final String path in failedPaths) path: _environmentFailure,
        },
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(fileSystem.fileReads, failedPaths);
      expect(outcome.hostData['matches'], isEmpty);
      expect(outcome.hostData['incomplete'], isTrue);
      expect(outcome.hostData['truncated'], isTrue);
      expect(outcome.modelContent, contains('Search truncated:'));
    });

    test(
      'does not report a skipped-only search as exhaustively empty',
      () async {
        final _FileSystem fileSystem = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[
              _directory('unavailable', 'unavailable'),
            ],
          },
          directoryErrors: <String, Object>{'unavailable': _environmentFailure},
        );

        final ToolOutcome outcome = await _run(fileSystem, 'needle');
        expect(outcome.disposition, ToolOutcomeDisposition.success);
        expect(outcome.hostData['matches'], isEmpty);
        expect(outcome.hostData['incomplete'], isTrue);
        expect(outcome.hostData['truncated'], isFalse);
        expect(outcome.modelContent, contains('No matches.'));
        expect(outcome.modelContent, contains('Search incomplete:'));
        expect(outcome.modelContent, isNot('Search results:\nNo matches.'));
      },
    );

    test('reports no matches predictably', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[_file('source.txt')],
        },
        files: <String, String>{'source.txt': 'haystack'},
      );

      final ToolOutcome outcome = await _run(fileSystem, 'needle');
      expect(outcome.modelContent, startsWith('Search results:\nNo matches.'));
      expect(outcome.modelContent, contains('Scope note:'));
      expect(outcome.hostData['matches'], isEmpty);
      expect(outcome.hostData['truncated'], isFalse);
      expect(outcome.hostData['incomplete'], isFalse);
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

    test(
      'exactly 100 matches remain complete and later files are read',
      () async {
        final _FileSystem fileSystem = _FileSystem(
          directories: <String, List<EnvironmentDirectoryEntry>>{
            '': <EnvironmentDirectoryEntry>[
              _file('a-many.txt'),
              _file('z-later.txt'),
            ],
          },
          files: <String, String>{
            'a-many.txt': List.filled(100, 'hit').join('\n'),
            'z-later.txt': 'no additional match',
          },
        );
        final ToolOutcome outcome = await _run(fileSystem, 'hit');

        expect((outcome.hostData['matches']! as List<Object?>), hasLength(100));
        expect(fileSystem.fileReads, <String>['a-many.txt', 'z-later.txt']);
        expect(outcome.hostData['truncated'], isFalse);
        expect(outcome.hostData['incomplete'], isFalse);
        expect(outcome.modelContent, isNot(contains('Search truncated:')));
      },
    );

    test('the 101st match proves the result is truncated', () async {
      final _FileSystem fileSystem = _FileSystem(
        directories: <String, List<EnvironmentDirectoryEntry>>{
          '': <EnvironmentDirectoryEntry>[_file('many.txt')],
        },
        files: <String, String>{'many.txt': List.filled(101, 'hit').join('\n')},
      );
      final ToolOutcome outcome = await _run(fileSystem, 'hit');

      expect((outcome.hostData['matches']! as List<Object?>), hasLength(100));
      expect(_matchLocations(outcome).first, 'many.txt:1');
      expect(_matchLocations(outcome).last, 'many.txt:100');
      expect(outcome.hostData['truncated'], isTrue);
      expect(outcome.hostData['incomplete'], isFalse);
      expect(outcome.modelContent, contains('Search truncated:'));
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

void _globTests() {
  Future<ToolOutcome> run(
    _FileSystem fs,
    String pattern, {
    SessionId? session,
  }) {
    final tool = GlobExecutable(fs);
    return _execute(
      tool,
      tool.validateAndNormalize({'pattern': pattern}),
      session ?? fs.sessionId,
    );
  }

  List<String> paths(ToolOutcome outcome) => [
    for (final match in outcome.hostData['matches']! as List)
      (match as Map)['relativePath'] as String,
  ];
  test('Glob discloses and preserves pinned **/ zero-depth behavior', () async {
    final fs = _FileSystem(
      directories: {
        '': [_file('foo.dart'), _directory('src', 'src')],
        'src': [_file('src/nested.dart')],
      },
    );
    final description =
        const GlobExecutable.unbound().registration.modelDefinition.description;
    expect(description, contains('** recurses'));
    expect(description, contains('**/ requires a directory level'));
    expect(description, contains('**/*.dart omits root-level Dart files'));
    expect(description, contains('{*.dart,**/*.dart}'));
    expect(paths(await run(fs, '**/*.dart')), ['src/nested.dart']);
    expect(paths(await run(fs, '{*.dart,**/*.dart}')), [
      'foo.dart',
      'src/nested.dart',
    ]);
    expect(fs.fileReads, isEmpty);
  });
  test(
    'Glob success certainty distinguishes skipped and completed reads',
    () async {
      final fs = _FileSystem();
      for (final pattern in [
        'build/**',
        '.GiT/**',
        '.dart_tool/*',
        'node_modules/*',
        'src/BUILD/**',
      ]) {
        final result = await run(fs, pattern);
        expect(result.disposition, ToolOutcomeDisposition.success);
        expect(paths(result), isEmpty);
        expect(result.effectCertainty, EffectCertainty.knownNotOccurred);
      }
      expect(fs.directoryReads, isEmpty);
      final result = await run(fs, '*');
      expect(result.disposition, ToolOutcomeDisposition.success);
      expect(paths(result), isEmpty);
      expect(result.effectCertainty, EffectCertainty.knownOccurred);
      expect(fs.directoryReads, ['']);
      expect(fs.fileReads, isEmpty);
    },
  );
  test(
    'Glob validates before reads, with no extra arguments or malformed patterns',
    () {
      final fs = _FileSystem();
      final tool = GlobExecutable(fs);
      for (final args in <Map<String, Object?>>[
        {},
        {'pattern': 1},
        {'pattern': '*', 'path': ''},
        for (final pattern in [
          '',
          'x' * 513,
          'a\u0000b',
          'bad\ud800',
          'bad\udfff',
          '[',
          '{a,b',
          '{,src/}*.dart',
          '{/,}',
          '/abs',
          '../x',
          'x/../y',
          r'C:\foo',
        ])
          {'pattern': pattern},
      ]) {
        expect(
          () => tool.validateAndNormalize(args),
          throwsA(isA<ToolArgumentValidationException>()),
          reason: '$args',
        );
      }
      expect(fs.directoryReads, isEmpty);
      expect(fs.fileReads, isEmpty);
    },
  );
  test(
    'Glob POSIX matching, kinds, recursion, lexical order and shallow reads',
    () async {
      final fs = _FileSystem(
        directories: {
          '': [
            _directory('xyz', 'xyz'),
            _file('Z'),
            _file('a'),
            const EnvironmentDirectoryEntry(
              name: 'other',
              relativePath: 'other',
              kind: EnvironmentDirectoryEntryKind.other,
            ),
            _directory('plugins', 'plugins'),
          ],
          'xyz': [
            _directory('nested', 'xyz/nested'),
            _file('xyz/a_test.rb'),
            _file('xyz/A_TEST.RB'),
          ],
          'xyz/nested': [_file('xyz/nested/b_test.rb')],
          'plugins': [_directory('one', 'plugins/one')],
          'plugins/one': [_file('plugins/one/pubspec.yaml')],
          'other': [_file('other/hidden')],
        },
      );
      final immediate = await run(fs, '*');
      expect(paths(immediate), ['Z', 'a', 'other', 'plugins', 'xyz']);
      expect(
        (immediate.hostData['matches'] as List).map((m) => (m as Map)['kind']),
        ['file', 'file', 'other', 'directory', 'directory'],
      );
      expect(fs.directoryReads, ['']);
      fs.directoryReads.clear();
      expect(paths(await run(fs, 'xyz/*')), [
        'xyz/A_TEST.RB',
        'xyz/a_test.rb',
        'xyz/nested',
      ]);
      expect(fs.directoryReads, contains('xyz'));
      expect(fs.directoryReads, isNot(contains('xyz/nested')));
      expect(fs.directoryReads, isNot(contains('plugins')));
      fs.directoryReads.clear();
      // package:glob treats the slash after ** as required.
      expect(paths(await run(fs, 'xyz/**/*_test.rb')), [
        'xyz/nested/b_test.rb',
      ]);
      expect(fs.directoryReads, containsAll(['xyz', 'xyz/nested']));
      expect(fs.directoryReads, isNot(contains('plugins')));
      expect(paths(await run(fs, 'xyz/*_test.rb')), ['xyz/a_test.rb']);
      expect(paths(await run(fs, 'plugins/*/pubspec.yaml')), [
        'plugins/one/pubspec.yaml',
      ]);
      final recursive = paths(await run(fs, '**'));
      expect(
        recursive,
        containsAll(['xyz', 'xyz/nested', 'xyz/nested/b_test.rb', 'other']),
      );
      expect(fs.directoryReads, isNot(contains('other')));
      expect(recursive, isNot(contains('other/hidden')));
      expect(fs.fileReads, isEmpty);
      expect(paths(await run(fs, 'xyz\\\\*')), isEmpty);
    },
  );
  for (final kind in [
    EnvironmentDirectoryEntryKind.file,
    EnvironmentDirectoryEntryKind.other,
  ]) {
    test('Glob never traverses ${kind.name} in a literal prefix', () async {
      final fs = _FileSystem(
        directories: {
          '': [
            EnvironmentDirectoryEntry(
              name: 'alias',
              relativePath: 'alias',
              kind: kind,
            ),
            _directory('scope', 'scope'),
            _directory('unrelated', 'unrelated'),
          ],
          'scope': [
            EnvironmentDirectoryEntry(
              name: 'alias',
              relativePath: 'scope/alias',
              kind: kind,
            ),
          ],
          for (final prefix in ['alias', 'scope/alias']) ...{
            prefix: [_directory('nested', '$prefix/nested')],
            '$prefix/nested': [_file('$prefix/nested/hidden')],
          },
        },
      );
      for (final prefix in ['alias', 'scope/alias']) {
        // The provider can resolve this path; its entry kind must stop Glob.
        expect((await fs.readDirectory(prefix)).entries, isNotEmpty);
        fs.directoryReads.clear();
        for (final pattern in ['$prefix/*', '$prefix/**', '$prefix/nested/*']) {
          final result = await run(fs, pattern);
          expect(result.disposition, ToolOutcomeDisposition.success);
          expect(paths(result), isEmpty, reason: pattern);
          expect(result.hostData['truncated'], false);
          expect(result.hostData['incomplete'], false);
        }
        expect(fs.directoryReads, isNot(contains(prefix)));
        expect(fs.directoryReads, isNot(contains('$prefix/nested')));
        expect(fs.directoryReads, isNot(contains('unrelated')));
      }
      expect(fs.fileReads, isEmpty);
    });
  }
  test(
    'Glob stops at absent literal-prefix components without broadening',
    () async {
      final fs = _FileSystem(
        directories: {
          '': [
            _directory('scope', 'scope'),
            _directory('unrelated', 'unrelated'),
          ],
          'scope': [],
          'missing': [_file('missing/hidden')],
          'scope/missing': [_file('scope/missing/hidden')],
        },
      );
      for (final pattern in ['missing/*', 'scope/missing/*']) {
        final result = await run(fs, pattern);
        expect(result.disposition, ToolOutcomeDisposition.success);
        expect(paths(result), isEmpty);
        expect(result.hostData['incomplete'], false);
      }
      expect(fs.directoryReads, isNot(contains('missing')));
      expect(fs.directoryReads, isNot(contains('scope/missing')));
      expect(fs.directoryReads, isNot(contains('unrelated')));
      expect(fs.fileReads, isEmpty);
    },
  );
  test(
    'Glob hides stock excluded directories and descendants case insensitively',
    () async {
      final fs = _FileSystem(
        directories: {
          '': [
            for (final name in ['.GiT', '.DART_TOOL', 'BuIlD', 'NODE_MODULES'])
              _directory(name, name),
          ],
        },
      );
      for (final pattern in ['*', '**', 'BuIlD/**']) {
        final result = await run(fs, pattern);
        expect(paths(result), isEmpty);
        expect(result.hostData['truncated'], false);
        expect(result.modelContent, contains('stock directory exclusions'));
      }
      expect(fs.directoryReads, ['', '']);
    },
  );
  test(
    'Glob bounds matches and visited entries with explicit diagnostics',
    () async {
      final matches = await run(
        _FileSystem(
          directories: {
            '': [for (var i = 0; i < 101; i++) _file('f$i')],
          },
        ),
        '*',
      );
      expect(paths(matches), hasLength(100));
      expect(matches.hostData, containsPair('stopReason', 'max_matches'));
      expect(matches.hostData, containsPair('stopLimit', 100));
      expect(matches.hostData, containsPair('entriesVisited', 101));
      final entries = await run(
        _FileSystem(
          directories: {
            '': [for (var i = 0; i < 10001; i++) _file('f$i')],
          },
        ),
        'missing',
      );
      expect(entries.hostData, containsPair('stopReason', 'max_entries'));
      expect(entries.hostData, containsPair('stopLimit', 10000));
      expect(entries.hostData, containsPair('entriesVisited', 10000));
      expect(entries.hostData, containsPair('truncated', true));
      final scopedEntries = await run(
        _FileSystem(
          directories: {
            '': [_directory('scope', 'scope')],
            'scope': [for (var i = 0; i < 10000; i++) _file('scope/f$i')],
          },
        ),
        'scope/missing',
      );
      expect(scopedEntries.hostData, containsPair('stopReason', 'max_entries'));
      expect(scopedEntries.hostData, containsPair('entriesVisited', 10000));
      expect(scopedEntries.hostData, containsPair('retainedMatchCount', 0));
    },
  );
  test(
    'Glob nested failure is incomplete but required root failure never broadens',
    () async {
      final fs = _FileSystem(
        directories: {
          '': [_directory('bad', 'bad'), _file('ok')],
        },
        directoryErrors: {'bad': _environmentFailure},
      );
      final partial = await run(fs, '**');
      expect(partial.disposition, ToolOutcomeDisposition.success);
      expect(partial.effectCertainty, EffectCertainty.knownOccurred);
      expect(partial.hostData, containsPair('incomplete', true));
      expect(partial.hostData, containsPair('failedDirectoryReads', 1));
      expect(partial.modelContent, contains('could not be inspected'));
      for (final pattern in ['bad/*', 'bad/deeper/*']) {
        fs.directoryReads.clear();
        final failed = await run(fs, pattern);
        expect(failed.failureKind, ToolFailureKind.domain);
        expect(failed.effectCertainty, EffectCertainty.uncertain);
        expect(fs.directoryReads, contains('bad'));
        expect(failed.hostData['failedDirectoryReads'], 0);
      }
      final rootFailure = await run(
        _FileSystem(directoryErrors: {'': _environmentFailure}),
        'bad/*',
      );
      expect(rootFailure.failureKind, ToolFailureKind.domain);
      expect(rootFailure.effectCertainty, EffectCertainty.uncertain);
    },
  );
  test(
    'Glob preserves binding failures, Session authority and read-free description',
    () async {
      final fs = _FileSystem();
      final tool = GlobExecutable(fs);
      final args = tool.validateAndNormalize({'pattern': '**'});
      expect((await tool.describe(args, _execution(fs.sessionId))).effects, {
        ToolEffect.sourceRead,
      });
      expect(fs.directoryReads, isEmpty);
      final wrongSession = await run(fs, '*', session: SessionId('other'));
      expect(wrongSession.failureKind, ToolFailureKind.infrastructure);
      expect(wrongSession.effectCertainty, EffectCertainty.knownNotOccurred);
      fs.stale = true;
      expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
      final stale = await run(fs, '*');
      expect(stale.failureKind, ToolFailureKind.staleBinding);
      expect(stale.effectCertainty, EffectCertainty.knownNotOccurred);
      fs.stale = false;
      fs.available = false;
      expect(
        tool.validateBinding,
        throwsA(isA<ToolBindingUnavailableException>()),
      );
      final unavailable = await run(fs, '*');
      expect(unavailable.failureKind, ToolFailureKind.infrastructure);
      expect(unavailable.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(fs.directoryReads, isEmpty);
      expect(fs.fileReads, isEmpty);
    },
  );
  for (final (failure, kind, readDependent) in [
    (
      const AuthorizedEnvironmentBindingStale('stale generation'),
      ToolFailureKind.staleBinding,
      true,
    ),
    (
      const AuthorizedEnvironmentBindingUnavailable('unavailable'),
      ToolFailureKind.infrastructure,
      true,
    ),
    (StateError('read failed'), ToolFailureKind.infrastructure, false),
  ]) {
    for (final failedPath in ['', 'nested']) {
      test(
        'Glob ${failure.runtimeType} certainty after failing read "$failedPath"',
        () async {
          final fs = _FileSystem(
            directories: {
              '': [_directory('nested', 'nested')],
            },
            directoryErrors: {failedPath: failure},
          );
          final result = await run(fs, '**');
          expect(result.disposition, ToolOutcomeDisposition.failure);
          expect(result.failureKind, kind);
          expect(
            result.effectCertainty,
            !readDependent
                ? EffectCertainty.uncertain
                : failedPath.isEmpty
                ? EffectCertainty.knownNotOccurred
                : EffectCertainty.knownOccurred,
          );
          expect(fs.directoryReads, ['', if (failedPath.isNotEmpty) 'nested']);
          expect(fs.fileReads, isEmpty);
        },
      );
    }
  }
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
      .first
      .executable;
}

FutureOr<CanonicalToolArguments> _arguments(
  ToolExecutable tool,
  String pattern,
) => tool.validateAndNormalize(<String, Object?>{'pattern': pattern});

ToolExecutionContext _execution(SessionId sessionId) => ToolExecutionContext(
  runId: RunId('run-1'),
  sessionId: sessionId,
  toolInvocationId: 'search-invocation',
);

Future<ToolOutcome> _run(
  _FileSystem fileSystem,
  String pattern, {
  String? path,
}) async {
  final ToolExecutable tool = await _search(fileSystem);
  return _execute(
    tool,
    tool.validateAndNormalize(<String, Object?>{
      'pattern': pattern,
      'path': ?path,
    }),
    fileSystem.sessionId,
  );
}

Future<ToolOutcome> _execute(
  ToolExecutable tool,
  FutureOr<CanonicalToolArguments> arguments,
  SessionId sessionId,
) async =>
    (await tool.execute(await arguments, _execution(sessionId)).single
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
  Future<T> requireHostService<T extends Object>() async {
    if (T == AuthorizedEnvironmentFileReadFacet) return fileSystem as T;
    throw StateError('Unsupported Search host service $T.');
  }
}

final class _FileSystem implements AuthorizedEnvironmentFileReadFacet {
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
    if (files.containsKey(relativePath)) {
      throw const EnvironmentFailure(
        code: 'not_directory',
        message: 'Not a directory.',
        details: <String, Object?>{},
      );
    }
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
      revision: 'fixture-revision',
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
