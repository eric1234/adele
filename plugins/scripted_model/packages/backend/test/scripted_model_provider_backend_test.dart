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

  test('proposal and outcome without prior user context are invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(_request(input: <ModelProviderInput>[_proposal(), _outcome()]))
        .toList();
    _expectInvalidContinuation(events, 'missing_user_context');
  });

  for (final ModelProviderToolChoice choice in <ModelProviderToolChoice>[
    ModelProviderToolChoice.auto,
    ModelProviderToolChoice.none,
  ]) {
    test(
      'proposal-only history is invalid before ${choice.name} handling',
      () async {
        final List<ModelProviderEvent> events = await provider
            .invoke(
              _request(
                input: <ModelProviderInput>[_user(), _proposal()],
                toolChoice: choice,
              ),
            )
            .toList();
        _expectInvalidContinuation(events, 'orphan_tool_proposal');
        expect(events.single.kind, ModelProviderEventKind.terminal);
      },
    );
  }

  test('user context after proposal cannot justify continuation', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[_proposal(), _user(), _outcome()],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_user_context');
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

  test('missing authoritative replay text is invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[_user(), _proposal(), _outcome()],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_replay_text');
  });

  test('altered authoritative replay text is invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _initialAssistantText(text: 'Altered text.'),
              _proposal(),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_replay_text');
  });

  test('wrong replay text item ID is invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _initialAssistantText(itemId: 'wrong-text-item'),
              _proposal(),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_replay_text');
  });

  test('replay text after proposal is invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _proposal(),
              _initialAssistantText(),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'missing_replay_text');
  });

  test('orphan outcome cannot hide before a valid continuation', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _outcome(callId: 'orphan-call'),
              _proposal(),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'unsupported_tool_history');
  });

  test('two plausible outcomes exceed scripted history support', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _proposal(),
              _outcome(),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'unsupported_tool_history');
  });

  test('duplicate proposal correlations are invalid', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            input: <ModelProviderInput>[
              _user(),
              _proposal(),
              _proposal(),
              _outcome(),
            ],
          ),
        )
        .toList();
    _expectInvalidContinuation(events, 'ambiguous_tool_proposal');
  });

  test(
    'first invocation below output limit is incomplete without proposal',
    () async {
      final List<ModelProviderEvent> events = await provider
          .invoke(_request(maxOutputTokens: 7))
          .toList();
      expect(
        events.where((ModelProviderEvent event) => event.output != null),
        isEmpty,
      );
      expect(
        events.single.terminal!.settlement,
        ModelProviderSettlement.incomplete,
      );
      expect(
        events.single.terminal!.incompleteReason,
        ModelProviderIncompleteReason.outputLimit,
      );
      expect(events.single.terminal!.usage!.outputTokens, 0);
    },
  );

  test(
    'first invocation at output limit retains completed proposal path',
    () async {
      final List<ModelProviderEvent> events = await provider
          .invoke(_request(maxOutputTokens: 8))
          .toList();
      expect(
        events.where(
          (ModelProviderEvent event) => event.output?.toolProposal != null,
        ),
        hasLength(1),
      );
      expect(
        events.last.terminal!.settlement,
        ModelProviderSettlement.completed,
      );
    },
  );

  test('no-tool response honors output limit', () async {
    final List<ModelProviderEvent> events = await provider
        .invoke(
          _request(
            toolChoice: ModelProviderToolChoice.none,
            maxOutputTokens: 4,
          ),
        )
        .toList();
    expect(
      events.single.terminal!.settlement,
      ModelProviderSettlement.incomplete,
    );
    expect(
      events.single.terminal!.incompleteReason,
      ModelProviderIncompleteReason.outputLimit,
    );
  });

  test(
    'continuation below output limit emits only incomplete terminal',
    () async {
      final List<ModelProviderEvent> events = await provider
          .invoke(
            _request(
              input: <ModelProviderInput>[
                _user(),
                _initialAssistantText(),
                _proposal(),
                _outcome(),
              ],
              maxOutputTokens: 9,
            ),
          )
          .toList();
      expect(events, hasLength(1));
      expect(events.single.kind, ModelProviderEventKind.terminal);
      expect(
        events.single.terminal!.settlement,
        ModelProviderSettlement.incomplete,
      );
      expect(
        events.single.terminal!.incompleteReason,
        ModelProviderIncompleteReason.outputLimit,
      );
      expect(events.single.terminal!.usage!.outputTokens, 0);
    },
  );

  test(
    'continuation at output limit emits normal completed response',
    () async {
      final List<ModelProviderEvent> events = await provider
          .invoke(
            _request(
              input: <ModelProviderInput>[
                _user(),
                _initialAssistantText(),
                _proposal(),
                _outcome(),
              ],
              maxOutputTokens: 10,
            ),
          )
          .toList();
      expect(
        events.where(
          (ModelProviderEvent event) =>
              event.kind == ModelProviderEventKind.observation,
        ),
        hasLength(1),
      );
      expect(
        events.where((ModelProviderEvent event) => event.output?.text != null),
        hasLength(1),
      );
      expect(
        events.last.terminal!.settlement,
        ModelProviderSettlement.completed,
      );
      expect(events.last.terminal!.usage!.outputTokens, 10);
    },
  );
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
  int? maxOutputTokens,
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
  maxOutputTokens: maxOutputTokens,
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

ModelProviderInput _initialAssistantText({
  String text = ScriptedCommonModelProvider.initialText,
  String itemId = ScriptedCommonModelProvider.textItemId,
}) => ModelProviderInput(
  kind: ModelProviderInputKind.message,
  itemId: itemId,
  message: ModelProviderMessage(
    role: ModelProviderMessageRole.assistant,
    content: <ModelProviderContent>[
      ModelProviderContent(kind: ModelProviderContentKind.text, text: text),
    ],
  ),
  toolProposal: null,
  toolOutcome: null,
  nativeMetadata: null,
);

ModelProviderInput _outcome({
  String callId = ScriptedCommonModelProvider.callId,
}) => ModelProviderInput(
  kind: ModelProviderInputKind.toolOutcome,
  itemId: null,
  message: null,
  toolProposal: null,
  toolOutcome: ModelProviderToolOutcome(
    callId: callId,
    status: ModelProviderToolOutcomeStatus.success,
    content: 'done',
  ),
  nativeMetadata: null,
);
