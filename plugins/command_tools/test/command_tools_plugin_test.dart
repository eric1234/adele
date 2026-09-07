import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  group('activation and schema', () {
    test('activates independently with only the process facet', () async {
      final _ProcessFacet process = _ProcessFacet();
      final ExtensionRegistry extensions = ExtensionRegistry();
      final _Context context = _Context(process);

      expect(
        (await ModelToolComposer(
          extensions,
        ).materialize(context)).materialize().tools,
        isEmpty,
      );
      final ExtensionRegistration activation = const CommandToolsPlugin()
          .activate(extensions);
      addTearDown(activation.close);

      final MaterializedToolSet tools = (await ModelToolComposer(
        extensions,
      ).materialize(context)).materialize();

      expect(commandToolsPluginId.value, 'dev.adele.plugin.command-tools');
      expect(tools.tools, hasLength(1));
      expect(tools.tools.single.modelDefinition.alias, 'run_command');
      expect(
        tools.tools.single.definition.id.value,
        'dev.adele.plugin.command-tools.run-command',
      );
      expect(context.requestedServices, <Type>[
        AuthorizedEnvironmentProcessFacet,
      ]);
    });

    test('retirement makes the old exact-generation tool stale', () async {
      final _ProcessFacet process = _ProcessFacet();
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionRegistration activation = const CommandToolsPlugin()
          .activate(extensions);
      final MaterializedTool tool = await _materializedTool(
        extensions,
        process,
      );
      final Stream<ToolExecutionEvent> deferred = tool.executable.execute(
        _canonical(tool, const <String, Object?>{'program': 'git'}),
        _executionContext(),
      );

      await activation.close();

      expect(
        tool.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      await expectLater(deferred, emitsError(isA<StaleToolBindingException>()));
      expect(process.executions, 0);
    });

    test('rejects a process facet authorized for another Session', () async {
      final _ProcessFacet process = _ProcessFacet(
        sessionId: SessionId('another-session'),
      );
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionRegistration activation = const CommandToolsPlugin()
          .activate(extensions);
      addTearDown(activation.close);

      await expectLater(
        ModelToolComposer(extensions).materialize(_Context(process)),
        throwsStateError,
      );
      expect(process.executions, 0);
    });

    test('binding validation delegates to the exact process facet', () async {
      final _ProcessFacet process = _ProcessFacet();
      final MaterializedTool tool = await _tool(process);

      process.bindingFailure = const AuthorizedEnvironmentBindingStale('stale');
      expect(
        tool.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      process.bindingFailure = const AuthorizedEnvironmentBindingUnavailable(
        'offline',
      );
      expect(
        tool.executable.validateBinding,
        throwsA(isA<ToolBindingUnavailableException>()),
      );
      expect(process.executions, 0);
    });

    test('publishes the narrow direct-execution schema', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());
      final Map<String, Object?> schema = tool.modelDefinition.argumentsSchema;
      final Map<String, Object?> properties =
          schema['properties']! as Map<String, Object?>;

      expect(schema['type'], 'object');
      expect(schema['required'], <Object?>['program']);
      expect(schema['additionalProperties'], isFalse);
      expect(properties.keys, <String>[
        'program',
        'arguments',
        'workingDirectory',
        'timeoutSeconds',
      ]);
      expect(properties.keys, isNot(contains('environmentId')));
      expect(properties.keys, isNot(contains('environmentVariables')));
      expect(properties['program'], <String, Object?>{
        'type': 'string',
        'minLength': 1,
      });
      expect(properties['arguments'], <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'type': 'string'},
      });
      expect(properties['timeoutSeconds'], <String, Object?>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 600,
      });
      expect(tool.modelDefinition.description, contains('passed verbatim'));
      expect(
        tool.modelDefinition.description,
        contains('does not implicitly invoke a shell'),
      );
    });
  });

  group('argument validation', () {
    test('fills canonical defaults', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());

      expect(
        _canonical(tool, const <String, Object?>{'program': 'git'}).snapshot,
        <String, Object?>{
          'program': 'git',
          'arguments': <Object?>[],
          'workingDirectory': '',
          'timeoutSeconds': 120,
        },
      );
    });

    test('preserves direct program and argument text exactly', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());
      const List<String> literalArguments = <String>[
        'two words',
        ';',
        r'$(touch nope)',
        '*',
        '"quoted"',
        "'single'",
        '',
      ];

      final CanonicalToolArguments canonical =
          _canonical(tool, const <String, Object?>{
            'program': ' sh ',
            'arguments': literalArguments,
            'workingDirectory': 'packages/./foo',
            'timeoutSeconds': 7,
          });

      expect(canonical.snapshot['program'], ' sh ');
      expect(canonical.snapshot['arguments'], literalArguments);
      expect(canonical.snapshot['workingDirectory'], 'packages/foo');
      expect(canonical.snapshot['timeoutSeconds'], 7);
    });

    test(
      'an explicit shell executable remains an ordinary direct program',
      () async {
        final _ProcessFacet process = _ProcessFacet();
        final MaterializedTool tool = await _tool(process);
        const List<String> arguments = <String>[
          '-c',
          r'printf "%s" "$HOME" | cat',
        ];

        await _execute(tool, const <String, Object?>{
          'program': 'sh',
          'arguments': arguments,
        });

        expect(process.requests.single.program, 'sh');
        expect(process.requests.single.arguments, arguments);
      },
    );

    test('canonicalizes logical working directories lexically', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());

      for (final MapEntry<String, String> fixture in const <String, String>{
        '': '',
        '.': '',
        './packages//foo': 'packages/foo',
        'packages/./foo': 'packages/foo',
      }.entries) {
        expect(
          _canonical(tool, <String, Object?>{
            'program': 'git',
            'workingDirectory': fixture.key,
          }).snapshot['workingDirectory'],
          fixture.value,
        );
      }
      for (final String invalid in const <String>[
        '../foo',
        'packages/../foo',
        '/absolute',
      ]) {
        expect(
          () => _canonical(tool, <String, Object?>{
            'program': 'git',
            'workingDirectory': invalid,
          }),
          throwsA(isA<ToolArgumentValidationException>()),
        );
      }
    });

    test('rejects malformed shapes and timeout bounds', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());
      for (final Map<String, Object?> invalid in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'program': ''},
        <String, Object?>{'program': 4},
        <String, Object?>{'program': 'git', 'extra': true},
        <String, Object?>{'program': 'git', 'arguments': null},
        <String, Object?>{'program': 'git', 'arguments': 'diff'},
        <String, Object?>{
          'program': 'git',
          'arguments': <Object?>['diff', 4],
        },
        <String, Object?>{'program': 'git', 'workingDirectory': 4},
        <String, Object?>{'program': 'git', 'workingDirectory': null},
        <String, Object?>{'program': 'git', 'timeoutSeconds': 1.5},
        <String, Object?>{'program': 'git', 'timeoutSeconds': null},
        <String, Object?>{'program': 'git', 'timeoutSeconds': 0},
        <String, Object?>{'program': 'git', 'timeoutSeconds': 601},
      ]) {
        expect(
          () => _canonical(tool, invalid),
          throwsA(isA<ToolArgumentValidationException>()),
        );
      }
    });

    test('rejects NUL and malformed UTF-16 before policy', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());
      final String malformed = String.fromCharCode(0xd800);
      for (final Map<String, Object?> invalid in <Map<String, Object?>>[
        <String, Object?>{'program': 'bad\u0000program'},
        <String, Object?>{
          'program': 'git',
          'arguments': <Object?>['bad\u0000argument'],
        },
        <String, Object?>{
          'program': 'git',
          'workingDirectory': 'bad\u0000directory',
        },
        <String, Object?>{'program': malformed},
        <String, Object?>{
          'program': 'git',
          'arguments': <Object?>[malformed],
        },
        <String, Object?>{'program': 'git', 'workingDirectory': malformed},
      ]) {
        expect(
          () => _canonical(tool, invalid),
          throwsA(isA<ToolArgumentValidationException>()),
        );
      }
    });
  });

  group('effect description', () {
    test(
      'targets the whole Environment with uncertain process execution',
      () async {
        final _ProcessFacet process = _ProcessFacet();
        final MaterializedTool tool = await _tool(process);
        final CanonicalToolArguments canonical = _canonical(
          tool,
          const <String, Object?>{
            'program': 'git',
            'arguments': <Object?>['diff', '--check'],
            'workingDirectory': './packages//foo',
            'timeoutSeconds': 30,
          },
        );

        final EffectDescription description = await tool.executable.describe(
          canonical,
          _executionContext(),
        );

        expect(description.effects, <ToolEffect>{ToolEffect.processExecution});
        expect(description.uncertainty, EffectUncertainty.uncertain);
        expect(
          description.targets.single.uri.toString(),
          'adele-environment:/environment-command/',
        );
        expect(
          description.summary,
          'Run program "git" with arguments ["diff","--check"] from '
          'Environment directory "packages/foo" with a 30-second timeout.',
        );
      },
    );

    test('rejects a Session mismatch without process execution', () async {
      final _ProcessFacet process = _ProcessFacet();
      final MaterializedTool tool = await _tool(process);

      await expectLater(
        tool.executable.describe(
          _canonical(tool, const <String, Object?>{'program': 'git'}),
          ToolExecutionContext(
            runId: RunId('run-command'),
            sessionId: SessionId('another-session'),
          ),
        ),
        throwsA(isA<Exception>()),
      );
      expect(process.executions, 0);
    });
  });

  group('process projection', () {
    test(
      'projects ordered stdout and stderr including whitespace and NUL',
      () async {
        final _ProcessFacet process = _ProcessFacet(
          events: () => Stream<EnvironmentProcessEvent>.fromIterable(
            <EnvironmentProcessEvent>[
              _output(EnvironmentProcessOutputStream.stdout, '\n'),
              _output(EnvironmentProcessOutputStream.stderr, ' '),
              _output(EnvironmentProcessOutputStream.stdout, '\u0000'),
              _output(EnvironmentProcessOutputStream.stderr, 'last'),
              _completed(exitCode: 0),
            ],
          ),
        );
        final MaterializedTool tool = await _tool(process);

        final ToolExecutionObservation observation = await _execute(
          tool,
          const <String, Object?>{'program': 'fixture'},
        );

        expect(
          observation.progress.map((ToolProgress value) => value.kind),
          <ToolProgressKind>[
            ToolProgressKind.stdout,
            ToolProgressKind.stderr,
            ToolProgressKind.stdout,
            ToolProgressKind.stderr,
          ],
        );
        expect(
          observation.progress.map((ToolProgress value) => value.content),
          <String>['\n', ' ', '\u0000', 'last'],
        );
        expect(observation.outcome.disposition, ToolOutcomeDisposition.success);
        expect(
          observation.outcome.effectCertainty,
          EffectCertainty.knownOccurred,
        );
        expect(observation.outcome.hostData['stdout'], '\n\u0000');
        expect(observation.outcome.hostData['stderr'], ' last');
      },
    );

    for (final int exitCode in <int>[0, 17]) {
      test('exit code $exitCode is a successful command result', () async {
        final _ProcessFacet process = _ProcessFacet(
          events: () => Stream<EnvironmentProcessEvent>.value(
            _completed(exitCode: exitCode),
          ),
        );
        final MaterializedTool tool = await _tool(process);
        final ToolExecutionObservation observation = await _execute(
          tool,
          const <String, Object?>{
            'program': 'git',
            'arguments': <Object?>['diff', '--check'],
          },
        );

        expect(observation.outcome.disposition, ToolOutcomeDisposition.success);
        expect(
          observation.outcome.effectCertainty,
          EffectCertainty.knownOccurred,
        );
        expect(observation.outcome.hostData['termination'], 'exited');
        expect(observation.outcome.hostData['exitCode'], exitCode);
        expect(
          observation.outcome.modelContent,
          contains('Exit code: $exitCode'),
        );
        expect(observation.outcome.modelContent, contains('STDOUT:\n'));
        expect(observation.outcome.modelContent, contains('STDERR:\n'));
      });
    }

    test('timeout retains partial output as a successful result', () async {
      final _ProcessFacet process = _ProcessFacet(
        events: () => Stream<EnvironmentProcessEvent>.fromIterable(
          <EnvironmentProcessEvent>[
            _output(EnvironmentProcessOutputStream.stdout, 'partial out'),
            _output(EnvironmentProcessOutputStream.stderr, 'partial err'),
            _completed(
              termination: EnvironmentProcessTermination.timedOut,
              stderrTruncated: true,
            ),
          ],
        ),
      );
      final MaterializedTool tool = await _tool(process);

      final ToolOutcome outcome = (await _execute(tool, const <String, Object?>{
        'program': 'slow',
      })).outcome;

      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(outcome.hostData['termination'], 'timedOut');
      expect(outcome.hostData['exitCode'], isNull);
      expect(outcome.hostData['stdout'], 'partial out');
      expect(outcome.hostData['stderr'], 'partial err');
      expect(outcome.hostData['stderrTruncated'], isTrue);
      expect(outcome.modelContent, contains('Termination: timedOut'));
      expect(outcome.modelContent, contains('Exit code: <not applicable>'));
      expect(outcome.modelContent, contains('partial out'));
    });

    test(
      'terminal output uses deterministic independent head and tail bounds',
      () async {
        final String head = List<String>.filled(16 * 1024, 'H').join();
        final String middle = List<String>.filled(2048, 'M').join();
        final String tail = List<String>.filled(16 * 1024, 'T').join();
        final String stderrText = List<String>.filled(1024, 'E').join();
        final _ProcessFacet process = _ProcessFacet(
          events: () => Stream<EnvironmentProcessEvent>.fromIterable(<
            EnvironmentProcessEvent
          >[
            _output(EnvironmentProcessOutputStream.stdout, '$head$middle$tail'),
            _output(EnvironmentProcessOutputStream.stderr, stderrText),
            _completed(exitCode: 0),
          ]),
        );
        final MaterializedTool tool = await _tool(process);

        final ToolOutcome outcome = (await _execute(
          tool,
          const <String, Object?>{'program': 'verbose'},
        )).outcome;

        expect(maximumRetainedCommandOutputCharacters, 32 * 1024);
        expect(outcome.hostData['stdout'], '$head$tail');
        expect((outcome.hostData['stdout']! as String).length, 32 * 1024);
        expect(outcome.hostData['stderr'], stderrText);
        expect(outcome.hostData['stdoutTruncated'], isTrue);
        expect(outcome.hostData['stderrTruncated'], isFalse);
        expect(outcome.modelContent, isNot(contains(middle)));
        expect(outcome.modelContent, contains('Stdout truncated: true'));
        expect(process.executions, 1);
      },
    );

    test('retention keeps valid Unicode at the head-tail boundary', () async {
      final String prefix = List<String>.filled(16 * 1024 - 1, 'H').join();
      final String suffix = List<String>.filled(16 * 1024 - 1, 'T').join();
      final String exactLimit = '$prefix\u{1f600}$suffix';
      final _ProcessFacet process = _ProcessFacet(
        events: () => Stream<EnvironmentProcessEvent>.fromIterable(
          <EnvironmentProcessEvent>[
            _output(EnvironmentProcessOutputStream.stdout, exactLimit),
            _completed(exitCode: 0),
          ],
        ),
      );

      final ToolOutcome outcome = (await _execute(
        await _tool(process),
        const <String, Object?>{'program': 'unicode'},
      )).outcome;

      expect(exactLimit.length, maximumRetainedCommandOutputCharacters);
      expect(outcome.hostData['stdout'], exactLimit);
      expect(outcome.hostData['stdoutTruncated'], isFalse);
    });

    test('returns complete structured host data', () async {
      final _ProcessFacet process = _ProcessFacet();
      final MaterializedTool tool = await _tool(process);

      final ToolOutcome outcome = (await _execute(tool, const <String, Object?>{
        'program': 'git',
        'arguments': <Object?>['status', '--short'],
        'workingDirectory': './packages//foo',
        'timeoutSeconds': 9,
      })).outcome;

      expect(
        outcome.hostData,
        containsPair('environmentId', 'environment-command'),
      );
      expect(outcome.hostData, containsPair('program', 'git'));
      expect(outcome.hostData['arguments'], <Object?>['status', '--short']);
      expect(
        outcome.hostData,
        containsPair('workingDirectory', 'packages/foo'),
      );
      expect(outcome.hostData, containsPair('timeoutSeconds', 9));
      expect(outcome.hostData, containsPair('termination', 'exited'));
      expect(outcome.hostData, containsPair('exitCode', 0));
      expect(outcome.hostData, containsPair('stdout', ''));
      expect(outcome.hostData, containsPair('stderr', ''));
      expect(process.requests.single.program, 'git');
      expect(process.requests.single.arguments, <String>['status', '--short']);
      expect(process.requests.single.relativeWorkingDirectory, 'packages/foo');
    });
  });

  group('stream failures', () {
    test(
      'maps Environment failures with uncertain effects and diagnostics',
      () async {
        const EnvironmentFailure failure = EnvironmentFailure(
          code: 'process_failed',
          message: 'Provider process failed.',
          details: <String, Object?>{'phase': 'stream'},
        );
        final ToolOutcome outcome = await _failureOutcome(failure);

        expect(outcome.disposition, ToolOutcomeDisposition.failure);
        expect(outcome.failureKind, ToolFailureKind.domain);
        expect(outcome.effectCertainty, EffectCertainty.uncertain);
        expect(outcome.hostData['stdout'], 'before failure');
        expect(outcome.hostData['code'], 'process_failed');
        expect(outcome.hostData['message'], 'Provider process failed.');
        expect(outcome.hostData['details'], <String, Object?>{
          'phase': 'stream',
        });
        expect(outcome.hostDiagnostic, contains('Provider process failed.'));
      },
    );

    for (final ({Object error, ToolFailureKind kind}) fixture
        in <({Object error, ToolFailureKind kind})>[
          (
            error: const AuthorizedEnvironmentBindingStale('stale'),
            kind: ToolFailureKind.staleBinding,
          ),
          (
            error: const AuthorizedEnvironmentBindingUnavailable('offline'),
            kind: ToolFailureKind.infrastructure,
          ),
          (
            error: StateError('transport'),
            kind: ToolFailureKind.infrastructure,
          ),
        ]) {
      test(
        'maps ${fixture.error.runtimeType} after output conservatively',
        () async {
          final ToolOutcome outcome = await _failureOutcome(fixture.error);

          expect(outcome.disposition, ToolOutcomeDisposition.failure);
          expect(outcome.failureKind, fixture.kind);
          expect(outcome.effectCertainty, EffectCertainty.uncertain);
          expect(outcome.hostData['stdout'], 'before failure');
        },
      );
    }

    test(
      'requires completion and does not manufacture a command result',
      () async {
        final _ProcessFacet process = _ProcessFacet(
          events: () => Stream<EnvironmentProcessEvent>.value(
            _output(EnvironmentProcessOutputStream.stdout, 'only output'),
          ),
        );
        final ToolOutcome outcome = (await _execute(
          await _tool(process),
          const <String, Object?>{'program': 'fixture'},
        )).outcome;

        expect(outcome.disposition, ToolOutcomeDisposition.failure);
        expect(outcome.failureKind, ToolFailureKind.infrastructure);
        expect(outcome.effectCertainty, EffectCertainty.uncertain);
        expect(outcome.hostData, isNot(contains('termination')));
        expect(outcome.hostData, isNot(contains('exitCode')));
      },
    );

    test(
      'rejects events after completion without projecting later output',
      () async {
        final _ProcessFacet process = _ProcessFacet(
          events: () => Stream<EnvironmentProcessEvent>.fromIterable(
            <EnvironmentProcessEvent>[
              _output(EnvironmentProcessOutputStream.stdout, 'before'),
              _completed(exitCode: 0),
              _output(EnvironmentProcessOutputStream.stderr, 'after'),
            ],
          ),
        );
        final ToolExecutionObservation observation = await _execute(
          await _tool(process),
          const <String, Object?>{'program': 'fixture'},
        );

        expect(observation.progress, hasLength(1));
        expect(observation.progress.single.content, 'before');
        expect(observation.outcome.disposition, ToolOutcomeDisposition.failure);
        expect(observation.outcome.failureKind, ToolFailureKind.infrastructure);
        expect(observation.outcome.effectCertainty, EffectCertainty.uncertain);
      },
    );

    test('requires exactly one completion event', () async {
      final _ProcessFacet process = _ProcessFacet(
        events: () => Stream<EnvironmentProcessEvent>.fromIterable(
          <EnvironmentProcessEvent>[
            _completed(exitCode: 0),
            _completed(exitCode: 0),
          ],
        ),
      );
      final ToolOutcome outcome = (await _execute(
        await _tool(process),
        const <String, Object?>{'program': 'fixture'},
      )).outcome;

      expect(outcome.disposition, ToolOutcomeDisposition.failure);
      expect(outcome.failureKind, ToolFailureKind.infrastructure);
      expect(outcome.effectCertainty, EffectCertainty.uncertain);
    });
  });

  group('policy gate', () {
    test(
      'ask delays the exact command until approval and executes once',
      () async {
        final _ProcessFacet process = _ProcessFacet();
        final MaterializedTool tool = await _tool(process);
        final ToolInvocation invocation = _resolveInvocation(
          tool,
          const <String, Object?>{'program': 'git'},
        );
        final ToolApprovalRequired required =
            await const ToolPolicyGate().evaluate(
                  invocation: invocation,
                  policy: const _DecisionPolicy(ToolPolicyDecision.ask),
                  interruptionId: RunInterruptionId('command-approval'),
                )
                as ToolApprovalRequired;
        final AgentRun run = AgentRun(
          id: RunId('run-command'),
          sessionId: SessionId('session-command'),
        )..start();

        run.interrupt(required.interruption);
        expect(run.state, RunState.waiting);
        expect(process.executions, 0);
        expect(required.invocation, same(invocation));
        expect(required.effects.effects, <ToolEffect>{
          ToolEffect.processExecution,
        });
        expect(required.effects.uncertainty, EffectUncertainty.uncertain);
        final ResolvedRunInterruption resolution = run.resolveInterruption(
          ToolApprovalResolution(
            interruptionId: required.interruption.id,
            toolInvocationId: invocation.id,
            approved: true,
          ),
        );
        final ToolExecutionAllowed allowed = const ToolPolicyGate().approve(
          resolution,
        );
        expect(allowed.invocation, same(invocation));
        final ToolExecutionStart start = run.startToolExecution(allowed);
        expect(process.executions, 0);

        final ToolExecutionObservation observation = await collectToolExecution(
          start.events(),
        );

        expect(process.executions, 1);
        expect(observation.outcome.disposition, ToolOutcomeDisposition.success);
        expect(invocation.canonicalArguments, <String, Object?>{
          'program': 'git',
          'arguments': <Object?>[],
          'workingDirectory': '',
          'timeoutSeconds': 120,
        });
      },
    );

    test('deny performs no Environment process call', () async {
      final _ProcessFacet process = _ProcessFacet();
      final MaterializedTool tool = await _tool(process);
      final ToolExecutionDenied denied =
          await const ToolPolicyGate().evaluate(
                invocation: _resolveInvocation(tool, const <String, Object?>{
                  'program': 'git',
                }),
                policy: const _DecisionPolicy(ToolPolicyDecision.deny),
                interruptionId: RunInterruptionId('unused-command-approval'),
              )
              as ToolExecutionDenied;

      expect(denied.outcome.disposition, ToolOutcomeDisposition.policyDenied);
      expect(denied.outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(process.executions, 0);
    });
  });
}

