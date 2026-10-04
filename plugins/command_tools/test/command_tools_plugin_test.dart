import 'dart:async';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

import 'support/command_storage.dart';

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
        await _canonical(tool, const <String, Object?>{'program': 'git'}),
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
      expect(
        tool.modelDefinition.description,
        allOf(
          contains('Prefer an available dedicated'),
          contains('absent or unsuitable'),
          contains('tool completion alone does not prove'),
        ),
      );
    });
  });

  group('argument validation', () {
    test('fills canonical defaults', () async {
      final MaterializedTool tool = await _tool(_ProcessFacet());

      expect(
        (await _canonical(tool, const <String, Object?>{
          'program': 'git',
        })).snapshot,
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
          await _canonical(tool, const <String, Object?>{
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
          (await _canonical(tool, <String, Object?>{
            'program': 'git',
            'workingDirectory': fixture.key,
          })).snapshot['workingDirectory'],
          fixture.value,
        );
      }
      for (final String invalid in const <String>[
        '../foo',
        'packages/../foo',
        '/absolute',
      ]) {
        await expectLater(
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
        await expectLater(
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
        await expectLater(
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
        final CanonicalToolArguments canonical = await _canonical(
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
          await _canonical(tool, const <String, Object?>{'program': 'git'}),
          ToolExecutionContext(
            runId: RunId('run-command'),
            sessionId: SessionId('another-session'),
            toolInvocationId: 'tool-command',
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

        expect(observation.progress, isEmpty);
        expect(observation.outcome.hostData['captureState'], 'complete');
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
            _completed(termination: EnvironmentProcessTermination.timedOut),
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
      expect(outcome.hostData['stderrTruncated'], isFalse);
      expect(outcome.hostData['captureState'], 'complete');
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
          events: () => Stream<EnvironmentProcessEvent>.fromIterable(
            <EnvironmentProcessEvent>[
              _output(EnvironmentProcessOutputStream.stdout, head),
              _output(EnvironmentProcessOutputStream.stdout, middle),
              _output(EnvironmentProcessOutputStream.stdout, tail),
              _output(EnvironmentProcessOutputStream.stderr, stderrText),
              _completed(exitCode: 0),
            ],
          ),
        );
        final MaterializedTool tool = await _tool(process);

        final observation = await _execute(tool, const <String, Object?>{
          'program': 'verbose',
        });
        final outcome = observation.outcome;

        expect(observation.progress, isEmpty);
        expect(outcome.hostData['captureState'], 'complete');
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
            _output(EnvironmentProcessOutputStream.stdout, prefix),
            _output(EnvironmentProcessOutputStream.stdout, '\u{1f600}'),
            _output(EnvironmentProcessOutputStream.stdout, suffix),
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
      expect(outcome.hostData, containsPair('captureState', 'complete'));
      expect(outcome.hostData, containsPair('stdout', ''));
      expect(outcome.hostData, containsPair('stderr', ''));
      expect(process.requests.single.program, 'git');
      expect(process.requests.single.arguments, <String>['status', '--short']);
      expect(process.requests.single.relativeWorkingDirectory, 'packages/foo');
    });
  });

  group('stream failures', () {
    test(
      'provider truncation is incomplete capture, not a successful preview',
      () async {
        final process = _ProcessFacet(
          events: () => Stream.fromIterable([
            _output(EnvironmentProcessOutputStream.stdout, 'delivered'),
            _completed(exitCode: 17, stdoutTruncated: true),
          ]),
        );
        final observation = await _execute(await _tool(process), {
          'program': 'fixture',
        });
        expect(observation.progress, isEmpty);
        expect(observation.outcome.disposition, ToolOutcomeDisposition.failure);
        expect(observation.outcome.effectCertainty, EffectCertainty.uncertain);
        expect(observation.outcome.failureKind, ToolFailureKind.infrastructure);
        expect(observation.outcome.hostData['captureState'], 'failed');
        expect(observation.outcome.hostData['termination'], 'exited');
        expect(observation.outcome.hostData['exitCode'], 17);
        expect(observation.outcome.hostData['stdoutTruncated'], isTrue);
        expect(observation.outcome.hostData['stderrTruncated'], isFalse);
      },
    );

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

        expect(observation.progress, isEmpty);
        expect(observation.outcome.hostData['stdout'], 'before');
        expect(observation.outcome.hostData['stderr'], '');
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
        final ToolInvocation invocation = await _resolveInvocation(
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
                invocation: await _resolveInvocation(
                  tool,
                  const <String, Object?>{'program': 'git'},
                ),
                policy: const _DecisionPolicy(ToolPolicyDecision.deny),
                interruptionId: RunInterruptionId('unused-command-approval'),
              )
              as ToolExecutionDenied;

      expect(denied.outcome.disposition, ToolOutcomeDisposition.policyDenied);
      expect(denied.outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(process.executions, 0);
    });
  });

  group('capture lifecycle', () {
    late CommandTestStorage storage;
    late CommandTranscriptStore transcripts;
    setUp(() {
      storage = CommandTestStorage();
      transcripts = CommandTranscriptStore(storage);
    });
    tearDown(() async {
      await transcripts.close();
      storage.close();
    });

    Future<void> checkFailureFacts({
      required Object? termination,
      required Object? exitCode,
      required (String?, int?) expected,
      EnvironmentProcessEvent? completion,
      bool outputIncomplete = true,
    }) async {
      final failure = EnvironmentFailure(
        code: 'original_provider_failure',
        message: 'Original provider failure.',
        details: {
          'outputIncomplete': outputIncomplete,
          'termination': termination,
          'exitCode': exitCode,
        },
      );
      Stream<EnvironmentProcessEvent> events() async* {
        yield _output(
          EnvironmentProcessOutputStream.stdout,
          'committed prefix',
        );
        if (completion != null) yield completion;
        throw failure;
      }

      final process = _ProcessFacet(events: events);
      final tool = await _tool(process, transcripts: transcripts);
      final result = await tool.executable
          .execute(
            await _canonical(tool, {'program': 'fixture'}),
            _executionContext(),
          )
          .toList()
          .timeout(const Duration(seconds: 2));
      expect(result, hasLength(1));
      final outcome = (result.single as ToolExecutionTerminal).outcome;
      expect(outcome.disposition, ToolOutcomeDisposition.failure);
      expect(outcome.effectCertainty, EffectCertainty.uncertain);
      expect(
        outcome.failureKind,
        outputIncomplete
            ? ToolFailureKind.infrastructure
            : ToolFailureKind.domain,
      );
      expect(outcome.hostData['code'], 'original_provider_failure');
      expect(outcome.hostDiagnostic, contains('original_provider_failure'));
      expect(outcome.cause, same(failure));
      expect(outcome.hostData['details'], {
        'outputIncomplete': outputIncomplete,
      });
      expect(outcome.hostData['stdout'], 'committed prefix');
      expect((
        outcome.hostData['termination'],
        outcome.hostData['exitCode'],
      ), expected);
      expect(process.executions, 1);
      expect(transcripts.activeCaptureCount, 0);
      expect(transcripts.uncertainCaptureCount, 0);
      expect(storage.transactionKinds, ['setup', 'append', 'failed']);

      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      for (final reader in [transcripts, fresh]) {
        final state = await reader.getState(
          'session-command',
          'run-command',
          'tool-command',
        );
        expect(state.state, 'failed');
        expect(state.highWater, 1);
        expect((state.termination, state.exitCode), expected);
        final page = await reader.readAfter(
          'session-command',
          'run-command',
          'tool-command',
          0,
          16,
          65536,
        );
        expect(page.chunks.single.text, 'committed prefix');
        final watched = await reader
            .watch('session-command', 'run-command', 'tool-command')
            .first
            .timeout(const Duration(seconds: 2));
        expect((watched.state, watched.highWater), ('failed', 1));
        expect((watched.termination, watched.exitCode), expected);
      }
    }

    for (final fixture in <(String, Object?, Object?, (String?, int?))>[
      ('non-string termination', 7, 23, (null, null)),
      ('unstructured termination', Object(), 23, (null, null)),
      ('non-integer exitCode', 'exited', '23', (null, null)),
      ('floating-point exitCode', 'exited', 23.0, (null, null)),
      ('unstructured exitCode', 'exited', Object(), (null, null)),
      ('unknown termination', 'cancelled', 23, (null, null)),
      ('exited without exitCode', 'exited', null, (null, null)),
      ('timedOut with exitCode', 'timedOut', 0, (null, null)),
      ('exitCode without termination', null, 23, (null, null)),
      ('absent outcome', null, null, (null, null)),
      ('valid exited zero', 'exited', 0, ('exited', 0)),
      ('valid exited nonzero', 'exited', 23, ('exited', 23)),
      ('valid timedOut', 'timedOut', null, ('timedOut', null)),
    ]) {
      test(
        'provider outcome facts: ${fixture.$1} keep failed capture readable',
        () => checkFailureFacts(
          termination: fixture.$2,
          exitCode: fixture.$3,
          expected: fixture.$4,
        ),
      );
    }

    test(
      'malformed optional facts preserve the original domain failure',
      () => checkFailureFacts(
        termination: false,
        exitCode: 'invalid',
        expected: (null, null),
        outputIncomplete: false,
      ),
    );

    for (final termination in EnvironmentProcessTermination.values) {
      for (final malformedDetails in [false, true]) {
        test(
          'typed ${termination.name} outcome takes precedence over ${malformedDetails ? 'malformed' : 'conflicting'} diagnostics',
          () => checkFailureFacts(
            termination: malformedDetails ? 7 : 'exited',
            exitCode: malformedDetails ? 'wrong' : 99,
            completion: _completed(
              termination: termination,
              exitCode: termination == EnvironmentProcessTermination.exited
                  ? 23
                  : null,
            ),
            expected: (
              termination.name,
              termination == EnvironmentProcessTermination.exited ? 23 : null,
            ),
          ),
        );
      }
    }

    test('missing storage rejects execution before any process call', () async {
      final process = _ProcessFacet();
      final executable = commandToolRegistration(process).executable;
      final arguments = await executable.validateAndNormalize({
        'program': 'fixture',
      });
      await executable.describe(arguments, _executionContext());
      final observation = await collectToolExecution(
        executable.execute(arguments, _executionContext()),
      );
      expect(observation.progress, isEmpty);
      expect(observation.outcome.disposition, ToolOutcomeDisposition.failure);
      expect(observation.outcome.failureKind, ToolFailureKind.infrastructure);
      expect(
        observation.outcome.effectCertainty,
        EffectCertainty.knownNotOccurred,
      );
      expect(process.executions, 0);
    });

    test(
      'reused invocation cannot launch twice or change the original completion',
      () async {
        final process = _ProcessFacet();
        final tool = await _tool(process, transcripts: transcripts);
        final first = await _execute(tool, {'program': 'fixture'});
        final duplicate = await _execute(tool, {
          'program': 'different-program',
        });
        expect(first.outcome.disposition, ToolOutcomeDisposition.success);
        expect(duplicate.outcome.disposition, ToolOutcomeDisposition.failure);
        expect(
          duplicate.outcome.effectCertainty,
          EffectCertainty.knownNotOccurred,
        );
        expect(process.executions, 1);
        final state = await transcripts.getState(
          'session-command',
          'run-command',
          'tool-command',
        );
        expect(state.state, 'complete');
        expect(state.program, 'fixture');
      },
    );

    test(
      'unreadable oversized metadata is rejected before command execution',
      () async {
        final process = _ProcessFacet();
        final tool = await _tool(process, transcripts: transcripts);
        final observation = await _execute(tool, {
          'program': 'fixture',
          'arguments': ['x' * (128 * 1024)],
        });
        expect(observation.outcome.disposition, ToolOutcomeDisposition.failure);
        expect(
          observation.outcome.effectCertainty,
          EffectCertainty.knownNotOccurred,
        );
        expect(process.executions, 0);
        expect(storage.transactions, 0);
        expect(transcripts.activeCaptureCount, 0);
      },
    );

    test(
      'tiny text is readable while process waits and no raw progress escapes',
      () async {
        final committed = Completer<void>();
        storage.afterCommit = (statements) {
          if (CommandTestStorage.kindOf(statements) == 'append') {
            committed.complete();
          }
        };
        final producer = StreamController<EnvironmentProcessEvent>();
        addTearDown(producer.close);
        final process = _ProcessFacet(events: () => producer.stream);
        final tool = await _tool(process, transcripts: transcripts);
        final events = <ToolExecutionEvent>[];
        final done = Completer<void>();
        final subscription = tool.executable
            .execute(
              await _canonical(tool, {'program': 'fixture'}),
              _executionContext(),
            )
            .listen(events.add, onDone: done.complete);
        addTearDown(subscription.cancel);
        producer.add(
          _output(EnvironmentProcessOutputStream.stdout, 'waiting\n'),
        );
        await committed.future.timeout(const Duration(seconds: 2));
        final page = await transcripts.readAfter(
          'session-command',
          'run-command',
          'tool-command',
          0,
          16,
          65536,
        );
        expect(page.chunks.single.text, 'waiting\n');
        expect(page.state.state, 'capturing');
        expect(events, isEmpty);
        producer.add(_completed());
        await producer.close();
        await done.future;
        expect(events, hasLength(1));
        expect(
          (events.single as ToolExecutionTerminal)
              .outcome
              .hostData['captureState'],
          'complete',
        );
      },
    );

    test(
      'silent producer is cancelled without waiting for another output',
      () async {
        final listening = Completer<void>();
        final cancelled = Completer<void>();
        final producer = StreamController<EnvironmentProcessEvent>(
          onListen: listening.complete,
          onCancel: cancelled.complete,
        );
        addTearDown(producer.close);
        final process = _ProcessFacet(events: () => producer.stream);
        final tool = await _tool(process, transcripts: transcripts);
        final events = <ToolExecutionEvent>[];
        final subscription = tool.executable
            .execute(
              await _canonical(tool, {'program': 'fixture'}),
              _executionContext(),
            )
            .listen(events.add);
        await listening.future;
        await subscription.cancel().timeout(const Duration(seconds: 2));
        await cancelled.future.timeout(const Duration(seconds: 2));
        expect(events, isEmpty);
        expect(process.executions, 1);
        expect(transcripts.activeCaptureCount, 0);
        expect(
          (await transcripts.getState(
            'session-command',
            'run-command',
            'tool-command',
          )).state,
          'failed',
        );
      },
    );

    test('cancelling during capture setup never launches a producer', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.beforeTransaction = (statements) async {
        if (CommandTestStorage.kindOf(statements) == 'setup') {
          entered.complete();
          await release.future;
        }
      };
      final process = _ProcessFacet();
      final tool = await _tool(process, transcripts: transcripts);
      final events = <ToolExecutionEvent>[];
      final subscription = tool.executable
          .execute(
            await _canonical(tool, {'program': 'fixture'}),
            _executionContext(),
          )
          .listen(events.add);
      await entered.future;
      final cancellation = subscription.cancel();
      release.complete();
      await cancellation.timeout(const Duration(seconds: 2));
      expect(process.executions, 0);
      expect(events, isEmpty);
      expect(transcripts.activeCaptureCount, 0);
    });

    test(
      'store close cancels a real silent producer despite paused observation',
      () async {
        final listening = Completer<void>();
        final cancelled = Completer<void>();
        final producer = StreamController<EnvironmentProcessEvent>(
          onListen: listening.complete,
          onCancel: cancelled.complete,
        );
        addTearDown(producer.close);
        final tool = await _tool(
          _ProcessFacet(events: () => producer.stream),
          transcripts: transcripts,
        );
        final execution = _execute(tool, {'program': 'fixture'});
        await listening.future;
        final observer = StreamIterator(
          transcripts.watch('session-command', 'run-command', 'tool-command'),
        );
        expect(await observer.moveNext(), isTrue);
        await transcripts.close().timeout(const Duration(seconds: 2));
        await cancelled.future.timeout(const Duration(seconds: 2));
        final observation = await execution.timeout(const Duration(seconds: 2));
        expect(observation.progress, isEmpty);
        expect(observation.outcome.disposition, ToolOutcomeDisposition.failure);
        expect(observation.outcome.effectCertainty, EffectCertainty.uncertain);
        expect(transcripts.activeCaptureCount, 0);
        expect(transcripts.observerCount, 0);
        expect(await observer.moveNext(), isFalse);
        await observer.cancel();
      },
    );

    for (final appendFailure in [true, false]) {
      test(
        '${appendFailure ? 'append failure' : 'post-completion protocol failure'} survives throwing producer cleanup',
        () async {
          final primary = StateError('primary append failure');
          if (appendFailure) {
            storage.beforeTransaction = (statements) {
              if (CommandTestStorage.kindOf(statements) == 'append') {
                throw primary;
              }
            };
          }
          var cancellations = 0;
          final producer = StreamController<EnvironmentProcessEvent>(
            onCancel: () async {
              cancellations++;
              throw StateError('secondary cancellation failure');
            },
          );
          addTearDown(producer.close);
          producer.add(
            _output(
              EnvironmentProcessOutputStream.stdout,
              'known partial text',
            ),
          );
          if (!appendFailure) {
            producer.add(_completed(exitCode: 23));
            producer.add(
              _output(
                EnvironmentProcessOutputStream.stderr,
                'forbidden after completion',
              ),
            );
          }
          final tool = await _tool(
            _ProcessFacet(events: () => producer.stream),
            transcripts: transcripts,
          );
          final observation = await _execute(tool, {
            'program': 'fixture',
          }).timeout(const Duration(seconds: 2));
          final outcome = observation.outcome;
          expect(observation.progress, isEmpty);
          expect(outcome.disposition, ToolOutcomeDisposition.failure);
          expect(outcome.failureKind, ToolFailureKind.infrastructure);
          expect(outcome.effectCertainty, EffectCertainty.uncertain);
          expect(outcome.hostData['stdout'], 'known partial text');
          expect(outcome.hostData['stderr'], '');
          expect(outcome.hostData['cleanupFailed'], isTrue);
          expect(
            outcome.hostDiagnostic,
            isNot(contains('secondary cancellation failure')),
          );
          expect(cancellations, 1);
          expect(transcripts.activeCaptureCount, 0);
          expect(transcripts.pendingBatchChunks, 0);
          final state = await transcripts.getState(
            'session-command',
            'run-command',
            'tool-command',
          );
          expect(state.state, 'failed');
          if (appendFailure) {
            expect(outcome.cause, same(primary));
            expect(state.highWater, 0);
          } else {
            expect(outcome.hostDiagnostic, contains('after completion'));
            expect(outcome.hostData['termination'], 'exited');
            expect(outcome.hostData['exitCode'], 23);
            expect(
              (state.highWater, state.termination, state.exitCode),
              (1, 'exited', 23),
            );
          }
        },
      );
    }

    for (final phase in ['setup', 'append', 'complete']) {
      for (final lostAck in [false, true]) {
        test(
          '$phase ${lostAck ? 'lost ack' : 'failure'} yields one conservative outcome without execution retry',
          () async {
            var injected = 0;
            void inject(List<RelationalStatement> statements) {
              if (CommandTestStorage.kindOf(statements) == phase) {
                injected++;
                throw StateError('injected $phase');
              }
            }

            if (lostAck) {
              storage.afterCommit = inject;
            } else {
              storage.beforeTransaction = inject;
            }
            var settled = 0;
            Stream<EnvironmentProcessEvent> events() async* {
              try {
                yield _output(EnvironmentProcessOutputStream.stdout, 'partial');
                yield _completed(exitCode: 23);
              } finally {
                settled++;
              }
            }

            final process = _ProcessFacet(events: events);
            final tool = await _tool(process, transcripts: transcripts);
            final observation = await _execute(tool, {'program': 'fixture'});
            expect(observation.progress, isEmpty);
            final outcome = observation.outcome;
            expect(outcome.disposition, ToolOutcomeDisposition.failure);
            expect(outcome.failureKind, ToolFailureKind.infrastructure);
            expect(
              outcome.effectCertainty,
              phase == 'setup'
                  ? EffectCertainty.knownNotOccurred
                  : EffectCertainty.uncertain,
            );
            expect(outcome.hostData['captureState'], 'failed');
            expect(process.executions, phase == 'setup' ? 0 : 1);
            expect(settled, phase == 'setup' ? 0 : 1);
            expect(injected, 1);
            if (phase == 'complete') {
              expect(outcome.hostData['termination'], 'exited');
              expect(outcome.hostData['exitCode'], 23);
            }
            expect(transcripts.activeCaptureCount, 0);
            expect(transcripts.pendingBatchChunks, 0);
          },
        );
      }
    }

    test(
      'provider incomplete output retains exit facts but cannot report capture complete',
      () async {
        final process = _ProcessFacet(
          events: () => _eventsThenError(
            const EnvironmentFailure(
              code: 'process_output_incomplete',
              message: 'Drain incomplete.',
              details: {
                'outputIncomplete': true,
                'termination': 'exited',
                'exitCode': 23,
              },
            ),
          ),
        );
        final observation = await _execute(
          await _tool(process, transcripts: transcripts),
          {'program': 'fixture'},
        );
        expect(observation.progress, isEmpty);
        expect(observation.outcome.failureKind, ToolFailureKind.infrastructure);
        expect(observation.outcome.effectCertainty, EffectCertainty.uncertain);
        expect(observation.outcome.hostData['captureState'], 'failed');
        expect(observation.outcome.hostData['exitCode'], 23);
        final state = await transcripts.getState(
          'session-command',
          'run-command',
          'tool-command',
        );
        expect(
          (state.state, state.termination, state.exitCode),
          ('failed', 'exited', 23),
        );
      },
    );
  });
}

Future<MaterializedTool> _tool(
  _ProcessFacet process, {
  CommandTranscriptStore? transcripts,
}) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  if (transcripts == null) {
    final storage = CommandTestStorage();
    final owned = CommandTranscriptStore(storage);
    transcripts = owned;
    addTearDown(() async {
      await owned.close();
      storage.close();
    });
  }
  final ExtensionRegistration activation = CommandToolsPlugin(
    transcripts: transcripts,
  ).activate(extensions);
  addTearDown(activation.close);
  return _materializedTool(extensions, process);
}

Future<MaterializedTool> _materializedTool(
  ExtensionRegistry extensions,
  _ProcessFacet process,
) async => (await ModelToolComposer(
  extensions,
).materialize(_Context(process))).materialize().tools.single;

FutureOr<CanonicalToolArguments> _canonical(
  MaterializedTool tool,
  Map<String, Object?> arguments,
) => tool.executable.validateAndNormalize(arguments);

Future<ToolExecutionObservation> _execute(
  MaterializedTool tool,
  Map<String, Object?> arguments,
) async => collectToolExecution(
  tool.executable.execute(
    await _canonical(tool, arguments),
    _executionContext(),
  ),
);

ToolExecutionContext _executionContext() => ToolExecutionContext(
  runId: RunId('run-command'),
  sessionId: SessionId('session-command'),
  toolInvocationId: 'tool-command',
);

Future<ToolInvocation> _resolveInvocation(
  MaterializedTool tool,
  Map<String, Object?> arguments,
) async =>
    (await const ToolInvocationResolver().resolve(
              invocationId: ToolInvocationId('tool-command'),
              proposal: ProviderToolProposal(
                providerCallId: 'provider-command',
                alias: 'run_command',
                arguments: arguments,
              ),
              tools: MaterializedToolSet(<MaterializedTool>[tool]),
              runId: RunId('run-command'),
              sessionId: SessionId('session-command'),
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
