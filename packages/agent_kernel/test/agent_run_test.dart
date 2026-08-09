import 'dart:async';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('AgentRun', () {
    test('completes directly with an exact event sequence', () async {
      final _RecordingModel model = _RecordingModel(<ModelResponse>[
        ModelResponse(content: 'complete'),
      ]);
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: model,
        tools: const <AgentTool>[],
      );

      await run.start();

      expect(run.state, AgentRunState.completed);
      expect(run.result, 'complete');
      expect(model.requests, hasLength(1));
      expect(run.events.map((AgentRunEvent event) => event.sequence), <int>[
        1,
        2,
        3,
        4,
      ]);
      expect(
        run.events.map((AgentRunEvent event) => event.kind),
        <AgentRunEventKind>[
          AgentRunEventKind.runStarted,
          AgentRunEventKind.modelInvocationStarted,
          AgentRunEventKind.modelInvocationCompleted,
          AgentRunEventKind.runCompleted,
        ],
      );
    });

    test('waits for approval then invokes exact tool once', () async {
      final _RecordingTool tool = _RecordingTool();
      final _RecordingModel model = _toolCallingModel();
      final AgentRun run = AgentRun(
        userRequest: 'inspect',
        model: model,
        tools: <AgentTool>[tool],
      );

      await run.start();

      expect(run.state, AgentRunState.awaitingApproval);
      expect(run.pendingApproval?.toolCallId, 'call-1');
      expect(run.pendingApproval?.arguments, <String, Object?>{
        'uri': 'file:///tmp/example.txt',
      });
      expect(tool.invocations, isEmpty);

      await run.approve('call-1');

      expect(tool.invocations, hasLength(1));
      expect(model.requests, hasLength(2));
      expect(model.requests.last.messages.last.role, ModelMessageRole.tool);
      expect(model.requests.last.messages.last.content, 'inspection result');
      expect(
        model.requests.last.messages.last.toolOutcome,
        ToolOutcomeStatus.success,
      );
      expect(run.state, AgentRunState.completed);
      expect(run.result, 'finished');
      expect(
        run.events.map((AgentRunEvent event) => event.kind),
        <AgentRunEventKind>[
          AgentRunEventKind.runStarted,
          AgentRunEventKind.modelInvocationStarted,
          AgentRunEventKind.modelInvocationCompleted,
          AgentRunEventKind.toolCallProposed,
          AgentRunEventKind.toolCallApproved,
          AgentRunEventKind.toolExecutionStarted,
          AgentRunEventKind.toolExecutionCompleted,
          AgentRunEventKind.modelInvocationStarted,
          AgentRunEventKind.modelInvocationCompleted,
          AgentRunEventKind.runCompleted,
        ],
      );
    });

    test('rejection skips tool and resumes the model', () async {
      final _RecordingTool tool = _RecordingTool();
      final _RecordingModel model = _toolCallingModel();
      final AgentRun run = AgentRun(
        userRequest: 'inspect',
        model: model,
        tools: <AgentTool>[tool],
      );
      await run.start();

      await run.reject('call-1');

      expect(tool.invocations, isEmpty);
      expect(
        model.requests.last.messages.last.toolOutcome,
        ToolOutcomeStatus.rejected,
      );
      expect(run.state, AgentRunState.completed);
      expect(
        run.events.map((AgentRunEvent event) => event.kind),
        contains(AgentRunEventKind.toolCallRejected),
      );
      expect(
        run.events.map((AgentRunEvent event) => event.kind),
        isNot(contains(AgentRunEventKind.toolExecutionStarted)),
      );
    });

    test('unknown tool request deterministically fails', () async {
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: _RecordingModel(<ModelResponse>[
          ModelResponse(
            content: 'call',
            toolCalls: <ModelToolCall>[
              ModelToolCall(id: '1', name: 'missing', arguments: const {}),
            ],
          ),
        ]),
        tools: const <AgentTool>[],
      );

      await run.start();

      expect(run.state, AgentRunState.failed);
      expect(run.failure, isA<UnknownAgentTool>());
      expect(run.events.last.kind, AgentRunEventKind.runFailed);
    });

    test('multiple tool calls deterministically fail', () async {
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: _RecordingModel(<ModelResponse>[
          ModelResponse(
            content: 'calls',
            toolCalls: <ModelToolCall>[
              ModelToolCall(
                id: '1',
                name: 'inspect_resource',
                arguments: const {},
              ),
              ModelToolCall(
                id: '2',
                name: 'inspect_resource',
                arguments: const {},
              ),
            ],
          ),
        ]),
        tools: <AgentTool>[_RecordingTool()],
      );

      await run.start();

      expect(run.state, AgentRunState.failed);
      expect(run.failure, isA<UnsupportedModelResponse>());
    });

    test(
      'wrong and duplicate decisions are non-mutating kernel errors',
      () async {
        final _RecordingTool tool = _RecordingTool();
        final AgentRun run = AgentRun(
          userRequest: 'request',
          model: _toolCallingModel(),
          tools: <AgentTool>[tool],
        );
        await run.start();
        final int eventCount = run.events.length;

        await expectLater(
          run.approve('wrong'),
          throwsA(isA<InvalidAgentRunOperation>()),
        );
        expect(run.state, AgentRunState.awaitingApproval);
        expect(run.events, hasLength(eventCount));
        await run.approve('call-1');
        await expectLater(
          run.approve('call-1'),
          throwsA(isA<InvalidAgentRunOperation>()),
        );
        await expectLater(
          run.reject('call-1'),
          throwsA(isA<InvalidAgentRunOperation>()),
        );
        expect(tool.invocations, hasLength(1));
      },
    );

    test('model failure terminalizes run and preserves cause', () async {
      final StateError cause = StateError('model unavailable');
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: _ThrowingModel(cause),
        tools: const <AgentTool>[],
      );

      await run.start();

      expect(run.state, AgentRunState.failed);
      expect(run.failure, same(cause));
      expect(run.events.last.error, same(cause));
    });

    test('tool failure terminalizes run and does not continue model', () async {
      final _RecordingModel model = _toolCallingModel();
      final StateError cause = StateError('tool unavailable');
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: model,
        tools: <AgentTool>[_RecordingTool(error: cause)],
      );
      await run.start();

      await run.approve('call-1');

      expect(run.state, AgentRunState.failed);
      expect(run.failure, same(cause));
      expect(model.requests, hasLength(1));
    });

    test('tool error result is structured and resumes the model', () async {
      final _RecordingModel model = _toolCallingModel();
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: model,
        tools: <AgentTool>[
          _RecordingTool(
            result: ToolResult(
              content: 'inspection denied',
              status: ToolOutcomeStatus.error,
            ),
          ),
        ],
      );
      await run.start();

      await run.approve('call-1');

      expect(run.state, AgentRunState.completed);
      expect(model.requests, hasLength(2));
      expect(
        model.requests.last.messages.last.toolOutcome,
        ToolOutcomeStatus.error,
      );
      expect(model.requests.last.messages.last.content, 'inspection denied');
    });

    test('terminal run cannot restart or accept decisions', () async {
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: _RecordingModel(<ModelResponse>[
          ModelResponse(content: 'complete'),
        ]),
        tools: const <AgentTool>[],
      );
      await run.start();

      await expectLater(run.start(), throwsA(isA<InvalidAgentRunOperation>()));
      await expectLater(
        run.approve('1'),
        throwsA(isA<InvalidAgentRunOperation>()),
      );
      await expectLater(
        run.reject('1'),
        throwsA(isA<InvalidAgentRunOperation>()),
      );
    });

    test('concurrent lifecycle operations are rejected', () async {
      final Completer<ModelResponse> response = Completer<ModelResponse>();
      final AgentRun run = AgentRun(
        userRequest: 'request',
        model: _CompletingModel(response.future),
        tools: const <AgentTool>[],
      );

      final Future<void> start = run.start();
      await Future<void>.delayed(Duration.zero);
      await expectLater(run.start(), throwsA(isA<InvalidAgentRunOperation>()));
      response.complete(ModelResponse(content: 'complete'));
      await start;
    });
  });
}

