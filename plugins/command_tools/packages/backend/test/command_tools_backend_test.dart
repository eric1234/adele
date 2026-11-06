import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_product/adele_product.dart';
import 'package:command_tools_backend/command_tools_backend.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

import '../../../test/support/command_storage.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  test(
    'descriptor reuses root identity, alias, schema and process-only dependency',
    () async {
      fixture.host.close();
      final local = commandToolRegistration(_NoEffects());
      final descriptor = (await fixture.client.materialize(
        RemoteModelToolMaterialization(
          sessionId: 'session',
          environmentId: null,
          shellProfile: null,
        ),
      )).single;
      expect(descriptor.routeId, runCommandToolId.value);
      expect(descriptor.toolId, 'dev.adele.plugin.command-tools.run-command');
      expect(descriptor.modelAlias, 'run_command');
      expect(descriptor.toolDescription, local.definition.description);
      expect(descriptor.modelDescription, local.modelDefinition.description);
      expect(descriptor.argumentsSchema, local.modelDefinition.argumentsSchema);
      expect(descriptor.executionHostServices, [
        authorizedEnvironmentProcessServiceId,
      ]);
      expect(fixture.messages, isEmpty);
    },
  );

  test('search materializes one separate authority-free descriptor', () async {
    fixture.host.close();
    final local = searchCommandOutputToolRegistration(fixture.search);
    final materialization = RemoteModelToolMaterialization(
      sessionId: 'session',
      environmentId: null,
      shellProfile: null,
    );
    final run = (await fixture.client.materialize(materialization)).single;
    final search = (await fixture.searchClient.materialize(
      materialization,
    )).single;
    expect(search.toolId, searchCommandOutputToolId.value);
    expect(search.routeId, searchCommandOutputToolId.value);
    expect(search.routeId, isNot(run.routeId));
    expect(search.modelAlias, 'search_command_output');
    expect(search.toolDescription, local.definition.description);
    expect(search.modelDescription, local.modelDefinition.description);
    expect(search.argumentsSchema, local.modelDefinition.argumentsSchema);
    expect(search.executionHostServices, isEmpty);
    expect(fixture.storage.schemaChecks, 0);
    expect(fixture.storage.queries, 0);
    expect(fixture.messages, isEmpty);
  });

  test(
    'search validation and description need no Environment or host token',
    () async {
      fixture.host.close();
      final local = searchCommandOutputToolRegistration(
        fixture.search,
      ).executable;
      final expected = await local.validateAndNormalize(_searchProposed);
      final arguments = await fixture.searchClient.validateAndNormalize(
        searchCommandOutputToolId.value,
        _searchProposed,
      );
      expect(arguments.snapshot, expected.snapshot);
      final expectedDescription = await local.describe(
        expected,
        ToolExecutionContext(
          sessionId: SessionId('session'),
          runId: RunId('current-run'),
          toolInvocationId: 'current-search',
        ),
      );
      final description = await fixture.searchClient.describe(
        searchCommandOutputToolId.value,
        arguments,
        'session',
        'current-run',
        'current-search',
        null,
      );
      expect(description.effects, [RemoteToolEffect.resourceInspection]);
      expect(description.uncertainty, RemoteEffectUncertainty.none);
      expect(description.summary, expectedDescription.summary);
      expect(
        description.targetUris,
        expectedDescription.targets.map((target) => target.uri),
      );
      for (final invalid in <Map<String, Object?>>[
        {},
        {..._searchProposed, 'sessionId': 'other'},
        {..._searchProposed, 'environmentId': 'forged'},
        {..._searchProposed, 'program': 'git'},
        {..._searchProposed, 'pattern': '['},
        {..._searchProposed, 'maxMatches': 11},
      ]) {
        await expectLater(
          fixture.searchClient.validateAndNormalize(
            searchCommandOutputToolId.value,
            invalid,
          ),
          throwsA(
            isA<RemoteToolArgumentValidationFailure>().having(
              (error) => error.code,
              'code',
              'invalid_arguments',
            ),
          ),
        );
      }
      expect(fixture.storage.schemaChecks, 0);
      expect(fixture.storage.queries, 0);
      expect(fixture.messages, isEmpty);
    },
  );

  test('search adapters reject the sibling route without fallback', () async {
    for (final (client, rejected) in [
      (fixture.client, searchCommandOutputToolId.value),
      (fixture.searchClient, runCommandToolId.value),
      (fixture.searchClient, 'search_command_output'),
    ]) {
      await expectLater(
        client.validateAndNormalize(rejected, _searchProposed),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having((error) => error.declaredFailureType, 'type', isNull),
        ),
      );
      final arguments = RemoteCanonicalToolArguments(snapshot: _searchProposed);
      await expectLater(
        client.describe(rejected, arguments, 'session', 'run', 'search', null),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      await expectLater(
        client
            .execute(
              rejected,
              arguments,
              'session',
              'run',
              'search',
              null,
              null,
            )
            .toList(),
        throwsA(isA<AdeleRemoteFailure>()),
      );
    }
    expect(fixture.storage.schemaChecks, 0);
    expect(fixture.messages, isEmpty);
  });

  test(
    'search uses the executing Session and retained candidate IDs without process authority',
    () async {
      await fixture.seedSearchCapture();
      fixture.host.close();
      final writes = fixture.storage.transactions;
      final arguments = await fixture.searchClient.validateAndNormalize(
        searchCommandOutputToolId.value,
        _searchProposed,
      );
      final events = await fixture.searchClient
          .execute(
            searchCommandOutputToolId.value,
            arguments,
            'session',
            'later-run',
            'search-invocation',
            null,
            null,
          )
          .toList();
      expect(events.map((event) => event.kind), [
        RemoteToolExecutionEventKind.terminal,
      ]);
      final outcome = events.single.outcome!;
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.modelContent, contains('hit one'));
      expect(outcome.modelContent, contains('hit two'));
      final wrongSession = await fixture.searchClient
          .execute(
            searchCommandOutputToolId.value,
            arguments,
            'other',
            'later-run',
            'search-invocation',
            null,
            null,
          )
          .single;
      expect(
        wrongSession.outcome!.disposition,
        RemoteToolOutcomeDisposition.failure,
      );
      expect(wrongSession.outcome!.modelContent, isNot(contains('hit one')));
      expect(fixture.storage.transactions, writes);
      expect(fixture.process.settled, 0);
      expect(fixture.messages, isEmpty);
    },
  );

  test(
    'one generation retains continuation across distinct tool invocations',
    () async {
      await fixture.seedSearchCapture();
      final writes = fixture.storage.transactions;
      final firstArguments = await fixture.searchClient.validateAndNormalize(
        searchCommandOutputToolId.value,
        {..._searchProposed, 'maxMatches': 1},
      );
      Future<RemoteToolOutcome> execute(
        RemoteModelToolServiceClient client,
        RemoteCanonicalToolArguments arguments,
        String invocation,
      ) async =>
          (await client
                  .execute(
                    searchCommandOutputToolId.value,
                    arguments,
                    'session',
                    'later-run',
                    invocation,
                    null,
                    null,
                  )
                  .single)
              .outcome!;
      final first = await execute(
        fixture.searchClient,
        firstArguments,
        'search-one',
      );
      expect(first.disposition, RemoteToolOutcomeDisposition.success);
      final firstResult = jsonDecode(first.modelContent) as Map;
      final cursor = firstResult['cursor']! as String;
      expect(firstResult['lines'], hasLength(1));
      expect((firstResult['lines'] as List).single['text'], 'hit one');
      final nextArguments = await fixture.searchClient.validateAndNormalize(
        searchCommandOutputToolId.value,
        {...firstArguments.snapshot, 'cursor': cursor},
      );
      await fixture.searchClient.materialize(
        RemoteModelToolMaterialization(
          sessionId: 'session',
          environmentId: null,
          shellProfile: null,
        ),
      );
      final next = await execute(
        fixture.searchClient,
        nextArguments,
        'search-two',
      );
      expect(next.disposition, RemoteToolOutcomeDisposition.success);
      final nextResult = jsonDecode(next.modelContent) as Map;
      expect((nextResult['lines'] as List).single['text'], 'hit two');

      final replacement = RemoteModelToolServiceDispatcher(
        CommandOutputSearchBackend(CommandOutputSearch(fixture.transcripts)),
      );
      addTearDown(replacement.close);
      final replacementClient = RemoteModelToolServiceClient(
        _Channel(replacement),
      );
      final reads = fixture.storage.queries;
      final invalidated = await execute(
        replacementClient,
        nextArguments,
        'search-three',
      );
      expect(invalidated.disposition, RemoteToolOutcomeDisposition.failure);
      expect(invalidated.hostData['code'], 'invalid_search_cursor');
      expect(fixture.storage.queries, reads);
      final fresh = await execute(
        replacementClient,
        firstArguments,
        'search-four',
      );
      expect(fresh.disposition, RemoteToolOutcomeDisposition.success);
      expect(
        (jsonDecode(fresh.modelContent)['lines'] as List).single['text'],
        'hit one',
      );
      expect(fixture.storage.transactions, writes);
      expect(fixture.process.settled, 0);
      expect(fixture.messages, isEmpty);
    },
  );

  test(
    'validation and identity-only description exactly reuse root semantics',
    () async {
      fixture.host.close();
      for (final environment in ['environment-one', 'environment-two']) {
        final facet = _NoEffects(environment);
        final local = commandToolRegistration(facet).executable;
        final canonical = await local.validateAndNormalize(_proposed);
        final arguments = await fixture.client.validateAndNormalize(
          runCommandToolId.value,
          _proposed,
        );
        expect(arguments.snapshot, canonical.snapshot);
        expect(arguments.snapshot, {
          'program': 'git',
          'arguments': ['diff', '--check', 'literal | argument'],
          'workingDirectory': 'src',
          'timeoutSeconds': 120,
        });
        final description = await local.describe(
          canonical,
          ToolExecutionContext(
            sessionId: facet.sessionId,
            runId: RunId('run'),
            toolInvocationId: 'invocation',
          ),
        );
        final remote = await fixture.client.describe(
          runCommandToolId.value,
          arguments,
          'session',
          'run',
          'invocation',
          environment,
        );
        expect(remote.effects, [RemoteToolEffect.processExecution]);
        expect(remote.targetUris, [
          Uri.parse('adele-environment:/$environment/'),
        ]);
        expect(remote.summary, description.summary);
        expect(remote.uncertainty, RemoteEffectUncertainty.uncertain);
      }
      for (final timeout in [601, 1800]) {
        final arguments = await fixture.client.validateAndNormalize(
          runCommandToolId.value,
          {..._proposed, 'timeoutSeconds': timeout},
        );
        expect(arguments.snapshot['timeoutSeconds'], timeout);
      }
      for (final invalid in <Map<String, Object?>>[
        {},
        {..._proposed, 'environmentId': 'forged'},
        {..._proposed, 'timeoutSeconds': 1801},
        {..._proposed, 'workingDirectory': '../outside'},
        {
          ..._proposed,
          'arguments': [1],
        },
      ]) {
        await expectLater(
          fixture.client.validateAndNormalize(runCommandToolId.value, invalid),
          throwsA(
            isA<RemoteToolArgumentValidationFailure>().having(
              (error) => error.code,
              'code',
              'invalid_arguments',
            ),
          ),
        );
      }
      expect(fixture.messages, isEmpty);
    },
  );

  test(
    'operation-bound process emits only bounded terminal outcome and captures output',
    () async {
      final events = await fixture.execute();
      expect(events.map((event) => event.kind), [
        RemoteToolExecutionEventKind.terminal,
      ]);
      expect(events.where((event) => event.progress != null), isEmpty);
      final outcome = events.last.outcome!;
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, RemoteEffectCertainty.knownOccurred);
      expect(outcome.hostData, {
        'runId': 'run-data',
        'toolInvocationId': 'invocation-1',
        'environmentId': 'environment-data',
        'program': 'git',
        'arguments': ['diff', '--check', 'literal | argument'],
        'workingDirectory': 'src',
        'timeoutSeconds': 120,
        'stdout': 'out\n',
        'stderr': 'err\n',
        'termination': 'exited',
        'exitCode': 7,
        'captureState': 'complete',
        'stdoutTruncated': false,
        'stderrTruncated': false,
      });
      expect(outcome.modelContent, contains('Exit code: 7'));
      expect(outcome.toLocal().cause, isNull);
      final page = await fixture.transcripts.readAfter(
        'session-data',
        'run-data',
        'invocation-1',
        0,
        16,
        65536,
      );
      expect(page.state.state, 'complete');
      expect(page.chunks.map((chunk) => (chunk.stream, chunk.text)), [
        ('stdout', 'out\n'),
        ('stderr', 'err\n'),
      ]);
      final open = fixture.messages.singleWhere(
        (message) => message['kind'] == 'hostStreamOpen',
      );
      expect(open, {
        'kind': 'hostStreamOpen',
        'requestId': isA<int>(),
        'hostContextKind': 'invocation',
        'hostContext': 'operation',
        'serviceId': authorizedEnvironmentProcessServiceId,
        'method': authorizedEnvironmentProcessServiceRunForegroundProcessId,
        'payload': {
          'request': {
            'program': 'git',
            'arguments': ['diff', '--check', 'literal | argument'],
            'relativeWorkingDirectory': 'src',
            'timeoutSeconds': 120,
          },
        },
      });
    },
  );

  test(
    'interleaved materializations retain their exact shell descriptions',
    () async {
      final bash = await fixture.materializeShell(
        'bash-selection',
        '/bin/bash',
        'bash',
      );
      final powershell = await fixture.materializeShell(
        'pwsh-selection',
        'PowerShell',
        'powershell',
      );
      final direct = (await fixture.client.materialize(
        RemoteModelToolMaterialization(
          sessionId: 'direct-session',
          environmentId: 'direct-environment',
          shellProfile: null,
        ),
      )).single;
      expect({bash.routeId, powershell.routeId, direct.routeId}, hasLength(3));
      expect(bash.toolId, direct.toolId);
      expect(bash.modelAlias, 'run_command');
      expect(bash.modelDescription, contains('/bin/bash'));
      expect(powershell.modelDescription, contains('powershell'));
      expect(bash.argumentsSchema, isNot(contains('oneOf')));
      expect(bash.argumentsSchema, isNot(contains('anyOf')));
      expect(bash.argumentsSchema['properties'], contains('shellCommand'));
      expect(
        direct.argumentsSchema['properties'],
        isNot(contains('shellCommand')),
      );
      expect(bash.executionHostServices, [
        authorizedEnvironmentProcessServiceId,
        authorizedEnvironmentShellServiceId,
      ]);
      const script = '  printf "%s\\n" "quoted | text"\nprintf second\n';
      for (final descriptor in [powershell, bash, powershell, bash]) {
        final arguments = await fixture.client.validateAndNormalize(
          descriptor.routeId,
          {'shellCommand': script, 'workingDirectory': './src//.'},
        );
        expect(arguments.snapshot, {
          'shellCommand': script,
          'workingDirectory': 'src',
          'timeoutSeconds': 120,
        });
        final description = await fixture.client.describe(
          descriptor.routeId,
          arguments,
          'session',
          'run',
          'invocation',
          'environment',
        );
        expect(description.effects, [RemoteToolEffect.processExecution]);
        expect(description.uncertainty, RemoteEffectUncertainty.uncertain);
        expect(description.targetUris, [
          Uri.parse('adele-environment:/environment/'),
        ]);
        expect(
          description.summary,
          contains(descriptor == bash ? '/bin/bash' : 'PowerShell'),
        );
        expect(description.summary, isNot(contains('\n')));
        expect(description.summary, isNot(contains(script)));
      }
      await expectLater(
        fixture.client.validateAndNormalize(direct.routeId, {
          'shellCommand': script,
        }),
        throwsA(isA<RemoteToolArgumentValidationFailure>()),
      );
      expect(fixture.messages, isEmpty);
      expect(fixture.storage.transactions, 0);
      for (final descriptor in [bash, powershell, bash]) {
        final outcome = await fixture.executeShell(descriptor.routeId, script);
        expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
        expect(outcome.hostData['shellCommand'], script);
        expect(outcome.hostData['shellProfile'], {
          'profileId': descriptor == bash ? 'bash-selection' : 'pwsh-selection',
          'interpreter': descriptor == bash ? '/bin/bash' : 'PowerShell',
          'dialect': descriptor == bash ? 'bash' : 'powershell',
        });
        expect(outcome.hostData, isNot(contains('program')));
        expect(outcome.hostData, isNot(contains('arguments')));
      }
      expect(
        fixture.shell.requests.map((request) => request.expectedProfileId),
        ['bash-selection', 'pwsh-selection', 'bash-selection'],
      );
      expect(
        fixture.shell.requests.map((request) => request.command),
        everyElement(script),
      );
      expect(fixture.process.settled, 0);
      expect(
        fixture.messages
            .where((message) => message['kind'] == 'hostStreamOpen')
            .map((message) => message['serviceId']),
        everyElement(authorizedEnvironmentShellServiceId),
      );
    },
  );

  test(
    'shell routes are bounded versioned data, not execution authority',
    () async {
      final descriptor = await fixture.materializeShell(
        'selection',
        '/bin/bash',
        'bash',
      );
      final maximal = await fixture.materializeShell(
        'p' * 256,
        '\u0800' * 4096,
        'd' * 64,
      );
      expect(maximal.routeId.length, lessThanOrEqualTo(24 * 1024));
      await fixture.client.validateAndNormalize(maximal.routeId, {
        'shellCommand': 'true',
      });
      final prefix = '${runCommandToolId.value}/shell-v1:';
      for (final route in [
        '${runCommandToolId.value}/shell-v2:unknown',
        '$prefix${'x' * (24 * 1024)}',
        '${prefix}not-base64!',
        '$prefix${base64Url.encode(utf8.encode(jsonEncode(['selection', '/bin/bash'])))}',
        '$prefix${base64Url.encode(utf8.encode(jsonEncode(['selection', '/bin/bash', 'INVALID'])))}',
        '${descriptor.routeId}\n',
      ]) {
        await expectLater(
          fixture.client.validateAndNormalize(route, {'shellCommand': 'true'}),
          throwsA(isA<AdeleRemoteFailure>()),
        );
      }
      for (final invalid in <Map<String, Object?>>[
        {},
        {'shellCommand': 'true', 'program': 'true'},
        {'shellCommand': 'true', 'arguments': []},
        {'shellCommand': ''},
        {'shellCommand': ' \n '},
        {'shellCommand': 1},
        {'shellCommand': 'true', 'environmentId': 'other'},
        {
          'shellCommand': 'true',
          'environment': {'PATH': 'other'},
        },
        {'shellCommand': 'true', 'profileId': 'other'},
        {'shellCommand': 'true', 'workingDirectory': '../other'},
        {'shellCommand': 'true', 'timeoutSeconds': 1801},
        {'shellCommand': 'true', 'timeoutSeconds': 1.0},
        {'shellCommand': 'x' * 16385},
        {'shellCommand': 'nul\u0000'},
        {'shellCommand': '\ud800'},
      ]) {
        await expectLater(
          fixture.client.validateAndNormalize(descriptor.routeId, invalid),
          throwsA(isA<RemoteToolArgumentValidationFailure>()),
        );
      }
      expect(fixture.storage.transactions, 0);
      expect(fixture.messages, isEmpty);
      final arguments = await fixture.client.validateAndNormalize(
        descriptor.routeId,
        {'shellCommand': 'true'},
      );
      await expectLater(
        fixture.backend
            .execute(
              descriptor.routeId,
              arguments,
              'session',
              'run',
              'no-token',
              'environment',
              null,
            )
            .toList(),
        throwsStateError,
      );
      expect(fixture.storage.transactions, 0);
      final denied = await fixture.executeShell(
        descriptor.routeId,
        'true',
        token: 'forged',
      );
      expect(denied.disposition, RemoteToolOutcomeDisposition.failure);
      expect(fixture.shell.requests, isEmpty);
      expect(fixture.process.settled, 0);
    },
  );

  test(
    'shell outcomes reuse capture, search, failures and cancellation',
    () async {
      final descriptor = await fixture.materializeShell(
        'selection',
        '/bin/bash',
        'bash',
      );
      var outcome = await fixture.executeShell(descriptor.routeId, 'exit 7');
      expect(outcome.hostData['exitCode'], 7);
      expect(outcome.hostData['captureState'], 'complete');
      expect(outcome.modelContent, contains('Exit code: 7'));
      final searchArgs = await fixture.searchClient
          .validateAndNormalize(searchCommandOutputToolId.value, {
            'runId': outcome.hostData['runId'],
            'toolInvocationId': outcome.hostData['toolInvocationId'],
            'pattern': 'out',
          });
      final search = await fixture.searchClient
          .execute(
            searchCommandOutputToolId.value,
            searchArgs,
            'session-data',
            'search-run',
            'search-shell',
            null,
            null,
          )
          .single;
      expect(search.outcome!.disposition, RemoteToolOutcomeDisposition.success);
      expect(search.outcome!.modelContent, contains('out'));
      fixture.shell.events.timedOut = true;
      outcome = await fixture.executeShell(descriptor.routeId, 'wait');
      expect(outcome.hostData['termination'], 'timedOut');
      expect(outcome.hostData['exitCode'], isNull);
      expect(outcome.hostData['captureState'], 'complete');
      fixture.shell.events.timedOut = false;
      for (final failure in [
        const EnvironmentFailure(
          code: environmentShellUnavailableCode,
          message: 'Missing shell.',
          details: {},
        ),
        const EnvironmentFailure(
          code: environmentShellProfileChangedCode,
          message: 'Selection changed.',
          details: {},
        ),
        StateError('transport failure'),
      ]) {
        fixture.shell.events.failure = failure;
        final before = fixture.shell.requests.length;
        outcome = await fixture.executeShell(descriptor.routeId, 'never retry');
        expect(outcome.disposition, RemoteToolOutcomeDisposition.failure);
        expect(outcome.hostData['captureState'], 'failed');
        expect(outcome.hostData['stdout'], 'out\n');
        expect(fixture.shell.requests.length, before + 1);
      }
      fixture.shell.events.failure = null;
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      final producer = StreamController<EnvironmentProcessEvent>(
        onListen: listening.complete,
        onCancel: cancelled.complete,
      );
      addTearDown(producer.close);
      fixture.shell.events.producer = producer.stream;
      final arguments = await fixture.client.validateAndNormalize(
        descriptor.routeId,
        {'shellCommand': 'silent'},
      );
      final events = <RemoteToolExecutionEvent>[];
      final subscription = fixture.backend
          .execute(
            descriptor.routeId,
            arguments,
            'session',
            'run',
            'cancel-shell',
            'environment',
            fixture.token,
          )
          .listen(events.add);
      await listening.future.timeout(const Duration(seconds: 2));
      await subscription.cancel().timeout(const Duration(seconds: 2));
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(events, isEmpty);
      expect(fixture.transcripts.activeCaptureCount, 0);
      final state = await fixture.transcripts.getState(
        'session',
        'run',
        'cancel-shell',
      );
      expect(state.state, 'failed');
      expect(fixture.process.settled, 0);
    },
  );

  test(
    'timeout is a completed outcome, declared failure is domain, transport is infrastructure',
    () async {
      fixture.process.timedOut = true;
      var outcome = (await fixture.execute()).last.outcome!;
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.hostData['termination'], 'timedOut');
      expect(outcome.hostData['exitCode'], isNull);
      for (final declared in [true, false]) {
        fixture.process.failure = declared
            ? const EnvironmentFailure(
                code: 'process_start_failed',
                message: 'Cannot start.',
                details: {'program': 'git'},
              )
            : StateError('private provider detail');
        outcome = (await fixture.execute()).last.outcome!;
        expect(outcome.disposition, RemoteToolOutcomeDisposition.failure);
        expect(
          outcome.failureKind,
          declared
              ? RemoteToolFailureKind.domain
              : RemoteToolFailureKind.infrastructure,
        );
        expect(outcome.effectCertainty, RemoteEffectCertainty.uncertain);
        expect(outcome.hostData['stdout'], 'out\n');
        expect(
          outcome.hostData['code'],
          declared ? 'process_start_failed' : isNull,
        );
        if (declared) expect(outcome.hostData['details'], {'program': 'git'});
        expect(
          outcome.hostDiagnostic,
          isNot(contains('private provider detail')),
        );
        expect(outcome.toLocal().cause, isNull);
      }
      fixture.process.failure = null;
      outcome = (await fixture.execute(token: 'expired')).last.outcome!;
      expect(outcome.failureKind, RemoteToolFailureKind.infrastructure);
    },
  );

  test(
    'fresh invocation binds each execution and cancellation reaches process',
    () async {
      await fixture.execute();
      fixture.token = 'second-operation';
      await fixture.execute(token: fixture.token);
      expect(
        fixture.messages
            .where((message) => message['kind'] == 'hostStreamOpen')
            .map((message) => message['hostContext']),
        ['operation', 'second-operation'],
      );
      final before = fixture.process.settled;
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      final producer = StreamController<EnvironmentProcessEvent>(
        onListen: listening.complete,
        onCancel: cancelled.complete,
      );
      addTearDown(producer.close);
      fixture.process.producer = producer.stream;
      final arguments = await fixture.client.validateAndNormalize(
        runCommandToolId.value,
        _proposed,
      );
      final events = <RemoteToolExecutionEvent>[];
      final subscription = fixture.backend
          .execute(
            runCommandToolId.value,
            arguments,
            'session',
            'run',
            'invocation-direct',
            'environment',
            fixture.token,
          )
          .listen(events.add);
      await listening.future.timeout(const Duration(seconds: 2));
      await subscription.cancel().timeout(const Duration(seconds: 2));
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(events, isEmpty);
      expect(fixture.process.settled, before + 1);
      expect(fixture.transcripts.activeCaptureCount, 0);
      expect(
        fixture.messages.any(
          (message) => message['kind'] == 'hostStreamCancel',
        ),
        isTrue,
      );
    },
  );

  test(
    'route, wrapper and missing authority errors are not semantic argument failures',
    () async {
      for (final route in ['run_command', '', 'unknown']) {
        await expectLater(
          fixture.client.validateAndNormalize(route, {}),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((error) => error.code, 'code', 'internal_error')
                .having((error) => error.declaredFailureType, 'type', isNull),
          ),
        );
      }
      final arguments = await fixture.client.validateAndNormalize(
        runCommandToolId.value,
        _proposed,
      );
      for (final token in <String?>[null, '']) {
        await expectLater(
          fixture.backend
              .execute(
                runCommandToolId.value,
                arguments,
                'session',
                'run',
                'invocation-invalid',
                'environment',
                token,
              )
              .toList(),
          throwsA(isNot(isA<RemoteToolArgumentValidationFailure>())),
        );
      }
      await expectLater(
        fixture.client.describe(
          runCommandToolId.value,
          arguments,
          'session',
          'run',
          'invocation',
          null,
        ),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      for (final (method, payload) in [
        (
          remoteModelToolServiceMaterializeId,
          <String, Object?>{
            'materialization': {
              'sessionId': 'session',
              'environmentId': null,
              'shellProfile': null,
            },
          },
        ),
        (
          remoteModelToolServiceValidateAndNormalizeId,
          <String, Object?>{
            'routeId': runCommandToolId.value,
            'proposedArguments': _proposed,
          },
        ),
        (
          remoteModelToolServiceDescribeId,
          <String, Object?>{
            'routeId': runCommandToolId.value,
            'arguments': {'snapshot': arguments.snapshot},
            'sessionId': 'session',
            'runId': 'run',
            'toolInvocationId': 'invocation',
            'environmentId': 'environment',
          },
        ),
      ]) {
        final response = await fixture.forward.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': method,
          'payload': {...payload, 'hostInvocationContext': 'forbidden'},
        });
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(fixture.messages, isEmpty);
    },
  );
}

