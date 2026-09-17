@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _agentsId = 'dev.adele.plugin.agents-md';
const _agentsSource = 'dev.adele.plugin.agents-md.instructions';
const _probeId = 'dev.adele.test.remote-inference-probe';
const _probeSource = 'dev.adele.test.remote-inference-probe.instructions';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File agentsArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp('adele-remote-context-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    agentsArtifact = File.fromUri(artifacts.uri.resolve('agents.aot'));
    probeArtifact = File.fromUri(artifacts.uri.resolve('probe.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
        artifact: agentsArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/remote_inference_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-inference-integration',
      );
    }
  });

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;
  late _Files files;
  late _Context context;
  late StrategyInferenceMaterial strategy;

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
    strategy = StrategyInferenceMaterial(
      instructions: 'Exact strategy instructions.\n',
      input: [
        SemanticMessageInput(
          role: SemanticMessageRole.user,
          content: 'An explicit user request.',
        ),
      ],
    );
  });

  Future<PluginBackendActivation> start(
    File artifact,
    String pluginId, {
    String? sourceId,
    Map<String, Object?> probeOptions = const {},
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: artifact.uri,
      arguments: sourceId == null
          ? const []
          : [sourceId, if (probeOptions.isNotEmpty) jsonEncode(probeOptions)],
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

  Future<InferenceContextSnapshot> compose() => InferenceContextComposer(
    extensions,
  ).compose(strategyMaterial: strategy, sourceContext: context).timeout(_bound);

  test('real AGENTS advertisement composes exact text, semantics and revision; '
      'new snapshots reread only the captured read facet', () async {
    final activation = await start(agentsArtifact, _agentsId);
    final connection = activation.connection;
    expect(connection.pluginId, _agentsId);
    expect(connection.capabilityExposures, isEmpty);
    expect(connection.extensionExposures.single.toMap(), {
      'extensionPointId': inferenceContextSources.value,
      'extensionId': _agentsSource,
      'serviceId': remoteInferenceContextSourceServiceId,
      'configurationContext': 'default',
      'metadata': {'failureMode': 'required'},
    });
    expect(context.requested, isEmpty);
    expect(
      files.paths,
      isEmpty,
      reason: 'Activation grants no read authority.',
    );

    files.text = ' \r\n# Root guidance\r\n  Preserve these exact bytes.\n';
    final first = await compose();
    final result = first.sourceResults.single;
    expect(result.sourceId.value, _agentsSource);
    expect(result.failureMode, InferenceContextFailureMode.required);
    expect(result.status, InferenceContextSourceStatus.contributed);
    expect(result.failure, isNull);
    expect(result.materials.map((item) => item.key), [
      'semantics',
      'AGENTS.md',
    ]);
    expect(result.materials.first.text, contains('Session Environment root'));
    expect(
      result.materials.first.text,
      contains(
        'Explicit user instructions and direct user requests take precedence',
      ),
    );
    expect(result.materials.first.revision, isNull);
    expect(result.materials.last.text, files.text);
    expect(result.materials.last.revision, files.revision);
    expect(first.input.single, same(strategy.input.single));
    expect(
      renderInferenceInstructions(first),
      '${strategy.instructions}\n\n${result.materials.first.text}\n\n${files.text}',
    );
    expect(renderInferenceInstructions(first), isNot(contains(files.revision)));
    expect(files.paths, ['AGENTS.md']);
    expect(files.validations, 3);
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);

    final originalText = files.text;
    files.text = 'Changed root guidance.\n';
    files.revision = 'opaque-revision-2';
    final second = await compose();
    expect(second.sourceResults.single.materials.last.text, files.text);
    expect(second.sourceResults.single.materials.last.revision, files.revision);
    expect(first.sourceResults.single.materials.last.text, originalText);
    expect(
      first.sourceResults.single.materials.last.revision,
      'opaque-revision-1',
    );
    expect(files.paths, ['AGENTS.md', 'AGENTS.md']);
    expect(context.requested, [
      AuthorizedEnvironmentFileReadFacet,
      AuthorizedEnvironmentFileReadFacet,
    ]);
    expect(
      () => first.sourceResults.single.materials.clear(),
      throwsUnsupportedError,
    );
    await activation.close();
    expect(first.sourceResults.single.materials.last.text, originalText);
  });

  for (final text in <String?>[null, '', ' \t\r\n']) {
    test(
      'real AGENTS ${text == null ? 'not_found' : 'blank ${jsonEncode(text)}'} '
      'is successful empty output over generated reverse transport',
      () async {
        await start(agentsArtifact, _agentsId);
        files.text = text;
        final snapshot = await compose();
        expect(
          snapshot.sourceResults.single.status,
          InferenceContextSourceStatus.empty,
        );
        expect(snapshot.sourceResults.single.failure, isNull);
        expect(snapshot.sourceResults.single.materials, isEmpty);
        expect(renderInferenceInstructions(snapshot), strategy.instructions);
        expect(snapshot.input.single, same(strategy.input.single));
        expect(files.paths, ['AGENTS.md']);
        expect(files.validations, 3);
        expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      },
    );
  }

  for (final invalid in [
    (
      name: 'unknown failureMode',
      options: <String, Object?>{
        'metadata': {'failureMode': 'best-effort'},
      },
      message: 'Inference source failureMode must be required or optional.',
    ),
    (
      name: 'extra metadata keys',
      options: <String, Object?>{
        'metadata': {
          'failureMode': 'required',
          'unexpected': [
            {'nested': true},
          ],
        },
      },
      message: 'Inference source metadata requires only failureMode.',
    ),
    (
      name: 'mismatched service',
      options: <String, Object?>{'serviceId': 'notInferenceContextSource'},
      message: 'Unsupported inference source service.',
    ),
  ]) {
    test(
      'real inference adapter rejects ${invalid.name} before granting authority',
      () async {
        final connection = await host.startPlugin(
          pluginId: _probeId,
          artifactUri: probeArtifact.uri,
          arguments: [_probeSource, jsonEncode(invalid.options)],
        );
        addTearDown(connection.close);
        expect(connection.extensionExposures, hasLength(1));
        await expectLater(
          PluginBackendActivation.registerAdvertised(
            connection: connection,
            capabilities: capabilities,
            extensions: extensions,
            adapters: createRemoteExtensionAdapters(),
          ),
          throwsA(
            isA<ExtensionContractException>().having(
              (error) => error.message,
              'message',
              invalid.message,
            ),
          ),
        );
        expect(connection.isClosed, isTrue);
        expect(extensions.discover(inferenceContextSources), isEmpty);
        expect(context.requested, isEmpty);
        expect(files.paths, isEmpty);
        expect(host.isClosed, isFalse);
        // Failed inference adaptation leaves the host available for the stock source.
        await start(agentsArtifact, _agentsId);
        expect(
          (await compose()).sourceResults.single.sourceId.value,
          _agentsSource,
        );
      },
    );
  }

  test('optional remote source failure omits all material, retains diagnostics '
      'and revokes its token without retiring the source', () async {
    final probe = await start(
      probeArtifact,
      _probeId,
      sourceId: _probeSource,
      probeOptions: {
        'metadata': {'failureMode': 'optional'},
        'failSnapshot': true,
      },
    );
    final snapshot = await compose();
    final result = snapshot.sourceResults.single;
    expect(result.sourceId.value, _probeSource);
    expect(result.failureMode, InferenceContextFailureMode.optional);
    expect(result.status, InferenceContextSourceStatus.omitted);
    expect(result.materials, isEmpty);
    expect(result.failure, _requiredFailure(_probeSource));
    expect(
      (result.failure!.cause as PluginRemoteFailure).code,
      'internal_error',
    );
    expect(snapshot.instructionGroups, hasLength(1));
    expect(renderInferenceInstructions(snapshot), strategy.instructions);
    expect(snapshot.input.single, same(strategy.input.single));
    expect(files.paths, ['AGENTS.md']);
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    _expectDenied(
      await _control(probe.connection, 'replay'),
      'host_invocation_unavailable',
    );
    expect(files.paths, ['AGENTS.md']);
    expect(probe.connection.isClosed, isFalse);
    expect(
      extensions.discover(inferenceContextSources).single.validate,
      returnsNormally,
    );
  });

  test(
    'non-absence Environment failure aborts the required real AGENTS source',
    () async {
      await start(agentsArtifact, _agentsId);
      files.failure = const EnvironmentFailure(
        code: 'permission_denied',
        message: 'The authorized provider refused this read.',
        details: {'relativePath': 'AGENTS.md', 'evidence': 'provider-failure'},
      );
      await expectLater(compose(), throwsA(_requiredFailure(_agentsSource)));
      expect(files.paths, ['AGENTS.md']);
      expect(files.validations, 2);
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    },
  );

  test(
    'wrong-Session facet and unavailable host service fail before file access',
    () async {
      await start(agentsArtifact, _agentsId);
      files.sessionId = SessionId('another-session');
      await expectLater(compose(), throwsA(_requiredFailure(_agentsSource)));
      expect(files.paths, isEmpty);
      expect(files.validations, 0);
      context.available = false;
      await expectLater(compose(), throwsA(_requiredFailure(_agentsSource)));
      expect(files.paths, isEmpty);
      expect(context.requested, [
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileReadFacet,
      ]);
    },
  );

  for (final absent in [false, true]) {
    test('provider retirement rejects late ${absent ? 'not_found' : 'success'} '
        'instead of accepting stale material or empty output', () async {
      await start(agentsArtifact, _agentsId);
      files.release = Completer<void>();
      addTearDown(files.unblock);
      if (absent) files.text = null;
      final failed = expectLater(
        compose(),
        throwsA(_requiredFailure(_agentsSource)),
      );
      await files.entered.future.timeout(_bound);
      expect(files.validations, 1);
      files.stale = true;
      files.unblock();
      await failed;
      expect(files.paths, ['AGENTS.md']);
      expect(files.validations, 2);
    });
  }

  test('probe cannot turn semantic IDs, service names or an invented token '
      'into authority; captured read remains usable', () async {
    final activation = await start(
      probeArtifact,
      _probeId,
      sourceId: _probeSource,
    );
    final snapshot = await compose();
    final materials = snapshot.sourceResults.single.materials;
    expect(
      snapshot.sourceResults.single.failureMode,
      InferenceContextFailureMode.required,
    );
    expect(_receipt(materials, 'semanticIds'), {
      'sessionId': context.session.id.value,
      'runId': context.runId.value,
    });
    for (final key in ['forgedSession', 'forgedRun']) {
      _expectDenied(_receipt(materials, key), 'invalid_request');
    }
    for (final key in ['mutationService', 'processService']) {
      _expectDenied(_receipt(materials, key), 'service_unavailable');
    }
    _expectDenied(_receipt(materials, 'mutationMethod'), 'unknown_method');
    _expectDenied(
      _receipt(materials, 'inventedContext'),
      'host_invocation_unavailable',
    );
    final read = _receipt(materials, 'read');
    expect(read['ok'], isTrue);
    expect(read['payload'], {
      'relativePath': 'AGENTS.md',
      'text': files.text,
      'sizeBytes': utf8.encode(files.text!).length,
      'revision': files.revision,
    });
    expect(files.paths, ['AGENTS.md']);
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    expect(activation.connection.isClosed, isFalse);

    // The probe retained its own token, but the composer operation has settled.
    _expectDenied(
      await _control(activation.connection, 'replay'),
      'host_invocation_unavailable',
    );
    expect(files.paths, ['AGENTS.md']);
    final next = await compose();
    expect(
      _material(next.sourceResults.single.materials, 'context').text,
      isNot(_material(materials, 'context').text),
    );
    expect(files.paths, ['AGENTS.md', 'AGENTS.md']);
  });

  test(
    'reverse Environment failure preserves declared type, code, message and details',
    () async {
      await start(probeArtifact, _probeId, sourceId: _probeSource);
      files.failure = const EnvironmentFailure(
        code: 'permission_denied',
        message: 'Denied by captured authority.',
        details: {
          'relativePath': 'AGENTS.md',
          'nested': {'reason': 'test'},
        },
      );
      final snapshot = await compose();
      final read = _receipt(snapshot.sourceResults.single.materials, 'read');
      expect(read['ok'], isFalse);
      expect(read['error'], {
        'declaredFailureType': environmentFailureTypeId,
        'code': 'permission_denied',
        'message': 'Denied by captured authority.',
        'details': {
          'relativePath': 'AGENTS.md',
          'nested': {'reason': 'test'},
        },
      });
      expect(files.paths, ['AGENTS.md']);
    },
  );

  test(
    'provider retirement after read but before snapshot settlement rejects captured material',
    () async {
      final probe = await start(
        probeArtifact,
        _probeId,
        sourceId: _probeSource,
        probeOptions: {'holdSnapshot': true},
      );
      final failed = expectLater(
        compose(),
        throwsA(
          isA<InferenceContextSourceFailed>()
              .having((error) => error.sourceId.value, 'sourceId', _probeSource)
              .having(
                (error) => error.cause,
                'cause',
                isA<AuthorizedEnvironmentBindingStale>(),
              ),
        ),
      );
      await _control(probe.connection, 'snapshotReady');
      expect(files.paths, ['AGENTS.md']);
      expect(files.validations, 2);
      files.stale = true;
      await _control(probe.connection, 'finishSnapshot');
      await failed;
      expect(files.validations, 3);
      _expectDenied(
        await _control(probe.connection, 'replay'),
        'host_invocation_unavailable',
      );
    },
  );

  test(
    'settled snapshot prevents deferred acquisition and queued reads from using authority',
    () async {
      final probe = await start(
        probeArtifact,
        _probeId,
        sourceId: _probeSource,
        probeOptions: {'detachedReads': true},
      );
      final release = Completer<void>();
      context.releaseAcquisition = release;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final composing = compose();
      await context.acquisitionEntered.future.timeout(_bound);
      await _control(probe.connection, 'snapshotReady');
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      expect(files.paths, isEmpty);
      await _control(probe.connection, 'finishSnapshot');
      expect(
        (await composing).sourceResults.single.status,
        InferenceContextSourceStatus.contributed,
      );
      final responses = await _control(probe.connection, 'readResults') as List;
      expect(responses, hasLength(2));
      for (final response in responses) {
        _expectDenied(response, 'host_invocation_unavailable');
      }
      expect(release.isCompleted, isFalse);
      release.complete();
      // This process round trip follows the resumed local dispatcher microtasks.
      await _control(probe.connection, 'savedContext');
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      expect(files.paths, isEmpty);
      expect(files.validations, 0);
    },
  );

  test('a live token cannot cross plugins; pending termination cleans up '
      'without blocking the sibling or a same-ID replacement', () async {
    final probe = await start(probeArtifact, _probeId, sourceId: _probeSource);
    final sibling = await start(
      probeArtifact,
      'dev.adele.test.sibling',
      sourceId: 'dev.adele.test.sibling.instructions',
    );
    final oldBinding = extensions.discover(inferenceContextSources).first;
    final oldSource = oldBinding.value;
    files.release = Completer<void>();
    addTearDown(files.unblock);
    final failed = expectLater(
      compose(),
      throwsA(_requiredFailure(_probeSource)),
    );
    await files.entered.future.timeout(_bound);
    final token = await _control(probe.connection, 'savedContext') as String;
    _expectDenied(
      await _control(sibling.connection, 'replay', {
        'hostInvocationContext': token,
      }),
      'host_invocation_unavailable',
    );
    expect(files.paths, ['AGENTS.md']);
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);

    final terminated = probe.connection.terminated.timeout(_bound);
    final terminationCall = expectLater(
      _control(probe.connection, 'terminate'),
      throwsA(isA<PluginRemoteFailure>()),
    );
    await terminated;
    await terminationCall;
    await failed; // Must settle while arbitrary provider code is still blocked.
    expect(files.release!.isCompleted, isFalse);
    expect(probe.connection.isClosed, isTrue);
    expect(oldBinding.validate, throwsA(isA<StaleExtensionBinding>()));
    await expectLater(
      oldSource.snapshot(context),
      throwsA(isA<StaleExtensionBinding>()),
    );
    expect(
      extensions.discover(inferenceContextSources).map((item) => item.id.value),
      ['dev.adele.test.sibling.instructions'],
    );

    final replacement = await start(
      probeArtifact,
      _probeId,
      sourceId: _probeSource,
    );
    final freshFiles = _Files()..text = 'Replacement authority.';
    context.files = freshFiles;
    final fresh = await compose();
    expect(fresh.sourceResults, hasLength(2));
    for (final result in fresh.sourceResults) {
      expect(
        (_receipt(result.materials, 'read')['payload'] as Map)['text'],
        freshFiles.text,
      );
    }
    _expectDenied(
      await _control(replacement.connection, 'replay', {
        'hostInvocationContext': token,
      }),
      'host_invocation_unavailable',
    );
    await probe.close(); // Old cleanup must not stop the replacement.
    expect(replacement.connection.isClosed, isFalse);
    expect(sibling.connection.isClosed, isFalse);
    expect(host.isClosed, isFalse);
    files.unblock();
    await files.settled.future.timeout(_bound);
    // A subsequent complete round trip also proves late replies cannot poison routes.
    expect((await compose()).sourceResults, hasLength(2));
    expect(freshFiles.paths, List.filled(4, 'AGENTS.md'));
    expect(oldBinding.validate, throwsA(isA<StaleExtensionBinding>()));
    await expectLater(
      oldSource.snapshot(context),
      throwsA(isA<StaleExtensionBinding>()),
    );
  });

  test(
    'real AGENTS termination retires the source; same-ID activation requires '
    'fresh resolution and leaves captured data intact',
    () async {
      final original = await start(agentsArtifact, _agentsId);
      final binding = extensions.discover(inferenceContextSources).single;
      final retained = binding.value;
      final snapshot = await compose();
      await host.stopPlugin(_agentsId);
      await original.connection.terminated;
      expect(extensions.discover(inferenceContextSources), isEmpty);
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      await expectLater(
        retained.snapshot(context),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect((await compose()).sourceResults, isEmpty);

      files.text = 'New generation guidance.';
      final replacement = await start(agentsArtifact, _agentsId);
      await original.close();
      expect(replacement.connection.isClosed, isFalse);
      expect(
        (await compose()).sourceResults.single.materials.last.text,
        files.text,
      );
      expect(
        snapshot.sourceResults.single.materials.last.text,
        'Root guidance.\n',
      );
      await expectLater(
        retained.snapshot(context),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(files.paths, ['AGENTS.md', 'AGENTS.md']);
    },
  );

  test(
    'explicit invocation close synchronously revokes a pending reverse read',
    () async {
      final probe = await start(
        probeArtifact,
        _probeId,
        sourceId: _probeSource,
      );
      final service = _ReadService(files);
      final dispatcher = AuthorizedEnvironmentReadServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final invocation = probe.connection.openHostInvocation({
        authorizedEnvironmentReadServiceId: dispatcher,
      });
      addTearDown(invocation.close);
      files.release = Completer<void>();
      addTearDown(files.unblock);
      final pending = _control(probe.connection, 'replay', {
        'hostInvocationContext': invocation.id,
      });
      await files.entered.future.timeout(_bound);
      invocation.close();
      expect(invocation.isClosed, isTrue);
      _expectDenied(await pending, 'host_invocation_unavailable');
      expect(files.release!.isCompleted, isFalse);
      _expectDenied(
        await _control(probe.connection, 'replay', {
          'hostInvocationContext': invocation.id,
        }),
        'host_invocation_unavailable',
      );
      expect(files.paths, ['AGENTS.md']);
      files.unblock();
      await files.settled.future.timeout(_bound);
      expect(
        (await compose()).sourceResults.single.status,
        InferenceContextSourceStatus.contributed,
      );
    },
  );

  test(
    'plugin-supplied PluginId is rejected, not trusted to select a sibling token',
    () async {
      final probe = await start(
        probeArtifact,
        _probeId,
        sourceId: _probeSource,
      );
      final sibling = await start(agentsArtifact, _agentsId);
      final dispatcher = AuthorizedEnvironmentReadServiceDispatcher(
        _ReadService(files),
      );
      addTearDown(dispatcher.close);
      final invocation = sibling.connection.openHostInvocation({
        authorizedEnvironmentReadServiceId: dispatcher,
      });
      addTearDown(invocation.close);
      final terminated = probe.connection.terminated.timeout(_bound);
      await expectLater(
        _control(probe.connection, 'replay', {
          'hostInvocationContext': invocation.id,
          'pluginId': sibling.connection.pluginId,
        }),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await terminated;
      expect(files.paths, isEmpty);
      expect(invocation.isClosed, isFalse);
      expect(sibling.connection.isClosed, isFalse);
      expect(
        (await compose()).sourceResults.single.sourceId.value,
        _agentsSource,
      );
      expect(files.paths, ['AGENTS.md']);
      expect(host.isClosed, isFalse);
    },
  );
}

Matcher _requiredFailure(String sourceId) => isA<InferenceContextSourceFailed>()
    .having((error) => error.sourceId.value, 'sourceId', sourceId)
    .having((error) => error.cause, 'cause', isA<PluginRemoteFailure>());

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

InferenceInstructionMaterial _material(
  List<InferenceInstructionMaterial> materials,
  String key,
) => materials.singleWhere((item) => item.key == key);

Map<String, Object?> _receipt(
  List<InferenceInstructionMaterial> materials,
  String key,
) => Map<String, Object?>.from(
  jsonDecode(_material(materials, key).text) as Map,
);

void _expectDenied(Object? response, String code) {
  expect(response, isA<Map<Object?, Object?>>());
  final envelope = response! as Map;
  expect(envelope['ok'], isFalse);
  expect((envelope['error'] as Map)['code'], code);
  expect(envelope.containsKey('payload'), isFalse);
}

final class _Context implements InferenceContextSourceContext {
  _Context(this.files);

  _Files files;
  bool available = true;
  final requested = <Type>[];
  final acquisitionEntered = Completer<void>();
  Completer<void>? releaseAcquisition;
  @override
  final session = Session(
    id: SessionId('authoritative-session'),
    taskId: TaskId('authoritative-task'),
    strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
  );
  @override
  final runId = RunId('authoritative-run');

  @override
  Future<T> requireHostService<T extends Object>() async {
    requested.add(T);
    if (available && T == AuthorizedEnvironmentFileReadFacet) {
      final captured = files;
      if (!acquisitionEntered.isCompleted) acquisitionEntered.complete();
      await releaseAcquisition?.future;
      return captured as T;
    }
    throw StateError('No authority granted for $T.');
  }
}

final class _Files implements AuthorizedEnvironmentFileReadFacet {
  String? text = 'Root guidance.\n';
  String revision = 'opaque-revision-1';
  Object? failure;
  bool stale = false;
  int validations = 0;
  final paths = <String>[];
  final entered = Completer<void>();
  final settled = Completer<void>();
  Completer<void>? release;

  @override
  SessionId sessionId = SessionId('authoritative-session');
  @override
  final environmentId = EnvironmentId('authoritative-environment');

  @override
  void validateBinding() {
    validations++;
    if (stale) {
      throw const AuthorizedEnvironmentBindingStale('Provider retired.');
    }
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    paths.add(relativePath);
    if (!entered.isCompleted) entered.complete();
    try {
      await release?.future;
      if (failure case final Object error) throw error;
      if (text == null) {
        throw EnvironmentFailure(
          code: 'not_found',
          message: 'No file in the authorized Environment.',
          details: {'relativePath': relativePath},
        );
      }
      return EnvironmentTextFile(
        relativePath: relativePath,
        text: text!,
        sizeBytes: utf8.encode(text!).length,
        revision: revision,
      );
    } finally {
      if (!settled.isCompleted) settled.complete();
    }
  }

  void unblock() {
    final barrier = release;
    if (barrier != null && !barrier.isCompleted) barrier.complete();
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      throw StateError('A root instruction source must not scan directories.');
}

final class _ReadService implements AuthorizedEnvironmentReadService {
  const _ReadService(this.files);
  final _Files files;

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      files.readFile(relativePath);
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
