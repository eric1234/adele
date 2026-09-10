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
      expect(
        tool.modelDefinition.description,
        contains('stock search defaults'),
      );
      expect(tool.modelDefinition.description, contains('.git'));
      expect(tool.modelDefinition.description, contains('node_modules'));
      expect(tool.modelDefinition.argumentsSchema['required'], const <Object?>[
        'query',
      ]);

      expect(tool.modelDefinition.argumentsSchema, <String, Object?>{
        'type': 'object',
        'required': <Object?>['query'],
        'properties': <String, Object?>{
          'query': <String, Object?>{
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

    test('validates the exact literal query contract', () async {
      final ToolExecutable tool = await _search(_FileSystem());
      for (final Map<String, Object?> invalid in <Map<String, Object?>>[
        const <String, Object?>{},
        const <String, Object?>{'query': ''},
        const <String, Object?>{'query': 'a\nb'},
        const <String, Object?>{'query': 'a\u0000b'},
        <String, Object?>{'query': 'x' * 257},
        const <String, Object?>{'query': 'x', 'unknown': 'forbidden'},
        const <String, Object?>{'query': 'x', 'path': null},
        const <String, Object?>{'query': 'x', 'path': 1},
        const <String, Object?>{'query': 'x', 'path': '/absolute'},
        const <String, Object?>{'query': 'x', 'path': 'a/../b'},
        const <String, Object?>{'query': 'x', 'path': 'a\u0000b'},
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
        const <String, Object?>{'query': r'a.*[literal]', 'path': ''},
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
        expect(
          () => tool.validateAndNormalize(<String, Object?>{
            'query': 'needle',
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
            'query': 'needle',
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
          final CanonicalToolArguments args = tool.validateAndNormalize(
            <String, Object?>{'query': 'needle', 'path': './$scope//./'},
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

    test('excluded segments fail without provider reads', () async {
      for (final String excluded in <String>[
        '.git',
        '.dart_tool',
        'build',
        'node_modules',
      ]) {
        for (final String path in <String>[excluded, 'src/$excluded/nested']) {
          final _FileSystem fs = _FileSystem();
          final ToolOutcome outcome = await _run(fs, 'needle', path: path);
          expect(outcome.disposition, ToolOutcomeDisposition.failure);
          expect(outcome.failureKind, ToolFailureKind.domain);
          expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
          expect(outcome.modelContent, contains('excluded'));
          expect(outcome.hostData['path'], path);
          expect(fs.directoryReads, isEmpty);
          expect(fs.fileReads, isEmpty);
        }
      }
    });

    test(
      'missing and file scopes fail at the directory-read boundary',
      () async {
        for (final String code in <String>['not_found', 'not_a_directory']) {
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
        expect(outcome.hostData['incomplete'], isFalse);
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

Future<ToolOutcome> _run(
  _FileSystem fileSystem,
  String query, {
  String? path,
}) async {
  final ToolExecutable tool = await _search(fileSystem);
  return _execute(
    tool,
    tool.validateAndNormalize(<String, Object?>{'query': query, 'path': ?path}),
    fileSystem.sessionId,
  );
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
