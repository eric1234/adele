import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart' as product;
import 'package:test/test.dart';

void main() {
  test('source point has the agreed typed public identity', () {
    expect(
      inferenceContextSources,
      ExtensionPoint<InferenceContextSourceContribution>(
        'dev.adele.extension.inference-context-sources',
      ),
    );
  });

  test('instruction materials reject blank keys and text', () {
    for (final String blank in <String>['', ' ', '\t\r\n', '\u00a0']) {
      expect(
        () => InferenceInstructionMaterial(key: blank, text: 'text'),
        throwsFormatException,
      );
      expect(
        () => InferenceInstructionMaterial(key: 'key', text: blank),
        throwsFormatException,
      );
    }
  });

  test(
    'capture preserves exact valid bytes and never renders revision',
    () async {
      final _Fixture fixture = _Fixture();
      const String key = ' \tkey\r\n\u00e9 ';
      const String text = ' \ttext\r\n\u00e9\u0301\n ';
      const String revision = ' \trevision-only\r\n ';
      final InferenceContextMaterial original = InferenceInstructionMaterial(
        key: key,
        text: text,
        revision: revision,
      );
      fixture.register(
        'alpha',
        (_) async => <InferenceContextMaterial>[original],
      );

      final InferenceContextSnapshot snapshot = await fixture.compose();
      final InferenceInstructionMaterial captured =
          snapshot.sourceResults.single.materials.single;
      expect(captured, isNot(same(original)));
      expect(captured.key, key);
      expect(captured.text, text);
      expect(captured.revision, revision);
      expect(
        switch (original) {
          InferenceInstructionMaterial(
            :final key,
            :final text,
            :final revision,
          ) =>
            (key, text, revision),
        },
        (key, text, revision),
      );
      expect(renderInferenceInstructions(snapshot), 'strategy\n\n$text');
      expect(renderInferenceInstructions(snapshot), isNot(contains(revision)));
      expect(_instruction('plain').revision, isNull);
    },
  );

  for (final String instructions in <String>['', ' \t\r\n', ' original\r\n ']) {
    test(
      'zero sources preserve exact strategy ${instructions.codeUnits}',
      () async {
        final SemanticMessageInput first = SemanticMessageInput(
          role: SemanticMessageRole.user,
          content: 'first',
        );
        final SemanticMessageInput second = SemanticMessageInput(
          role: SemanticMessageRole.assistant,
          content: 'second',
        );
        final List<SemanticModelInputItem> supplied = <SemanticModelInputItem>[
          first,
          second,
        ];
        final StrategyInferenceMaterial material = StrategyInferenceMaterial(
          instructions: instructions,
          input: supplied,
        );
        final InferenceContextSnapshot direct =
            InferenceContextSnapshot.fromStrategy(material);
        final InferenceContextSnapshot composed =
            await InferenceContextComposer(ExtensionRegistry()).compose(
              strategyMaterial: material,
              sourceContext: _SourceContext(),
            );
        supplied.clear();

        for (final InferenceContextSnapshot snapshot
            in <InferenceContextSnapshot>[direct, composed]) {
          expect(renderInferenceInstructions(snapshot), instructions);
          expect(snapshot.input, <SemanticModelInputItem>[first, second]);
          expect(snapshot.input, isNot(same(material.input)));
          expect(snapshot.sourceResults, isEmpty);
          expect(() => snapshot.input.clear(), throwsUnsupportedError);
          expect(() => snapshot.input[0] = second, throwsUnsupportedError);
          expect(() => snapshot.sourceResults.clear(), throwsUnsupportedError);
          expect(
            () => snapshot.instructionGroups.clear(),
            throwsUnsupportedError,
          );
          expect(
            snapshot.instructionGroups.single,
            isA<StrategyInstructionGroup>().having(
              (group) => group.instructions,
              'instructions',
              instructions,
            ),
          );
        }
      },
    );
  }

  test(
    'sources are lexicographic across permutations, preserving local order',
    () async {
      for (final List<String> order in <List<String>>[
        <String>['alpha', 'middle', 'zulu'],
        <String>['alpha', 'zulu', 'middle'],
        <String>['middle', 'alpha', 'zulu'],
        <String>['middle', 'zulu', 'alpha'],
        <String>['zulu', 'alpha', 'middle'],
        <String>['zulu', 'middle', 'alpha'],
      ]) {
        final _Fixture fixture = _Fixture();
        final List<String> calls = <String>[];
        for (final String name in order) {
          fixture.register(name, (_) async {
            calls.add(name);
            return <InferenceContextMaterial>[
              _instruction('$name second-key', key: 'z'),
              _instruction('$name first-key', key: 'a'),
            ];
          });
        }

        final InferenceContextSnapshot snapshot = await fixture.compose();
        expect(calls, <String>['alpha', 'middle', 'zulu']);
        expect(
          snapshot.sourceResults.map((result) => result.sourceId),
          <ExtensionId>[_id('alpha'), _id('middle'), _id('zulu')],
        );
        expect(
          snapshot.instructionGroups.map(
            (group) => switch (group) {
              StrategyInstructionGroup(:final instructions) => instructions,
              SourceInstructionGroup(:final sourceId) => sourceId,
            },
          ),
          <Object>['strategy', _id('alpha'), _id('middle'), _id('zulu')],
        );
        expect(
          renderInferenceInstructions(snapshot),
          'strategy\n\nalpha second-key\n\nalpha first-key\n\n'
          'middle second-key\n\nmiddle first-key\n\n'
          'zulu second-key\n\nzulu first-key',
        );
        for (final InferenceContextSourceResult result
            in snapshot.sourceResults) {
          expect(result.materials.map((material) => material.key), <String>[
            'z',
            'a',
          ]);
          expect(result.status, InferenceContextSourceStatus.contributed);
          expect(result.failureMode, InferenceContextFailureMode.required);
          expect(result.failure, isNull);
        }
      }
    },
  );

  test(
    'key identity uses exact strings, not trimmed or normalized keys',
    () async {
      final _Fixture fixture = _Fixture();
      final List<String> keys = <String>['key', ' key ', '\u00e9', 'e\u0301'];
      fixture.register(
        'alpha',
        (_) async => <InferenceContextMaterial>[
          for (final String key in keys) _instruction(key, key: key),
        ],
      );

      expect(
        (await fixture.compose()).sourceResults.single.materials.map(
          (material) => material.key,
        ),
        keys,
      );
    },
  );

  test(
    'empty strategy group is retained but omitted only from rendering',
    () async {
      for (final String instructions in <String>['', ' \t\r\n']) {
        final _Fixture fixture = _Fixture(instructions: instructions);
        fixture.register(
          'alpha',
          (_) async => <InferenceContextMaterial>[
            _instruction('source one'),
            _instruction('source two', key: 'second'),
          ],
        );

        final InferenceContextSnapshot snapshot = await fixture.compose();
        expect(
          renderInferenceInstructions(snapshot),
          '${instructions.isEmpty ? '' : '$instructions\n\n'}'
          'source one\n\nsource two',
        );
        expect(snapshot.instructionGroups, hasLength(2));
        expect(
          snapshot.instructionGroups.first,
          isA<StrategyInstructionGroup>().having(
            (group) => group.instructions,
            'instructions',
            instructions,
          ),
        );
        expect(snapshot.instructionGroups.last, isA<SourceInstructionGroup>());
      }
    },
  );

  test(
    'source receives exact canonical context and required typed host service',
    () async {
      final _InstructionService service = _InstructionService(
        'service instructions',
      );
      final _SourceContext context = _SourceContext(service: service);
      final _Fixture fixture = _Fixture(context: context);
      fixture.register('alpha', (received) async {
        expect(received, same(context));
        expect(received.session, same(context.session));
        expect(received.runId, context.runId);
        final _InstructionService resolved = await received
            .requireHostService<_InstructionService>();
        expect(resolved, same(service));
        return <InferenceContextMaterial>[_instruction(resolved.instructions)];
      });

      final InferenceContextSnapshot snapshot = await fixture.compose();
      expect(context.requestedServices, <Type>[_InstructionService]);
      expect(
        renderInferenceInstructions(snapshot),
        'strategy\n\nservice instructions',
      );
    },
  );

  for (final InferenceContextFailureMode mode
      in InferenceContextFailureMode.values) {
    test('successful empty $mode source is not an omission', () async {
      final _Fixture fixture = _Fixture();
      int calls = 0;
      fixture.register('alpha', (_) async {
        calls++;
        return const <InferenceContextMaterial>[];
      }, failureMode: mode);

      final InferenceContextSnapshot snapshot = await fixture.compose();
      final InferenceContextSourceResult result = snapshot.sourceResults.single;
      expect(calls, 1);
      expect(result.sourceId, _id('alpha'));
      expect(result.failureMode, mode);
      expect(result.status, InferenceContextSourceStatus.empty);
      expect(result.materials, isEmpty);
      expect(result.failure, isNull);
      expect(() => result.materials.clear(), throwsUnsupportedError);
      expect(
        snapshot.instructionGroups.single,
        isA<StrategyInstructionGroup>(),
      );
      expect(renderInferenceInstructions(snapshot), 'strategy');
    });

    for (final String failureKind in <String>[
      'duplicate keys',
      'synchronous throw',
      'asynchronous throw',
      'lazy throw after valid',
      'lazy invalid key after valid',
      'lazy invalid text after valid',
    ]) {
      test(
        '$mode $failureKind is a whole-source failure without partial data',
        () async {
          final _Fixture fixture = _Fixture();
          final StateError cause = StateError(failureKind);
          final StackTrace stackTrace = StackTrace.fromString(
            'original source stack',
          );
          final List<String> calls = <String>[];
          fixture.register('alpha', (_) async {
            calls.add('before');
            return <InferenceContextMaterial>[_instruction('before')];
          });
          fixture.register('middle', (_) {
            calls.add('failed');
            return switch (failureKind) {
              'duplicate keys' =>
                Future<Iterable<InferenceContextMaterial>>.value(
                  <InferenceContextMaterial>[
                    _instruction('partial', key: 'duplicate'),
                    InferenceInstructionMaterial(
                      key: String.fromCharCodes('duplicate'.codeUnits),
                      text: 'different text',
                      revision: 'different revision',
                    ),
                  ],
                ),
              'synchronous throw' => Error.throwWithStackTrace(
                cause,
                stackTrace,
              ),
              'asynchronous throw' =>
                Future<Iterable<InferenceContextMaterial>>.error(
                  cause,
                  stackTrace,
                ),
              _ => Future<Iterable<InferenceContextMaterial>>.value(
                _invalidMaterials(failureKind, cause, stackTrace),
              ),
            };
          }, failureMode: mode);
          fixture.register('zulu', (_) async {
            calls.add('after');
            return <InferenceContextMaterial>[_instruction('after')];
          });
          final bool originalFailure = failureKind.contains('throw');

          await _expectSourceFailure(
            fixture.compose(),
            mode,
            _id('middle'),
            originalFailure ? same(cause) : isA<FormatException>(),
            stackTrace: originalFailure ? stackTrace : null,
            instructions: 'strategy\n\nbefore\n\nafter',
          );
          expect(calls, <String>[
            'before',
            'failed',
            if (mode == InferenceContextFailureMode.optional) 'after',
          ]);
        },
      );
    }

    test('$mode missing required host service is a source failure', () async {
      final _SourceContext context = _SourceContext();
      final _Fixture fixture = _Fixture(context: context);
      fixture.register('alpha', (received) async {
        await received.requireHostService<_InstructionService>();
        return <InferenceContextMaterial>[_instruction('unreachable')];
      }, failureMode: mode);

      await _expectSourceFailure(
        fixture.compose(),
        mode,
        _id('alpha'),
        isA<StateError>(),
      );
      expect(context.requestedServices, <Type>[_InstructionService]);
    });

    test(
      '$mode async capture never migrates from retired A to replacement B',
      () async {
        final _Fixture fixture = _Fixture();
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        int originalCalls = 0;
        int replacementCalls = 0;
        final ExtensionRegistration original = fixture.register('alpha', (
          _,
        ) async {
          originalCalls++;
          entered.complete();
          await release.future;
          return <InferenceContextMaterial>[_instruction('A')];
        }, failureMode: mode);
        final Future<void> checked = _expectSourceFailure(
          fixture.compose(),
          mode,
          _id('alpha'),
          isA<StaleExtensionBinding>().having(
            (error) => error.id,
            'id',
            _id('alpha'),
          ),
        );
        await entered.future;
        await original.close();
        fixture.register('alpha', (_) async {
          replacementCalls++;
          return <InferenceContextMaterial>[_instruction('B')];
        }, failureMode: _opposite(mode));
        release.complete();
        await checked;
        expect(originalCalls, 1);
        expect(replacementCalls, 0);

        final InferenceContextSnapshot fresh = await fixture.compose();
        expect(replacementCalls, 1);
        expect(fresh.sourceResults.single.failureMode, _opposite(mode));
        expect(renderInferenceInstructions(fresh), 'strategy\n\nB');
      },
    );

    test(
      '$mode source retired before its turn keeps its captured policy',
      () async {
        final _Fixture fixture = _Fixture();
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        int firstCalls = 0;
        int originalCalls = 0;
        int replacementCalls = 0;
        // Register the later source first to exercise sorting as well as capture.
        final ExtensionRegistration original = fixture.register('zulu', (
          _,
        ) async {
          originalCalls++;
          return <InferenceContextMaterial>[_instruction('A')];
        }, failureMode: mode);
        fixture.register('alpha', (_) async {
          if (firstCalls++ == 0) entered.complete();
          await release.future;
          return <InferenceContextMaterial>[_instruction('first')];
        });
        final Future<void> checked = _expectSourceFailure(
          fixture.compose(),
          mode,
          _id('zulu'),
          isA<StaleExtensionBinding>(),
          instructions: 'strategy\n\nfirst',
        );
        await entered.future;
        await original.close();
        fixture.register('zulu', (_) async {
          replacementCalls++;
          return <InferenceContextMaterial>[_instruction('B')];
        }, failureMode: _opposite(mode));
        release.complete();
        await checked;
        expect(originalCalls, 0);
        expect(replacementCalls, 0);

        final InferenceContextSnapshot fresh = await fixture.compose();
        expect(replacementCalls, 1);
        expect(fresh.sourceResults.last.failureMode, _opposite(mode));
        expect(renderInferenceInstructions(fresh), 'strategy\n\nfirst\n\nB');
      },
    );

    test(
      '$mode retirement during iterable capture discards the whole source',
      () async {
        final _Fixture fixture = _Fixture();
        late final ExtensionRegistration registration;
        Future<void>? retirement;
        bool consumedToEnd = false;
        Iterable<InferenceContextMaterial> materialize() sync* {
          yield _instruction('partial');
          retirement = registration.close();
          yield _instruction('also partial', key: 'second');
          consumedToEnd = true;
        }

        registration = fixture.register(
          'alpha',
          (_) async => materialize(),
          failureMode: mode,
        );
        await _expectSourceFailure(
          fixture.compose(),
          mode,
          _id('alpha'),
          isA<StaleExtensionBinding>(),
        );
        await retirement;
        expect(consumedToEnd, isTrue);
        expect(registration.isClosed, isTrue);
      },
    );

    test(
      '$mode safely captured A survives retirement while a later source awaits',
      () async {
        final _Fixture fixture = _Fixture();
        final InferenceInstructionMaterial originalMaterial = _instruction('A');
        final List<InferenceContextMaterial> supplied =
            <InferenceContextMaterial>[originalMaterial];
        final ExtensionRegistration original = fixture.register(
          'alpha',
          (_) async => supplied,
          failureMode: mode,
        );
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        int laterCalls = 0;
        int replacementCalls = 0;
        final ExtensionRegistration later = fixture.register('zulu', (_) async {
          if (laterCalls++ == 0) entered.complete();
          await release.future;
          return <InferenceContextMaterial>[_instruction('later')];
        });
        final Future<InferenceContextSnapshot> pending = fixture.compose();
        await entered.future;
        await original.close();
        supplied.clear();
        fixture.register('alpha', (_) async {
          replacementCalls++;
          return <InferenceContextMaterial>[_instruction('B')];
        });
        release.complete();

        final InferenceContextSnapshot snapshot = await pending;
        expect(replacementCalls, 0);
        expect(
          snapshot.sourceResults.first.status,
          InferenceContextSourceStatus.contributed,
        );
        expect(snapshot.sourceResults.first.failure, isNull);
        expect(snapshot.sourceResults.first.failureMode, mode);
        expect(
          snapshot.sourceResults.first.materials.single,
          isNot(same(originalMaterial)),
        );
        expect(renderInferenceInstructions(snapshot), 'strategy\n\nA\n\nlater');

        final InferenceContextSnapshot fresh = await fixture.compose();
        expect(replacementCalls, 1);
        expect(renderInferenceInstructions(fresh), 'strategy\n\nB\n\nlater');
        await later.close();
        expect(renderInferenceInstructions(snapshot), 'strategy\n\nA\n\nlater');
      },
    );
  }

  test(
    'new source registrations wait for the next inference discovery',
    () async {
      final _Fixture fixture = _Fixture();
      final Completer<void> entered = Completer<void>();
      final Completer<void> release = Completer<void>();
      int originalCalls = 0;
      int newCalls = 0;
      fixture.register('middle', (_) async {
        if (originalCalls++ == 0) entered.complete();
        await release.future;
        return <InferenceContextMaterial>[_instruction('original')];
      });
      final Future<InferenceContextSnapshot> pending = fixture.compose();
      await entered.future;
      fixture.register('alpha', (_) async {
        newCalls++;
        return <InferenceContextMaterial>[_instruction('new')];
      });
      release.complete();

      final InferenceContextSnapshot snapshot = await pending;
      expect(newCalls, 0);
      expect(snapshot.sourceResults.single.sourceId, _id('middle'));
      expect(renderInferenceInstructions(snapshot), 'strategy\n\noriginal');
      expect(
        renderInferenceInstructions(await fixture.compose()),
        'strategy\n\nnew\n\noriginal',
      );
      expect(newCalls, 1);
    },
  );

  test('snapshot owns frozen lists and copies source materials', () async {
    final List<Object?> nested = <Object?>['original native data'];
    final SemanticNativeInput native = SemanticNativeInput(
      providerNativeMetadata: ModelNativeEnvelope(
        kind: 'native',
        compatibility: const <String, Object?>{},
        data: <String, Object?>{'nested': nested},
      ),
    );
    final List<SemanticModelInputItem> input = <SemanticModelInputItem>[native];
    final _Fixture fixture = _Fixture(input: input);
    final InferenceInstructionMaterial first = _instruction('first');
    final InferenceInstructionMaterial second = _instruction(
      'second',
      key: 'second',
    );
    final List<InferenceContextMaterial> supplied = <InferenceContextMaterial>[
      first,
      second,
    ];
    final ExtensionRegistration registration = fixture.register(
      'alpha',
      (_) async => supplied,
    );
    final InferenceContextSnapshot snapshot = await fixture.compose();
    supplied[0] = _instruction('changed');
    supplied.clear();
    input.clear();
    nested.clear();
    await registration.close();

    final InferenceContextSourceResult result = snapshot.sourceResults.single;
    final SourceInstructionGroup group =
        snapshot.instructionGroups.last as SourceInstructionGroup;
    expect(result.materials, isNot(same(supplied)));
    expect(result.materials[0], isNot(same(first)));
    expect(result.materials[1], isNot(same(second)));
    expect(group.sourceId, result.sourceId);
    expect(group.materials, same(result.materials));
    expect(result.materials.map((material) => material.text), <String>[
      'first',
      'second',
    ]);
    expect(snapshot.input.single, same(native));
    expect(native.providerNativeMetadata.data['nested'], <Object?>[
      'original native data',
    ]);
    expect(
      () => (native.providerNativeMetadata.data['nested']! as List<Object?>)
          .clear(),
      throwsUnsupportedError,
    );
    expect(() => snapshot.input.clear(), throwsUnsupportedError);
    expect(() => snapshot.input[0] = native, throwsUnsupportedError);
    expect(() => snapshot.sourceResults.clear(), throwsUnsupportedError);
    expect(() => snapshot.sourceResults[0] = result, throwsUnsupportedError);
    expect(() => snapshot.instructionGroups.clear(), throwsUnsupportedError);
    expect(() => snapshot.instructionGroups[0] = group, throwsUnsupportedError);
    expect(() => result.materials.clear(), throwsUnsupportedError);
    expect(() => result.materials[0] = first, throwsUnsupportedError);
    expect(() => group.materials.clear(), throwsUnsupportedError);
    expect(() => group.materials[0] = first, throwsUnsupportedError);
    expect(
      renderInferenceInstructions(snapshot),
      'strategy\n\nfirst\n\nsecond',
    );
  });
}

