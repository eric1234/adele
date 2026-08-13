import 'package:scripted_model_backend/scripted_model_backend.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';
import 'package:test/test.dart';

void main() {
  final ScriptedModelProvider provider = ScriptedModelProvider();
  const ScriptedToolDefinition tool = ScriptedToolDefinition(
    name: ScriptedModelProvider.toolName,
    description: 'Inspect.',
    argumentsSchema: <String, Object?>{},
  );
  const ScriptedModelMessage proposalMessage = ScriptedModelMessage(
    role: ScriptedModelMessageRole.assistant,
    content: 'Inspecting.',
    toolCallId: null,
    toolOutcome: null,
    toolProposal: ScriptedToolCall(
      id: ScriptedModelProvider.toolCallId,
      name: ScriptedModelProvider.toolName,
      arguments: <String, Object?>{'uri': ScriptedModelProvider.resourceUri},
    ),
  );

  test(
    'proposes deterministic inspection then consumes typed success',
    () async {
      final ScriptedModelResponse proposal = await provider.invoke(
        const ScriptedModelRequest(
          messages: <ScriptedModelMessage>[
            ScriptedModelMessage(
              role: ScriptedModelMessageRole.user,
              content: 'inspect',
              toolCallId: null,
              toolOutcome: null,
              toolProposal: null,
            ),
          ],
          tools: <ScriptedToolDefinition>[tool],
        ),
      );
      expect(proposal.toolCall?.id, ScriptedModelProvider.toolCallId);

      final ScriptedModelResponse completion = await provider.invoke(
        const ScriptedModelRequest(
          messages: <ScriptedModelMessage>[
            ScriptedModelMessage(
              role: ScriptedModelMessageRole.user,
              content: 'inspect',
              toolCallId: null,
              toolOutcome: null,
              toolProposal: null,
            ),
            proposalMessage,
            ScriptedModelMessage(
              role: ScriptedModelMessageRole.tool,
              content: 'summary',
              toolCallId: ScriptedModelProvider.toolCallId,
              toolOutcome: ScriptedToolOutcomeStatus.success,
              toolProposal: null,
            ),
          ],
          tools: <ScriptedToolDefinition>[tool],
        ),
      );
      expect(completion.toolCall, isNull);
      expect(completion.content, contains('summary'));
    },
  );

  test('uses structured rejection status', () async {
    final ScriptedModelResponse completion = await provider.invoke(
      const ScriptedModelRequest(
        messages: <ScriptedModelMessage>[
          ScriptedModelMessage(
            role: ScriptedModelMessageRole.user,
            content: 'inspect',
            toolCallId: null,
            toolOutcome: null,
            toolProposal: null,
          ),
          proposalMessage,
          ScriptedModelMessage(
            role: ScriptedModelMessageRole.tool,
            content: 'arbitrary localized display prose',
            toolCallId: ScriptedModelProvider.toolCallId,
            toolOutcome: ScriptedToolOutcomeStatus.userRejected,
            toolProposal: null,
          ),
        ],
        tools: <ScriptedToolDefinition>[tool],
      ),
    );

    expect(completion.content, contains('rejected'));
  });

  test(
    'rejects an orphan tool outcome without its assistant proposal',
    () async {
      await expectLater(
        provider.invoke(
          const ScriptedModelRequest(
            messages: <ScriptedModelMessage>[
              ScriptedModelMessage(
                role: ScriptedModelMessageRole.user,
                content: 'inspect',
                toolCallId: null,
                toolOutcome: null,
                toolProposal: null,
              ),
              ScriptedModelMessage(
                role: ScriptedModelMessageRole.tool,
                content: 'summary',
                toolCallId: ScriptedModelProvider.toolCallId,
                toolOutcome: ScriptedToolOutcomeStatus.success,
                toolProposal: null,
              ),
            ],
            tools: <ScriptedToolDefinition>[tool],
          ),
        ),
        throwsA(isA<ScriptedModelFailure>()),
      );
    },
  );

  test(
    'uses the latest user input in an existing Session projection',
    () async {
      final ScriptedModelResponse response = await provider.invoke(
        const ScriptedModelRequest(
          messages: <ScriptedModelMessage>[
            ScriptedModelMessage(
              role: ScriptedModelMessageRole.user,
              content: ScriptedModelProvider.failingResourceRequest,
              toolCallId: null,
              toolOutcome: null,
              toolProposal: null,
            ),
            ScriptedModelMessage(
              role: ScriptedModelMessageRole.assistant,
              content: 'Earlier run complete.',
              toolCallId: null,
              toolOutcome: null,
              toolProposal: null,
            ),
            ScriptedModelMessage(
              role: ScriptedModelMessageRole.user,
              content: 'fresh request',
              toolCallId: null,
              toolOutcome: null,
              toolProposal: null,
            ),
          ],
          tools: <ScriptedToolDefinition>[tool],
        ),
      );

      expect(
        response.toolCall?.arguments['uri'],
        ScriptedModelProvider.resourceUri,
      );
    },
  );
}
