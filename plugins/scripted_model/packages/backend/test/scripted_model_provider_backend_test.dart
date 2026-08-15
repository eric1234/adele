import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:scripted_model_backend/scripted_model_provider_backend.dart';
import 'package:test/test.dart';

void main() {
  final ScriptedCommonModelProvider provider = ScriptedCommonModelProvider();

  test('tool choice none completes without proposing a tool', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(_request(toolChoice: ModelProviderToolChoice.none))
        .toList();
    expect(
      events.where((event) => event.output?.toolProposal != null),
      isEmpty,
    );
    expect(events.last.terminal!.settlement, ModelProviderSettlement.completed);
  });

  test('missing user context is a semantic invalid request', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(_request(input: const <ModelProviderInput>[]))
        .toList();
    expect(
      events.single.terminal!.failure!.kind,
      ModelProviderFailureKind.invalidRequest,
    );
    expect(
      events.single.terminal!.failure!.providerCode,
      'missing_user_context',
    );
  });

  test('orphan tool outcome is a semantic invalid request', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              ModelProviderInput(
                kind: ModelProviderInputKind.toolOutcome,
                itemId: null,
                message: null,
                toolProposal: null,
                toolOutcome: ModelProviderToolOutcome(
                  callId: ScriptedCommonModelProvider.callId,
                  status: ModelProviderToolOutcomeStatus.success,
                  content: 'done',
                ),
                nativeMetadata: null,
              ),
            ],
          ),
        )
        .toList();
    expect(
      events.single.terminal!.failure!.kind,
      ModelProviderFailureKind.invalidRequest,
    );
    expect(
      events.single.terminal!.failure!.providerCode,
      'orphan_tool_outcome',
    );
  });
}

ModelProviderRequest _request({
  ModelProviderToolChoice toolChoice = ModelProviderToolChoice.auto,
  List<ModelProviderInput>? input,
}) => ModelProviderRequest(
  model: ScriptedCommonModelProvider.model,
  instructions: '',
  input: input ?? <ModelProviderInput>[_user()],
  tools: <ModelProviderTool>[
    ModelProviderTool(
      name: ScriptedCommonModelProvider.toolName,
      description: 'Inspect.',
      argumentsSchema: const <String, Object?>{'type': 'object'},
    ),
  ],
  toolChoice: toolChoice,
  maxOutputTokens: null,
  providerOptions: const <String, Object?>{},
  nativeState: null,
);

ModelProviderInput _user() => ModelProviderInput(
  kind: ModelProviderInputKind.message,
  itemId: null,
  message: ModelProviderMessage(
    role: ModelProviderMessageRole.user,
    content: <ModelProviderContent>[
      ModelProviderContent(
        kind: ModelProviderContentKind.text,
        text: 'Inspect.',
      ),
    ],
  ),
  toolProposal: null,
  toolOutcome: null,
  nativeMetadata: null,
);