ExtensionId _id(String name) => ExtensionId('dev.adele.test.context.$name');

InferenceInstructionMaterial _instruction(String text, {String key = 'key'}) =>
    InferenceInstructionMaterial(key: key, text: text);

InferenceContextFailureMode _opposite(InferenceContextFailureMode mode) =>
    mode == InferenceContextFailureMode.required
    ? InferenceContextFailureMode.optional
    : InferenceContextFailureMode.required;

Iterable<InferenceContextMaterial> _invalidMaterials(
  String kind,
  Object cause,
  StackTrace stackTrace,
) sync* {
  yield _instruction('partial');
  if (kind == 'lazy throw after valid') {
    Error.throwWithStackTrace(cause, stackTrace);
  }
  yield InferenceInstructionMaterial(
    key: kind == 'lazy invalid key after valid' ? ' \t' : 'second',
    text: kind == 'lazy invalid text after valid' ? '\r\n' : 'invalid',
  );
}

Future<void> _expectSourceFailure(
  Future<InferenceContextSnapshot> pending,
  InferenceContextFailureMode mode,
  ExtensionId sourceId,
  Matcher cause, {
  StackTrace? stackTrace,
  String instructions = 'strategy',
}) async {
  final Matcher failure = isA<InferenceContextSourceFailed>()
      .having((error) => error.sourceId, 'sourceId', sourceId)
      .having((error) => error.cause, 'cause', cause)
      .having(
        (error) => error.stackTrace,
        'stackTrace',
        stackTrace == null ? isA<StackTrace>() : same(stackTrace),
      )
      .having(
        (error) => error.stackTrace.toString(),
        'nonempty stack',
        isNotEmpty,
      )
      .having(
        (error) => error.toString(),
        'diagnostic',
        contains(sourceId.value),
      );
  if (mode == InferenceContextFailureMode.required) {
    await expectLater(pending, throwsA(failure));
    return;
  }
  final InferenceContextSnapshot snapshot = await pending;
  final InferenceContextSourceResult result = snapshot.sourceResults
      .singleWhere((result) => result.sourceId == sourceId);
  expect(result.failureMode, mode);
  expect(result.status, InferenceContextSourceStatus.omitted);
  expect(result.materials, isEmpty);
  expect(() => result.materials.clear(), throwsUnsupportedError);
  expect(result.failure, failure);
  expect(
    snapshot.instructionGroups.whereType<SourceInstructionGroup>().map(
      (group) => group.sourceId,
    ),
    isNot(contains(sourceId)),
  );
  expect(renderInferenceInstructions(snapshot), instructions);
}