const _proposed = <String, Object?>{
  'program': 'git',
  'arguments': ['diff', '--check', 'literal | argument'],
  'workingDirectory': './src//.',
};

const _searchProposed = <String, Object?>{
  'runId': 'retained-run',
  'toolInvocationId': 'retained-command',
  'pattern': 'hit',
  'before': 0,
  'after': 0,
};

final class _NoEffects implements AuthorizedEnvironmentProcessFacet {
  _NoEffects([String environment = 'environment'])
    : environmentId = EnvironmentId(environment);
  @override
  final SessionId sessionId = SessionId('session');
  @override
  final EnvironmentId environmentId;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No effects allowed.');
}

final class _Fixture {
  final messages = <Map<String, Object?>>[];
  final process = _Process();
  final shell = _Shell();
  final storage = CommandTestStorage();
  late final transcripts = CommandTranscriptStore(storage);
  int invocations = 0;
  String token = 'operation';
  final routes = <int, AdeleBackendDispatcher>{};
  late final reverse = AuthorizedEnvironmentProcessServiceDispatcher(process);
  late final reverseShell = AuthorizedEnvironmentShellServiceDispatcher(shell);
  late final host = AdeleHostRequestMultiplexer(
    send: (message) {
      messages.add(message);
      unawaited(Future<void>(() => _respond(message)));
    },
  );
  late final backend = CommandToolsBackend(host, transcripts);
  late final forward = RemoteModelToolServiceDispatcher(backend);
  late final client = RemoteModelToolServiceClient(_Channel(forward));
  late final search = CommandOutputSearch(transcripts);
  late final searchBackend = CommandOutputSearchBackend(search);
  late final searchForward = RemoteModelToolServiceDispatcher(searchBackend);
  late final searchClient = RemoteModelToolServiceClient(
    _Channel(searchForward),
  );

