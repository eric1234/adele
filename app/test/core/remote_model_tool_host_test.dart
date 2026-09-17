@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart'
    show
        MaterializedToolSet,
        ModelToolComposer,
        ProviderToolProposal,
        RejectedToolProposal,
        ToolInvocationId,
        ToolInvocationResolver,
        ToolMaterializationException,
        ToolProposalFailureKind,
        ToolProposalResolution;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _probeId = 'dev.adele.test.remote-model-tool';
const _extensionId = 'dev.adele.test.remote-model-tool.tools';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp('adele-remote-tool-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    probeArtifact = File.fromUri(artifacts.uri.resolve('probe.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/remote_model_tool_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-model-tool-test',
      );
    }
  });

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;
  late _Files files;
  late _Context context;
  late ToolExecutionContext execution;

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(host.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
    files = _Files();
    context = _Context(files);
    execution = ToolExecutionContext(
      sessionId: context.sessionId,
      runId: RunId('tool-run'),
    );
  });

  Future<PluginBackendActivation> start({
    String pluginId = _probeId,
    String extensionId = _extensionId,
    Map<String, Object?> options = const {},
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [extensionId, jsonEncode(options)],
    );
    addTearDown(connection.close);
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: capabilities,
      extensions: extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    addTearDown(activation.close);
    return activation;
  }

  Future<List<ToolRegistration>> materialize() async =>
      (await extensions
              .discover(modelToolContributions)
              .first
              .value
              .materialize(context))
          .toList();

  Future<MaterializedToolSet> compose() async =>
      (await ModelToolComposer(extensions).materialize(context)).materialize();

  for (final count in [0, 1, 3]) {
    test('generated remote contribution materializes $count tools without '
        'requiring Environment authority', () async {
      final probe = await start(options: {'count': count, 'read': false});
      expect(context.requested, isEmpty);
      final tools = await compose();
      expect(tools.tools, hasLength(count));
      expect(
        tools.tools.map((tool) => tool.definition.id.value),
        List.generate(count, (index) => 'probe-tool-$index'),
      );
      expect(
        tools.tools.map((tool) => tool.modelDefinition.alias),
        List.generate(count, (index) => 'probe_$index'),
      );
      if (count > 0) {
        final tool = tools.tools.first;
        expect(tool.definition.description, 'Host probe tool 0');
        expect(tool.modelDefinition.description, 'Model probe tool 0');
        expect(tool.modelDefinition.argumentsSchema, {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
          'required': ['value'],
          'additionalProperties': false,
        });
        final arguments = await tool.executable.validateAndNormalize({
          'value': '  canonical  ',
        });
        expect(arguments.snapshot, {'value': 'canonical'});
        tool.executable.validateBinding();
        await tool.executable.describe(arguments, execution);
        await collectToolExecution(
          tool.executable.execute(arguments, execution),
        );
      }
      expect(context.requested, isEmpty);
      expect(files.reads, isEmpty);
      final records = await _records(probe.connection);
      expect(
        records.where((record) => record.containsKey('token')),
        everyElement(containsPair('token', isNull)),
      );
    });
  }

  for (final collision in ['id', 'alias']) {
    test(
      '$collision collisions remain composer-owned, not adapter policy',
      () async {
        await start(
          options: {'count': 2, 'collision': collision, 'read': false},
        );
        expect(await materialize(), hasLength(2));
        await expectLater(
          compose(),
          throwsA(isA<ToolMaterializationException>()),
        );
        expect(extensions.discover(modelToolContributions), hasLength(1));
      },
    );
  }

  for (final invalid in <String, Map<String, Object?>>{
    'missing hostServices': {'metadata': <String, Object?>{}},
    'extra metadata': {
      'metadata': {'hostServices': <String>[], 'extra': true},
    },
    'null services': {
      'metadata': {'hostServices': null},
    },
    'non-list services': {
      'metadata': {'hostServices': 'authorizedEnvironmentRead'},
    },
    'non-string service': {
      'metadata': {
        'hostServices': [1],
      },
    },
    'duplicate service': {
      'metadata': {
        'hostServices': [
          'authorizedEnvironmentRead',
          'authorizedEnvironmentRead',
        ],
      },
    },
    'unsupported service': {
      'metadata': {
        'hostServices': ['authorizedEnvironmentMutation'],
      },
    },
    'wrong service route': {'serviceId': 'notModelTools'},
  }.entries) {
    test('rejects ${invalid.key} before granting authority', () async {
      await expectLater(
        start(options: invalid.value),
        throwsA(isA<ExtensionContractException>()),
      );
      expect(extensions.discover(modelToolContributions), isEmpty);
      expect(context.requested, isEmpty);
      expect(files.reads, isEmpty);
      expect(host.isClosed, isFalse);
      await start(options: {'read': false});
      expect((await compose()).tools, hasLength(1));
    });
  }

  test('captures the read facet once and maps generated values without cause; '
      'each operation has fresh, short-lived authority', () async {
    final probe = await start();
    expect(context.requested, isEmpty);
    final tool = (await materialize()).single;
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    final replacementFiles = _Files()..text = 'A later authority';
    context.files = replacementFiles;

    final arguments = await tool.executable.validateAndNormalize({
      'value': ' data ',
    });
    expect(arguments.snapshot, {'value': 'data'});
    expect(
      () => arguments.snapshot['value'] = 'changed',
      throwsUnsupportedError,
    );
    expect(tool.executable.validateBinding, returnsNormally);
    final effect = await tool.executable.describe(arguments, execution);
    expect(effect.effects, {
      ToolEffect.resourceInspection,
      ToolEffect.sourceRead,
    });
    expect(effect.targets.map((target) => target.uri.toString()), [
      'adele-environment://tool-environment/probe.txt',
    ]);
    expect(effect.summary, 'Inspect the captured probe authority');
    expect(effect.uncertainty, EffectUncertainty.uncertain);
    final observation = await collectToolExecution(
      tool.executable.execute(arguments, execution),
    );
    expect(
      observation.progress.map((progress) => progress.kind),
      ToolProgressKind.values,
    );
    expect(observation.progress.map((progress) => progress.content), [
      'Working',
      'out\n',
      'err\n',
    ]);
    final outcome = observation.outcome;
    expect(outcome.disposition, ToolOutcomeDisposition.failure);
    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
    expect(outcome.modelContent, 'Probe result');
    expect(outcome.hostData, {
      'nested': {
        'values': [1, true, null],
      },
    });
    expect(outcome.hostDiagnostic, 'Probe diagnostic');
    expect(
      outcome.cause,
      isNull,
      reason: 'In-process diagnostics are not wire data.',
    );
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    expect(replacementFiles.reads, isEmpty);
    expect(files.reads, [
      'directory:',
      'file:probe.txt',
      'directory:',
      'file:probe.txt',
      'directory:',
      'file:probe.txt',
    ]);

    final records = await _records(probe.connection);
    expect(records.map((record) => record['operation']), [
      'materialize',
      'validate',
      'describe',
      'execute',
    ]);
    final operations = records
        .where((record) => record.containsKey('token'))
        .toList();
    final tokens = operations.map((record) => record['token']).toSet();
    expect(tokens, hasLength(3));
    expect(tokens, everyElement(isA<String>()));
    for (final record in operations) {
      expect(record['authority'], {
        'sessionId': 'tool-session',
        'environmentId': 'tool-environment',
      });
      expect(record['text'], 'Captured authority');
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': record['token']}),
      );
    }
    expect(records[1].containsKey('token'), isFalse);
    _expectDenied(records[1]['replay']);
    expect(operations.first['routes'], hasLength(1));
    final route = (operations.first['routes']! as List).single;
    for (final record in operations.skip(1)) {
      expect(record['sessionId'], 'tool-session');
      expect(record['runId'], 'tool-run');
      expect(record['arguments'], arguments.snapshot);
      expect(record['routeId'], route);
    }
    await materialize();
    final next = (await _records(probe.connection)).last;
    expect(tokens, isNot(contains(next['token'])));
    expect(next['text'], replacementFiles.text);
    expect(context.requested, [
      AuthorizedEnvironmentFileReadFacet,
      AuthorizedEnvironmentFileReadFacet,
    ]);
  });

  test('only declared argument failure becomes invalidArguments; protocol and '
      'backend failures are not model argument errors', () async {
    final probe = await start(options: {'read': false});
    final tools = await compose();
    Future<ToolProposalResolution> resolve(String value) =>
        const ToolInvocationResolver().resolve(
          invocationId: ToolInvocationId('invocation-$value'),
          proposal: ProviderToolProposal(
            providerCallId: 'call-$value',
            alias: 'probe_0',
            arguments: {'value': value},
          ),
          tools: tools,
          context: execution,
        );
    final rejected = await resolve('invalid') as RejectedToolProposal;
    expect(rejected.failure.kind, ToolProposalFailureKind.invalidArguments);
    expect(rejected.failure.message, 'The probe rejects this value.');
    expect(rejected.failure.cause, isA<ToolArgumentValidationException>());
    await expectLater(resolve('crash'), throwsA(isA<PluginRemoteFailure>()));
    await _control(probe.connection, 'malform', {'operation': 'validate'});
    await expectLater(
      resolve('valid'),
      throwsA(
        isA<PluginRemoteFailure>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(context.requested, isEmpty);
  });

  for (final operation in ['materialize', 'describe', 'execute']) {
    test(
      'malformed $operation response is rejected and revokes authority',
      () async {
        final probe = await start();
        final tools = operation == 'materialize' ? null : await materialize();
        await _control(probe.connection, 'malform', {'operation': operation});
        final arguments = CanonicalToolArguments({'value': 'data'});
        final Future<Object?> pending = switch (operation) {
          'materialize' => materialize(),
          'describe' => tools!.single.executable.describe(arguments, execution),
          _ => tools!.single.executable.execute(arguments, execution).toList(),
        };
        await expectLater(pending, throwsA(isA<AdeleProtocolException>()));
        final token = (await _records(probe.connection)).last['token'];
        _expectDenied(
          await _control(probe.connection, 'replay', {'token': token}),
        );
        expect(probe.connection.isClosed, isFalse);
        await _control(probe.connection, 'malform', {'operation': null});
        expect(await materialize(), hasLength(1));
      },
    );
  }

  test(
    'wrong-Session or absent host facet fails before remote materialization',
    () async {
      final probe = await start();
      files.sessionId = SessionId('foreign-session');
      await expectLater(materialize(), throwsA(isA<StateError>()));
      expect(files.reads, isEmpty);
      expect(await _records(probe.connection), isEmpty);
      context.available = false;
      await expectLater(materialize(), throwsStateError);
      expect(files.reads, isEmpty);
      expect(await _records(probe.connection), isEmpty);
    },
  );

  test('synchronous proxy validation maps stale and unavailable captured '
      'Environment bindings without reacquiring authority', () async {
    await start();
    final tool = (await materialize()).single.executable;
    files.bindingFailure = const AuthorizedEnvironmentBindingStale('Retired');
    expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
    files.bindingFailure = const AuthorizedEnvironmentBindingUnavailable(
      'Unavailable',
    );
    expect(
      tool.validateBinding,
      throwsA(isA<ToolBindingUnavailableException>()),
    );
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    expect(files.reads, ['directory:', 'file:probe.txt']);
  });

  test(
    'execution cannot substitute another Session for captured authority',
    () async {
      final probe = await start();
      final tool = (await materialize()).single.executable;
      final arguments = CanonicalToolArguments({'value': 'data'});
      final foreign = ToolExecutionContext(
        sessionId: SessionId('foreign-session'),
        runId: RunId('foreign-run'),
      );
      await expectLater(
        Future.sync(() => tool.describe(arguments, foreign)),
        throwsStateError,
      );
      await expectLater(
        tool.execute(arguments, foreign).toList(),
        throwsStateError,
      );
      expect(
        (await _records(probe.connection)).map((record) => record['operation']),
        ['materialize'],
      );
      expect(files.reads, ['directory:', 'file:probe.txt']);
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      expect(tool.validateBinding, returnsNormally);
    },
  );

  test(
    'live token rejects invented authority, forged IDs, mutation/process '
    'services and foreign generation while captured reads still work',
    () async {
      final probe = await start(options: {'hold': 'describe'});
      final tool = (await materialize()).single.executable;
      final sibling = await start(
        pluginId: 'dev.adele.test.sibling-tool',
        extensionId: 'dev.adele.test.sibling-tool.tools',
      );
      final describing = tool.describe(
        CanonicalToolArguments({'value': 'data'}),
        execution,
      );
      await _control(probe.connection, 'ready', {'operation': 'describe'});
      final token = (await _records(probe.connection)).last['token'];
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': 'invented'}),
      );
      _expectDenied(
        await _control(sibling.connection, 'replay', {'token': token}),
      );
      for (final id in ['sessionId', 'environmentId', 'runId']) {
        _expectDenied(
          await _control(probe.connection, 'replay', {
            'token': token,
            'payload': {'relativePath': 'probe.txt', id: 'forged'},
          }),
          'invalid_request',
        );
      }
      for (final service in [
        'authorizedEnvironmentMutation',
        'authorizedEnvironmentProcess',
      ]) {
        _expectDenied(
          await _control(probe.connection, 'replay', {
            'token': token,
            'service': service,
          }),
          'service_unavailable',
        );
      }
      _expectDenied(
        await _control(probe.connection, 'replay', {
          'token': token,
          'method': 'authorizedEnvironmentRead.createTextFile',
        }),
        'unknown_method',
      );
      final identity =
          await _control(probe.connection, 'replay', {
                'token': token,
                'method': 'authorizedEnvironmentRead.authority',
                'payload': <String, Object?>{},
              })
              as Map;
      expect(identity['payload'], {
        'sessionId': 'tool-session',
        'environmentId': 'tool-environment',
      });
      final read =
          await _control(probe.connection, 'replay', {'token': token}) as Map;
      expect(read['ok'], isTrue);
      expect((read['payload'] as Map)['text'], files.text);
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      await _control(probe.connection, 'release', {'operation': 'describe'});
      await describing;
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': token}),
      );
    },
  );

  for (final operation in ['materialize', 'describe', 'execute']) {
    test('Environment retirement before $operation settlement rejects late '
        'success and revokes the token', () async {
      final probe = await start(options: {'hold': operation});
      final tools = operation == 'materialize' ? null : await materialize();
      final arguments = CanonicalToolArguments({'value': 'data'});
      final Future<Object?> pending = switch (operation) {
        'materialize' => materialize(),
        'describe' => tools!.single.executable.describe(arguments, execution),
        _ => tools!.single.executable.execute(arguments, execution).toList(),
      };
      final failed = expectLater(
        pending,
        throwsA(isA<StaleToolBindingException>()),
      );
      await _control(probe.connection, 'ready', {'operation': operation});
      files.bindingFailure = const AuthorizedEnvironmentBindingStale(
        'Retired during operation',
      );
      await _control(probe.connection, 'release', {'operation': operation});
      await failed;
      final token = (await _records(probe.connection)).last['token'];
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': token}),
      );
    });
  }

  for (final operation in ['materialize', 'describe']) {
    test('exact retirement revokes held $operation authority and rejects its '
        'late result', () async {
      final probe = await start(options: {'hold': operation});
      final tools = operation == 'materialize' ? null : await materialize();
      final Future<Object?> pending = operation == 'materialize'
          ? materialize()
          : tools!.single.executable.describe(
              CanonicalToolArguments({'value': 'data'}),
              execution,
            );
      final failed = expectLater(
        pending,
        throwsA(isA<StaleToolBindingException>()),
      );
      await _control(probe.connection, 'ready', {'operation': operation});
      final token = (await _records(probe.connection)).last['token'];
      await probe.retire();
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': token}),
      );
      await _control(probe.connection, 'release', {'operation': operation});
      await failed;
      expect(extensions.discover(modelToolContributions), isEmpty);
      expect(probe.connection.isClosed, isFalse);
    });
  }

  test('Environment retirement after terminal but before stream done rejects '
      'settlement and revokes execution authority', () async {
    final probe = await start(options: {'hold': 'done'});
    final tool = (await materialize()).single.executable;
    final terminal = Completer<void>();
    final received = <ToolExecutionEvent>[];
    final failed = expectLater(
      collectToolExecution(
        tool.execute(CanonicalToolArguments({'value': 'data'}), execution).map((
          event,
        ) {
          received.add(event);
          if (event is ToolExecutionTerminal) terminal.complete();
          return event;
        }),
      ),
      throwsA(isA<StaleToolBindingException>()),
    );
    await terminal.future.timeout(_bound);
    await _control(probe.connection, 'ready', {'operation': 'done'});
    expect(received, hasLength(4));
    expect(received.last, isA<ToolExecutionTerminal>());
    final token = (await _records(probe.connection)).last['token'];
    files.bindingFailure = const AuthorizedEnvironmentBindingStale(
      'Retired between terminal and stream done',
    );
    await _control(probe.connection, 'release', {'operation': 'done'});
    await failed;
    _expectDenied(await _control(probe.connection, 'replay', {'token': token}));
    expect(received, hasLength(4));
    expect(probe.connection.isClosed, isFalse);
  });

  test('stream cancellation immediately revokes pending reverse calls without '
      'waiting for arbitrary provider work', () async {
    final probe = await start(options: {'hold': 'execute'});
    final tool = (await materialize()).single.executable;
    final subscription = tool
        .execute(CanonicalToolArguments({'value': 'data'}), execution)
        .listen((_) {});
    addTearDown(subscription.cancel);
    await _control(probe.connection, 'ready', {'operation': 'execute'});
    final token = (await _records(probe.connection)).last['token'];
    files.release = Completer<void>();
    files.entered = Completer<void>();
    addTearDown(files.unblock);
    final pendingRead = _control(probe.connection, 'replay', {'token': token});
    await files.entered.future.timeout(_bound);
    final cancelling = subscription.cancel();
    _expectDenied(await pendingRead);
    _expectDenied(await _control(probe.connection, 'replay', {'token': token}));
    expect(files.release!.isCompleted, isFalse);
    await _control(probe.connection, 'release', {'operation': 'execute'});
    await cancelling.timeout(_bound);
    files.unblock();
    await _control(probe.connection, 'records');
    expect(tool.validateBinding, returnsNormally);
    expect(await materialize(), hasLength(1));
  });

  for (final terminate in [false, true]) {
    test(
      '${terminate ? 'connection termination' : 'exact retirement'} makes '
      'retained proxies stale without affecting sibling or replacement',
      () async {
        final original = await start(options: {'hold': 'execute'});
        final binding = extensions.discover(modelToolContributions).single;
        final retained = binding.value;
        final tool = (await materialize()).single.executable;
        final sibling = await start(
          pluginId: 'dev.adele.test.sibling-tool',
          extensionId: 'dev.adele.test.sibling-tool.tools',
        );
        final failed = expectLater(
          tool
              .execute(CanonicalToolArguments({'value': 'data'}), execution)
              .toList(),
          throwsA(isA<StaleToolBindingException>()),
        );
        await _control(original.connection, 'ready', {'operation': 'execute'});
        final token = (await _records(original.connection)).last['token'];
        if (terminate) {
          final terminated = original.connection.terminated.timeout(_bound);
          await expectLater(
            _control(original.connection, 'terminate'),
            throwsA(isA<PluginRemoteFailure>()),
          );
          await terminated;
        } else {
          await original.retire().timeout(_bound);
          _expectDenied(
            await _control(original.connection, 'replay', {'token': token}),
          );
          await _control(original.connection, 'release', {
            'operation': 'execute',
          });
        }
        await failed;
        expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
        await expectLater(
          retained.materialize(context),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(
          extensions
              .discover(modelToolContributions)
              .map((binding) => binding.id.value),
          ['dev.adele.test.sibling-tool.tools'],
        );
        await original.connection.close();
        final replacement = await start();
        final freshBinding = extensions.discover(modelToolContributions).last;
        final fresh = (await freshBinding.value.materialize(context)).single;
        expect(fresh.executable.validateBinding, returnsNormally);
        _expectDenied(
          await _control(replacement.connection, 'replay', {'token': token}),
        );
        await original.close();
        expect(replacement.connection.isClosed, isFalse);
        expect(sibling.connection.isClosed, isFalse);
        expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
        expect(host.isClosed, isFalse);
      },
    );
  }
}

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<List<Map<String, Object?>>> _records(
  PluginBackendConnection connection,
) async => [
  for (final record in (await _control(connection, 'records'))! as List)
    Map<String, Object?>.from(record as Map),
];