Future<MaterializedTool> _tool(_ProcessFacet process) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  final ExtensionRegistration activation = const CommandToolsPlugin().activate(
    extensions,
  );
  addTearDown(activation.close);
  return _materializedTool(extensions, process);
}

Future<MaterializedTool> _materializedTool(
  ExtensionRegistry extensions,
  _ProcessFacet process,
) async => (await ModelToolComposer(
  extensions,
).materialize(_Context(process))).materialize().tools.single;

CanonicalToolArguments _canonical(
  MaterializedTool tool,
  Map<String, Object?> arguments,
) => tool.executable.validateAndNormalize(arguments);

Future<ToolExecutionObservation> _execute(
  MaterializedTool tool,
  Map<String, Object?> arguments,
) => collectToolExecution(
  tool.executable.execute(_canonical(tool, arguments), _executionContext()),
);

ToolExecutionContext _executionContext() => ToolExecutionContext(
  runId: RunId('run-command'),
  sessionId: SessionId('session-command'),
);

ToolInvocation _resolveInvocation(
  MaterializedTool tool,
  Map<String, Object?> arguments,
) =>
    (const ToolInvocationResolver().resolve(
              invocationId: ToolInvocationId('tool-command'),
              proposal: ProviderToolProposal(
                providerCallId: 'provider-command',
                alias: 'run_command',
                arguments: arguments,
              ),
              tools: MaterializedToolSet(<MaterializedTool>[tool]),
              context: _executionContext(),
            )
            as ResolvedToolProposal)
        .invocation;