  Future<void> seedSearchCapture() async {
    final writer = await transcripts.begin(
      context: ToolExecutionContext(
        sessionId: SessionId('session'),
        runId: RunId('retained-run'),
        toolInvocationId: 'retained-command',
      ),
      environmentId: 'retired-environment',
      request: EnvironmentForegroundProcessRequest(
        program: 'fixture',
        arguments: [],
        relativeWorkingDirectory: '',
        timeoutSeconds: 30,
      ),
    );
    await writer.append(
      EnvironmentProcessOutput(
        stream: EnvironmentProcessOutputStream.stdout,
        text: 'hit one\nhit two\n',
      ),
    );
    await writer.seal(
      EnvironmentProcessCompleted(
        termination: EnvironmentProcessTermination.exited,
        exitCode: 0,
        stdoutTruncated: false,
        stderrTruncated: false,
      ),
    );
  }

  Future<RemoteToolDescriptor> materializeShell(
    String id,
    String interpreter,
    String dialect,
  ) async => (await client.materialize(
    RemoteModelToolMaterialization(
      sessionId: 'session-$id',
      environmentId: 'environment-$id',
      shellProfile: RemoteEnvironmentShellProfile(
        profileId: id,
        interpreter: interpreter,
        dialect: dialect,
      ),
    ),
  )).single;

