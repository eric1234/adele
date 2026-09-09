import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'activation contributes four exact-generation filesystem tools',
    () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      expect(extensions.discover(modelToolContributions), isEmpty);

      final ExtensionRegistration activation = const FilesystemToolsPlugin()
          .activate(extensions);
      final _FileSystem fileSystem = _FileSystem();
      final ToolCatalog catalog = await ModelToolComposer(
        extensions,
      ).materialize(_Context(fileSystem));
      final MaterializedToolSet tools = catalog.materialize();

      expect(tools.tools.map((tool) => tool.modelDefinition.alias), <String>[
        'read_file',
        'apply_patch',
        'create_file',
        'delete_file',
      ]);
      expect(
        tools.tools.map((tool) => tool.definition.id.value),
        everyElement(contains('filesystem-tools')),
      );

      await activation.close();
      expect(extensions.discover(modelToolContributions), isEmpty);
      for (final MaterializedTool tool in tools.tools) {
        expect(
          tool.executable.validateBinding,
          throwsA(isA<StaleToolBindingException>()),
        );
      }
    },
  );

  test('Read File exposes the opaque revision to model and host', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'plugin-owned source',
      revision: 'opaque "revision"\n2',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'read_file');

    expect(
      () => executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'source.dart',
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
    final ToolOutcome outcome = await _execute(
      executable,
      executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'source.dart',
      }),
      fileSystem.sessionId,
    );

    expect(fileSystem.readPaths, <String>['source.dart']);
    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(
      outcome.modelContent,
      'File: ${jsonEncode('source.dart')}\n'
      'Revision: ${jsonEncode('opaque "revision"\n2')}\n\n'
      'plugin-owned source',
    );
    expect(outcome.hostData, containsPair('environmentId', 'environment-1'));
    expect(outcome.hostData, containsPair('relativePath', 'source.dart'));
    expect(outcome.hostData, containsPair('revision', 'opaque "revision"\n2'));
    expect(outcome.hostData, containsPair('text', 'plugin-owned source'));
  });

  test('Read File canonicalizes its policy and execution path', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'canonical source',
      revision: 'R1',
      reportedRelativePath: 'provider/alternate.dart',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'read_file');
    final CanonicalToolArguments arguments = executable.validateAndNormalize(
      const <String, Object?>{'relativePath': 'dir//./source.dart'},
    );

    expect(arguments.snapshot['relativePath'], 'dir/source.dart');
    final EffectDescription effects = await executable.describe(
      arguments,
      _execution(fileSystem.sessionId),
    );
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/dir/source.dart',
    );
    expect(effects.summary, 'Read Environment file dir/source.dart.');
    final ToolOutcome outcome = await _execute(
      executable,
      arguments,
      fileSystem.sessionId,
    );

    expect(fileSystem.readPaths, <String>['dir/source.dart']);
    expect(outcome.modelContent, startsWith('File: "dir/source.dart"\n'));
    expect(outcome.hostData['relativePath'], 'dir/source.dart');
  });

  test('Read File describes effects and preserves failure classes', () async {
    final _FileSystem fileSystem = _FileSystem();
    final ToolExecutable executable = await _tool(fileSystem, 'read_file');
    final CanonicalToolArguments arguments = executable.validateAndNormalize(
      const <String, Object?>{'relativePath': 'source.dart'},
    );
    final EffectDescription effects = await executable.describe(
      arguments,
      _execution(fileSystem.sessionId),
    );

    expect(effects.effects, <ToolEffect>{ToolEffect.sourceRead});
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/source.dart',
    );

    final _FileSystem domainFileSystem = _FileSystem(
      readError: const EnvironmentFailure(
        code: 'not_found',
        message: 'Missing file.',
        details: <String, Object?>{'path': 'missing.dart'},
      ),
    );
    final ToolExecutable domainTool = await _tool(
      domainFileSystem,
      'read_file',
    );
    final ToolOutcome domainOutcome = await _execute(
      domainTool,
      domainTool.validateAndNormalize(const <String, Object?>{
        'relativePath': 'missing.dart',
      }),
      domainFileSystem.sessionId,
    );
    expect(domainOutcome.failureKind, ToolFailureKind.domain);
    expect(domainOutcome.hostData['code'], 'not_found');

    final _FileSystem staleFileSystem = _FileSystem()..stale = true;
    final ToolExecutable staleTool = await _tool(staleFileSystem, 'read_file');
    expect(
      staleTool.validateBinding,
      throwsA(isA<StaleToolBindingException>()),
    );
    final ToolOutcome staleOutcome = await _execute(
      staleTool,
      arguments,
      staleFileSystem.sessionId,
    );
    expect(staleOutcome.failureKind, ToolFailureKind.staleBinding);
    expect(staleOutcome.effectCertainty, EffectCertainty.knownNotOccurred);

    final _FileSystem unavailableFileSystem = _FileSystem()..available = false;
    final ToolExecutable unavailableTool = await _tool(
      unavailableFileSystem,
      'read_file',
    );
    expect(
      unavailableTool.validateBinding,
      throwsA(isA<ToolBindingUnavailableException>()),
    );
    final ToolOutcome unavailableOutcome = await _execute(
      unavailableTool,
      arguments,
      unavailableFileSystem.sessionId,
    );
    expect(unavailableOutcome.failureKind, ToolFailureKind.infrastructure);
    expect(
      unavailableOutcome.effectCertainty,
      EffectCertainty.knownNotOccurred,
    );
  });

  test('Create File schema is exact and permits empty content', () async {
    final _FileSystem fileSystem = _FileSystem();
    final ToolRegistration registration = await _registration(
      fileSystem,
      'create_file',
    );
    final ToolExecutable executable = registration.executable;
    final Map<String, Object?> schema =
        registration.modelDefinition.argumentsSchema;
    const Map<String, Object?> valid = <String, Object?>{
      'relativePath': 'source.dart',
      'content': '',
    };

    expect(schema['required'], <Object?>['relativePath', 'content']);
    expect((schema['properties']! as Map<String, Object?>).keys, <String>[
      'relativePath',
      'content',
    ]);
    expect(schema['additionalProperties'], isFalse);
    expect(executable.validateAndNormalize(valid).snapshot, valid);
    for (final String field in valid.keys) {
      expect(
        () => executable.validateAndNormalize(
          Map<String, Object?>.of(valid)..remove(field),
        ),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
    expect(
      () => executable.validateAndNormalize(<String, Object?>{
        ...valid,
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
    final ToolOutcome emptyOutcome = await _execute(
      executable,
      executable.validateAndNormalize(valid),
      fileSystem.sessionId,
    );
    expect(emptyOutcome.disposition, ToolOutcomeDisposition.success);
    expect(fileSystem.creations.single.content, isEmpty);
  });

  test(
    'Create File preserves authored text and rejects malformed UTF-16',
    () async {
      final String content = '  first\nsecond \u{1f642}\n';
      final _FileSystem fileSystem = _FileSystem();
      final ToolExecutable executable = await _tool(fileSystem, 'create_file');
      final ToolOutcome outcome = await _execute(
        executable,
        executable.validateAndNormalize(<String, Object?>{
          'relativePath': 'created.dart',
          'content': content,
        }),
        fileSystem.sessionId,
      );

      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(fileSystem.creations.single.content, content);
      for (final ({String field, String value}) fixture
          in <({String field, String value})>[
            (field: 'relativePath', value: 'bad${String.fromCharCode(0xd800)}'),
            (field: 'content', value: String.fromCharCode(0xdc00)),
          ]) {
        final _FileSystem malformedFileSystem = _FileSystem();
        final ToolExecutable malformed = await _tool(
          malformedFileSystem,
          'create_file',
        );
        final Map<String, Object?> arguments = <String, Object?>{
          'relativePath': 'created.dart',
          'content': '',
          fixture.field: fixture.value,
        };
        expect(
          () => malformed.validateAndNormalize(arguments),
          throwsA(isA<ToolArgumentValidationException>()),
        );
        expect(malformedFileSystem.creations, isEmpty);
      }
    },
  );

  test('Create File canonicalizes path for policy and execution', () async {
    for (final ({String spelling, String canonical}) fixture
        in <({String spelling, String canonical})>[
          (spelling: 'foo.dart', canonical: 'foo.dart'),
          (spelling: './foo.dart', canonical: 'foo.dart'),
          (spelling: 'dir//foo.dart', canonical: 'dir/foo.dart'),
          (spelling: 'dir/./foo.dart', canonical: 'dir/foo.dart'),
        ]) {
      final _FileSystem fileSystem = _FileSystem(postCreateRevision: 'R-new');
      final ToolExecutable executable = await _tool(fileSystem, 'create_file');
      final CanonicalToolArguments arguments = executable.validateAndNormalize(
        <String, Object?>{'relativePath': fixture.spelling, 'content': ''},
      );
      final EffectDescription effects = await executable.describe(
        arguments,
        _execution(fileSystem.sessionId),
      );
      final ToolOutcome outcome = await _execute(
        executable,
        arguments,
        fileSystem.sessionId,
      );

      expect(arguments.snapshot['relativePath'], fixture.canonical);
      expect(effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
      expect(effects.uncertainty, EffectUncertainty.none);
      expect(
        effects.targets.single.uri.toString(),
        'adele-environment:/environment-1/${fixture.canonical}',
      );
      expect(effects.summary, 'Create Environment file ${fixture.canonical}.');
      expect(fileSystem.creations.single.relativePath, fixture.canonical);
      expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(
        outcome.modelContent,
        'Created: ${jsonEncode(fixture.canonical)}\nRevision: "R-new"',
      );
      expect(outcome.hostData, <String, Object?>{
        'environmentId': 'environment-1',
        'relativePath': fixture.canonical,
        'revision': 'R-new',
      });
    }
  });

  test(
    'Create File maps only existing-target failure as known no-effect',
    () async {
      final _FileSystem existing = _FileSystem(
        createError: const EnvironmentFailure(
          code: environmentFileAlreadyExistsCode,
          message: 'Already exists.',
          details: <String, Object?>{'relativePath': 'created.dart'},
        ),
      );
      final ToolExecutable existingTool = await _tool(existing, 'create_file');
      final ToolOutcome existingOutcome = await _execute(
        existingTool,
        existingTool.validateAndNormalize(const <String, Object?>{
          'relativePath': 'created.dart',
          'content': 'new',
        }),
        existing.sessionId,
      );
      expect(existing.creations, hasLength(1));
      expect(existingOutcome.failureKind, ToolFailureKind.domain);
      expect(existingOutcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(
        existingOutcome.hostData['code'],
        environmentFileAlreadyExistsCode,
      );
      expect(existingOutcome.modelContent, contains('use apply_patch'));

      final _FileSystem unexpected = _FileSystem(
        createError: const EnvironmentFailure(
          code: 'unwritable',
          message: 'Ambiguous provider failure.',
          details: <String, Object?>{},
        ),
      );
      final ToolExecutable unexpectedTool = await _tool(
        unexpected,
        'create_file',
      );
      final ToolOutcome unexpectedOutcome = await _execute(
        unexpectedTool,
        unexpectedTool.validateAndNormalize(const <String, Object?>{
          'relativePath': 'created.dart',
          'content': 'new',
        }),
        unexpected.sessionId,
      );
      expect(unexpected.creations, hasLength(1));
      expect(unexpectedOutcome.effectCertainty, EffectCertainty.uncertain);

      final _FileSystem stale = _FileSystem()..stale = true;
      final ToolExecutable staleTool = await _tool(stale, 'create_file');
      final ToolOutcome staleOutcome = await _execute(
        staleTool,
        staleTool.validateAndNormalize(const <String, Object?>{
          'relativePath': 'created.dart',
          'content': 'new',
        }),
        stale.sessionId,
      );
      expect(stale.creations, isEmpty);
      expect(staleOutcome.failureKind, ToolFailureKind.staleBinding);
      expect(staleOutcome.effectCertainty, EffectCertainty.knownNotOccurred);
    },
  );

  test('Delete File schema is exact and revision remains opaque', () async {
    final ToolRegistration registration = await _registration(
      _FileSystem(),
      'delete_file',
    );
    final ToolExecutable executable = registration.executable;
    final Map<String, Object?> schema =
        registration.modelDefinition.argumentsSchema;
    final String opaqueRevision = String.fromCharCode(0xd800);
    final Map<String, Object?> valid = <String, Object?>{
      'relativePath': './source.dart',
      'expectedRevision': opaqueRevision,
    };

    expect(schema['required'], <Object?>['relativePath', 'expectedRevision']);
    expect((schema['properties']! as Map<String, Object?>).keys, <String>[
      'relativePath',
      'expectedRevision',
    ]);
    expect(schema['additionalProperties'], isFalse);
    expect(executable.validateAndNormalize(valid).snapshot, <String, Object?>{
      'relativePath': 'source.dart',
      'expectedRevision': opaqueRevision,
    });
    for (final String field in valid.keys) {
      expect(
        () => executable.validateAndNormalize(
          Map<String, Object?>.of(valid)..remove(field),
        ),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
    expect(
      () => executable.validateAndNormalize(<String, Object?>{
        ...valid,
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
  });

  test('Delete File preflights revision without invoking mutation', () async {
    final _FileSystem fileSystem = _FileSystem(revision: 'current');
    final ToolExecutable executable = await _tool(fileSystem, 'delete_file');
    final ToolOutcome outcome = await _execute(
      executable,
      executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'source.dart',
        'expectedRevision': 'stale',
      }),
      fileSystem.sessionId,
    );

    expect(fileSystem.readPaths, <String>['source.dart']);
    expect(fileSystem.deletions, isEmpty);
    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.hostData['code'], environmentRevisionConflictCode);
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(outcome.modelContent, contains('Re-read the file'));
  });

  test(
    'Delete File passes the original revision and reports exact effect',
    () async {
      final _FileSystem fileSystem = _FileSystem(revision: 'opaque R1');
      final ToolExecutable executable = await _tool(fileSystem, 'delete_file');
      final CanonicalToolArguments arguments = executable.validateAndNormalize(
        const <String, Object?>{
          'relativePath': 'dir//./source.dart',
          'expectedRevision': 'opaque R1',
        },
      );
      final EffectDescription effects = await executable.describe(
        arguments,
        _execution(fileSystem.sessionId),
      );
      final ToolOutcome outcome = await _execute(
        executable,
        arguments,
        fileSystem.sessionId,
      );

      expect(effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
      expect(effects.uncertainty, EffectUncertainty.none);
      expect(
        effects.targets.single.uri.toString(),
        'adele-environment:/environment-1/dir/source.dart',
      );
      expect(effects.summary, 'Delete Environment file dir/source.dart.');
      expect(fileSystem.readPaths, <String>['dir/source.dart']);
      expect(fileSystem.deletions.single.relativePath, 'dir/source.dart');
      expect(fileSystem.deletions.single.expectedRevision, 'opaque R1');
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(outcome.modelContent, 'Deleted: "dir/source.dart"');
      expect(outcome.hostData, <String, Object?>{
        'environmentId': 'environment-1',
        'relativePath': 'dir/source.dart',
      });
    },
  );

  test(
    'Delete File preserves provider conflict and failure certainty',
    () async {
      final _FileSystem conflict = _FileSystem(
        revision: 'R1',
        deleteError: const EnvironmentFailure(
          code: environmentRevisionConflictCode,
          message: 'Changed before delete.',
          details: <String, Object?>{},
        ),
      );
      final ToolExecutable conflictTool = await _tool(conflict, 'delete_file');
      final ToolOutcome conflictOutcome = await _execute(
        conflictTool,
        conflictTool.validateAndNormalize(const <String, Object?>{
          'relativePath': 'source.dart',
          'expectedRevision': 'R1',
        }),
        conflict.sessionId,
      );
      expect(conflict.deletions, hasLength(1));
      expect(conflictOutcome.hostData['code'], environmentRevisionConflictCode);
      expect(conflictOutcome.effectCertainty, EffectCertainty.knownNotOccurred);

      final _FileSystem missing = _FileSystem(
        readError: const EnvironmentFailure(
          code: 'not_found',
          message: 'Missing.',
          details: <String, Object?>{},
        ),
      );
      final ToolExecutable missingTool = await _tool(missing, 'delete_file');
      final ToolOutcome missingOutcome = await _execute(
        missingTool,
        missingTool.validateAndNormalize(const <String, Object?>{
          'relativePath': 'missing.dart',
          'expectedRevision': 'R1',
        }),
        missing.sessionId,
      );
      expect(missing.deletions, isEmpty);
      expect(missingOutcome.hostData['code'], 'not_found');
      expect(missingOutcome.effectCertainty, EffectCertainty.knownNotOccurred);

      final _FileSystem unexpected = _FileSystem(
        revision: 'R1',
        deleteError: const EnvironmentFailure(
          code: 'unwritable',
          message: 'Ambiguous delete failure.',
          details: <String, Object?>{},
        ),
      );
      final ToolExecutable unexpectedTool = await _tool(
        unexpected,
        'delete_file',
      );
      final ToolOutcome unexpectedOutcome = await _execute(
        unexpectedTool,
        unexpectedTool.validateAndNormalize(const <String, Object?>{
          'relativePath': 'source.dart',
          'expectedRevision': 'R1',
        }),
        unexpected.sessionId,
      );
      expect(unexpected.deletions, hasLength(1));
      expect(unexpectedOutcome.effectCertainty, EffectCertainty.uncertain);
    },
  );

  test('Apply Patch schema is exact and permits empty replacement', () async {
    final ToolExecutable executable = await _tool(_FileSystem(), 'apply_patch');
    final ToolRegistration registration = await _registration(
      _FileSystem(),
      'apply_patch',
    );
    final Map<String, Object?> schema =
        registration.modelDefinition.argumentsSchema;

    expect(schema, <String, Object?>{
      'type': 'object',
      'required': <Object?>['relativePath', 'expectedRevision', 'edits'],
      'properties': <String, Object?>{
        'relativePath': <String, Object?>{'type': 'string'},
        'expectedRevision': <String, Object?>{'type': 'string'},
        'edits': <String, Object?>{
          'type': 'array',
          'minItems': 1,
          'items': <String, Object?>{
            'type': 'object',
            'required': <Object?>['search', 'replace'],
            'properties': <String, Object?>{
              'search': <String, Object?>{'type': 'string', 'minLength': 1},
              'replace': <String, Object?>{'type': 'string'},
            },
            'additionalProperties': false,
          },
        },
      },
      'additionalProperties': false,
    });

    const Map<String, Object?> valid = <String, Object?>{
      'relativePath': 'source.dart',
      'expectedRevision': 'R1',
      'edits': <Object?>[
        <String, Object?>{'search': 'source', 'replace': ''},
      ],
    };
    expect(executable.validateAndNormalize(valid).snapshot, valid);
    for (final String field in valid.keys) {
      expect(
        () => executable.validateAndNormalize(
          Map<String, Object?>.of(valid)..remove(field),
        ),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
    expect(
      () => executable.validateAndNormalize(<String, Object?>{
        ...valid,
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
    for (final Map<String, Object?> invalid in <Map<String, Object?>>[
      <String, Object?>{
        'relativePath': 'source.dart',
        'expectedRevision': 'R1',
        'search': 'old',
        'replace': 'new',
      },
      <String, Object?>{...valid, 'search': 'old', 'replace': 'new'},
      <String, Object?>{...valid, 'relativePath': ''},
      <String, Object?>{...valid, 'relativePath': 1},
      <String, Object?>{...valid, 'expectedRevision': 1},
    ]) {
      expect(
        () => executable.validateAndNormalize(invalid),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
    for (final Object? invalidEdits in <Object?>[
      null,
      'old',
      <String, Object?>{'search': 'old', 'replace': 'new'},
      <Object?>[],
      <Object?>[null],
      <Object?>['old'],
      <Object?>[
        <Object?>['old', 'new'],
      ],
      <Object?>[<String, Object?>{}],
      <Object?>[
        <String, Object?>{'search': 'old'},
      ],
      <Object?>[
        <String, Object?>{'replace': 'new'},
      ],
      <Object?>[
        <String, Object?>{'search': '', 'replace': 'new'},
      ],
      <Object?>[
        <String, Object?>{'search': 1, 'replace': 'new'},
      ],
      <Object?>[
        <String, Object?>{'search': 'old', 'replace': null},
      ],
      <Object?>[
        <String, Object?>{'search': 'old', 'replace': 'new', 'extra': true},
      ],
      <Object?>[
        <String, Object?>{'search': 'old', 'replace': 'new'},
        <String, Object?>{'search': 'new'},
      ],
    ]) {
      expect(
        () => executable.validateAndNormalize(<String, Object?>{
          ...valid,
          'edits': invalidEdits,
        }),
        throwsA(isA<ToolArgumentValidationException>()),
        reason: 'Invalid edits: $invalidEdits',
      );
    }
    expect(
      executable.validateAndNormalize(<String, Object?>{
        ...valid,
        'expectedRevision': '',
      }).snapshot['expectedRevision'],
      '',
    );
  });

  test(
    'Apply Patch canonical edits retain order in a detached snapshot',
    () async {
      final ToolExecutable executable = await _tool(
        _FileSystem(),
        'apply_patch',
      );
      final Map<String, Object?> first = <String, Object?>{
        'search': 'A',
        'replace': 'B',
      };
      final List<Object?> edits = <Object?>[
        first,
        <String, Object?>{'search': 'B', 'replace': 'C'},
      ];
      final CanonicalToolArguments arguments = executable.validateAndNormalize(
        <String, Object?>{
          'relativePath': 'dir//./source.dart',
          'expectedRevision': 'R1',
          'edits': edits,
        },
      );
      first['replace'] = 'modified';
      edits.clear();
      expect(arguments.snapshot, <String, Object?>{
        'relativePath': 'dir/source.dart',
        'expectedRevision': 'R1',
        'edits': <Object?>[
          <String, Object?>{'search': 'A', 'replace': 'B'},
          <String, Object?>{'search': 'B', 'replace': 'C'},
        ],
      });
      final List<Object?> snapshotEdits = arguments.snapshot['edits']! as List;
      expect(snapshotEdits.clear, throwsUnsupportedError);
      expect(
        () => (snapshotEdits.first! as Map)['replace'] = 'modified',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'Apply Patch rejects malformed search and replace before access',
    () async {
      for (final ({String field, String value}) fixture
          in <({String field, String value})>[
            (field: 'search', value: String.fromCharCode(0xdc00)),
            (field: 'replace', value: String.fromCharCode(0xd800)),
          ]) {
        final _FileSystem fileSystem = _FileSystem();
        final ToolExecutable executable = await _tool(
          fileSystem,
          'apply_patch',
        );
        final Map<String, Object?> proposed = <String, Object?>{
          'relativePath': 'source.dart',
          'expectedRevision': 'R1',
          'edits': <Object?>[
            <String, Object?>{'search': 'old', 'replace': 'new'},
            <String, Object?>{
              'search': 'new',
              'replace': 'final',
              fixture.field: fixture.value,
            },
          ],
        };

        expect(
          () => executable.validateAndNormalize(proposed),
          throwsA(isA<ToolArgumentValidationException>()),
        );
        expect(fileSystem.readPaths, isEmpty);
        expect(fileSystem.replacements, isEmpty);
      }
    },
  );

  test(
    'filesystem tools reject malformed relative paths before access',
    () async {
      final String malformedPath = 'bad${String.fromCharCode(0xd800)}name.dart';
      for (final String alias in <String>[
        'read_file',
        'apply_patch',
        'create_file',
        'delete_file',
      ]) {
        final _FileSystem fileSystem = _FileSystem();
        final ToolExecutable executable = await _tool(fileSystem, alias);
        final Map<String, Object?> proposed = _argumentsFor(
          alias,
          malformedPath,
        );

        expect(
          () => executable.validateAndNormalize(proposed),
          throwsA(isA<ToolArgumentValidationException>()),
        );
        expect(fileSystem.readPaths, isEmpty);
        expect(fileSystem.replacements, isEmpty);
      }
    },
  );

  test(
    'Apply Patch accepts paired surrogates and opaque revision text',
    () async {
      final String search = String.fromCharCodes(<int>[0xd83d, 0xde00]);
      final String replace = String.fromCharCodes(<int>[0xd83d, 0xde42]);
      final String opaqueRevision = String.fromCharCode(0xd800);
      final _FileSystem fileSystem = _FileSystem(
        text: 'before $search after',
        revision: opaqueRevision,
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final CanonicalToolArguments arguments = _patchArguments(
        executable,
        expectedRevision: opaqueRevision,
        edits: <Map<String, Object?>>[
          <String, Object?>{'search': search, 'replace': replace},
        ],
      );

      expect(arguments.snapshot['expectedRevision'], opaqueRevision);
      final ToolOutcome outcome = await _execute(
        executable,
        arguments,
        fileSystem.sessionId,
      );

      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(
        fileSystem.replacements.single.replacementText,
        'before $replace after',
      );
      expect(fileSystem.replacements.single.expectedRevision, opaqueRevision);
    },
  );

  test('Apply Patch describes the authorized source mutation target', () async {
    final _FileSystem fileSystem = _FileSystem();
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final EffectDescription effects = await executable.describe(
      _patchArguments(executable),
      _execution(fileSystem.sessionId),
    );

    expect(effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/source.dart',
    );
    expect(
      effects.summary,
      'Apply 1 exact edit to Environment file source.dart.',
    );
  });

  test('Apply Patch canonicalizes its policy and execution path', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
      postWriteRevision: 'R2',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final CanonicalToolArguments arguments = _patchArguments(
      executable,
      relativePath: 'dir//./source.dart',
    );

    expect(arguments.snapshot['relativePath'], 'dir/source.dart');
    final EffectDescription effects = await executable.describe(
      arguments,
      _execution(fileSystem.sessionId),
    );
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/dir/source.dart',
    );
    expect(
      effects.summary,
      'Apply 1 exact edit to Environment file dir/source.dart.',
    );
    final ToolOutcome outcome = await _execute(
      executable,
      arguments,
      fileSystem.sessionId,
    );

    expect(fileSystem.readPaths, <String>['dir/source.dart']);
    expect(fileSystem.replacements.single.relativePath, 'dir/source.dart');
    expect(outcome.modelContent, startsWith('Patched: "dir/source.dart"\n'));
    expect(outcome.hostData['relativePath'], 'dir/source.dart');
  });

  test('invalid logical paths are rejected before filesystem access', () async {
    for (final String alias in <String>[
      'read_file',
      'apply_patch',
      'create_file',
      'delete_file',
    ]) {
      for (final String path in <String>[
        '../source.dart',
        'dir/../source.dart',
        '/source.dart',
        './',
      ]) {
        final _FileSystem fileSystem = _FileSystem();
        final ToolExecutable executable = await _tool(fileSystem, alias);
        final Map<String, Object?> proposed = _argumentsFor(alias, path);

        expect(
          () => executable.validateAndNormalize(proposed),
          throwsA(isA<ToolArgumentValidationException>()),
        );
        expect(fileSystem.readPaths, isEmpty);
        expect(fileSystem.replacements, isEmpty);
        expect(fileSystem.creations, isEmpty);
        expect(fileSystem.deletions, isEmpty);
      }
    }
  });

  test('Apply Patch replaces one exact occurrence with full text', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'bool first() => false;\nbool second() => true;\n',
      revision: 'R1',
      postWriteRevision: 'R2',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(
        executable,
        edits: const <Map<String, Object?>>[
          <String, Object?>{
            'search': 'bool second() => true;',
            'replace': 'bool second() => false;',
          },
        ],
      ),
      fileSystem.sessionId,
    );

    expect(fileSystem.readPaths, <String>['source.dart']);
    expect(fileSystem.replacements, hasLength(1));
    expect(fileSystem.replacements.single.relativePath, 'source.dart');
    expect(fileSystem.replacements.single.expectedRevision, 'R1');
    expect(
      fileSystem.replacements.single.replacementText,
      'bool first() => false;\nbool second() => false;\n',
    );
    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
    expect(
      outcome.modelContent,
      'Patched: "source.dart"\nEdits applied: 1\nRevision: "R2"',
    );
    expect(outcome.hostData, <String, Object?>{
      'environmentId': 'environment-1',
      'relativePath': 'source.dart',
      'editCount': 1,
      'newRevision': 'R2',
    });
  });

  test(
    'Apply Patch evaluates ordered edits on one working copy then replaces once',
    () async {
      final _FileSystem fileSystem = _FileSystem(
        text: 'A\nkeep\nD\n',
        revision: 'opaque:observed',
        postWriteRevision: 'opaque:result',
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final CanonicalToolArguments arguments = _patchArguments(
        executable,
        expectedRevision: 'opaque:observed',
        edits: const <Map<String, Object?>>[
          <String, Object?>{'search': 'A', 'replace': 'B'},
          <String, Object?>{'search': 'B', 'replace': 'C'},
          <String, Object?>{'search': 'D', 'replace': 'E'},
        ],
      );
      final EffectDescription effects = await executable.describe(
        arguments,
        _execution(fileSystem.sessionId),
      );
      expect(effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
      expect(effects.targets, hasLength(1));
      expect(
        effects.summary,
        'Apply 3 exact edits to Environment file source.dart.',
      );
      expect(fileSystem.readPaths, isEmpty);
      final ToolOutcome outcome = await _execute(
        executable,
        arguments,
        fileSystem.sessionId,
      );

      expect(fileSystem.readPaths, <String>['source.dart']);
      expect(fileSystem.replacements, hasLength(1));
      expect(fileSystem.replacements.single.relativePath, 'source.dart');
      expect(
        fileSystem.replacements.single.expectedRevision,
        'opaque:observed',
      );
      expect(fileSystem.replacements.single.replacementText, 'C\nkeep\nE\n');
      expect(fileSystem.text, 'C\nkeep\nE\n');
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(outcome.hostData, <String, Object?>{
        'environmentId': 'environment-1',
        'relativePath': 'source.dart',
        'editCount': 3,
        'newRevision': 'opaque:result',
      });
      expect(
        outcome.modelContent,
        'Patched: "source.dart"\nEdits applied: 3\nRevision: "opaque:result"',
      );
    },
  );

  test('later edit failures discard all earlier in-memory edits', () async {
    for (final ({String search, String replace, String code}) fixture
        in <({String search, String replace, String code})>[
          (search: 'A', replace: 'C', code: 'patch_target_not_found'),
          (search: 'B', replace: 'C', code: 'patch_target_ambiguous'),
          (search: 'BB', replace: 'BB', code: 'no_change'),
          (search: 'BB', replace: 'C', code: 'patch_target_ambiguous'),
        ]) {
      // The overlapping BB matches only become ambiguous after the first edit.
      final String replacement =
          fixture.search == 'BB' && fixture.replace == 'C' ? 'BBB' : 'BB';
      final _FileSystem fileSystem = _FileSystem(text: 'A', revision: 'R1');
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(
          executable,
          edits: <Map<String, Object?>>[
            <String, Object?>{'search': 'A', 'replace': replacement},
            <String, Object?>{
              'search': fixture.search,
              'replace': fixture.replace,
            },
            <String, Object?>{'search': 'never evaluated', 'replace': 'unused'},
          ],
        ),
        fileSystem.sessionId,
      );

      expect(fileSystem.readPaths, <String>['source.dart']);
      expect(fileSystem.replacements, isEmpty);
      expect(fileSystem.text, 'A');
      expect(fileSystem.revision, 'R1');
      expect(outcome.disposition, ToolOutcomeDisposition.failure);
      expect(outcome.failureKind, ToolFailureKind.domain);
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(outcome.hostData, <String, Object?>{
        'environmentId': 'environment-1',
        'relativePath': 'source.dart',
        'editCount': 3,
        'failedEditIndex': 1,
        'code': fixture.code,
      });
      expect(outcome.modelContent, startsWith('Edit 2 of 3 failed:'));
      expect(outcome.modelContent, contains('No changes were made.'));
    }
  });

  test(
    'cancelling edits reject a final no-op without provider mutation',
    () async {
      final _FileSystem fileSystem = _FileSystem(text: 'A', revision: 'R1');
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(
          executable,
          edits: const <Map<String, Object?>>[
            <String, Object?>{'search': 'A', 'replace': 'B'},
            <String, Object?>{'search': 'B', 'replace': 'A'},
          ],
        ),
        fileSystem.sessionId,
      );

      expect(fileSystem.text, 'A');
      expect(fileSystem.replacements, isEmpty);
      expect(outcome.failureKind, ToolFailureKind.domain);
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(outcome.hostData['code'], 'no_change');
      expect(outcome.hostData['editCount'], 2);
      expect(outcome.hostData, isNot(contains('failedEditIndex')));
      expect(
        outcome.modelContent,
        contains('2 edits leave the file unchanged'),
      );
    },
  );

  test('Apply Patch searches literals rather than regex patterns', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: r'a.*[b] axb',
      revision: 'R1',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(
        executable,
        edits: const <Map<String, Object?>>[
          <String, Object?>{'search': r'a.*[b]', 'replace': r'$1'},
        ],
      ),
      fileSystem.sessionId,
    );

    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(fileSystem.replacements.single.replacementText, r'$1 axb');
  });

  test(
    'Apply Patch rejects absent and repeated targets without mutation',
    () async {
      for (final ({String text, String search, String code}) fixture
          in <({String text, String search, String code})>[
            (
              text: 'bool result() => true;\n',
              search: 'return false;',
              code: 'patch_target_not_found',
            ),
            (text: 'Value', search: 'value', code: 'patch_target_not_found'),
            (
              text: 'first\r\nsecond',
              search: 'first\nsecond',
              code: 'patch_target_not_found',
            ),
            (
              text: 'Cafe\u0301',
              search: 'Caf\u00e9',
              code: 'patch_target_not_found',
            ),
            (
              text: 'return false;\nreturn false;\nreturn false;\n',
              search: 'return false;',
              code: 'patch_target_ambiguous',
            ),
            (text: 'aaa', search: 'aa', code: 'patch_target_ambiguous'),
          ]) {
        final _FileSystem fileSystem = _FileSystem(
          text: fixture.text,
          revision: 'R1',
        );
        final ToolExecutable executable = await _tool(
          fileSystem,
          'apply_patch',
        );
        final ToolOutcome outcome = await _execute(
          executable,
          _patchArguments(
            executable,
            edits: <Map<String, Object?>>[
              <String, Object?>{'search': fixture.search, 'replace': 'new'},
            ],
          ),
          fileSystem.sessionId,
        );

        expect(outcome.failureKind, ToolFailureKind.domain);
        expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
        expect(outcome.hostData['code'], fixture.code);
        expect(outcome.hostData['failedEditIndex'], 0);
        expect(outcome.hostData['editCount'], 1);
        if (fixture.code == 'patch_target_ambiguous') {
          expect(outcome.modelContent, contains('matched multiple locations'));
          expect(outcome.modelContent, isNot(contains('3 locations')));
        }
        expect(fileSystem.replacements, isEmpty);
      }
    },
  );

  test('surrounding function context disambiguates repeated code', () async {
    final _FileSystem fileSystem = _FileSystem(
      text:
          'bool first() {\n  return false;\n}\n\n'
          'bool second() {\n  return false;\n}\n',
      revision: 'R1',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(
        executable,
        edits: const <Map<String, Object?>>[
          <String, Object?>{
            'search': 'bool second() {\n  return false;\n}',
            'replace': 'bool second() {\n  return true;\n}',
          },
        ],
      ),
      fileSystem.sessionId,
    );

    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(
      fileSystem.replacements.single.replacementText,
      contains('bool second() {\n  return true;\n}'),
    );
  });

  test('Apply Patch rejects no-op and permits empty replacement', () async {
    final _FileSystem noOpFileSystem = _FileSystem(
      text: 'remove me',
      revision: 'R1',
    );
    final ToolExecutable noOp = await _tool(noOpFileSystem, 'apply_patch');
    final ToolOutcome noOpOutcome = await _execute(
      noOp,
      _patchArguments(
        noOp,
        edits: const <Map<String, Object?>>[
          <String, Object?>{'search': 'remove me', 'replace': 'remove me'},
        ],
      ),
      noOpFileSystem.sessionId,
    );
    expect(noOpOutcome.hostData['code'], 'no_change');
    expect(noOpOutcome.hostData['failedEditIndex'], 0);
    expect(noOpOutcome.hostData['editCount'], 1);
    expect(noOpOutcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(noOpFileSystem.replacements, isEmpty);

    final _FileSystem deletionFileSystem = _FileSystem(
      text: 'before remove me after',
      revision: 'R1',
    );
    final ToolExecutable deletion = await _tool(
      deletionFileSystem,
      'apply_patch',
    );
    final ToolOutcome deletionOutcome = await _execute(
      deletion,
      _patchArguments(
        deletion,
        edits: const <Map<String, Object?>>[
          <String, Object?>{'search': 'remove me', 'replace': ''},
        ],
      ),
      deletionFileSystem.sessionId,
    );
    expect(deletionOutcome.disposition, ToolOutcomeDisposition.success);
    expect(
      deletionFileSystem.replacements.single.replacementText,
      'before  after',
    );
  });

  test('Apply Patch requires an exact unique target before no-op', () async {
    for (final ({String text, String code}) fixture
        in <({String text, String code})>[
          (text: 'other', code: 'patch_target_not_found'),
          (text: 'same same', code: 'patch_target_ambiguous'),
        ]) {
      final _FileSystem fileSystem = _FileSystem(
        text: fixture.text,
        revision: 'R1',
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(
          executable,
          edits: const <Map<String, Object?>>[
            <String, Object?>{'search': 'same', 'replace': 'same'},
          ],
        ),
        fileSystem.sessionId,
      );

      expect(outcome.hostData['code'], fixture.code);
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(fileSystem.replacements, isEmpty);
    }
  });

  test('revision conflict wins before absent or ambiguous matching', () async {
    for (final ({String text, String search}) fixture
        in <({String text, String search})>[
          (text: 'current source', search: 'absent'),
          (text: 'repeat repeat', search: 'repeat'),
        ]) {
      final _FileSystem fileSystem = _FileSystem(
        text: fixture.text,
        revision: 'R2',
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(
          executable,
          edits: <Map<String, Object?>>[
            <String, Object?>{
              'search': fixture.search,
              'replace': fixture.search,
            },
            <String, Object?>{'search': 'absent', 'replace': 'new'},
          ],
        ),
        fileSystem.sessionId,
      );

      expect(outcome.hostData['code'], environmentRevisionConflictCode);
      expect(outcome.hostData['editCount'], 2);
      expect(outcome.hostData, isNot(contains('failedEditIndex')));
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(outcome.modelContent, contains('Re-read the file'));
      expect(fileSystem.replacements, isEmpty);
    }
  });

  test('read-side path alias failure is known not occurred', () async {
    final _FileSystem fileSystem = _FileSystem(
      readError: const EnvironmentFailure(
        code: 'path_alias_unsupported',
        message: 'Symbolic-link aliases are unsupported.',
        details: <String, Object?>{'relativePath': 'alias.dart'},
      ),
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(executable, relativePath: 'alias.dart'),
      fileSystem.sessionId,
    );

    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.hostData['code'], 'path_alias_unsupported');
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(fileSystem.replacements, isEmpty);
  });

  test('unexpected read failure is known not occurred', () async {
    final _FileSystem fileSystem = _FileSystem(
      readError: StateError('Unexpected read failure.'),
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(executable),
      fileSystem.sessionId,
    );

    expect(outcome.failureKind, ToolFailureKind.infrastructure);
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(fileSystem.replacements, isEmpty);
  });

  test('conditional replacement conflict is known not occurred', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
      replacementError: const EnvironmentFailure(
        code: environmentRevisionConflictCode,
        message: 'Changed before promotion.',
        details: <String, Object?>{'relativePath': 'source.dart'},
      ),
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(
        executable,
        edits: const <Map<String, Object?>>[
          <String, Object?>{'search': 'old', 'replace': 'intermediate'},
          <String, Object?>{'search': 'intermediate', 'replace': 'new'},
        ],
      ),
      fileSystem.sessionId,
    );

    expect(fileSystem.replacements, hasLength(1));
    expect(fileSystem.replacements.single.expectedRevision, 'R1');
    expect(fileSystem.replacements.single.replacementText, 'new');
    expect(fileSystem.text, 'old');
    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.hostData['code'], environmentRevisionConflictCode);
    expect(outcome.hostData['editCount'], 2);
    expect(outcome.hostData, isNot(contains('failedEditIndex')));
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(outcome.hostData, isNot(contains('details')));
  });

  test(
    'other replacement failure remains uncertain after invocation',
    () async {
      final _FileSystem fileSystem = _FileSystem(
        text: 'old',
        revision: 'R1',
        replacementError: const EnvironmentFailure(
          code: 'unwritable',
          message: 'Post-promotion verification failed.',
          details: <String, Object?>{'relativePath': 'source.dart'},
        ),
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(executable),
        fileSystem.sessionId,
      );

      expect(fileSystem.replacements, hasLength(1));
      expect(outcome.failureKind, ToolFailureKind.domain);
      expect(outcome.hostData['code'], 'unwritable');
      expect(outcome.effectCertainty, EffectCertainty.uncertain);
    },
  );

  test(
    'post-invocation binding and unexpected failures remain uncertain',
    () async {
      for (final ({Object error, ToolFailureKind kind}) fixture
          in <({Object error, ToolFailureKind kind})>[
            (
              error: const AuthorizedEnvironmentBindingUnavailable(
                'Response failed after replacement dispatch.',
              ),
              kind: ToolFailureKind.infrastructure,
            ),
            (
              error: const AuthorizedEnvironmentBindingStale(
                'Stale after dispatch.',
              ),
              kind: ToolFailureKind.staleBinding,
            ),
            (
              error: StateError('Unexpected provider failure after dispatch.'),
              kind: ToolFailureKind.infrastructure,
            ),
          ]) {
        final _FileSystem fileSystem = _FileSystem(
          text: 'old',
          revision: 'R1',
          replacementError: fixture.error,
        );
        final ToolExecutable executable = await _tool(
          fileSystem,
          'apply_patch',
        );
        final ToolOutcome outcome = await _execute(
          executable,
          _patchArguments(executable),
          fileSystem.sessionId,
        );

        expect(fileSystem.replacements, hasLength(1));
        expect(outcome.failureKind, fixture.kind);
        expect(outcome.effectCertainty, EffectCertainty.uncertain);
      }
    },
  );

  test('Session mismatch and stale binding do not reach mutation', () async {
    final _FileSystem wrongSessionFileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
    );
    final ToolExecutable wrongSession = await _tool(
      wrongSessionFileSystem,
      'apply_patch',
    );
    final ToolOutcome wrongSessionOutcome = await _execute(
      wrongSession,
      _patchArguments(wrongSession),
      SessionId('session-other'),
    );
    expect(wrongSessionOutcome.failureKind, ToolFailureKind.infrastructure);
    expect(
      wrongSessionOutcome.effectCertainty,
      EffectCertainty.knownNotOccurred,
    );
    expect(wrongSessionFileSystem.readPaths, isEmpty);
    expect(wrongSessionFileSystem.replacements, isEmpty);

    final _FileSystem staleFileSystem = _FileSystem(text: 'old', revision: 'R1')
      ..stale = true;
    final ToolExecutable stale = await _tool(staleFileSystem, 'apply_patch');
    expect(stale.validateBinding, throwsA(isA<StaleToolBindingException>()));
    final ToolOutcome staleOutcome = await _execute(
      stale,
      _patchArguments(stale),
      staleFileSystem.sessionId,
    );
    expect(staleOutcome.failureKind, ToolFailureKind.staleBinding);
    expect(staleOutcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(staleFileSystem.replacements, isEmpty);

    final _FileSystem unavailableFileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
    )..available = false;
    final ToolExecutable unavailable = await _tool(
      unavailableFileSystem,
      'apply_patch',
    );
    expect(
      unavailable.validateBinding,
      throwsA(isA<ToolBindingUnavailableException>()),
    );
    final ToolOutcome unavailableOutcome = await _execute(
      unavailable,
      _patchArguments(unavailable),
      unavailableFileSystem.sessionId,
    );
    expect(unavailableOutcome.failureKind, ToolFailureKind.infrastructure);
    expect(
      unavailableOutcome.effectCertainty,
      EffectCertainty.knownNotOccurred,
    );
    expect(unavailableFileSystem.replacements, isEmpty);
  });

  test('Filesystem Tools rejects facets from different authorities', () async {
    final _FileSystem read = _FileSystem();
    final _FileSystem mutation = _FileSystem(
      environmentId: EnvironmentId('environment-other'),
    );
    final ExtensionRegistry extensions = ExtensionRegistry();
    const FilesystemToolsPlugin().activate(extensions);

    await expectLater(
      extensions
          .discover(modelToolContributions)
          .single
          .value
          .materialize(_Context(read, mutation: mutation)),
      throwsStateError,
    );
  });
}

Future<ToolRegistration> _registration(
  _FileSystem fileSystem,
  String alias,
) async => (await _registrations(
  fileSystem,
)).singleWhere((registration) => registration.modelDefinition.alias == alias);

Future<ToolExecutable> _tool(_FileSystem fileSystem, String alias) async =>
    (await _registration(fileSystem, alias)).executable;

Future<List<ToolRegistration>> _registrations(_FileSystem fileSystem) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  const FilesystemToolsPlugin().activate(extensions);
  return (await extensions
          .discover(modelToolContributions)
          .single
          .value
          .materialize(_Context(fileSystem)))
      .toList(growable: false);
}

CanonicalToolArguments _patchArguments(
  ToolExecutable executable, {
  String relativePath = 'source.dart',
  String expectedRevision = 'R1',
  List<Map<String, Object?>> edits = const <Map<String, Object?>>[
    <String, Object?>{'search': 'old', 'replace': 'new'},
  ],
}) => executable.validateAndNormalize(<String, Object?>{
  'relativePath': relativePath,
  'expectedRevision': expectedRevision,
  'edits': edits,
});

ToolExecutionContext _execution(SessionId sessionId) =>
    ToolExecutionContext(runId: RunId('run-execute'), sessionId: sessionId);

Future<ToolOutcome> _execute(
  ToolExecutable executable,
  CanonicalToolArguments arguments,
  SessionId sessionId,
) async =>
    (await executable.execute(arguments, _execution(sessionId)).single
            as ToolExecutionTerminal)
        .outcome;

Map<String, Object?> _argumentsFor(String alias, String relativePath) =>
    switch (alias) {
      'read_file' => <String, Object?>{'relativePath': relativePath},
      'apply_patch' => <String, Object?>{
        'relativePath': relativePath,
        'expectedRevision': 'R1',
        'edits': <Object?>[
          <String, Object?>{'search': 'old', 'replace': 'new'},
        ],
      },
      'create_file' => <String, Object?>{
        'relativePath': relativePath,
        'content': 'new',
      },
      'delete_file' => <String, Object?>{
        'relativePath': relativePath,
        'expectedRevision': 'R1',
      },
      _ => throw StateError('Unknown fixture alias $alias.'),
    };

final class _Context implements ModelToolHostContext {
  const _Context(this.read, {AuthorizedEnvironmentFileMutationFacet? mutation})
    : mutation = mutation ?? read;

  final _FileSystem read;
  final AuthorizedEnvironmentFileMutationFacet mutation;

  @override
  SessionId get sessionId => read.sessionId;

  @override
  Future<T> requireHostService<T extends Object>() async {
    if (T == AuthorizedEnvironmentFileReadFacet) return read as T;
    if (T == AuthorizedEnvironmentFileMutationFacet) return mutation as T;
    throw StateError('Unsupported test host service $T.');
  }
}

final class _ReplacementCall {
  const _ReplacementCall({
    required this.relativePath,
    required this.replacementText,
    required this.expectedRevision,
  });

  final String relativePath;
  final String replacementText;
  final String expectedRevision;
}

final class _CreationCall {
  const _CreationCall({required this.relativePath, required this.content});

  final String relativePath;
  final String content;
}

final class _DeletionCall {
  const _DeletionCall({
    required this.relativePath,
    required this.expectedRevision,
  });

  final String relativePath;
  final String expectedRevision;
}

final class _FileSystem
    implements
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet {
  _FileSystem({
    this.text = 'source',
    this.revision = 'fixture-revision',
    this.postWriteRevision = 'post-write-revision',
    this.postCreateRevision = 'post-create-revision',
    this.reportedRelativePath,
    this.readError,
    this.replacementError,
    this.createError,
    this.deleteError,
    EnvironmentId? environmentId,
  }) : environmentId = environmentId ?? EnvironmentId('environment-1');

  String text;
  String revision;
  final String postWriteRevision;
  final String postCreateRevision;
  final String? reportedRelativePath;
  final Object? readError;
  final Object? replacementError;
  final Object? createError;
  final Object? deleteError;
  final List<String> readPaths = <String>[];
  final List<_ReplacementCall> replacements = <_ReplacementCall>[];
  final List<_CreationCall> creations = <_CreationCall>[];
  final List<_DeletionCall> deletions = <_DeletionCall>[];
  bool stale = false;
  bool available = true;

  @override
  final SessionId sessionId = SessionId('session-1');

  @override
  final EnvironmentId environmentId;

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    validateBinding();
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: const <EnvironmentDirectoryEntry>[],
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    validateBinding();
    readPaths.add(relativePath);
    if (readError case final Object error) throw error;
    return EnvironmentTextFile(
      relativePath: reportedRelativePath ?? relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: revision,
    );
  }

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    validateBinding();
    creations.add(_CreationCall(relativePath: relativePath, content: text));
    if (createError case final Object error) throw error;
    this.text = text;
    revision = postCreateRevision;
    return EnvironmentTextFileCreation(revision: postCreateRevision);
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    validateBinding();
    replacements.add(
      _ReplacementCall(
        relativePath: relativePath,
        replacementText: replacementText,
        expectedRevision: expectedRevision,
      ),
    );
    if (replacementError case final Object error) throw error;
    text = replacementText;
    revision = postWriteRevision;
    return EnvironmentTextFileReplacement(revision: postWriteRevision);
  }

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    validateBinding();
    deletions.add(
      _DeletionCall(
        relativePath: relativePath,
        expectedRevision: expectedRevision,
      ),
    );
    if (deleteError case final Object error) throw error;
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