Future<ToolOutcome> _failureOutcome(Object error) async {
  final _ProcessFacet process = _ProcessFacet(
    events: () => _eventsThenError(error),
  );
  return (await _execute(await _tool(process), const <String, Object?>{
    'program': 'fixture',
  })).outcome;
}

Stream<EnvironmentProcessEvent> _eventsThenError(Object error) async* {
  yield _output(EnvironmentProcessOutputStream.stdout, 'before failure');
  throw error;
}

EnvironmentProcessEvent _output(
  EnvironmentProcessOutputStream stream,
  String text,
) => EnvironmentProcessEvent(
  kind: EnvironmentProcessEventKind.output,
  output: EnvironmentProcessOutput(stream: stream, text: text),
  completed: null,
);

EnvironmentProcessEvent _completed({
  EnvironmentProcessTermination termination =
      EnvironmentProcessTermination.exited,
  int? exitCode,
  bool stdoutTruncated = false,
  bool stderrTruncated = false,
}) => EnvironmentProcessEvent(
  kind: EnvironmentProcessEventKind.completed,
  output: null,
  completed: EnvironmentProcessCompleted(
    termination: termination,
    exitCode:
        exitCode ??
        (termination == EnvironmentProcessTermination.exited ? 0 : null),
    stdoutTruncated: stdoutTruncated,
    stderrTruncated: stderrTruncated,
  ),
);