  Future<RemoteToolOutcome> executeShell(
    String route,
    String command, {
    String token = 'operation',
  }) async {
    final arguments = await client.validateAndNormalize(route, {
      'shellCommand': command,
    });
    return (await backend
            .execute(
              route,
              arguments,
              'session-data',
              'run-data',
              'invocation-${++invocations}',
              'environment-data',
              token,
            )
            .single)
        .outcome!;
  }

  Future<List<RemoteToolExecutionEvent>> execute({
    String token = 'operation',
  }) async {
    final arguments = await client.validateAndNormalize(
      runCommandToolId.value,
      _proposed,
    );
    return backend
        .execute(
          runCommandToolId.value,
          arguments,
          'session-data',
          'run-data',
          'invocation-${++invocations}',
          'environment-data',
          token,
        )
        .toList();
  }

  Future<void> _respond(Map<String, Object?> message) async {
    final id = message['requestId']! as int;
    final kind = message['kind'];
    if (kind == 'hostStreamAck') return;
    if (kind == 'hostStreamOpen') {
      if (message['hostContextKind'] != 'invocation' ||
          message['hostContext'] != token ||
          ![
            authorizedEnvironmentProcessServiceId,
            authorizedEnvironmentShellServiceId,
          ].contains(message['serviceId'])) {
        host.handleResponse({
          'kind': 'hostStreamFailure',
          'requestId': id,
          'error': {
            'code': 'host_invocation_unavailable',
            'message': 'No operation.',
          },
        });
        return;
      }
      routes[id] = message['serviceId'] == authorizedEnvironmentShellServiceId
          ? reverseShell
          : reverse;
    }
    final dispatcher = routes[id];
    if (dispatcher == null) return;
    await dispatcher.handle(
      {
          ...message,
          'kind': switch (kind) {
            'hostStreamOpen' => 'streamOpen',
            'hostStreamCredit' => 'streamCredit',
            'hostStreamCancel' => 'streamCancel',
            _ => throw StateError('Unexpected host call.'),
          },
        }
        ..remove('hostContextKind')
        ..remove('hostContext')
        ..remove('serviceId'),
      (event) {
        host.handleResponse({
          ...event,
          'kind':
              'host${(event['kind']! as String).replaceFirst('stream', 'Stream')}',
        });
      },
    );
  }

