import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/adele_model_tool.dart' as local;
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:test/test.dart';

void main() {
  late _Service service;
  late RemoteModelToolServiceDispatcher dispatcher;
  late _Channel channel;
  late RemoteModelToolServiceClient client;

  setUp(() {
    service = _Service();
    dispatcher = RemoteModelToolServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = RemoteModelToolServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'materialize preserves descriptor fields and opaque executable route',
    () async {
      for (final context in <String?>[null, 'opaque-host-context']) {
        final descriptors = await client.materialize('session-1', context);
        expect(remoteModelToolServiceId, 'modelTool');
        expect(channel.method, 'modelTool.materialize');
        expect(channel.payload, {
          'sessionId': 'session-1',
          'hostInvocationContext': context,
        });
        expect(service.materialization, ('session-1', context));
        final descriptor = descriptors.single;
        expect(descriptor.toolId, 'dev.adele.tool.test');
        expect(descriptor.toolDescription, 'Semantic tool description');
        expect(descriptor.modelAlias, 'test_tool');
        expect(descriptor.modelDescription, 'Model tool description');
        expect(descriptor.argumentsSchema, {'type': 'object'});
        expect(descriptor.routeId, 'opaque/generation:1/executable:2');
        expect(descriptor.toToolDefinition().id.value, descriptor.toolId);
        expect(descriptor.toModelDefinition().alias, descriptor.modelAlias);
        expect(
          descriptor.toModelDefinition().argumentsSchema,
          descriptor.argumentsSchema,
        );
        expect(descriptor, isNot(same(service.descriptor)));
        expect(() => descriptors.clear(), throwsUnsupportedError);
      }
    },
  );

  test(
    'validation transports immutable canonical arguments without authority',
    () async {
      final arguments = await client.validateAndNormalize('opaque-route', {
        'query': 'needle',
        'options': <Object?>[true, null, 1.5],
      });
      expect(channel.method, 'modelTool.validateAndNormalize');
      expect(channel.payload, {
        'routeId': 'opaque-route',
        'proposedArguments': {
          'query': 'needle',
          'options': [true, null, 1.5],
        },
      });
      expect(service.validationRoute, 'opaque-route');
      expect(arguments.snapshot, channel.payload!['proposedArguments']);
      expect(arguments.toLocal().snapshot, arguments.snapshot);
      expect(() => arguments.snapshot.clear(), throwsUnsupportedError);
      expect(
        () => (arguments.snapshot['options']! as List).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'describe roundtrips effects, URI targets, summary and uncertainty',
    () async {
      final arguments = RemoteCanonicalToolArguments(
        snapshot: {'query': 'needle'},
      );
      final effect = await client.describe(
        'route',
        arguments,
        'session',
        'run',
        null,
      );
      expect(channel.method, 'modelTool.describe');
      expect(channel.payload, {
        'routeId': 'route',
        'arguments': {
          'snapshot': {'query': 'needle'},
        },
        'sessionId': 'session',
        'runId': 'run',
        'hostInvocationContext': null,
      });
      expect(service.invocation, ('route', 'session', 'run', null));
      expect(service.arguments!.snapshot, arguments.snapshot);
      expect(effect.effects, RemoteToolEffect.values);
      expect(effect.targetUris, [Uri.parse('environment://authorized/lib')]);
      expect(effect.summary, 'Inspect authorized source');
      expect(effect.uncertainty, RemoteEffectUncertainty.uncertain);
      expect(() => effect.effects.clear(), throwsUnsupportedError);
      expect(() => effect.targetUris.clear(), throwsUnsupportedError);
    },
  );

  test(
    'execution is lazy and roundtrips ordered progress and terminal outcome',
    () async {
      final stream = client.execute(
        'route',
        RemoteCanonicalToolArguments(snapshot: {}),
        'session',
        'run',
        'context',
      );
      expect(service.executions, 0);
      final events = await stream.toList();
      expect(service.executions, 1);
      expect(channel.method, 'modelTool.execute');
      expect(service.invocation, ('route', 'session', 'run', 'context'));
      expect(events.map((event) => event.kind), [
        RemoteToolExecutionEventKind.progress,
        RemoteToolExecutionEventKind.terminal,
      ]);
      expect(events.first.progress!.kind, RemoteToolProgressKind.stderr);
      expect(events.first.progress!.content, 'working\n');
      final outcome = events.last.outcome!;
      expect(outcome.disposition, RemoteToolOutcomeDisposition.failure);
      expect(outcome.failureKind, RemoteToolFailureKind.domain);
      expect(outcome.effectCertainty, RemoteEffectCertainty.knownNotOccurred);
      expect(outcome.modelContent, 'Tool failed safely');
      expect(outcome.hostData, {
        'nested': [1, null],
      });
      expect(outcome.hostDiagnostic, 'Host-only diagnostic');
      expect(
        () => (outcome.hostData['nested']! as List).clear(),
        throwsUnsupportedError,
      );
      expect(channel.frames.last['kind'], 'streamDone');
      final wireOutcome =
          (channel.frames[1]['payload']! as Map)['outcome']! as Map;
      expect(
        wireOutcome.keys,
        unorderedEquals([
          'disposition',
          'failureKind',
          'effectCertainty',
          'modelContent',
          'hostData',
          'hostDiagnostic',
        ]),
      );
      expect(
        (events.last.toLocal() as local.ToolExecutionTerminal).outcome.cause,
        isNull,
      );
    },
  );

  test(
    'generated execution cancellation reaches the backend producer',
    () async {
      var cancellations = 0;
      late StreamController<RemoteToolExecutionEvent> producer;
      producer = StreamController<RemoteToolExecutionEvent>(
        onListen: () => producer.add(service.events.first),
        onCancel: () => cancellations++,
      );
      service.producer = producer.stream;
      final first = await client
          .execute(
            'route',
            RemoteCanonicalToolArguments(snapshot: {}),
            'session',
            'run',
            null,
          )
          .first;
      expect(first.kind, RemoteToolExecutionEventKind.progress);
      expect(cancellations, 1);
      await producer.close();
    },
  );

  test('only the declared argument failure is reconstructed', () async {
    service.failure = const RemoteToolArgumentValidationFailure(
      code: 'invalid_arguments',
      message: 'query must not be empty',
      details: {'field': 'query'},
    );
    await expectLater(
      client.validateAndNormalize('route', {}),
      throwsA(
        isA<RemoteToolArgumentValidationFailure>()
            .having((failure) => failure.code, 'code', 'invalid_arguments')
            .having(
              (failure) => failure.message,
              'message',
              'query must not be empty',
            )
            .having((failure) => failure.details, 'details', {
              'field': 'query',
            }),
      ),
    );
    expect(
      (channel.response!['error']! as Map)['declaredFailureType'],
      remoteToolArgumentValidationFailureTypeId,
    );

    for (final failure in <Object>[
      const FormatException('private malformed backend state'),
      StateError('private backend state'),
    ]) {
      service.failure = failure;
      await expectLater(
        client.validateAndNormalize('route', {}),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((failure) => failure.code, 'code', 'internal_error')
              .having((failure) => failure.declaredFailureType, 'type', isNull)
              .having(
                (failure) => failure.message,
                'message',
                isNot(contains('private')),
              ),
        ),
      );
    }
    final unknown = _RemoteFailure({
      'declaredFailureType': 'other.failure',
      'code': 'invalid_arguments',
      'message': 'Not this service failure',
      'details': <String, Object?>{},
    });
    await expectLater(
      RemoteModelToolServiceClient(
        _ResponseChannel(failure: unknown),
      ).validateAndNormalize('route', {}),
      throwsA(same(unknown)),
    );
  });

  test('malformed requests fail before service invocation', () async {
    for (final payload in <Map<String, Object?>>[
      {'routeId': 'route'},
      {'routeId': 1, 'proposedArguments': <String, Object?>{}},
      {
        'routeId': 'route',
        'proposedArguments': {'nonJson': Object()},
      },
      {'routeId': 'route', 'proposedArguments': {}, 'sessionId': 'forged'},
    ]) {
      final response = await dispatcher.dispatch(
        _request(remoteModelToolServiceValidateAndNormalizeId, payload),
      );
      expect((response['error']! as Map)['code'], 'invalid_request');
    }
    expect(service.validationRoute, isNull);
    final missingContext = await dispatcher.dispatch(
      _request(remoteModelToolServiceMaterializeId, {'sessionId': 'session'}),
    );
    expect((missingContext['error']! as Map)['code'], 'invalid_request');
    expect(service.materialization, isNull);
  });

  test(
    'all structured DTO maps snapshot deeply and reject invalid JSON graphs',
    () {
      final constructors =
          <Map<String, Object?> Function(Map<String, Object?>)>[
            (map) => _descriptor(schema: map).argumentsSchema,
            (map) => RemoteCanonicalToolArguments(snapshot: map).snapshot,
            (map) => _outcome(hostData: map).hostData,
          ];
      for (final snapshot in constructors) {
        final shared = <Object?>[
          {'value': 1},
        ];
        final source = <String, Object?>{'first': shared, 'second': shared};
        final frozen = snapshot(source);
        shared.clear();
        source.clear();
        expect(frozen['first'], [
          {'value': 1},
        ]);
        expect(() => frozen.clear(), throwsUnsupportedError);
        expect(
          () => (frozen['first']! as List).clear(),
          throwsUnsupportedError,
        );
        expect(
          () => ((frozen['first']! as List).single as Map).clear(),
          throwsUnsupportedError,
        );

        final cycle = <String, Object?>{};
        cycle['self'] = cycle;
        final cyclicList = <Object?>[];
        cyclicList.add(cyclicList);
        Map<String, Object?> deep = {};
        for (var i = 0; i < 65; i++) {
          deep = {'next': deep};
        }
        for (final invalid in <Map<String, Object?>>[
          cycle,
          {'list': cyclicList},
          deep,
          {'value': double.nan},
          {'value': double.infinity},
          {'value': Object()},
          {
            'value': <int, Object?>{1: true},
          },
        ]) {
          expect(() => snapshot(invalid), throwsFormatException);
        }
      }
    },
  );

  test(
    'constructors reject invalid semantic fields and event combinations',
    () {
      for (final field in [
        'toolId',
        'toolDescription',
        'modelAlias',
        'modelDescription',
        'routeId',
      ]) {
        final values = <String, String>{
          'toolId': 'tool',
          'toolDescription': 'Tool',
          'modelAlias': 'alias',
          'modelDescription': 'Model',
          'routeId': 'route',
        }..[field] = ' \n';
        expect(
          () => RemoteToolDescriptor(
            toolId: values['toolId']!,
            toolDescription: values['toolDescription']!,
            modelAlias: values['modelAlias']!,
            modelDescription: values['modelDescription']!,
            argumentsSchema: {},
            routeId: values['routeId']!,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => RemoteEffectDescription(
          effects: [],
          targetUris: [],
          summary: ' ',
          uncertainty: RemoteEffectUncertainty.none,
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteEffectDescription(
          effects: [RemoteToolEffect.sourceRead, RemoteToolEffect.sourceRead],
          targetUris: [],
          summary: 'Read',
          uncertainty: RemoteEffectUncertainty.none,
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteEffectDescription(
          effects: [],
          targetUris: [Uri.parse('relative/path')],
          summary: 'Read',
          uncertainty: RemoteEffectUncertainty.none,
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteToolProgress(
          kind: RemoteToolProgressKind.status,
          content: '',
        ),
        throwsFormatException,
      );
      // Output whitespace is semantic content, not an empty status message.
      expect(
        RemoteToolProgress(
          kind: RemoteToolProgressKind.stdout,
          content: '\n',
        ).content,
        '\n',
      );
      expect(() => _outcome(modelContent: ' '), throwsFormatException);
      expect(
        () => _outcome(disposition: RemoteToolOutcomeDisposition.failure),
        throwsFormatException,
      );
      expect(
        () => _outcome(failureKind: RemoteToolFailureKind.domain),
        throwsFormatException,
      );
      for (final kind in RemoteToolExecutionEventKind.values) {
        for (final progress in <RemoteToolProgress?>[
          null,
          service.events.first.progress,
        ]) {
          for (final outcome in <RemoteToolOutcome?>[null, _outcome()]) {
            final valid = kind == RemoteToolExecutionEventKind.progress
                ? progress != null && outcome == null
                : progress == null && outcome != null;
            if (valid) continue;
            expect(
              () => RemoteToolExecutionEvent(
                kind: kind,
                progress: progress,
                outcome: outcome,
              ),
              throwsFormatException,
            );
          }
        }
      }
    },
  );

  test('local conversions cover every semantic enum and drop only cause', () {
    for (final uncertainty in local.EffectUncertainty.values) {
      final original = local.EffectDescription(
        effects: local.ToolEffect.values,
        targets: [local.EffectTarget(uri: Uri.parse('file:///source'))],
        summary: 'All effects',
        uncertainty: uncertainty,
      );
      final restored = RemoteEffectDescription.fromLocal(original).toLocal();
      expect(restored.effects, original.effects);
      expect(restored.targets.single.uri, original.targets.single.uri);
      expect(restored.summary, original.summary);
      expect(restored.uncertainty, uncertainty);
    }
    for (final kind in local.ToolProgressKind.values) {
      final restored =
          RemoteToolExecutionEvent.fromLocal(
                local.ToolExecutionProgress(
                  local.ToolProgress(kind: kind, content: ' exact\n'),
                ),
              ).toLocal()
              as local.ToolExecutionProgress;
      expect(restored.progress.kind, kind);
      expect(restored.progress.content, ' exact\n');
    }
    for (final disposition in local.ToolOutcomeDisposition.values) {
      for (final certainty in local.EffectCertainty.values) {
        for (final failure
            in disposition == local.ToolOutcomeDisposition.failure
                ? local.ToolFailureKind.values
                : <local.ToolFailureKind?>[null]) {
          final original = local.ToolOutcome(
            disposition: disposition,
            failureKind: failure,
            effectCertainty: certainty,
            modelContent: 'Exact result',
            hostData: {
              'data': [true],
            },
            hostDiagnostic: 'Exact diagnostic',
            cause: StateError('not transported'),
          );
          final restored =
              (RemoteToolExecutionEvent.fromLocal(
                        local.ToolExecutionTerminal(original),
                      ).toLocal()
                      as local.ToolExecutionTerminal)
                  .outcome;
          expect(restored.disposition, disposition);
          expect(restored.failureKind, failure);
          expect(restored.effectCertainty, certainty);
          expect(restored.modelContent, original.modelContent);
          expect(restored.hostData, original.hostData);
          expect(restored.hostDiagnostic, original.hostDiagnostic);
          expect(restored.cause, isNull);
        }
      }
    }
    final canonical = local.CanonicalToolArguments({
      'nested': [1, null],
    });
    expect(
      RemoteCanonicalToolArguments.fromLocal(canonical).toLocal().snapshot,
      canonical.snapshot,
    );
  });

  test(
    'generated decoders enforce constructor rules, enums and exact fields',
    () async {
      await client.materialize('session', null);
      final descriptor = Map<String, Object?>.from(
        (channel.response!['payload']! as List).single as Map,
      );
      for (final invalid in <Map<String, Object?>>[
        {...descriptor, 'routeId': ''},
        {...descriptor}..remove('routeId'),
        {...descriptor, 'extra': true},
      ]) {
        await expectLater(
          RemoteModelToolServiceClient(
            _ResponseChannel(response: [invalid]),
          ).materialize('session', null),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
      final events = await client
          .execute(
            'route',
            RemoteCanonicalToolArguments(snapshot: {}),
            'session',
            'run',
            null,
          )
          .toList();
      expect(events, hasLength(2));
      final progress = Map<String, Object?>.from(
        channel.frames.first['payload']! as Map,
      );
      final terminal = Map<String, Object?>.from(
        channel.frames[1]['payload']! as Map,
      );
      for (final invalid in <Map<String, Object?>>[
        {...progress, 'kind': 'unknown'},
        {...progress, 'outcome': terminal['outcome']},
        {...progress, 'progress': null},
        {...progress}..remove('outcome'),
        {
          ...progress,
          'progress': {'kind': 'unknown', 'content': 'text'},
        },
        {
          ...progress,
          'progress': {'kind': 'status', 'content': ''},
        },
        {
          ...terminal,
          'outcome': {...terminal['outcome']! as Map, 'failureKind': null},
        },
        {
          ...terminal,
          'outcome': {...terminal['outcome']! as Map}..remove('hostDiagnostic'),
        },
        {
          ...terminal,
          'outcome': {...terminal['outcome']! as Map, 'cause': 'forbidden'},
        },
      ]) {
        await expectLater(
          RemoteModelToolServiceClient(_ResponseChannel(response: invalid))
              .execute(
                'route',
                RemoteCanonicalToolArguments(snapshot: {}),
                'session',
                'run',
                null,
              )
              .toList(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );
}

RemoteToolDescriptor _descriptor({
  Map<String, Object?> schema = const {'type': 'object'},
}) => RemoteToolDescriptor(
  toolId: 'dev.adele.tool.test',
  toolDescription: 'Semantic tool description',
  modelAlias: 'test_tool',
  modelDescription: 'Model tool description',
  argumentsSchema: schema,
  routeId: 'opaque/generation:1/executable:2',
);

RemoteToolOutcome _outcome({
  RemoteToolOutcomeDisposition disposition =
      RemoteToolOutcomeDisposition.success,
  RemoteToolFailureKind? failureKind,
  String modelContent = 'Result',
  Map<String, Object?> hostData = const {},
}) => RemoteToolOutcome(
  disposition: disposition,
  failureKind: failureKind,
  effectCertainty: RemoteEffectCertainty.knownNotOccurred,
  modelContent: modelContent,
  hostData: hostData,
  hostDiagnostic: null,
);

final class _Service implements RemoteModelToolService {
  final descriptor = _descriptor();
  (String, String?)? materialization;
  String? validationRoute;
  (String, String, String, String?)? invocation;
  RemoteCanonicalToolArguments? arguments;
  Object? failure;
  int executions = 0;
  Stream<RemoteToolExecutionEvent>? producer;
  final events = [
    RemoteToolExecutionEvent.fromLocal(
      local.ToolExecutionProgress(
        local.ToolProgress(
          kind: local.ToolProgressKind.stderr,
          content: 'working\n',
        ),
      ),
    ),
    RemoteToolExecutionEvent.fromLocal(
      local.ToolExecutionTerminal(
        local.ToolOutcome(
          disposition: local.ToolOutcomeDisposition.failure,
          failureKind: local.ToolFailureKind.domain,
          effectCertainty: local.EffectCertainty.knownNotOccurred,
          modelContent: 'Tool failed safely',
          hostData: {
            'nested': [1, null],
          },
          hostDiagnostic: 'Host-only diagnostic',
          cause: StateError('private cause'),
        ),
      ),
    ),
  ];

  @override
  Future<List<RemoteToolDescriptor>> materialize(
    String sessionId,
    String? hostInvocationContext,
  ) async {
    materialization = (sessionId, hostInvocationContext);
    return [descriptor];
  }

  @override
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  ) async {
    validationRoute = routeId;
    if (failure case final Object error) throw error;
    return RemoteCanonicalToolArguments(snapshot: proposedArguments);
  }

  @override
  Future<RemoteEffectDescription> describe(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? hostInvocationContext,
  ) async {
    invocation = (routeId, sessionId, runId, hostInvocationContext);
    this.arguments = arguments;
    return RemoteEffectDescription(
      effects: RemoteToolEffect.values,
      targetUris: [Uri.parse('environment://authorized/lib')],
      summary: 'Inspect authorized source',
      uncertainty: RemoteEffectUncertainty.uncertain,
    );
  }

  @override
  Stream<RemoteToolExecutionEvent> execute(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? hostInvocationContext,
  ) {
    executions++;
    invocation = (routeId, sessionId, runId, hostInvocationContext);
    this.arguments = arguments;
    return producer ?? Stream.fromIterable(events);
  }
}

Map<String, Object?> _request(String method, Map<String, Object?> payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': method,
  'payload': payload,
};

final class _Channel implements AdeleStreamChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;
  final frames = <Map<String, Object?>>[];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch(_request(method, payload));
    this.response = response;
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return response['payload'];
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    this.method = method;
    this.payload = payload;
    final responses = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(responses.stream);
    void send(Map<String, Object?> frame) {
      frames.add(frame);
      responses.add(frame);
    }

    try {
      await dispatcher.handle({
        ..._request(method, payload),
        'kind': 'streamOpen',
      }, send);
      while (true) {
        await dispatcher.handle({
          'kind': 'streamCredit',
          'requestId': 1,
          'credit': 1,
        }, send);
        if (!await iterator.moveNext()) break;
        final frame = iterator.current;
        if (frame['kind'] == 'streamDone') break;
        if (frame['kind'] == 'streamError') {
          throw _RemoteFailure(frame['error']! as Map);
        }
        yield frame['payload'];
      }
    } finally {
      await dispatcher.handle({'kind': 'streamCancel', 'requestId': 1}, send);
      await iterator.cancel();
      await responses.close();
    }
  }
}

final class _ResponseChannel implements AdeleStreamChannel {
  const _ResponseChannel({this.response, this.failure});
  final Object? response;
  final Object? failure;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (failure case final Object error) throw error;
    return response;
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      Stream.value(response);
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;

  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}