final class _Context implements ModelToolHostContext {
  _Context(this.process);

  final _ProcessFacet process;
  final List<Type> requestedServices = <Type>[];

  @override
  SessionId get sessionId => SessionId('session-command');

  @override
  Future<T> requireHostService<T extends Object>() async {
    requestedServices.add(T);
    if (T == AuthorizedEnvironmentProcessFacet) return process as T;
    throw StateError('Unexpected host service request: $T.');
  }
}

final class _ProcessFacet implements AuthorizedEnvironmentProcessFacet {
  _ProcessFacet({this.events, SessionId? sessionId})
    : _sessionId = sessionId ?? SessionId('session-command');

  final Stream<EnvironmentProcessEvent> Function()? events;
  final SessionId _sessionId;
  final List<EnvironmentForegroundProcessRequest> requests =
      <EnvironmentForegroundProcessRequest>[];
  int executions = 0;
  Object? bindingFailure;

  @override
  SessionId get sessionId => _sessionId;

  @override
  EnvironmentId get environmentId => EnvironmentId('environment-command');

  @override
  void validateBinding() {
    final Object? failure = bindingFailure;
    if (failure is AuthorizedEnvironmentBindingStale) throw failure;
    if (failure is AuthorizedEnvironmentBindingUnavailable) throw failure;
  }

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) {
    executions++;
    requests.add(request);
    return events?.call() ??
        Stream<EnvironmentProcessEvent>.value(_completed(exitCode: 0));
  }
}

final class _DecisionPolicy implements ToolPolicy {
  const _DecisionPolicy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}
