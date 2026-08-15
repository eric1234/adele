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

  test('tool outcome before its matching proposal is invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[_user(), _outcome(), _proposal()],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'orphan_tool_outcome');
  });

  test('wrong replayed tool name is invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _proposal(name: 'wrong_tool'),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_replay_metadata');
  });

  test('wrong replayed arguments are invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _proposal(uri: 'file:///tmp/wrong.txt'),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_replay_metadata');
  });
}

void _expectInvalidContinuation(List<ModelProviderEvent> events, String code) {
  expect(
    events.single.terminal!.failure!.kind,
    ModelProviderFailureKind.invalidRequest,
  );
  expect(events.single.terminal!.failure!.providerCode, code);
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

ModelProviderInput _proposal({
  String name = ScriptedCommonModelProvider.toolName,
  String uri = ScriptedCommonModelProvider.resourceUri,
}) => ModelProviderInput(
  kind: ModelProviderInputKind.toolProposal,
  itemId: ScriptedCommonModelProvider.itemId,
  message: null,
  toolProposal: ModelProviderToolProposal(
    callId: ScriptedCommonModelProvider.callId,
    name: name,
    arguments: <String, Object?>{'uri': uri},
  ),
  toolOutcome: null,
  nativeMetadata: ModelProviderNativeEnvelope(
    kind: ScriptedCommonModelProvider.nativeKind,
    compatibility: ScriptedCommonModelProvider.nativeCompatibility,
    data: ScriptedCommonModelProvider.proposalMetadata,
  ),
);

ModelProviderInput _outcome() => ModelProviderInput(
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
);
