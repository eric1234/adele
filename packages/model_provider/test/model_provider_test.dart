import 'dart:async';

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

  test('consecutive native-only items remain distinct and ordered', () {
    final List<ModelProviderInput> input = <ModelProviderInput>[
      _nativeInput('native-1', 'first-v1'),
      _nativeInput('native-2', 'second-v1'),
    ];

    expect(input.map((item) => item.kind), <ModelProviderInputKind>[
      ModelProviderInputKind.nativeItem,
      ModelProviderInputKind.nativeItem,
    ]);
    expect(input.map((item) => item.itemId), <String?>['native-1', 'native-2']);
    expect(input.map((item) => item.nativeMetadata!.kind), <String>[
      'first-v1',
      'second-v1',
    ]);
  });

  test('multiple completed proposals and usage round-trip', () async {
    final List<ModelProviderEvent> events = <ModelProviderEvent>[];
    for (final ModelProviderEvent event in <ModelProviderEvent>[
      _proposal('call-1', 'item-1'),
      _proposal('call-2', 'item-2'),
      _terminal(),
    ]) {
      events.add(
        await ModelProviderServiceClient(
          _Channel(event: await _generatedEvent(event)),
        ).invoke(_request()).single,
      );
    }
    expect(
      events.where((event) => event.output?.toolProposal != null),
      hasLength(2),
    );
    expect(events.last.terminal!.usage!.cacheWriteTokens, 3);
  });

  for (final String scope in <String>['absent', 'initial', 'continuation']) {
    test('generated affinity round-trip preserves $scope scope', () async {
      final Map<String, Object?> compatibility = <String, Object?>{
        'owner': <String, Object?>{'binding': 'fixture'},
      };
      final List<Object?> tokens = <Object?>['opaque-token', null, 0];
      final Map<String, Object?> data = <String, Object?>{'tokens': tokens};
      final ModelProviderNativeEnvelope state = ModelProviderNativeEnvelope(
        kind: 'fixture-affinity.v1',
        compatibility: compatibility,
        data: data,
      );
      final ModelProviderAffinity? affinity = scope == 'absent'
          ? null
          : ModelProviderAffinity(
              id: 'opaque-run-scope',
              state: scope == 'continuation' ? state : null,
            );
      final ModelProviderRequest request = _request(affinity: affinity);
      final _EventService service = _EventService(
        _terminal(affinityState: affinity?.state),
      );
      (compatibility['owner']! as Map<String, Object?>).clear();
      tokens.clear();
      data.clear();

      final Map<String, Object?> frame = await _dispatchEvent(
        service,
        request: request,
        mutateRequest: (wire) {
          expect(wire, contains('affinity'));
          expect(
            wire['affinity'],
            scope == 'absent'
                ? isNull
                : <String, Object?>{
                    'id': 'opaque-run-scope',
                    'state': scope == 'initial'
                        ? null
                        : <String, Object?>{
                            'kind': state.kind,
                            'compatibility': state.compatibility,
                            'data': state.data,
                          },
                  },
          );
        },
      );
      expect(frame['kind'], 'streamItem');
      final Map<String, Object?> encoded =
          frame['payload']! as Map<String, Object?>;
      final Map<String, Object?> wireTerminal =
          encoded['terminal']! as Map<String, Object?>;
      expect(wireTerminal, contains('affinityState'));
      expect(
        wireTerminal['affinityState'],
        scope == 'continuation' ? isNotNull : isNull,
      );
      final ModelProviderTerminal terminal = (await ModelProviderServiceClient(
        _Channel(event: encoded),
      ).invoke(request).single).terminal!;
      final ModelProviderRequest decoded = service.request!;
      expect(decoded.nativeState!.kind, 'cursor-v1');
      expect(decoded.nativeState!.data, <String, Object?>{'cursor': 'abc'});
      expect(terminal.nativeState!.kind, 'invocation-v1');
      expect(terminal.nativeState!.data, <String, Object?>{'opaque': 'value'});
      if (affinity == null) {
        expect(decoded.affinity, isNull);
      } else {
        expect(decoded.affinity!.id, affinity.id);
        expect(decoded.affinity, isNot(same(affinity)));
      }
      if (scope != 'continuation') {
        expect(decoded.affinity?.state, isNull);
        expect(terminal.affinityState, isNull);
        return;
      }
      for (final ModelProviderNativeEnvelope value
          in <ModelProviderNativeEnvelope>[
            affinity!.state!,
            decoded.affinity!.state!,
            terminal.affinityState!,
          ]) {
        expect(value.kind, 'fixture-affinity.v1');
        expect(value.compatibility, <String, Object?>{
          'owner': <String, Object?>{'binding': 'fixture'},
        });
        expect(value.data, <String, Object?>{
          'tokens': <Object?>['opaque-token', null, 0],
        });
        expect(() => value.compatibility.clear(), throwsUnsupportedError);
        expect(
          () => (value.compatibility['owner']! as Map<String, Object?>).clear(),
          throwsUnsupportedError,
        );
        expect(() => value.data.clear(), throwsUnsupportedError);
        expect(
          () => (value.data['tokens']! as List<Object?>).clear(),
          throwsUnsupportedError,
        );
      }
      expect(decoded.affinity!.state, isNot(same(state)));
      expect(terminal.affinityState, isNot(same(state)));
    });
  }

  test('affinity validates IDs and required nullable request keys', () async {
    for (final String id in <String>['', ' \t\n']) {
      expect(
        () => ModelProviderAffinity(id: id, state: null),
        throwsFormatException,
      );
    }
    for (final Object? invalid in <Object?>[
      <String, Object?>{'id': '', 'state': null},
      <String, Object?>{'id': ' \t\n', 'state': null},
      <String, Object?>{'id': 1, 'state': null},
      <String, Object?>{'id': 'scope'},
      <String, Object?>{'id': 'scope', 'state': true},
      <String, Object?>{
        'id': 'scope',
        'state': <String, Object?>{
          'kind': '',
          'compatibility': <String, Object?>{},
          'data': <String, Object?>{},
        },
      },
      true,
    ]) {
      final _EventService service = _EventService(_terminal());
      final Map<String, Object?> frame = await _dispatchEvent(
        service,
        mutateRequest: (wire) => wire['affinity'] = invalid,
      );
      expect(frame['kind'], 'streamFailure');
      expect(service.request, isNull);
    }
    final _EventService service = _EventService(_terminal());
    expect(
      (await _dispatchEvent(
        service,
        mutateRequest: (wire) => wire.remove('affinity'),
      ))['kind'],
      'streamFailure',
    );
    expect(service.request, isNull);
  });

  for (final (int? read, int? write) in <(int?, int?)>[
    (12, 8),
    (0, 0),
    (12, null),
    (null, 8),
    (null, null),
  ]) {
    test('generated cache usage round-trips read=$read write=$write', () async {
      final ModelProviderUsage usage = ModelProviderUsage(
        inputTokens: null,
        outputTokens: null,
        cacheReadTokens: read,
        cacheWriteTokens: write,
        providerDetails: const <String, Object?>{},
      );
      final Map<String, Object?> encoded = await _generatedEvent(
        _terminal(usage: usage),
      );
      final Map<String, Object?> expected = <String, Object?>{
        'inputTokens': null,
        'outputTokens': null,
        'cacheReadTokens': read,
        'cacheWriteTokens': write,
        'providerDetails': <String, Object?>{},
      };
      expect((encoded['terminal']! as Map<String, Object?>)['usage'], expected);
      final ModelProviderUsage decoded = (await ModelProviderServiceClient(
        _Channel(event: encoded),
      ).invoke(_request()).single).terminal!.usage!;
      expect(decoded.inputTokens, isNull);
      expect(decoded.outputTokens, isNull);
      expect(decoded.cacheReadTokens, read);
      expect(decoded.cacheWriteTokens, write);
      expect(decoded.providerDetails, isEmpty);
      expect(decoded, isNot(same(usage)));
    });
  }

  test(
    'generated absent usage remains distinct from present all-null usage',
    () async {
      final Map<String, Object?> encoded = await _generatedEvent(
        _terminal(reportUsage: false),
      );
      final Map<String, Object?> terminal =
          encoded['terminal']! as Map<String, Object?>;
      expect(terminal, containsPair('usage', null));
      expect(
        (await ModelProviderServiceClient(
          _Channel(event: encoded),
        ).invoke(_request()).single).terminal!.usage,
        isNull,
      );
    },
  );

  test('terminal and cache usage nullable wire keys remain required', () async {
    for (final String key in <String>[
      'affinityState',
      'usage',
      'cacheReadTokens',
      'cacheWriteTokens',
    ]) {
      final Map<String, Object?> encoded = await _generatedEvent(_terminal());
      final Map<String, Object?> terminal =
          encoded['terminal']! as Map<String, Object?>;
      final Map<String, Object?> owner = key.startsWith('cache')
          ? terminal['usage']! as Map<String, Object?>
          : terminal;
      owner.remove(key);
      await expectLater(
        ModelProviderServiceClient(
          _Channel(event: encoded),
        ).invoke(_request()).single,
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });

  test(
    'cache usage rejects negative counts and malformed wire types',
    () async {
      for (final String key in <String>[
        'cacheReadTokens',
        'cacheWriteTokens',
      ]) {
        expect(
          () => ModelProviderUsage(
            inputTokens: null,
            outputTokens: null,
            cacheReadTokens: key == 'cacheReadTokens' ? -1 : null,
            cacheWriteTokens: key == 'cacheWriteTokens' ? -1 : null,
            providerDetails: const <String, Object?>{},
          ),
          throwsFormatException,
        );
        for (final Object invalid in <Object>[-1, 1.5, '0', false]) {
          final Map<String, Object?> encoded = await _generatedEvent(
            _terminal(),
          );
          ((encoded['terminal']! as Map<String, Object?>)['usage']!
                  as Map<String, Object?>)[key] =
              invalid;
          await expectLater(
            ModelProviderServiceClient(
              _Channel(event: encoded),
            ).invoke(_request()).single,
            throwsA(isA<AdeleProtocolException>()),
          );
        }
      }
    },
  );

  for (final bool present in <bool>[false, true]) {
    test('generated native output round-trips presentation=$present', () async {
      final Map<String, Object?> nested = <String, Object?>{
        'text': 'Safe detail',
      };
      final List<Object?> parts = <Object?>[nested, true, null, 1, 1.5];
      final Map<String, Object?> data = <String, Object?>{'parts': parts};
      final ModelProviderNativePresentation? presentation = present
          ? ModelProviderNativePresentation(
              kind: 'display.fixture.v2',
              compactText: ' Safe heading.\n',
              data: data,
            )
          : null;
      final ModelProviderNativeEnvelope native = _native('opaque');
      final ModelProviderOutput output = ModelProviderOutput(
        kind: ModelProviderOutputKind.nativeItem,
        text: null,
        toolProposal: null,
        itemId: 'native-1',
        nativeMetadata: native,
        nativePresentation: presentation,
      );
      nested['text'] = 'Changed';
      parts.clear();
      data.clear();

      final Map<String, Object?> encoded = await _generatedOutputEvent(output);
      final Map<String, Object?> wireOutput =
          encoded['output']! as Map<String, Object?>;
      expect(wireOutput['nativeMetadata'], <String, Object?>{
        'kind': native.kind,
        'compatibility': native.compatibility,
        'data': native.data,
      });
      expect(wireOutput, contains('nativePresentation'));
      expect(
        wireOutput['nativePresentation'],
        present
            ? <String, Object?>{
                'kind': 'display.fixture.v2',
                'compactText': ' Safe heading.\n',
                'data': <String, Object?>{
                  'parts': <Object?>[
                    <String, Object?>{'text': 'Safe detail'},
                    true,
                    null,
                    1,
                    1.5,
                  ],
                },
              }
            : null,
      );

      final ModelProviderOutput decoded = (await ModelProviderServiceClient(
        _Channel(event: encoded),
      ).invoke(_request()).single).output!;
      expect(decoded.kind, ModelProviderOutputKind.nativeItem);
      expect(decoded.itemId, output.itemId);
      expect(decoded.text, isNull);
      expect(decoded.toolProposal, isNull);
      expect(decoded.nativeMetadata!.kind, native.kind);
      expect(decoded.nativeMetadata!.compatibility, native.compatibility);
      expect(decoded.nativeMetadata!.data, native.data);
      expect(decoded.nativeMetadata, isNot(same(native)));
      if (!present) {
        expect(decoded.nativePresentation, isNull);
        return;
      }
      expect(decoded.nativePresentation!.kind, presentation!.kind);
      expect(decoded.nativePresentation!.compactText, presentation.compactText);
      expect(decoded.nativePresentation, isNot(same(presentation)));
      for (final ModelProviderNativePresentation value
          in <ModelProviderNativePresentation>[
            presentation,
            decoded.nativePresentation!,
          ]) {
        expect(value.data, presentation.data);
        expect(() => value.data.clear(), throwsUnsupportedError);
        final List<Object?> frozenParts = value.data['parts']! as List<Object?>;
        expect(() => frozenParts.clear(), throwsUnsupportedError);
        expect(
          () => (frozenParts.first! as Map<String, Object?>).clear(),
          throwsUnsupportedError,
        );
      }
    });
  }

  test(
    'presentation absence is explicit null, not an optional wire key',
    () async {
      final Map<String, Object?> event = _encodedTextOutput('Text');
      (event['output']! as Map<String, Object?>).remove('nativePresentation');
      await expectLater(
        ModelProviderServiceClient(
          _Channel(event: event),
        ).invoke(_request()).single,
        throwsA(isA<AdeleProtocolException>()),
      );
    },
  );

  test(
    'presentation is rejected on text and proposal outputs, including wire',
    () async {
      final ModelProviderNativePresentation presentation =
          ModelProviderNativePresentation(
            kind: 'display.fixture',
            compactText: 'Safe heading',
            data: const <String, Object?>{},
          );
      for (final ModelProviderOutputKind kind in <ModelProviderOutputKind>[
        ModelProviderOutputKind.text,
        ModelProviderOutputKind.toolProposal,
      ]) {
        final ModelProviderToolProposal? proposal =
            kind == ModelProviderOutputKind.toolProposal
            ? _proposal('call-1', 'item-1').output!.toolProposal
            : null;
        expect(
          () => ModelProviderOutput(
            kind: kind,
            text: proposal == null ? 'Text' : null,
            toolProposal: proposal,
            itemId: null,
            nativeMetadata: _native('opaque'),
            nativePresentation: presentation,
          ),
          throwsFormatException,
        );
        final Map<String, Object?> event = _encodedTextOutput('Text');
        final Map<String, Object?> output =
            event['output']! as Map<String, Object?>;
        output['kind'] = kind.name;
        output['text'] = proposal == null ? 'Text' : null;
        output['toolProposal'] = proposal == null
            ? null
            : <String, Object?>{
                'callId': proposal.callId,
                'name': proposal.name,
                'arguments': proposal.arguments,
              };
        output['nativePresentation'] = <String, Object?>{
          'kind': presentation.kind,
          'compactText': presentation.compactText,
          'data': presentation.data,
        };
        await expectLater(
          ModelProviderServiceClient(
            _Channel(event: event),
          ).invoke(_request()).single,
          throwsA(
            isA<AdeleProtocolException>().having(
              (error) => error.message,
              'bounded category error',
              'Invalid value for ModelProviderOutput.',
            ),
          ),
        );
      }
    },
  );

  test(
    'presentation validates labels and structured data at both boundaries',
    () async {
      final Map<String, Object?> cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      final List<Object?> cyclicList = <Object?>[];
      cyclicList.add(cyclicList);
      Object? deep = true;
      for (int i = 0; i < 64; i++) {
        deep = <Object?>[deep];
      }
      final List<Map<String, Object?>> invalidData = <Map<String, Object?>>[
        cyclic,
        <String, Object?>{'list': cyclicList},
        <String, Object?>{'deep': deep},
        for (final Object value in <Object>[
          double.nan,
          double.infinity,
          double.negativeInfinity,
          Object(),
          <int, Object?>{1: true},
        ])
          <String, Object?>{'value': value},
      ];
      final List<Map<String, Object?>> invalidPresentations =
          <Map<String, Object?>>[
            for (final String blank in <String>[
              '',
              ' \t\n',
            ]) ...<Map<String, Object?>>[
              <String, Object?>{
                'kind': blank,
                'compactText': 'Heading',
                'data': <String, Object?>{},
              },
              <String, Object?>{
                'kind': 'display.fixture',
                'compactText': blank,
                'data': <String, Object?>{},
              },
            ],
            for (final Map<String, Object?> data in invalidData)
              <String, Object?>{
                'kind': 'display.fixture',
                'compactText': 'Heading',
                'data': data,
              },
          ];
      for (final Map<String, Object?> invalid in invalidPresentations) {
        expect(
          () => ModelProviderNativePresentation(
            kind: invalid['kind']! as String,
            compactText: invalid['compactText']! as String,
            data: invalid['data']! as Map<String, Object?>,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString().length,
              'bounded error',
              lessThan(200),
            ),
          ),
        );
        final Map<String, Object?> event = _encodedTextOutput('Text');
        final Map<String, Object?> output =
            event['output']! as Map<String, Object?>;
        output['kind'] = 'nativeItem';
        output['text'] = null;
        output['nativeMetadata'] = <String, Object?>{
          'kind': 'opaque',
          'compatibility': <String, Object?>{},
          'data': <String, Object?>{'opaque': 'unchanged'},
        };
        output['nativePresentation'] = invalid;
        await expectLater(
          ModelProviderServiceClient(
            _Channel(event: event),
          ).invoke(_request()).single,
          throwsA(
            isA<AdeleProtocolException>().having(
              (error) => error.message.length,
              'bounded wire error',
              lessThan(200),
            ),
          ),
        );
      }
    },
  );

  test('presentation accepts shared data at the maximum container depth', () {
    Object? nested = true;
    for (int i = 0; i < 63; i++) {
      nested = <Object?>[nested];
    }
    final Map<String, Object?> data = <String, Object?>{
      'left': nested,
      'right': nested,
    };
    expect(
      ModelProviderNativePresentation(
        kind: 'display.fixture',
        compactText: 'Heading',
        data: data,
      ).data,
      data,
    );
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
        affinityState: null,
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
    expect(
      () => ModelProviderInput(
        kind: ModelProviderInputKind.nativeItem,
        message: null,
        toolProposal: null,
        toolOutcome: null,
        itemId: null,
        nativeMetadata: null,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelProviderOutput(
        kind: ModelProviderOutputKind.nativeItem,
        nativePresentation: null,
        text: 'semantic payload',
        toolProposal: null,
        itemId: null,
        nativeMetadata: _native('native'),
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
        affinity: null,
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

  test('failure and usage snapshot nested provider details', () {
    final Map<String, Object?> failureNested = <String, Object?>{
      'code': 'original',
    };
    final List<Object?> failureItems = <Object?>['original'];
    final Map<String, Object?> failureSource = <String, Object?>{
      'nested': failureNested,
      'items': failureItems,
    };
    final ModelProviderFailure failure = ModelProviderFailure(
      kind: ModelProviderFailureKind.providerFailure,
      providerCode: null,
      providerMessage: null,
      providerDetails: failureSource,
    );
    failureNested['code'] = 'mutated';
    failureItems.add('mutated');
    failureSource['late'] = true;
    expect(failure.providerDetails, const <String, Object?>{
      'nested': <String, Object?>{'code': 'original'},
      'items': <Object?>['original'],
    });
    expect(
      () =>
          (failure.providerDetails['nested']! as Map<String, Object?>)['code'] =
              'late',
      throwsUnsupportedError,
    );

    final Map<String, Object?> usageNested = <String, Object?>{
      'tier': 'original',
    };
    final List<Object?> usageItems = <Object?>['original'];
    final ModelProviderUsage usage = ModelProviderUsage(
      inputTokens: null,
      outputTokens: null,
      cacheReadTokens: null,
      cacheWriteTokens: null,
      providerDetails: <String, Object?>{
        'nested': usageNested,
        'items': usageItems,
      },
    );
    usageNested['tier'] = 'mutated';
    usageItems.add('mutated');
    expect(usage.providerDetails, const <String, Object?>{
      'nested': <String, Object?>{'tier': 'original'},
      'items': <Object?>['original'],
    });
    expect(
      () => (usage.providerDetails['items']! as List<Object?>).add('late'),
      throwsUnsupportedError,
    );
  });

  test('terminal provider details reject cyclic structures', () {
    final Map<String, Object?> cyclic = <String, Object?>{};
    cyclic['self'] = cyclic;
    expect(
      () => ModelProviderFailure(
        kind: ModelProviderFailureKind.providerFailure,
        providerCode: null,
        providerMessage: null,
        providerDetails: cyclic,
      ),
      throwsFormatException,
    );
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
      affinity: null,
    );

ModelProviderRequest _request({ModelProviderAffinity? affinity}) =>
    ModelProviderRequest(
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
      affinity: affinity,
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
        nativePresentation: null,
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
  nativePresentation: null,
  text: text,
  toolProposal: null,
  itemId: null,
  nativeMetadata: null,
);

ModelProviderEvent _terminal({
  ModelProviderUsage? usage,
  bool reportUsage = true,
  ModelProviderNativeEnvelope? affinityState,
}) => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.completed,
    incompleteReason: null,
    failure: null,
    providerStopReason: 'complete',
    usage: !reportUsage
        ? null
        : usage ??
              ModelProviderUsage(
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
    affinityState: affinityState,
  ),
);

ModelProviderNativeEnvelope _native(String kind) => ModelProviderNativeEnvelope(
  kind: '$kind-v1',
  compatibility: const <String, Object?>{'model': 'scripted-v1'},
  data: const <String, Object?>{'opaque': 'value'},
);

ModelProviderInput _nativeInput(String itemId, String kind) =>
    ModelProviderInput(
      kind: ModelProviderInputKind.nativeItem,
      message: null,
      toolProposal: null,
      toolOutcome: null,
      itemId: itemId,
      nativeMetadata: ModelProviderNativeEnvelope(
        kind: kind,
        compatibility: const <String, Object?>{'model': 'scripted-v1'},
        data: <String, Object?>{'item': itemId},
      ),
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

Future<Map<String, Object?>> _generatedOutputEvent(
  ModelProviderOutput output,
) => _generatedEvent(
  ModelProviderEvent(
    kind: ModelProviderEventKind.output,
    observation: null,
    output: output,
    terminal: null,
  ),
);

Future<Map<String, Object?>> _generatedEvent(ModelProviderEvent event) async {
  final Map<String, Object?> frame = await _dispatchEvent(_EventService(event));
  expect(frame['kind'], 'streamItem');
  return frame['payload']! as Map<String, Object?>;
}

Future<Map<String, Object?>> _dispatchEvent(
  _EventService service, {
  ModelProviderRequest? request,
  void Function(Map<String, Object?>)? mutateRequest,
}) async {
  final _CapturingChannel channel = _CapturingChannel();
  await ModelProviderServiceClient(
    channel,
  ).invoke(request ?? _request()).toList();
  mutateRequest?.call(channel.encodedRequest!);
  final ModelProviderServiceDispatcher dispatcher =
      ModelProviderServiceDispatcher(service);
  final Completer<Map<String, Object?>> received =
      Completer<Map<String, Object?>>();
  try {
    await dispatcher.handle(<String, Object?>{
      'kind': 'streamOpen',
      'requestId': 1,
      'method': modelProviderServiceInvokeId,
      'payload': <String, Object?>{'request': channel.encodedRequest},
    }, received.complete);
    await dispatcher.handle(<String, Object?>{
      'kind': 'streamCredit',
      'requestId': 1,
      'credit': 1,
    }, received.complete);
    return await received.future;
  } finally {
    await dispatcher.close();
  }
}

final class _EventService implements ModelProviderService {
  _EventService(this.event);

  final ModelProviderEvent event;
  ModelProviderRequest? request;

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) {
    this.request = request;
    return Stream<ModelProviderEvent>.value(event);
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
    'nativePresentation': null,
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
      'affinityState': null,
      'nativeState': <String, Object?>{
        'kind': terminal.nativeState!.kind,
        'compatibility': terminal.nativeState!.compatibility,
        'data': terminal.nativeState!.data,
      },
    },
  };
}