final class _Fixture {
  _Fixture({
    String instructions = 'strategy',
    Iterable<SemanticModelInputItem> input = const <SemanticModelInputItem>[],
    InferenceContextSourceContext? context,
  }) : material = StrategyInferenceMaterial(
         instructions: instructions,
         input: input,
       ),
       context = context ?? _SourceContext();

  final ExtensionRegistry registry = ExtensionRegistry();
  late final InferenceContextComposer composer = InferenceContextComposer(
    registry,
  );
  final StrategyInferenceMaterial material;
  final InferenceContextSourceContext context;

  Future<InferenceContextSnapshot> compose() =>
      composer.compose(strategyMaterial: material, sourceContext: context);

  ExtensionRegistration register(
    String name,
    Future<Iterable<InferenceContextMaterial>> Function(
      InferenceContextSourceContext,
    )
    snapshot, {
    InferenceContextFailureMode failureMode =
        InferenceContextFailureMode.required,
  }) => registry.register(
    point: inferenceContextSources,
    id: _id(name),
    value: InferenceContextSourceContribution(
      failureMode: failureMode,
      snapshot: snapshot,
    ),
  );
}

final class _InstructionService {
  const _InstructionService(this.instructions);

  final String instructions;
}

final class _SourceContext implements InferenceContextSourceContext {
  _SourceContext({this.service});

  final Object? service;
  final List<Type> requestedServices = <Type>[];

  @override
  final Session session = Session(
    id: SessionId('session-1'),
    taskId: product.TaskId('task-1'),
    strategyId: OrchestrationStrategyId('dev.adele.strategy.test'),
  );

  @override
  final RunId runId = RunId('run-1');

  @override
  Future<T> requireHostService<T extends Object>() async {
    requestedServices.add(T);
    final Object? available = service;
    if (available is T) return available;
    throw StateError('Required host service $T is unavailable.');
  }
}