void _expectDenied(
  Object? response, [
  String code = 'host_invocation_unavailable',
]) {
  final envelope = response! as Map;
  expect(envelope['ok'], isFalse);
  expect((envelope['error'] as Map)['code'], code);
  expect(envelope.containsKey('payload'), isFalse);
}

final class _Context implements ModelToolHostContext {
  _Context(this.files);

  _Files files;
  bool available = true;
  final requested = <Type>[];

  @override
  final sessionId = SessionId('tool-session');

  @override
  Future<T> requireHostService<T extends Object>() async {
    requested.add(T);
    if (available && T == AuthorizedEnvironmentFileReadFacet) return files as T;
    throw StateError('No authority granted for $T.');
  }
}

final class _Files implements AuthorizedEnvironmentFileReadFacet {
  String text = 'Captured authority';
  Object? bindingFailure;
  final reads = <String>[];
  Completer<void> entered = Completer<void>();
  Completer<void>? release;

  @override
  SessionId sessionId = SessionId('tool-session');
  @override
  final environmentId = EnvironmentId('tool-environment');

  @override
  void validateBinding() {
    if (bindingFailure case final Object error) throw error;
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    reads.add('file:$relativePath');
    if (!entered.isCompleted) entered.complete();
    await release?.future;
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: 'opaque-revision',
    );
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    reads.add('directory:$relativePath');
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: const [
        EnvironmentDirectoryEntry(
          name: 'probe.txt',
          relativePath: 'probe.txt',
          kind: EnvironmentDirectoryEntryKind.file,
        ),
      ],
    );
  }

  void unblock() {
    if (release != null && !release!.isCompleted) release!.complete();
  }
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
