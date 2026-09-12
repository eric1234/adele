import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart' show TaskId;
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

void main() {
  test('structured context flattens only text into the exact provider contract '
      'and remains captured across local retry', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    final ExtensionRegistrationGroup registrations =
        ExtensionRegistrationGroup();
    final List<String> sourceCalls = <String>[];
    final List<InferenceContextMaterial> alphaMaterials =
        <InferenceContextMaterial>[
          InferenceInstructionMaterial(
            key: 'second-key',
            text: 'Alpha first.\n',
            revision: 'alpha-revision',
          ),
          InferenceInstructionMaterial(
            key: 'first-key',
            text: ' \tAlpha second. ',
          ),
        ];
    final StateError optionalFailure = StateError('private source failure');
    for (final entry in <String, InferenceContextSourceContribution>{
      'zulu': InferenceContextSourceContribution(
        failureMode: InferenceContextFailureMode.required,
        snapshot: (_) async {
          sourceCalls.add('zulu');
          return <InferenceContextMaterial>[
            InferenceInstructionMaterial(
              key: 'zulu-key',
              text: 'Zulu.\r\n',
              revision: 'zulu-revision',
            ),
          ];
        },
      ),
      'failure': InferenceContextSourceContribution(
        failureMode: InferenceContextFailureMode.optional,
        snapshot: (_) async {
          sourceCalls.add('failure');
          throw optionalFailure;
        },
      ),
      'empty': InferenceContextSourceContribution(
        failureMode: InferenceContextFailureMode.optional,
        snapshot: (_) async {
          sourceCalls.add('empty');
          return const <InferenceContextMaterial>[];
        },
      ),
      'alpha': InferenceContextSourceContribution(
        failureMode: InferenceContextFailureMode.required,
        snapshot: (_) async {
          sourceCalls.add('alpha');
          return alphaMaterials;
        },
      ),
    }.entries) {
      registrations.add(
        registry.register(
          point: inferenceContextSources,
          id: ExtensionId('dev.adele.fixture.context.${entry.key}'),
          value: entry.value,
        ),
      );
    }
    addTearDown(registrations.close);
    final List<SemanticModelInputItem> input = <SemanticModelInputItem>[
      SemanticMessageInput(role: SemanticMessageRole.user, content: 'Inspect.'),
      SemanticToolProposalInput(
        proposal: ProviderToolProposal(
          providerCallId: 'call-1',
          alias: 'inspect_resource',
          arguments: const <String, Object?>{'uri': 'file:///tmp/example.dart'},
        ),
        providerItemId: 'proposal-1',
        providerNativeMetadata: ModelNativeEnvelope(
          kind: 'fixture-v1',
          compatibility: const <String, Object?>{'route': 'fixture'},
          data: const <String, Object?>{'signed': 'call-signature'},
        ),
      ),
      SemanticToolOutcomeInput(
        providerCallId: 'call-1',
        outcome: ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: 'Inspected.',
          hostData: const <String, Object?>{'private': 'host-only'},
        ),
      ),
    ];
    final InferenceContextSnapshot context =
        await InferenceContextComposer(registry).compose(
          strategyMaterial: StrategyInferenceMaterial(
            instructions: ' Strategy.\n',
            input: input,
          ),
          sourceContext: _SourceContext(),
        );
    final ToolCatalog catalog = ToolCatalog()
      ..register(
        ResourceInspectorToolExecutable(_resourceBinding()).registration,
      );
    final SemanticModelRequest request = SemanticModelRequest(
      invocationId: ModelInvocationId('captured-context'),
      context: context,
      tools: catalog.materialize(),
    );

    expect(sourceCalls, <String>['alpha', 'empty', 'failure', 'zulu']);
    expect(
      context.instructionGroups.first,
      isA<StrategyInstructionGroup>().having(
        (group) => group.instructions,
        'instructions',
        ' Strategy.\n',
      ),
    );
    final List<SourceInstructionGroup> sourceGroups = context.instructionGroups
        .whereType<SourceInstructionGroup>()
        .toList();
    expect(sourceGroups.map((group) => group.sourceId.value), <String>[
      'dev.adele.fixture.context.alpha',
      'dev.adele.fixture.context.zulu',
    ]);
    expect(
      sourceGroups.first.materials.map(
        (material) => (material.key, material.revision),
      ),
      <(String, String?)>[
        ('second-key', 'alpha-revision'),
        ('first-key', null),
      ],
    );
    expect(
      context.sourceResults.map((result) => result.status),
      <InferenceContextSourceStatus>[
        InferenceContextSourceStatus.contributed,
        InferenceContextSourceStatus.empty,
        InferenceContextSourceStatus.omitted,
        InferenceContextSourceStatus.contributed,
      ],
    );
    expect(
      context.sourceResults[2].failureMode,
      InferenceContextFailureMode.optional,
    );
    expect(context.sourceResults[2].failure!.cause, same(optionalFailure));
    expect(context.sourceResults[1].failure, isNull);

    late final _ProviderChannel channel;
    channel = _ProviderChannel(
      events: Stream<ModelProviderEvent>.multi((controller) {
        controller.add(
          channel.streamCount == 1 ? _failedTerminal() : _terminal(),
        );
        controller.close();
      }),
    );
    final ModelProviderCapabilityAdapter adapter =
        ModelProviderCapabilityAdapter(
          _binding(channel),
          selectedModel: 'scripted-v1',
          maxOutputTokens: 200,
          toolChoice: ModelProviderToolChoice.none,
          providerOptions: const <String, Object?>{'fixture': true},
        );
    final Stream<ModelEvent> firstAttempt = adapter.invoke(request);
    input.clear();
    alphaMaterials.clear();
    catalog.remove(resourceInspectionToolId);
    await registrations.close();

    for (var attempt = 0; attempt < 2; attempt++) {
      final List<ModelEvent> events =
          await (attempt == 0 ? firstAttempt : adapter.invoke(request))
              .toList();
      expect(
        events.single,
        attempt == 0
            ? isA<ModelInvocationFailedEvent>()
            : isA<ModelInvocationSettledEvent>(),
      );
      expect(events.single.invocationId, same(request.invocationId));
      expect(channel.lastPayload!.keys, <String>['request']);
      final Map<Object?, Object?> encoded =
          channel.lastPayload!['request']! as Map<Object?, Object?>;
      expect(
        encoded.keys,
        unorderedEquals(<String>[
          'model',
          'instructions',
          'input',
          'tools',
          'toolChoice',
          'maxOutputTokens',
          'providerOptions',
          'nativeState',
        ]),
      );
      expect(encoded, <String, Object?>{
        'model': 'scripted-v1',
        'instructions':
            ' Strategy.\n\n\nAlpha first.\n\n\n \tAlpha second. \n\nZulu.\r\n',
        'input': <Object?>[
          <String, Object?>{
            'kind': 'message',
            'message': <String, Object?>{
              'role': 'user',
              'content': <Object?>[
                <String, Object?>{'kind': 'text', 'text': 'Inspect.'},
              ],
            },
            'toolProposal': null,
            'toolOutcome': null,
            'itemId': null,
            'nativeMetadata': null,
          },
          <String, Object?>{
            'kind': 'toolProposal',
            'message': null,
            'toolProposal': <String, Object?>{
              'callId': 'call-1',
              'name': 'inspect_resource',
              'arguments': <String, Object?>{'uri': 'file:///tmp/example.dart'},
            },
            'toolOutcome': null,
            'itemId': 'proposal-1',
            'nativeMetadata': <String, Object?>{
              'kind': 'fixture-v1',
              'compatibility': <String, Object?>{'route': 'fixture'},
              'data': <String, Object?>{'signed': 'call-signature'},
            },
          },
          <String, Object?>{
            'kind': 'toolOutcome',
            'message': null,
            'toolProposal': null,
            'toolOutcome': <String, Object?>{
              'callId': 'call-1',
              'status': 'success',
              'content': 'Inspected.',
            },
            'itemId': null,
            'nativeMetadata': null,
          },
        ],
        'tools': <Object?>[
          <String, Object?>{
            'name': 'inspect_resource',
            'description':
                'Inspect one resource identified by an absolute URI.',
            'argumentsSchema': <String, Object?>{
              'type': 'object',
              'required': <Object?>['uri'],
              'properties': <String, Object?>{
                'uri': <String, Object?>{'type': 'string', 'format': 'uri'},
              },
              'additionalProperties': false,
            },
          },
        ],
        'toolChoice': 'none',
        'maxOutputTokens': 200,
        'providerOptions': <String, Object?>{'fixture': true},
        'nativeState': null,
      });
      expect(request.instructions, encoded['instructions']);
    }
    expect(request.context, same(context));
    expect(sourceCalls, <String>['alpha', 'empty', 'failure', 'zulu']);
    expect(adapter.invocationCount, 2);
    expect(channel.streamCount, 2);
    expect(channel.requestCount, 0);
  });

  for (final String strategy in <String>['', ' Strategy only.\n']) {
    for (final String? source in <String?>[null, ' \tSource only.\n']) {
      test(
        'context rendering handles ${strategy.isEmpty ? 'empty' : 'nonempty'} '
        'strategy and ${source == null ? 'zero' : 'one'} sources',
        () async {
          final ExtensionRegistry registry = ExtensionRegistry();
          if (source != null) {
            final ExtensionRegistration registration = registry.register(
              point: inferenceContextSources,
              id: ExtensionId('dev.adele.fixture.context.only'),
              value: InferenceContextSourceContribution(
                failureMode: InferenceContextFailureMode.required,
                snapshot: (_) async => <InferenceContextMaterial>[
                  InferenceInstructionMaterial(key: 'only', text: source),
                ],
              ),
            );
            addTearDown(registration.close);
          }
          final InferenceContextSnapshot context =
              await InferenceContextComposer(registry).compose(
                strategyMaterial: StrategyInferenceMaterial(
                  instructions: strategy,
                  input: const <SemanticModelInputItem>[],
                ),
                sourceContext: _SourceContext(),
              );
          final _ProviderChannel channel = _ProviderChannel(
            events: Stream<ModelProviderEvent>.value(_terminal()),
          );

          final List<ModelEvent> events =
              await ModelProviderCapabilityAdapter(
                    _binding(channel),
                    selectedModel: 'scripted-v1',
                  )
                  .invoke(
                    SemanticModelRequest(
                      invocationId: ModelInvocationId('empty-context'),
                      context: context,
                      tools: MaterializedToolSet(const <MaterializedTool>[]),
                    ),
                  )
                  .toList();

          expect(events.single, isA<ModelInvocationSettledEvent>());
          final Map<Object?, Object?> encoded =
              channel.lastPayload!['request']! as Map<Object?, Object?>;
          expect(
            encoded['instructions'],
            source == null
                ? strategy
                : strategy.isEmpty
                ? source
                : '$strategy\n\n$source',
          );
          expect(encoded['input'], isEmpty);
          expect(encoded['tools'], isEmpty);
        },
      );
    }
  }

  test(
    'common adapter preserves multiple proposals and metadata through replay',
    () async {
      final _ProviderChannel channel = _ProviderChannel(
        events: Stream<ModelProviderEvent>.fromIterable(<ModelProviderEvent>[
          _delta('Inspecting '),
          _native('native-1', 'reasoning-v1'),
          _text('Inspecting.', 'text-1'),
          _proposal('call-z', 'item-z', 'file:///tmp/first.dart'),
          _proposal('call-a', 'item-a', 'file:///tmp/second.dart'),
          _terminal(),
        ]),
      );
      final ModelProviderCapabilityAdapter adapter =
          ModelProviderCapabilityAdapter(
            _binding(channel),
            selectedModel: 'scripted-v1',
            maxOutputTokens: 200,
            toolChoice: ModelProviderToolChoice.none,
            providerOptions: const <String, Object?>{'fixture': true},
          );

      final List<ModelEvent> events = await adapter.invoke(_request()).toList();

      expect(channel.requestCount, 0);
      expect(channel.streamCount, 1);
      expect(channel.lastPayload!['request'], isA<Map<Object?, Object?>>());
      expect(events, <Matcher>[
        isA<ModelObservationEvent>().having(
          (ModelObservationEvent event) =>
              (event.observation as ModelTextDeltaObservation).delta,
          'delta',
          'Inspecting ',
        ),
        isA<ModelOutputItemCompleted>().having(
          (ModelOutputItemCompleted event) =>
              (event.item as ModelNativeOutput).providerItemId,
          'native item ID',
          'native-1',
        ),
        isA<ModelOutputItemCompleted>(),
        isA<ModelOutputItemCompleted>().having(
          (ModelOutputItemCompleted event) =>
              (event.item as ModelToolProposalOutput).providerItemId,
          'item ID',
          'item-z',
        ),
        isA<ModelOutputItemCompleted>().having(
          (ModelOutputItemCompleted event) =>
              (event.item as ModelToolProposalOutput).providerItemId,
          'item ID',
          'item-a',
        ),
        isA<ModelInvocationSettledEvent>(),
      ]);
      final List<ModelToolProposalOutput> proposals = events
          .whereType<ModelOutputItemCompleted>()
          .map((event) => event.item)
          .whereType<ModelToolProposalOutput>()
          .toList(growable: false);
      expect(proposals.map((item) => item.proposal.providerCallId), <String>[
        'call-z',
        'call-a',
      ]);
      for (var index = 0; index < proposals.length; index++) {
        final ModelToolProposalOutput output = proposals[index];
        expect(output.proposal.alias, 'inspect_resource');
        expect(output.proposal.arguments, <String, Object?>{
          'uri': index == 0
              ? 'file:///tmp/first.dart'
              : 'file:///tmp/second.dart',
        });
        expect(output.providerNativeMetadata!.kind, 'fixture-v1');
        expect(output.providerNativeMetadata!.compatibility, <String, Object?>{
          'route': 'fixture',
        });
        expect(output.providerNativeMetadata!.data, <String, Object?>{
          'signed': '${output.proposal.providerCallId}-signature',
        });
      }

      final _ProviderChannel replayChannel = _ProviderChannel(
        events: Stream<ModelProviderEvent>.value(_terminal()),
      );
      await ModelProviderCapabilityAdapter(
            _binding(replayChannel),
            selectedModel: 'scripted-v1',
          )
          .invoke(
            SemanticModelRequest(
              invocationId: ModelInvocationId('replay-proposals'),
              context: InferenceContextSnapshot.fromStrategy(
                StrategyInferenceMaterial(
                  input: <SemanticModelInputItem>[
                    for (final ModelToolProposalOutput output in proposals)
                      SemanticToolProposalInput(
                        proposal: output.proposal,
                        providerItemId: output.providerItemId,
                        providerNativeMetadata: output.providerNativeMetadata,
                      ),
                  ],
                ),
              ),
              tools: MaterializedToolSet(const <MaterializedTool>[]),
            ),
          )
          .toList();
      final Map<Object?, Object?> replayRequest =
          replayChannel.lastPayload!['request']! as Map<Object?, Object?>;
      expect(replayRequest['input'], <Object?>[
        for (final ModelToolProposalOutput output in proposals)
          <String, Object?>{
            'kind': 'toolProposal',
            'message': null,
            'toolProposal': <String, Object?>{
              'callId': output.proposal.providerCallId,
              'name': 'inspect_resource',
              'arguments': output.proposal.arguments,
            },
            'toolOutcome': null,
            'itemId': output.providerItemId,
            'nativeMetadata': <String, Object?>{
              'kind': 'fixture-v1',
              'compatibility': <String, Object?>{'route': 'fixture'},
              'data': <String, Object?>{
                'signed': '${output.proposal.providerCallId}-signature',
              },
            },
          },
      ]);
    },
  );

  test('common adapter lowers native-only semantic input exactly', () async {
    final _ProviderChannel channel = _ProviderChannel(
      events: Stream<ModelProviderEvent>.value(_terminal()),
    );
    await ModelProviderCapabilityAdapter(
          _binding(channel),
          selectedModel: 'scripted-v1',
        )
        .invoke(
          SemanticModelRequest(
            invocationId: ModelInvocationId('native-replay'),
            context: InferenceContextSnapshot.fromStrategy(
              StrategyInferenceMaterial(
                input: <SemanticModelInputItem>[
                  SemanticNativeInput(
                    providerItemId: 'native-1',
                    providerNativeMetadata: ModelNativeEnvelope(
                      kind: 'reasoning-v1',
                      compatibility: const <String, Object?>{
                        'route': 'fixture',
                      },
                      data: const <String, Object?>{'opaque': 'signed'},
                    ),
                  ),
                ],
              ),
            ),
            tools: MaterializedToolSet(const <MaterializedTool>[]),
          ),
        )
        .toList();

    final Map<Object?, Object?> request =
        channel.lastPayload!['request']! as Map<Object?, Object?>;
    final Map<Object?, Object?> input =
        (request['input']! as List<Object?>).single! as Map<Object?, Object?>;
    expect(input['kind'], 'nativeItem');
    expect(input['itemId'], 'native-1');
    expect(input['message'], isNull);
    expect(input['toolProposal'], isNull);
    expect(input['toolOutcome'], isNull);
    expect(input['nativeMetadata'], <String, Object?>{
      'kind': 'reasoning-v1',
      'compatibility': <String, Object?>{'route': 'fixture'},
      'data': <String, Object?>{'opaque': 'signed'},
    });
  });

  test(
    'common adapter preserves partial output before semantic failure',
    () async {
      final _ProviderChannel channel = _ProviderChannel(
        events: Stream<ModelProviderEvent>.fromIterable(<ModelProviderEvent>[
          _text('Partial.', 'partial-1'),
          _failedTerminal(),
        ]),
      );
      final List<ModelEvent> events = await ModelProviderCapabilityAdapter(
        _binding(channel),
        selectedModel: 'scripted-v1',
      ).invoke(_request()).toList();

      expect(events, <Matcher>[
        isA<ModelOutputItemCompleted>(),
        isA<ModelInvocationFailedEvent>().having(
          (ModelInvocationFailedEvent event) => event.error,
          'structured failure',
          isA<ModelFailure>().having(
            (ModelFailure failure) => failure.kind,
            'kind',
            ModelFailureKind.rateLimited,
          ),
        ),
      ]);
      final ModelInvocationFailedEvent failure =
          events.last as ModelInvocationFailedEvent;
      expect(failure.semanticTerminalMetadata!.effectiveModel, 'scripted-v1');
      expect(failure.semanticTerminalMetadata!.providerRequestId, 'request-f');
      expect(
        failure.semanticTerminalMetadata!.providerResponseId,
        'response-f',
      );
      expect(failure.semanticTerminalMetadata!.providerStopReason, 'error');
      expect(failure.semanticTerminalMetadata!.usage!.inputTokens, 4);
      expect(
        failure.semanticTerminalMetadata!.providerNativeState!.kind,
        'failure-state-v1',
      );
    },
  );

  test('EOF before semantic terminal fails', () async {
    final List<ModelEvent> events = await ModelProviderCapabilityAdapter(
      _binding(
        _ProviderChannel(
          events: Stream<ModelProviderEvent>.value(_text('Partial.', 'p')),
        ),
      ),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList();
    expect(events.last, isA<ModelInvocationFailedEvent>());
  });

  test('transport error after terminal does not replace settlement', () async {
    final Stream<ModelProviderEvent> events = Stream<ModelProviderEvent>.multi((
      controller,
    ) {
      controller.add(_terminal());
      controller.addError(StateError('late teardown'));
    });
    final List<ModelEvent> mapped = await ModelProviderCapabilityAdapter(
      _binding(_ProviderChannel(events: events)),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList();
    expect(mapped, hasLength(1));
    expect(mapped.single, isA<ModelInvocationSettledEvent>());
  });

  test(
    'semantic terminal settles while provider transport remains open',
    () async {
      final Completer<void> cancelled = Completer<void>();
      late final StreamController<ModelProviderEvent> source;
      source = StreamController<ModelProviderEvent>(
        onListen: () => source.add(_terminal()),
        onCancel: () => cancelled.complete(),
      );

      final List<ModelEvent> mapped = await ModelProviderCapabilityAdapter(
        _binding(_ProviderChannel(events: source.stream)),
        selectedModel: 'scripted-v1',
      ).invoke(_request()).toList().timeout(const Duration(seconds: 1));

      expect(mapped, <Matcher>[isA<ModelInvocationSettledEvent>()]);
      await cancelled.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'semantic completion does not await blocked transport cleanup',
    () async {
      final Completer<void> cancellationStarted = Completer<void>();
      final Completer<void> releaseCancellation = Completer<void>();
      late final StreamController<ModelProviderEvent> source;
      source = StreamController<ModelProviderEvent>(
        sync: true,
        onListen: () => source.add(_terminal()),
        onCancel: () async {
          cancellationStarted.complete();
          await releaseCancellation.future;
        },
      );

      final List<ModelEvent> mapped = await ModelProviderCapabilityAdapter(
        _binding(_ProviderChannel(events: source.stream)),
        selectedModel: 'scripted-v1',
      ).invoke(_request()).toList().timeout(const Duration(seconds: 1));

      expect(mapped, <Matcher>[isA<ModelInvocationSettledEvent>()]);
      await cancellationStarted.future.timeout(const Duration(seconds: 1));
      releaseCancellation.complete();
    },
  );

  test('take one terminal awaits the same blocked transport cleanup', () async {
    final Completer<void> cancellationStarted = Completer<void>();
    final Completer<void> releaseCancellation = Completer<void>();
    late final StreamController<ModelProviderEvent> source;
    source = StreamController<ModelProviderEvent>(
      sync: true,
      onListen: () => source.add(_terminal()),
      onCancel: () async {
        cancellationStarted.complete();
        await releaseCancellation.future;
      },
    );
    bool consumerCompleted = false;
    final Future<List<ModelEvent>> result =
        ModelProviderCapabilityAdapter(
          _binding(_ProviderChannel(events: source.stream)),
          selectedModel: 'scripted-v1',
        ).invoke(_request()).take(1).toList().whenComplete(() {
          consumerCompleted = true;
        });

    await cancellationStarted.future.timeout(const Duration(seconds: 1));
    expect(consumerCompleted, isFalse);
    releaseCancellation.complete();

    final List<ModelEvent> events = await result.timeout(
      const Duration(seconds: 1),
    );
    expect(events, <Matcher>[isA<ModelInvocationSettledEvent>()]);
    expect(consumerCompleted, isTrue);
  });

  test('synchronous terminal eventually cancels assigned transport', () async {
    final Completer<void> cancelled = Completer<void>();
    late final StreamController<ModelProviderEvent> source;
    source = StreamController<ModelProviderEvent>(
      sync: true,
      onListen: () => source.add(_terminal()),
      onCancel: () => cancelled.complete(),
    );

    final List<ModelEvent> mapped = await ModelProviderCapabilityAdapter(
      _binding(_ProviderChannel(events: source.stream)),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList().timeout(const Duration(seconds: 1));

    expect(mapped, <Matcher>[isA<ModelInvocationSettledEvent>()]);
    await cancelled.future.timeout(const Duration(seconds: 1));
  });

  test('whitespace completed text maps and lowers for replay', () async {
    final List<ModelEvent> events = await ModelProviderCapabilityAdapter(
      _binding(
        _ProviderChannel(
          events: Stream<ModelProviderEvent>.fromIterable(<ModelProviderEvent>[
            _text(' ', 'space-1'),
            _terminal(),
          ]),
        ),
      ),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList();
    final ModelTextOutput output =
        (events.first as ModelOutputItemCompleted).item as ModelTextOutput;
    expect(output.content, ' ');

    final _ProviderChannel replayChannel = _ProviderChannel(
      events: Stream<ModelProviderEvent>.value(_terminal()),
    );
    await ModelProviderCapabilityAdapter(
          _binding(replayChannel),
          selectedModel: 'scripted-v1',
        )
        .invoke(
          SemanticModelRequest(
            invocationId: ModelInvocationId('replay-space'),
            context: InferenceContextSnapshot.fromStrategy(
              StrategyInferenceMaterial(
                input: <SemanticModelInputItem>[
                  SemanticMessageInput(
                    role: SemanticMessageRole.assistant,
                    content: output.content,
                  ),
                ],
              ),
            ),
            tools: MaterializedToolSet(const <MaterializedTool>[]),
          ),
        )
        .toList();
    expect(replayChannel.streamCount, 1);
  });

  test('terminal settlement contains transport cancellation failure', () async {
    late final StreamController<ModelProviderEvent> source;
    source = StreamController<ModelProviderEvent>(
      onListen: () => source.add(_terminal()),
      onCancel: () async => throw StateError('cleanup failed'),
    );

    final List<ModelEvent> mapped = await ModelProviderCapabilityAdapter(
      _binding(_ProviderChannel(events: source.stream)),
      selectedModel: 'scripted-v1',
    ).invoke(_request()).toList().timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    expect(mapped, <Matcher>[isA<ModelInvocationSettledEvent>()]);
  });

  test('consumer cancellation reaches underlying stream', () async {
    final Completer<void> cancelled = Completer<void>();
    final StreamController<ModelProviderEvent> source =
        StreamController<ModelProviderEvent>(
          onCancel: () => cancelled.complete(),
        );
    final StreamSubscription<ModelEvent> subscription =
        ModelProviderCapabilityAdapter(
          _binding(_ProviderChannel(events: source.stream)),
          selectedModel: 'scripted-v1',
        ).invoke(_request()).listen((_) {});

    await subscription.cancel();
    await cancelled.future;
  });

  test('synchronous consumer cancellation awaits assigned transport', () async {
    final Completer<void> cancellationStarted = Completer<void>();
    final Completer<void> releaseCancellation = Completer<void>();
    late final StreamController<ModelProviderEvent> source;
    source = StreamController<ModelProviderEvent>(
      sync: true,
      onListen: () => source.add(_delta('first')),
      onCancel: () async {
        cancellationStarted.complete();
        await releaseCancellation.future;
      },
    );
    bool consumerCompleted = false;
    final Future<List<ModelEvent>> result =
        ModelProviderCapabilityAdapter(
          _binding(_ProviderChannel(events: source.stream)),
          selectedModel: 'scripted-v1',
        ).invoke(_request()).take(1).toList().whenComplete(() {
          consumerCompleted = true;
        });

    await cancellationStarted.future.timeout(const Duration(seconds: 1));
    expect(consumerCompleted, isFalse);
    releaseCancellation.complete();

    expect(await result.timeout(const Duration(seconds: 1)), hasLength(1));
    expect(consumerCompleted, isTrue);
  });

  test(
    'synchronous consumer pause is applied after transport assignment',
    () async {
      final Completer<void> providerPaused = Completer<void>();
      final Completer<void> providerResumed = Completer<void>();
      final Completer<void> releaseConsumer = Completer<void>();
      final List<ModelEvent> delivered = <ModelEvent>[];
      late final StreamController<ModelProviderEvent> source;
      source = StreamController<ModelProviderEvent>(
        sync: true,
        onListen: () => source.add(_delta('first')),
        onPause: () {
          if (!providerPaused.isCompleted) providerPaused.complete();
        },
        onResume: () {
          if (!providerResumed.isCompleted) providerResumed.complete();
        },
      );
      final Future<List<ModelEvent>> result =
          ModelProviderCapabilityAdapter(
            _binding(_ProviderChannel(events: source.stream)),
            selectedModel: 'scripted-v1',
          ).invoke(_request()).asyncMap((ModelEvent event) async {
            delivered.add(event);
            if (delivered.length == 1) await releaseConsumer.future;
            return event;
          }).toList();

      await providerPaused.future.timeout(const Duration(seconds: 1));
      source.add(_delta('second'));
      expect(delivered, hasLength(1));
      releaseConsumer.complete();
      await providerResumed.future.timeout(const Duration(seconds: 1));
      source.add(_terminal());

      expect(await result.timeout(const Duration(seconds: 1)), hasLength(3));
    },
  );

  test(
    'synchronous setup failure with take one does not await transport',
    () async {
      final StateError setupFailure = StateError('synchronous setup failure');
      final ModelProviderCapabilityAdapter adapter =
          ModelProviderCapabilityAdapter(
            _binding(_ThrowingStreamChannel(setupFailure)),
            selectedModel: 'scripted-v1',
          );

      for (final Stream<ModelEvent> stream in <Stream<ModelEvent>>[
        adapter.invoke(_request()).take(1),
        adapter.invoke(_request()),
      ]) {
        final List<ModelEvent> events = await stream.toList().timeout(
          const Duration(seconds: 1),
        );
        expect(events, hasLength(1));
        expect(
          events.single,
          isA<ModelInvocationFailedEvent>().having(
            (ModelInvocationFailedEvent event) => event.error,
            'error',
            same(setupFailure),
          ),
        );
      }
    },
  );

  test('adapter snapshots nested provider options at construction', () async {
    final Map<String, Object?> nested = <String, Object?>{'mode': 'original'};
    final List<Object?> values = <Object?>['original'];
    final _ProviderChannel channel = _ProviderChannel(
      events: Stream<ModelProviderEvent>.value(_terminal()),
    );
    final ModelProviderCapabilityAdapter adapter =
        ModelProviderCapabilityAdapter(
          _binding(channel),
          selectedModel: 'scripted-v1',
          providerOptions: <String, Object?>{
            'nested': nested,
            'values': values,
          },
        );
    nested['mode'] = 'mutated';
    values.add('mutated');

    await adapter.invoke(_request()).toList();

    final Map<Object?, Object?> encodedRequest =
        channel.lastPayload!['request']! as Map<Object?, Object?>;
    expect(encodedRequest['providerOptions'], const <String, Object?>{
      'nested': <String, Object?>{'mode': 'original'},
      'values': <Object?>['original'],
    });
    expect(
      () =>
          (adapter.providerOptions['nested']! as Map<String, Object?>)['mode'] =
              'late',
      throwsUnsupportedError,
    );
    expect(
      () => (adapter.providerOptions['values']! as List<Object?>).add('late'),
      throwsUnsupportedError,
    );
  });

  test('ResourceInspector validates its exact argument shape', () {
    final ResourceInspectorToolExecutable executable =
        ResourceInspectorToolExecutable(_resourceBinding());
    expect(
      executable.validateAndNormalize(const <String, Object?>{
        'uri': 'file:///tmp/example.dart',
      }).snapshot,
      const <String, Object?>{'uri': 'file:///tmp/example.dart'},
    );
    for (final Map<String, Object?> invalid in <Map<String, Object?>>[
      const <String, Object?>{},
      const <String, Object?>{'uri': 42},
      const <String, Object?>{'uri': 'relative/path'},
      const <String, Object?>{'uri': 'file:///tmp/example.dart', 'extra': true},
    ]) {
      expect(
        () => executable.validateAndNormalize(invalid),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
  });

  test('ResourceInspector unavailable endpoint does not dispatch', () async {
    final _UnusedChannel channel = _UnusedChannel();
    bool available = true;
    final ResourceInspectorToolExecutable executable =
        ResourceInspectorToolExecutable(
          _resourceBinding(channel: channel, isAvailable: () => available),
        );
    final CanonicalToolArguments arguments = executable.validateAndNormalize(
      const <String, Object?>{'uri': 'file:///tmp/example.dart'},
    );
    available = false;
    final ToolOutcome outcome =
        (await executable
                    .execute(
                      arguments,
                      ToolExecutionContext(
                        runId: RunId('run-1'),
                        sessionId: SessionId('session-1'),
                      ),
                    )
                    .single
                as ToolExecutionTerminal)
            .outcome;
    expect(outcome.failureKind, ToolFailureKind.infrastructure);
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(channel.requestCount, 0);
  });
}

SemanticModelRequest _request() => SemanticModelRequest(
  invocationId: ModelInvocationId('model-1'),
  context: InferenceContextSnapshot.fromStrategy(
    StrategyInferenceMaterial(
      instructions: 'Be concise.',
      input: <SemanticModelInputItem>[
        SemanticMessageInput(
          role: SemanticMessageRole.user,
          content: 'Inspect.',
        ),
      ],
    ),
  ),
  tools: MaterializedToolSet(const <MaterializedTool>[]),
);

final class _SourceContext implements InferenceContextSourceContext {
  @override
  final Session session = Session(
    id: SessionId('session-context'),
    taskId: TaskId('task-context'),
    strategyId: OrchestrationStrategyId('dev.adele.strategy.fixture'),
  );

  @override
  final RunId runId = RunId('run-context');

  @override
  Future<T> requireHostService<T extends Object>() =>
      throw StateError('The fixture does not require host services.');
}

ModelProviderEvent _delta(String text) => ModelProviderEvent(
  kind: ModelProviderEventKind.observation,
  observation: ModelProviderObservation(
    kind: ModelProviderObservationKind.textDelta,
    textDelta: text,
    itemId: null,
  ),
  output: null,
  terminal: null,
);

ModelProviderEvent _text(String text, String itemId) => ModelProviderEvent(
  kind: ModelProviderEventKind.output,
  observation: null,
  output: ModelProviderOutput(
    kind: ModelProviderOutputKind.text,
    text: text,
    toolProposal: null,
    itemId: itemId,
    nativeMetadata: null,
  ),
  terminal: null,
);

ModelProviderEvent _native(String itemId, String kind) => ModelProviderEvent(
  kind: ModelProviderEventKind.output,
  observation: null,
  output: ModelProviderOutput(
    kind: ModelProviderOutputKind.nativeItem,
    text: null,
    toolProposal: null,
    itemId: itemId,
    nativeMetadata: ModelProviderNativeEnvelope(
      kind: kind,
      compatibility: const <String, Object?>{'route': 'fixture'},
      data: const <String, Object?>{'opaque': 'signed'},
    ),
  ),
  terminal: null,
);

ModelProviderEvent _proposal(String callId, String itemId, String uri) =>
    ModelProviderEvent(
      kind: ModelProviderEventKind.output,
      observation: null,
      output: ModelProviderOutput(
        kind: ModelProviderOutputKind.toolProposal,
        text: null,
        toolProposal: ModelProviderToolProposal(
          callId: callId,
          name: 'inspect_resource',
          arguments: <String, Object?>{'uri': uri},
        ),
        itemId: itemId,
        nativeMetadata: ModelProviderNativeEnvelope(
          kind: 'fixture-v1',
          compatibility: const <String, Object?>{'route': 'fixture'},
          data: <String, Object?>{'signed': '$callId-signature'},
        ),
      ),
      terminal: null,
    );

ModelProviderEvent _terminal() => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.completed,
    incompleteReason: null,
    failure: null,
    providerStopReason: 'stop',
    usage: null,
    effectiveModel: 'scripted-v1',
    responseId: 'response-1',
    requestId: 'request-1',
    nativeState: null,
  ),
);

ModelProviderEvent _failedTerminal() => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.failed,
    incompleteReason: null,
    failure: ModelProviderFailure(
      kind: ModelProviderFailureKind.rateLimited,
      providerCode: '429',
      providerMessage: 'Slow down.',
      providerDetails: const <String, Object?>{},
    ),
    providerStopReason: 'error',
    usage: ModelProviderUsage(
      inputTokens: 4,
      outputTokens: 2,
      cacheReadTokens: null,
      cacheWriteTokens: null,
      providerDetails: const <String, Object?>{},
    ),
    effectiveModel: 'scripted-v1',
    responseId: 'response-f',
    requestId: 'request-f',
    nativeState: ModelProviderNativeEnvelope(
      kind: 'failure-state-v1',
      compatibility: const <String, Object?>{'model': 'scripted-v1'},
      data: const <String, Object?>{'cursor': 'failed'},
    ),
  ),
);

ProviderBinding _binding(AdeleStreamChannel channel) {
  final CapabilityRegistry registry = CapabilityRegistry();
  registry.register(
    provider: ProviderDescriptor(
      id: ProviderId('dev.adele.fixture.common-model'),
      capability: modelProviderCapability,
      pluginId: 'dev.adele.fixture.common-model-plugin',
      displayName: 'Common Model Fixture',
      serviceId: modelProviderServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: modelProviderServiceId,
      isAvailable: () => true,
    ),
  );
  return registry.resolve(modelProviderCapability);
}

ProviderBinding _resourceBinding({
  AdeleRequestChannel? channel,
  bool Function()? isAvailable,
}) {
  final CapabilityRegistry registry = CapabilityRegistry();
  registry.register(
    provider: ProviderDescriptor(
      id: basicResourceInspectorProviderId,
      capability: resourceInspectCapability,
      pluginId: 'dev.adele.resource-inspector.basic-plugin',
      displayName: 'Basic Inspector',
      serviceId: resourceInspectorServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel ?? _UnusedChannel(),
      serviceId: resourceInspectorServiceId,
      isAvailable: isAvailable ?? () => true,
    ),
  );
  return registry.resolve(resourceInspectCapability);
}

final class _ProviderChannel implements AdeleStreamChannel {
  _ProviderChannel({required this.events});

  final Stream<ModelProviderEvent> events;
  int requestCount = 0;
  int streamCount = 0;
  Map<String, Object?>? lastPayload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requestCount++;
    throw StateError('The model adapter must not use unary transport.');
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    streamCount++;
    expect(method, modelProviderServiceInvokeId);
    lastPayload = payload;
    return events.map<Object?>(_encodeEvent);
  }
}

final class _ThrowingStreamChannel implements AdeleStreamChannel {
  const _ThrowingStreamChannel(this.error);

  final Object error;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Unary transport is forbidden.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      throw error;
}

Map<String, Object?> _encodeEvent(
  ModelProviderEvent event,
) => <String, Object?>{
  'kind': event.kind.name,
  'observation': event.observation == null
      ? null
      : <String, Object?>{
          'kind': event.observation!.kind.name,
          'textDelta': event.observation!.textDelta,
          'itemId': event.observation!.itemId,
        },
  'output': event.output == null ? null : _encodeOutput(event.output!),
  'terminal': event.terminal == null ? null : _encodeTerminal(event.terminal!),
};

Map<String, Object?> _encodeOutput(ModelProviderOutput output) =>
    <String, Object?>{
      'kind': output.kind.name,
      'text': output.text,
      'toolProposal': output.toolProposal == null
          ? null
          : _encodeProposal(output.toolProposal!),
      'itemId': output.itemId,
      'nativeMetadata': output.nativeMetadata == null
          ? null
          : _encodeNative(output.nativeMetadata!),
    };

Map<String, Object?> _encodeProposal(ModelProviderToolProposal proposal) =>
    <String, Object?>{
      'callId': proposal.callId,
      'name': proposal.name,
      'arguments': proposal.arguments,
    };

Map<String, Object?> _encodeTerminal(ModelProviderTerminal terminal) =>
    <String, Object?>{
      'settlement': terminal.settlement.name,
      'incompleteReason': terminal.incompleteReason?.name,
      'failure': terminal.failure == null
          ? null
          : <String, Object?>{
              'kind': terminal.failure!.kind.name,
              'providerCode': terminal.failure!.providerCode,
              'providerMessage': terminal.failure!.providerMessage,
              'providerDetails': terminal.failure!.providerDetails,
            },
      'providerStopReason': terminal.providerStopReason,
      'usage': terminal.usage == null
          ? null
          : <String, Object?>{
              'inputTokens': terminal.usage!.inputTokens,
              'outputTokens': terminal.usage!.outputTokens,
              'cacheReadTokens': terminal.usage!.cacheReadTokens,
              'cacheWriteTokens': terminal.usage!.cacheWriteTokens,
              'providerDetails': terminal.usage!.providerDetails,
            },
      'effectiveModel': terminal.effectiveModel,
      'responseId': terminal.responseId,
      'requestId': terminal.requestId,
      'nativeState': terminal.nativeState == null
          ? null
          : _encodeNative(terminal.nativeState!),
    };

Map<String, Object?> _encodeNative(ModelProviderNativeEnvelope native) =>
    <String, Object?>{
      'kind': native.kind,
      'compatibility': native.compatibility,
      'data': native.data,
    };

final class _UnusedChannel implements AdeleRequestChannel {
  int requestCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    requestCount++;
    throw StateError('Unused.');
  }
}
