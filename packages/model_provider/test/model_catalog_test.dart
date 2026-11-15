import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:test/test.dart';

void main() {
  late _Service service;
  late ModelCatalogServiceDispatcher dispatcher;
  late _Channel channel;
  late ModelCatalogServiceClient client;

  setUp(() {
    service = _Service();
    dispatcher = ModelCatalogServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = ModelCatalogServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test('catalog identity is independent from inference', () {
    expect(modelCatalogCapability.id.value, 'dev.adele.model.catalog');
    expect(modelCatalogCapability.majorVersion, 1);
    expect(modelCatalogCapability, isNot(modelProviderCapability));
    expect(modelCatalogServiceId, 'modelCatalog');
    expect(modelCatalogServiceListModelsId, 'modelCatalog.listModels');
    expect(modelCatalogFailureTypeId, 'modelCatalog.failure');
  });

  test(
    'generated unary round trip preserves exact IDs and nullable metadata',
    () async {
      service.models = [
        _entry(
          ' Vendor/Model:2026-11 ',
          name: 'Provider label',
          description: 'Line 1\nLine 2',
        ),
        _entry('vendor/model:2026-11'),
      ];
      final snapshot = await client.listModels();
      expect(channel.method, modelCatalogServiceListModelsId);
      expect(channel.payload, isEmpty);
      expect(service.calls, 1);
      expect(snapshot.models.map((model) => model.modelId), [
        ' Vendor/Model:2026-11 ',
        'vendor/model:2026-11',
      ]);
      expect(snapshot.models.first.displayName, 'Provider label');
      expect(snapshot.models.first.description, 'Line 1\nLine 2');
      expect(snapshot.models.last.displayName, isNull);
      expect(snapshot.models.last.description, isNull);
      expect(snapshot.models.first, isNot(same(service.models.first)));
      expect(() => snapshot.models.clear(), throwsUnsupportedError);
      expect((channel.response!['payload']! as Map)['models'], [
        _wireEntry(
          ' Vendor/Model:2026-11 ',
          name: 'Provider label',
          description: 'Line 1\nLine 2',
        ),
        _wireEntry('vendor/model:2026-11'),
      ]);
    },
  );

  test(
    'empty success and repeated observations are not startup state',
    () async {
      expect((await client.listModels()).models, isEmpty);
      service.models = [_entry('newly-available')];
      expect(
        (await client.listModels()).models.single.modelId,
        'newly-available',
      );
      expect(service.calls, 2);
    },
  );

  test('snapshot defensively copies and rejects exact duplicates only', () {
    final source = [_entry('Model'), _entry('model')];
    final snapshot = ModelCatalogSnapshot(models: source);
    source.clear();
    expect(snapshot.models.map((model) => model.modelId), ['Model', 'model']);
    expect(() => snapshot.models.add(_entry('other')), throwsUnsupportedError);
    expect(() => snapshot.models[0] = _entry('other'), throwsUnsupportedError);
    expect(
      () => ModelCatalogSnapshot(
        models: [
          _entry('same'),
          _entry('same', name: 'Different metadata'),
        ],
      ),
      throwsFormatException,
    );
  });

  test(
    'maximum finite catalog and text bounds round trip without truncation',
    () async {
      service.models = [
        _entry(
          'x' * modelCatalogMaxModelIdLength,
          name: 'n' * modelCatalogMaxDisplayNameLength,
          description: 'd' * modelCatalogMaxDescriptionLength,
        ),
        for (var i = 1; i < modelCatalogMaxModels; i++) _entry('model-$i'),
      ];
      final snapshot = await client.listModels();
      expect(snapshot.models, hasLength(modelCatalogMaxModels));
      expect(
        snapshot.models.first.modelId.length,
        modelCatalogMaxModelIdLength,
      );
      expect(
        snapshot.models.first.displayName!.length,
        modelCatalogMaxDisplayNameLength,
      );
      expect(
        snapshot.models.first.description!.length,
        modelCatalogMaxDescriptionLength,
      );
      expect(
        snapshot.models.last.modelId,
        'model-${modelCatalogMaxModels - 1}',
      );
      expect(
        () =>
            ModelCatalogSnapshot(models: [...service.models, _entry('excess')]),
        throwsFormatException,
      );
    },
  );

  for (final text in ['\u6a21', '\u0001']) {
    test(
      'aggregate text budget includes multibyte and escaped text ${text.codeUnitAt(0)}',
      () async {
        service.models = [
          for (var i = 0; i < 255; i++)
            _entry(
              'model-$i',
              description: text * modelCatalogMaxDescriptionLength,
            ),
        ];
        final used = service.models.fold<int>(
          0,
          (sum, model) =>
              sum + model.modelId.length + model.description!.length,
        );
        service.models.add(
          _entry(
            'last',
            name: 'label',
            description: text * (modelCatalogMaxTextLength - used - 4 - 5),
          ),
        );
        expect((await client.listModels()).models, hasLength(256));
        // The largest JSON expansion is six bytes per UTF-16 code unit.
        expect(
          utf8.encode(jsonEncode(channel.response)).length,
          lessThan(7 * 1024 * 1024),
        );
        final excessive = [...service.models, _entry('x')];
        expect(
          () => ModelCatalogSnapshot(models: excessive),
          throwsFormatException,
        );
        final wire = (channel.response!['payload']! as Map)['models']! as List;
        await expectLater(
          ModelCatalogServiceClient(
            _ResponseChannel({
              'models': [...wire, _wireEntry('x')],
            }),
          ).listModels(),
          throwsA(isA<AdeleProtocolException>()),
        );
      },
    );
  }

  test('invalid text rejects locally and through generated decoding', () async {
    final invalidEntries = <Map<String, Object?>>[
      for (final id in [
        '',
        ' \t\n',
        'bad\u0000id',
        'bad\nid',
        'bad\u007fid',
        'x' * (modelCatalogMaxModelIdLength + 1),
      ])
        _wireEntry(id),
      for (final name in [
        '',
        ' \t',
        'bad\u0000name',
        'n' * (modelCatalogMaxDisplayNameLength + 1),
      ])
        _wireEntry('model', name: name),
      for (final description in [
        '',
        ' \n',
        'bad\u0000description',
        'd' * (modelCatalogMaxDescriptionLength + 1),
      ])
        _wireEntry('model', description: description),
    ];
    for (final entry in invalidEntries) {
      expect(
        () => _entry(
          entry['modelId']! as String,
          name: entry['displayName'] as String?,
          description: entry['description'] as String?,
        ),
        throwsFormatException,
      );
      await expectLater(
        ModelCatalogServiceClient(
          _ResponseChannel({
            'models': [entry],
          }),
        ).listModels(),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });

  test(
    'malformed, duplicate, and excessive wire snapshots fail, not empty',
    () async {
      final entry = _wireEntry('model');
      for (final payload in <Object?>[
        null,
        [],
        {},
        {'models': null},
        {'models': <String, Object?>{}},
        {'models': <Object?>[], 'extra': true},
        {
          'models': [null],
        },
        {
          'models': [
            {'modelId': 'model'},
          ],
        },
        {
          'models': [
            {...entry, 'modelId': 42},
          ],
        },
        {
          'models': [
            {...entry, 'displayName': false},
          ],
        },
        {
          'models': [
            {...entry, 'description': <Object?>[]},
          ],
        },
        {
          'models': [
            {...entry, 'unknown': 'value'},
          ],
        },
        {
          'models': [entry, entry],
        },
        {
          'models': [
            for (var i = 0; i <= modelCatalogMaxModels; i++)
              _wireEntry('model-$i'),
          ],
        },
      ]) {
        await expectLater(
          ModelCatalogServiceClient(_ResponseChannel(payload)).listModels(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test('listModels accepts no route or authority selectors', () async {
    for (final payload in <Object?>[
      null,
      [],
      for (final key in [
        'providerId',
        'accountId',
        'credential',
        'endpoint',
        'configurationContext',
        'hostInvocationContext',
      ])
        {key: 'forged-private-value'},
    ]) {
      final response = await dispatcher.dispatch(
        _request(modelCatalogServiceListModelsId, payload),
      );
      expect(response['ok'], isFalse);
      expect((response['error']! as Map)['code'], 'invalid_request');
      expect(jsonEncode(response), isNot(contains('forged-private-value')));
    }
    expect(service.calls, 0);
  });

  test(
    'declared semantic failures reconstruct instead of returning empty',
    () async {
      for (final code in [
        'authentication',
        'rate_limited',
        'unsupported_discovery',
        'unavailable',
        'transport',
        'malformed_response',
        'provider_failure',
      ]) {
        service.failure = ModelCatalogFailure(
          code: code,
          message: 'Catalog discovery failed.',
        );
        await expectLater(
          client.listModels(),
          throwsA(
            isA<ModelCatalogFailure>()
                .having((failure) => failure.code, 'classification', code)
                .having(
                  (failure) => failure.message,
                  'safe message',
                  'Catalog discovery failed.',
                )
                .having((failure) => failure.details, 'details', isEmpty),
          ),
        );
        expect(
          (channel.response!['error']! as Map)['declaredFailureType'],
          modelCatalogFailureTypeId,
        );
      }
    },
  );

  test(
    'unexpected provider exceptions retain sanitized transport failure',
    () async {
      for (final error in <Object>[
        StateError('private credential and response body'),
        const FormatException('private malformed provider response'),
        const AdeleProtocolException('private backend diagnostics'),
      ]) {
        service.failure = error;
        await expectLater(
          client.listModels(),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((failure) => failure.code, 'code', 'internal_error')
                .having(
                  (failure) => failure.declaredFailureType,
                  'type',
                  isNull,
                )
                .having((failure) => failure.details, 'details', isEmpty),
          ),
        );
        expect(jsonEncode(channel.response), isNot(contains('private')));
      }
    },
  );
}

ModelCatalogEntry _entry(String id, {String? name, String? description}) =>
    ModelCatalogEntry(modelId: id, displayName: name, description: description);

Map<String, Object?> _wireEntry(
  String id, {
  String? name,
  String? description,
}) => {'modelId': id, 'displayName': name, 'description': description};

Map<String, Object?> _request(String method, Object? payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': method,
  'payload': payload,
};

final class _Service implements ModelCatalogService {
  List<ModelCatalogEntry> models = [];
  Object? failure;
  int calls = 0;

  @override
  Future<ModelCatalogSnapshot> listModels() async {
    calls++;
    if (failure != null) throw failure!;
    return ModelCatalogSnapshot(models: models);
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final ModelCatalogServiceDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch(
      _request(method, jsonDecode(jsonEncode(payload))),
    );
    this.response = response;
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return jsonDecode(jsonEncode(response['payload']));
  }
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

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}
