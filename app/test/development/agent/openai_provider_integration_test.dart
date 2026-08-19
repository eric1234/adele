import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/development_source_tools.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:development_source_contract/development_source_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File openAiArtifact;
  late File inspectorArtifact;
  late File developmentSourceArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/phase-iv-b4-openai',
    )..createSync(recursive: true);
    final String dart = _dartExecutable();
    dartaotruntime =
        '${File(dart).parent.path}/${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}';
    hostArtifact = File('${artifacts.path}/host.aot');
    openAiArtifact = File('${artifacts.path}/openai.aot');
    inspectorArtifact = File('${artifacts.path}/inspector.aot');
    developmentSourceArtifact = File(
      '${artifacts.path}/development-source.aot',
    );
    await Future.wait(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/development_source/packages/backend/bin/development_source_backend.dart',
        developmentSourceArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        openAiArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/resource_inspector/packages/basic_backend/bin/resource_inspector_basic_backend.dart',
        inspectorArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'runs OpenAI Responses through AOT provider, ADELE tool, and continuation',
    () async {
      final List<Map<String, Object?>> outbound = <Map<String, Object?>>[];
      final HttpServer responses = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final StreamSubscription<HttpRequest> responsesSubscription = responses
          .listen((HttpRequest request) {
            unawaited(() async {
              expect(request.uri.path, '/v1/responses');
              expect(
                request.headers.value(HttpHeaders.authorizationHeader),
                'Bearer fake-aot-openai-key',
              );
              final Map<String, Object?> body =
                  jsonDecode(await utf8.decoder.bind(request).join())!
                      as Map<String, Object?>;
              outbound.add(body);
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
                charset: 'utf-8',
              );
              if (outbound.length == 1) {
                _sse(
                  request.response,
                  _outputDone(_reasoning('rs_a', 'encrypted-a')),
                );
                _sse(
                  request.response,
                  _outputDone(_message('msg_1', 'Inspecting the resource.')),
                );
                _sse(
                  request.response,
                  _outputDone(_reasoning('rs_b', 'encrypted-b')),
                );
                _sse(
                  request.response,
                  _outputDone(<String, Object?>{
                    'type': 'function_call',
                    'id': 'fc_1',
                    'call_id': 'call_1',
                    'name': 'inspect_resource',
                    'arguments': '{"uri":"file:///tmp/adele-phase-iv.txt"}',
                    'status': 'completed',
                  }),
                );
                _sse(
                  request.response,
                  _outputDone(_reasoning('rs_c', 'encrypted-c')),
                );
                _sse(request.response, _completed('resp_1'));
              } else {
                _sse(
                  request.response,
                  _outputDone(
                    _message('msg_2', 'The resource inspection is complete.'),
                  ),
                );
                _sse(request.response, _completed('resp_2'));
              }
              await request.response.close();
            }());
          });
      addTearDown(() async {
        await responsesSubscription.cancel();
        await responses.close(force: true);
      });
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          'OPENAI_API_KEY': 'fake-aot-openai-key',
          'ADELE_OPENAI_ENDPOINT':
              'http://${responses.address.address}:${responses.port}/v1/responses',
        },
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final _Activation model = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.openai',
        artifact: openAiArtifact,
        descriptor: ProviderDescriptor(
          id: ProviderId('dev.adele.openai.api-key'),
          capability: modelProviderCapability,
          pluginId: 'dev.adele.openai',
          displayName: 'OpenAI API Key',
          serviceId: modelProviderServiceId,
        ),
      );
      final _Activation inspector = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.resource-inspector.basic-plugin',
        artifact: inspectorArtifact,
        descriptor: ProviderDescriptor(
          id: basicResourceInspectorProviderId,
          capability: resourceInspectCapability,
          pluginId: 'dev.adele.resource-inspector.basic-plugin',
          displayName: 'Basic Inspector',
          serviceId: resourceInspectorServiceId,
        ),
      );
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            registry.resolve(modelProviderCapability),
            selectedModel: 'test-openai-model',
          );
      final ResourceInspectorToolExecutable tool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final DevelopmentSessionHistory session = DevelopmentSessionHistory(
        SessionId('session-openai-b4'),
      )..append(UserSessionMessage('Inspect the Phase IV resource.'));
      final AgentRun run = AgentRun(
        id: RunId('run-openai-b4'),
        sessionId: session.id,
      );
      final ToolCatalog catalog = ToolCatalog()..register(tool.registration);
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: session,
        contextAssembler: const DevelopmentContextAssembler(),
        model: modelAdapter,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.ask),
      );

      await strategy.start();

      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(1));
      expect(outbound.single['parallel_tool_calls'], isFalse);
      final ToolApprovalInterruption approval =
          run.interruptions.values.single as ToolApprovalInterruption;
      expect(approval.toolId, resourceInspectionToolId);
      expect(approval.canonicalArguments, <String, Object?>{
        'uri': 'file:///tmp/adele-phase-iv.txt',
      });

      await strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: approval.id,
          toolInvocationId: approval.toolInvocationId,
          approved: true,
        ),
      );

      expect(run.state, RunState.completed);
      expect(tool.invocationCount, 1);
      expect(modelAdapter.invocationCount, 2);
      expect(outbound, hasLength(2));
      expect(outbound[1]['parallel_tool_calls'], isFalse);
      expect(
        (session.snapshot().entries.last as AssistantSessionMessage).content,
        'The resource inspection is complete.',
      );
      final List<Object?> secondInput = outbound[1]['input']! as List<Object?>;
      expect(
        secondInput.map(
          (Object? item) => (item! as Map<String, Object?>)['type'],
        ),
        <String>[
          'message',
          'reasoning',
          'message',
          'reasoning',
          'function_call',
          'reasoning',
          'function_call_output',
        ],
      );
      expect(secondInput[1], _reasoning('rs_a', 'encrypted-a'));
      expect(secondInput[3], _reasoning('rs_b', 'encrypted-b'));
      expect(secondInput[5], _reasoning('rs_c', 'encrypted-c'));
      expect(secondInput[4], <String, Object?>{
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'inspect_resource',
        'arguments': '{"uri":"file:///tmp/adele-phase-iv.txt"}',
        'status': 'completed',
      });
      expect(secondInput[2], <String, Object?>{
        'type': 'message',
        'role': 'assistant',
        'content': <Object?>[
          <String, Object?>{
            'type': 'output_text',
            'text': 'Inspecting the resource.',
            'annotations': <Object?>[],
          },
        ],
        'id': 'msg_1',
        'status': 'completed',
      });
      expect((secondInput[6]! as Map<String, Object?>)['call_id'], 'call_1');
      expect(
        (secondInput[6]! as Map<String, Object?>)['output'],
        contains('Basic inspection'),
      );

      await model.close();
      await inspector.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'searches and reads real ADELE source through two AOT provider generations',
    () async {
      const String strategyPath =
          'app/lib/development/agent/simple_tool_loop_strategy.dart';
      final List<Map<String, Object?>> outbound = <Map<String, Object?>>[];
      final HttpServer responses = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final StreamSubscription<HttpRequest>
      responsesSubscription = responses.listen((HttpRequest request) {
        unawaited(() async {
          expect(request.uri.path, '/v1/responses');
          final Map<String, Object?> body =
              jsonDecode(await utf8.decoder.bind(request).join())!
                  as Map<String, Object?>;
          outbound.add(body);
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          switch (outbound.length) {
            case 1:
              final List<Object?> tools = body['tools']! as List<Object?>;
              expect(
                tools.map(
                  (Object? tool) => (tool! as Map<String, Object?>)['name'],
                ),
                <String>['search_source_text', 'read_source_file'],
              );
              _sse(
                request.response,
                _outputDone(_reasoning('rs_search', 'encrypted-search')),
              );
              _sse(
                request.response,
                _outputDone(<String, Object?>{
                  'type': 'function_call',
                  'id': 'fc_search',
                  'call_id': 'call_search',
                  'name': 'search_source_text',
                  'arguments':
                      '{"literalText":"final class DevelopmentToolLoopStrategy"}',
                  'status': 'completed',
                }),
              );
              _sse(request.response, _completed('resp_search'));
            case 2:
              final List<Object?> input = body['input']! as List<Object?>;
              expect(
                input.map(
                  (Object? item) => (item! as Map<String, Object?>)['type'],
                ),
                <String>[
                  'message',
                  'reasoning',
                  'function_call',
                  'function_call_output',
                ],
              );
              expect(input[1], _reasoning('rs_search', 'encrypted-search'));
              expect(
                (input[3]! as Map<String, Object?>)['call_id'],
                'call_search',
              );
              expect(
                (input[3]! as Map<String, Object?>)['output'],
                allOf(contains(strategyPath), contains(':4:')),
              );
              _sse(
                request.response,
                _outputDone(_reasoning('rs_read', 'encrypted-read')),
              );
              _sse(
                request.response,
                _outputDone(<String, Object?>{
                  'type': 'function_call',
                  'id': 'fc_read',
                  'call_id': 'call_read',
                  'name': 'read_source_file',
                  'arguments': jsonEncode(<String, Object?>{
                    'relativePath': strategyPath,
                  }),
                  'status': 'completed',
                }),
              );
              _sse(request.response, _completed('resp_read'));
            case 3:
              final List<Object?> input = body['input']! as List<Object?>;
              expect(
                input.map(
                  (Object? item) => (item! as Map<String, Object?>)['type'],
                ),
                <String>[
                  'message',
                  'reasoning',
                  'function_call',
                  'function_call_output',
                  'reasoning',
                  'function_call',
                  'function_call_output',
                ],
              );
              expect(input[4], _reasoning('rs_read', 'encrypted-read'));
              expect(
                (input[6]! as Map<String, Object?>)['call_id'],
                'call_read',
              );
              expect(
                (input[6]! as Map<String, Object?>)['output'],
                allOf(
                  startsWith('File: $strategyPath'),
                  contains('final class DevelopmentToolLoopStrategy'),
                  contains('this.maxModelInvocations = 8'),
                ),
              );
              _sse(
                request.response,
                _outputDone(
                  _message(
                    'msg_final',
                    '$strategyPath declares DevelopmentToolLoopStrategy and defaults its model-invocation limit to 8.',
                  ),
                ),
              );
              _sse(request.response, _completed('resp_final'));
            default:
              fail('Unexpected Responses invocation ${outbound.length}.');
          }
          await request.response.close();
        }());
      });
      addTearDown(() async {
        await responsesSubscription.cancel();
        await responses.close(force: true);
      });
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          'OPENAI_API_KEY': 'fake-source-coding-key',
          'ADELE_OPENAI_ENDPOINT':
              'http://${responses.address.address}:${responses.port}/v1/responses',
        },
      );
      final int sharedBackendHostProcess = host.processId;
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final _Activation model = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.openai',
        artifact: openAiArtifact,
        descriptor: ProviderDescriptor(
          id: ProviderId('dev.adele.openai.api-key'),
          capability: modelProviderCapability,
          pluginId: 'dev.adele.openai',
          displayName: 'OpenAI API Key',
          serviceId: modelProviderServiceId,
        ),
      );
      addTearDown(model.close);
      final _Activation source = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.plugin.development-source',
        artifact: developmentSourceArtifact,
        arguments: <String>[repository],
        descriptor: ProviderDescriptor(
          id: ProviderId('dev.adele.development-source.local'),
          capability: developmentSourceCapability,
          pluginId: 'dev.adele.plugin.development-source',
          displayName: 'ADELE Development Source',
          serviceId: developmentSourceServiceId,
        ),
      );
      addTearDown(source.close);
      expect(host.processId, sharedBackendHostProcess);
      final ProviderBinding modelBinding = registry.resolve(
        modelProviderCapability,
      );
      final ProviderBinding sourceBinding = registry.resolve(
        developmentSourceCapability,
      );
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            modelBinding,
            selectedModel: 'test-openai-model',
          );
      final DevelopmentSourceSearchToolExecutable searchTool =
          DevelopmentSourceSearchToolExecutable(sourceBinding);
      final DevelopmentSourceReadToolExecutable readTool =
          DevelopmentSourceReadToolExecutable(sourceBinding);
      final DevelopmentSessionHistory
      session = DevelopmentSessionHistory(SessionId('session-source-coding'))
        ..append(
          UserSessionMessage(
            'Find where DevelopmentToolLoopStrategy is declared, inspect the source, and report its path and model invocation limit.',
          ),
        );
      final AgentRun run = AgentRun(
        id: RunId('run-source-coding'),
        sessionId: session.id,
      );
      final ToolCatalog catalog = ToolCatalog()
        ..register(searchTool.registration)
        ..register(readTool.registration);
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: session,
        contextAssembler: const DevelopmentContextAssembler(
          instructions:
              'Use search_source_text and read_source_file to inspect configured source before answering.',
        ),
        model: modelAdapter,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(modelAdapter.provider, same(modelBinding.provider));
      expect(searchTool.provider, same(sourceBinding.provider));
      expect(readTool.provider, same(sourceBinding.provider));
      expect(modelAdapter.invocationCount, 3);
      expect(model.streamCount, 3);
      expect(model.requestCount, 0);
      expect(searchTool.invocationCount, 1);
      expect(readTool.invocationCount, 1);
      expect(source.requestCount, 2);
      expect(source.streamCount, 0);
      expect(outbound, hasLength(3));
      expect(
        (session.snapshot().entries.last as AssistantSessionMessage).content,
        '$strategyPath declares DevelopmentToolLoopStrategy and defaults its model-invocation limit to 8.',
      );
      final List<ToolInvocationPrepared> prepared = run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ToolInvocationPrepared>()
          .toList(growable: false);
      expect(prepared, hasLength(2));
      expect(prepared[0].invocation.tool.definition.id, sourceTextSearchToolId);
      expect(
        prepared[0].invocation.tool.modelDefinition.alias,
        'search_source_text',
      );
      expect(prepared[0].invocation.tool.executable, same(searchTool));
      expect(prepared[1].invocation.tool.definition.id, sourceFileReadToolId);
      expect(
        prepared[1].invocation.tool.modelDefinition.alias,
        'read_source_file',
      );
      expect(prepared[1].invocation.tool.executable, same(readTool));

      await model.close();
      await source.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<_Activation> _startProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required String pluginId,
  required File artifact,
  required ProviderDescriptor descriptor,
  List<String> arguments = const <String>[],
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: pluginId,
    artifactUri: artifact.uri,
    arguments: arguments,
  );
  final _CountingChannel channel = _CountingChannel(
    connection.channelFor(
      connection.defaultConfigurationContext,
      descriptor.serviceId,
    ),
  );
  final CapabilityRegistration registration = registry.register(
    provider: descriptor,
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: descriptor.serviceId,
      isAvailable: () => !connection.isClosed,
    ),
  );
  return _Activation(connection, registration, channel);
}

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final String executable =
        '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}';
    if (File(executable).existsSync()) return executable;
  }
  final String executable = Platform.resolvedExecutable;
  if (File(executable).parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}

