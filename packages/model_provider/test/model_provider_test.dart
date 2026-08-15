import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:test/test.dart';

void main() {
  test('generated invocation is lazy single-subscription streaming', () async {
    final _Channel channel = _Channel();
    final Stream<ModelProviderEvent> stream = ModelProviderServiceClient(
      channel,
    ).invoke(_request());
    expect(channel.streams, 0);
    expect(await stream.toList(), hasLength(1));
    expect(channel.streams, 1);
    expect(() => stream.listen((_) {}), throwsStateError);
    expect(channel.requests, 0);
  });

  test('request preserves ordered typed input and native state', () {
    final ModelProviderRequest request = _request();
    expect(request.input.map((item) => item.kind), <ModelProviderInputKind>[
      ModelProviderInputKind.message,
      ModelProviderInputKind.toolProposal,
      ModelProviderInputKind.toolOutcome,
    ]);
    expect(request.input[1].toolProposal!.callId, 'call-1');
    expect(request.input[1].itemId, 'item-9');
    expect(request.input[1].nativeMetadata!.kind, 'item-v1');
    expect(request.nativeState!.data, const <String, Object?>{'cursor': 'abc'});
  });

  test('multiple completed proposals and usage round-trip', () {
    final List<ModelProviderEvent> events = <ModelProviderEvent>[
      _proposal('call-1', 'item-1'),
      _proposal('call-2', 'item-2'),
      _terminal(),
    ];
    expect(
      events.where((event) => event.output?.toolProposal != null),
      hasLength(2),
    );
    expect(events.last.terminal!.usage!.cacheWriteTokens, 3);
  });

  test('constructors reject incoherent categories and invalid values', () {
    expect(
      () => ModelProviderEvent(
        kind: ModelProviderEventKind.output,
        observation: ModelProviderObservation(
          kind: ModelProviderObservationKind.textDelta,
          textDelta: 'x',
          itemId: null,
        ),
        output: null,
        terminal: null,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelProviderTerminal(
        settlement: ModelProviderSettlement.failed,
        incompleteReason: null,
        failure: null,
        providerStopReason: null,
        usage: null,
        effectiveModel: null,
        responseId: null,
        requestId: null,
        nativeState: null,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelProviderUsage(
        inputTokens: -1,
        outputTokens: null,
        cacheReadTokens: null,
        cacheWriteTokens: null,
        providerDetails: const <String, Object?>{},
      ),
      throwsFormatException,
    );
  });

  test('text deltas reject empty but accept whitespace chunks', () {
    expect(
      () => ModelProviderObservation(
        kind: ModelProviderObservationKind.textDelta,
        textDelta: '',
        itemId: null,
      ),
      throwsFormatException,
    );
    for (final String delta in <String>[' ', '\n']) {
      expect(
        ModelProviderObservation(
          kind: ModelProviderObservationKind.textDelta,
          textDelta: delta,
          itemId: null,
        ).textDelta,
        delta,
      );
    }
  });

  test('generated client decodes a whitespace-only text delta', () async {
    final ModelProviderEvent event = await ModelProviderServiceClient(
      _Channel(event: _encodedDelta(' ')),
    ).invoke(_request()).single;
    expect(event.observation!.textDelta, ' ');
  });

  test('completed text rejects empty but accepts whitespace content', () {
    expect(() => _textOutput(''), throwsFormatException);
    expect(_textOutput(' ').text, ' ');
    expect(
      ModelProviderContent(
        kind: ModelProviderContentKind.text,
        text: '\n',
      ).text,
      '\n',
    );
  });

  test('generated client decodes whitespace-only completed text', () async {
    final ModelProviderEvent event = await ModelProviderServiceClient(
      _Channel(event: _encodedTextOutput(' ')),
    ).invoke(_request()).single;
    expect(event.output!.text, ' ');
  });

  test(
    'lazy invocation serializes construction-time request snapshots',
    () async {
      final List<ModelProviderContent> messageContent = <ModelProviderContent>[
        ModelProviderContent(
          kind: ModelProviderContentKind.text,
          text: 'original message',
        ),
      ];
      final Map<String, Object?> proposalArguments = <String, Object?>{
        'uri': 'file:///original',
      };
      final Map<String, Object?> schema = <String, Object?>{
        'properties': <String, Object?>{
          'uri': <String, Object?>{'type': 'string'},
        },
      };
      final Map<String, Object?> compatibility = <String, Object?>{
        'model': 'original-model',
      };
      final Map<String, Object?> nativeData = <String, Object?>{
        'tokens': <Object?>['original-token'],
      };
      final List<ModelProviderInput> input = <ModelProviderInput>[
        ModelProviderInput(
          kind: ModelProviderInputKind.message,
          itemId: null,
          message: ModelProviderMessage(
            role: ModelProviderMessageRole.user,
            content: messageContent,
          ),
          toolProposal: null,
          toolOutcome: null,
          nativeMetadata: null,
        ),
        ModelProviderInput(
          kind: ModelProviderInputKind.toolProposal,
          itemId: 'item-1',
          message: null,
          toolProposal: ModelProviderToolProposal(
            callId: 'call-1',
            name: 'inspect_resource',
            arguments: proposalArguments,
          ),
          toolOutcome: null,
          nativeMetadata: ModelProviderNativeEnvelope(
            kind: 'item-v1',
            compatibility: compatibility,
            data: nativeData,
          ),
        ),
      ];
      final ModelProviderInput retainedInput = input.first;
      final List<ModelProviderTool> tools = <ModelProviderTool>[
        ModelProviderTool(
          name: 'inspect_resource',
          description: 'Inspect.',
          argumentsSchema: schema,
        ),
      ];
      final Map<String, Object?> nestedOptions = <String, Object?>{
        'enabled': true,
      };
      final List<Object?> optionList = <Object?>['original-option'];
      final Map<String, Object?> providerOptions = <String, Object?>{
        'nested': nestedOptions,
        'list': optionList,
      };
      final ModelProviderRequest request = ModelProviderRequest(
        model: 'scripted-v1',
        instructions: '',
        input: input,
        tools: tools,
        toolChoice: ModelProviderToolChoice.auto,
        maxOutputTokens: null,
        providerOptions: providerOptions,
        nativeState: null,
      );
      final _CapturingChannel channel = _CapturingChannel();
      final Stream<ModelProviderEvent> stream = ModelProviderServiceClient(
        channel,
      ).invoke(request);

      input.clear();
      tools.clear();
      providerOptions['late'] = true;
      nestedOptions['enabled'] = false;
      optionList.add('late-option');
      proposalArguments['uri'] = 'file:///mutated';
      (schema['properties']! as Map<String, Object?>).clear();
      compatibility['model'] = 'mutated-model';
      (nativeData['tokens']! as List<Object?>).add('late-token');
      messageContent.add(
        ModelProviderContent(
          kind: ModelProviderContentKind.text,
          text: 'late message',
        ),
      );

      await stream.toList();

      final Map<String, Object?> encoded = channel.encodedRequest!;
      final List<Object?> encodedInput = encoded['input']! as List<Object?>;
      expect(encodedInput, hasLength(2));
      expect(
        ((encodedInput[0]! as Map<String, Object?>)['message']!
            as Map<String, Object?>)['content'],
        hasLength(1),
      );
      final Map<String, Object?> proposalInput =
          encodedInput[1]! as Map<String, Object?>;
      expect(
        (proposalInput['toolProposal']! as Map<String, Object?>)['arguments'],
        const <String, Object?>{'uri': 'file:///original'},
      );
      final Map<String, Object?> native =
          proposalInput['nativeMetadata']! as Map<String, Object?>;
      expect(native['compatibility'], const <String, Object?>{
        'model': 'original-model',
      });
      expect(native['data'], const <String, Object?>{
        'tokens': <Object?>['original-token'],
      });
      expect(encoded['tools'], hasLength(1));
      expect(
        ((encoded['tools']! as List<Object?>).single!
            as Map<String, Object?>)['argumentsSchema'],
        const <String, Object?>{
          'properties': <String, Object?>{
            'uri': <String, Object?>{'type': 'string'},
          },
        },
      );
      expect(encoded['providerOptions'], const <String, Object?>{
        'nested': <String, Object?>{'enabled': true},
        'list': <Object?>['original-option'],
      });
      expect(() => request.input.add(retainedInput), throwsUnsupportedError);
      expect(() => request.tools.clear(), throwsUnsupportedError);
      expect(
        () => request.providerOptions['late'] = true,
        throwsUnsupportedError,
      );
    },
  );

  test('structured snapshots reject cycles and excessive depth', () {
    final Map<String, Object?> cyclicMap = <String, Object?>{};
    cyclicMap['self'] = cyclicMap;
    expect(() => _optionsRequest(cyclicMap), throwsFormatException);
    final List<Object?> cyclicList = <Object?>[];
    cyclicList.add(cyclicList);
    expect(
      () => _optionsRequest(<String, Object?>{'list': cyclicList}),
      throwsFormatException,
    );
    final Map<String, Object?> deep = <String, Object?>{};
    Map<String, Object?> cursor = deep;
    for (int i = 0; i < 65; i++) {
      final Map<String, Object?> next = <String, Object?>{};
      cursor['next'] = next;
      cursor = next;
    }
    expect(() => _optionsRequest(deep), throwsFormatException);
  });

  test('structured snapshots allow shared acyclic references', () {
    final Map<String, Object?> shared = <String, Object?>{'value': true};
    final ModelProviderRequest request = _optionsRequest(<String, Object?>{
      'left': shared,
      'right': shared,
    });
    expect(request.providerOptions['left'], const <String, Object?>{
      'value': true,
    });
    expect(request.providerOptions['right'], const <String, Object?>{
      'value': true,
    });
  });
}

ModelProviderRequest _optionsRequest(Map<String, Object?> options) =>
    ModelProviderRequest(
      model: 'scripted-v1',
      instructions: '',
      input: const <ModelProviderInput>[],
      tools: const <ModelProviderTool>[],
      toolChoice: ModelProviderToolChoice.none,
      maxOutputTokens: null,
      providerOptions: options,
      nativeState: null,
    );

ModelProviderRequest _request() => ModelProviderRequest(
  model: 'scripted-v1',
  instructions: '',
  input: <ModelProviderInput>[
    ModelProviderInput(
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
    ),
    ModelProviderInput(
      kind: ModelProviderInputKind.toolProposal,
      itemId: 'item-9',
      message: null,
      toolProposal: ModelProviderToolProposal(
        callId: 'call-1',
        name: 'inspect_resource',
        arguments: const <String, Object?>{'uri': 'file:///tmp/a'},
      ),
      toolOutcome: null,
      nativeMetadata: _native('item'),
    ),
    ModelProviderInput(
      kind: ModelProviderInputKind.toolOutcome,
      itemId: null,
      message: null,
      toolProposal: null,
      toolOutcome: ModelProviderToolOutcome(
        callId: 'call-1',
        status: ModelProviderToolOutcomeStatus.success,
        content: 'ok',
      ),
      nativeMetadata: null,
    ),
  ],
  tools: <ModelProviderTool>[
    ModelProviderTool(
      name: 'inspect_resource',
      description: 'Inspect one resource.',
      argumentsSchema: const <String, Object?>{'type': 'object'},
    ),
  ],
  toolChoice: ModelProviderToolChoice.auto,
  maxOutputTokens: 100,
  providerOptions: const <String, Object?>{'mode': 'fixture'},
  nativeState: ModelProviderNativeEnvelope(
    kind: 'cursor-v1',
    compatibility: const <String, Object?>{'model': 'scripted-v1'},
    data: const <String, Object?>{'cursor': 'abc'},
  ),
);

ModelProviderEvent _proposal(String callId, String itemId) =>
    ModelProviderEvent(
      kind: ModelProviderEventKind.output,
      observation: null,
      output: ModelProviderOutput(
        kind: ModelProviderOutputKind.toolProposal,
        text: null,
        toolProposal: ModelProviderToolProposal(
          callId: callId,
          name: 'inspect_resource',
          arguments: const <String, Object?>{'uri': 'file:///tmp/a'},
        ),
        itemId: itemId,
        nativeMetadata: _native('item'),
      ),
      terminal: null,
    );

ModelProviderOutput _textOutput(String text) => ModelProviderOutput(
  kind: ModelProviderOutputKind.text,
  text: text,
  toolProposal: null,
  itemId: null,
  nativeMetadata: null,
);

ModelProviderEvent _terminal() => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.completed,
    incompleteReason: null,
    failure: null,
    providerStopReason: 'complete',
    usage: ModelProviderUsage(
      inputTokens: 10,
      outputTokens: 5,
      cacheReadTokens: 2,
      cacheWriteTokens: 3,
      providerDetails: const <String, Object?>{},
    ),
    effectiveModel: 'scripted-v1',
    responseId: 'response-1',
    requestId: 'request-1',
    nativeState: _native('invocation'),
  ),
);