  Future<void> close() async {
    host.close();
    await forward.close();
    await searchForward.close();
    await reverse.close();
    await reverseShell.close();
    await transcripts.close();
    storage.close();
  }
}

final class _Shell implements AuthorizedEnvironmentShellService {
  final requests = <EnvironmentShellCommandRequest>[];
  final events = _Process();

  @override
  Stream<EnvironmentProcessEvent> runShellCommand(
    EnvironmentShellCommandRequest request,
  ) {
    requests.add(request);
    return events.runForegroundProcess(
      EnvironmentForegroundProcessRequest(
        program: 'fixture',
        arguments: [],
        relativeWorkingDirectory: request.relativeWorkingDirectory,
        timeoutSeconds: request.timeoutSeconds,
      ),
    );
  }
}

final class _Process implements AuthorizedEnvironmentProcessService {
  Object? failure;
  Stream<EnvironmentProcessEvent>? producer;
  bool timedOut = false;
  int settled = 0;
  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) async* {
    try {
      if (producer case final stream?) {
        yield* stream;
        return;
      }
      for (final stream in EnvironmentProcessOutputStream.values) {
        yield EnvironmentProcessEvent(
          kind: EnvironmentProcessEventKind.output,
          output: EnvironmentProcessOutput(
            stream: stream,
            text: stream == EnvironmentProcessOutputStream.stdout
                ? 'out\n'
                : 'err\n',
          ),
          completed: null,
        );
      }
      if (failure case final error?) throw error;
      yield EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.completed,
        output: null,
        completed: EnvironmentProcessCompleted(
          termination: timedOut
              ? EnvironmentProcessTermination.timedOut
              : EnvironmentProcessTermination.exited,
          exitCode: timedOut ? null : 7,
          stdoutTruncated: false,
          stderrTruncated: false,
        ),
      );
    } finally {
      settled++;
    }
  }
}

final class _Channel implements AdeleStreamChannel {
  const _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return response['payload'];
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    final replies = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(replies.stream);
    try {
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': 1,
        'method': method,
        'payload': payload,
      }, replies.add);
      while (true) {
        await dispatcher.handle({
          'kind': 'streamCredit',
          'requestId': 1,
          'credit': 1,
        }, replies.add);
        if (!await iterator.moveNext()) break;
        final frame = iterator.current;
        if (frame['kind'] == 'streamDone') break;
        if (frame['kind'] == 'streamFailure') {
          throw _RemoteFailure(frame['error']! as Map);
        }
        yield frame['payload'];
      }
    } finally {
      await dispatcher.handle({
        'kind': 'streamCancel',
        'requestId': 1,
      }, replies.add);
      await iterator.cancel();
      await replies.close();
    }
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;
  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details'] as Map? ?? {});
}