_RecordingModel _toolCallingModel() => _RecordingModel(<ModelResponse>[
  ModelResponse(
    content: 'inspect first',
    toolCalls: <ModelToolCall>[
      ModelToolCall(
        id: 'call-1',
        name: 'inspect_resource',
        arguments: const <String, Object?>{'uri': 'file:///tmp/example.txt'},
      ),
    ],
  ),
  ModelResponse(content: 'finished'),
]);

final class _RecordingModel implements AgentModel {
  _RecordingModel(this.responses);

  final List<ModelResponse> responses;
  final List<ModelRequest> requests = <ModelRequest>[];

  @override
  Future<ModelResponse> invoke(ModelRequest request) async {
    requests.add(request);
    return responses[requests.length - 1];
  }
}

final class _ThrowingModel implements AgentModel {
  _ThrowingModel(this.error);

  final Object error;

  @override
  Future<ModelResponse> invoke(ModelRequest request) async => throw error;
}

final class _CompletingModel implements AgentModel {
  _CompletingModel(this.response);

  final Future<ModelResponse> response;

  @override
  Future<ModelResponse> invoke(ModelRequest request) => response;
}

final class _RecordingTool implements AgentTool {
  _RecordingTool({this.error, ToolResult? result})
    : result = result ?? ToolResult(content: 'inspection result');

  final Object? error;
  final ToolResult result;
  final List<Map<String, Object?>> invocations = <Map<String, Object?>>[];

  @override
  ToolDefinition get definition => ToolDefinition(
    name: 'inspect_resource',
    description: 'Inspect one resource.',
    argumentsSchema: const <String, Object?>{'uri': 'absolute URI string'},
  );

  @override
  Future<ToolResult> invoke(Map<String, Object?> arguments) async {
    invocations.add(arguments);
    if (error != null) throw error!;
    return result;
  }
}