ModelProviderNativeEnvelope _native(String kind) => ModelProviderNativeEnvelope(
  kind: '$kind-v1',
  compatibility: const <String, Object?>{'model': 'scripted-v1'},
  data: const <String, Object?>{'opaque': 'value'},
);

final class _Channel implements AdeleStreamChannel {
  _Channel({Map<String, Object?>? event}) : event = event ?? _encodedTerminal();

  final Map<String, Object?> event;
  int requests = 0;
  int streams = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requests++;
    throw StateError('Unary transport is forbidden.');
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    streams++;
    return Stream<Object?>.value(event);
  }
}

final class _CapturingChannel implements AdeleStreamChannel {
  Map<String, Object?>? encodedRequest;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Unary transport is forbidden.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    encodedRequest = Map<String, Object?>.from(
      payload['request']! as Map<Object?, Object?>,
    );
    return const Stream<Object?>.empty();
  }
}

Map<String, Object?> _encodedDelta(String delta) => <String, Object?>{
  'kind': 'observation',
  'observation': <String, Object?>{
    'kind': 'textDelta',
    'textDelta': delta,
    'itemId': null,
  },
  'output': null,
  'terminal': null,
};

Map<String, Object?> _encodedTextOutput(String text) => <String, Object?>{
  'kind': 'output',
  'observation': null,
  'output': <String, Object?>{
    'kind': 'text',
    'text': text,
    'toolProposal': null,
    'itemId': null,
    'nativeMetadata': null,
  },
  'terminal': null,
};

Map<String, Object?> _encodedTerminal() {
  final ModelProviderTerminal terminal = _terminal().terminal!;
  return <String, Object?>{
    'kind': 'terminal',
    'observation': null,
    'output': null,
    'terminal': <String, Object?>{
      'settlement': terminal.settlement.name,
      'incompleteReason': null,
      'failure': null,
      'providerStopReason': terminal.providerStopReason,
      'usage': <String, Object?>{
        'inputTokens': terminal.usage!.inputTokens,
        'outputTokens': terminal.usage!.outputTokens,
        'cacheReadTokens': terminal.usage!.cacheReadTokens,
        'cacheWriteTokens': terminal.usage!.cacheWriteTokens,
        'providerDetails': terminal.usage!.providerDetails,
      },
      'effectiveModel': terminal.effectiveModel,
      'responseId': terminal.responseId,
      'requestId': terminal.requestId,
      'nativeState': <String, Object?>{
        'kind': terminal.nativeState!.kind,
        'compatibility': terminal.nativeState!.compatibility,
        'data': terminal.nativeState!.data,
      },
    },
  };
}
