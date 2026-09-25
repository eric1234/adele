import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_product/adele_product.dart';
import 'package:command_tools_backend/command_tools_backend.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  test(
    'descriptor reuses root identity, alias, schema and process-only dependency',
    () async {
      fixture.host.close();
      final local = commandToolRegistration(_NoEffects());
      final descriptor = (await fixture.client.materialize('session')).single;
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
          ToolExecutionContext(sessionId: facet.sessionId, runId: RunId('run')),
        );
        final remote = await fixture.client.describe(
          runCommandToolId.value,
          arguments,
          'session',
          'run',
          environment,
        );
        expect(remote.effects, [RemoteToolEffect.processExecution]);
        expect(remote.targetUris, [
          Uri.parse('adele-environment:/$environment/'),
        ]);
        expect(remote.summary, description.summary);
        expect(remote.uncertainty, RemoteEffectUncertainty.uncertain);
      }
      for (final invalid in <Map<String, Object?>>[
        {},
        {..._proposed, 'environmentId': 'forged'},
        {..._proposed, 'timeoutSeconds': 601},
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
    'operation-bound generated process preserves ordered progress and nonzero outcome',
    () async {
      final events = await fixture.execute();
      expect(events.map((event) => event.kind), [
        RemoteToolExecutionEventKind.progress,
        RemoteToolExecutionEventKind.progress,
        RemoteToolExecutionEventKind.terminal,
      ]);
      expect(events.take(2).map((event) => event.progress!.kind), [
        RemoteToolProgressKind.stdout,
        RemoteToolProgressKind.stderr,
      ]);
      expect(events.take(2).map((event) => event.progress!.content), [
        'out\n',
        'err\n',
      ]);
      final outcome = events.last.outcome!;
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, RemoteEffectCertainty.knownOccurred);
      expect(outcome.hostData, {
        'environmentId': 'environment-data',
        'program': 'git',
        'arguments': ['diff', '--check', 'literal | argument'],
        'workingDirectory': 'src',
        'timeoutSeconds': 120,
        'stdout': 'out\n',
        'stderr': 'err\n',
        'termination': 'exited',
        'exitCode': 7,
        'stdoutTruncated': true,
        'stderrTruncated': false,
      });
      expect(outcome.modelContent, contains('Exit code: 7'));
      expect(outcome.toLocal().cause, isNull);
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
      final arguments = await fixture.client.validateAndNormalize(
        runCommandToolId.value,
        _proposed,
      );
      await fixture.backend
          .execute(
            runCommandToolId.value,
            arguments,
            'session',
            'run',
            'environment',
            fixture.token,
          )
          .first;
      expect(fixture.process.settled, before + 1);
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
          null,
        ),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      for (final (method, payload) in [
        (
          remoteModelToolServiceMaterializeId,
          <String, Object?>{'sessionId': 'session'},
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
  String token = 'operation';
  final routes = <int, AdeleBackendDispatcher>{};
  late final reverse = AuthorizedEnvironmentProcessServiceDispatcher(process);
  late final host = AdeleHostRequestMultiplexer(
    send: (message) {
      messages.add(message);
      unawaited(Future<void>(() => _respond(message)));
    },
  );
  late final backend = CommandToolsBackend(host);
  late final forward = RemoteModelToolServiceDispatcher(backend);
  late final client = RemoteModelToolServiceClient(_Channel(forward));

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
          message['serviceId'] != authorizedEnvironmentProcessServiceId) {
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
      routes[id] = reverse;
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
    await reverse.close();
  }
}

final class _Process implements AuthorizedEnvironmentProcessService {
  Object? failure;
  bool timedOut = false;
  int settled = 0;
  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) async* {
    try {
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
          stdoutTruncated: true,
          stderrTruncated: false,
        ),
      );
    } finally {
      settled++;
    }
  }
}

final class _Channel implements AdeleRequestChannel {
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