Map<String, Object?> _outputDone(Map<String, Object?> item) =>
    <String, Object?>{'type': 'response.output_item.done', 'item': item};

Map<String, Object?> _message(String id, String text) => <String, Object?>{
  'type': 'message',
  'id': id,
  'role': 'assistant',
  'status': 'completed',
  'content': <Object?>[
    <String, Object?>{
      'type': 'output_text',
      'text': text,
      'annotations': <Object?>[],
    },
  ],
};

Map<String, Object?> _reasoning(String id, String encrypted) =>
    <String, Object?>{
      'type': 'reasoning',
      'id': id,
      'summary': <Object?>[],
      'encrypted_content': encrypted,
    };

Map<String, Object?> _completed(String id) => <String, Object?>{
  'type': 'response.completed',
  'response': <String, Object?>{
    'id': id,
    'model': 'test-openai-model',
    'usage': <String, Object?>{
      'input_tokens': 10,
      'output_tokens': 5,
      'total_tokens': 15,
    },
  },
};

void _sse(HttpResponse response, Map<String, Object?> event) {
  response.write('data: ${jsonEncode(event)}\n\n');
}

final class _Activation {
  const _Activation(this.connection, this.registration, this.channel);

  final PluginBackendConnection connection;
  final CapabilityRegistration registration;
  final _CountingChannel channel;

  int get requestCount => channel.requestCount;
  int get streamCount => channel.streamCount;

  Future<void> close() async {
    await registration.close();
    if (!connection.isClosed) await connection.close();
  }
}

final class _CountingChannel implements AdeleStreamChannel {
  _CountingChannel(this.delegate);

  final AdeleStreamChannel delegate;
  int requestCount = 0;
  int streamCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    requestCount++;
    return delegate.request(method, payload);
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    streamCount++;
    return delegate.stream(method, payload);
  }
}
