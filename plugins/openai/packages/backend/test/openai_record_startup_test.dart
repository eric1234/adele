import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

import '../bin/openai_model_provider_backend.dart' as backend;

void main() {
  for (final entry in <String, Map<String, Object?>>{
    'missing': {},
    'null': {'records': null},
    'not a list': {'records': <String, Object?>{}},
    'missing values': {
      'records': [
        {
          'collection': 'providers',
          'type': 'dev.adele.openai.api-key',
          'id': 'work',
        },
      ],
    },
    'credential payload': {
      'records': [
        {
          'collection': 'providers',
          'type': 'dev.adele.openai.api-key',
          'id': 'work',
          'values': {'display-name': 'Work'},
          'credentials': {'api-key': 'must-not-be-decoded'},
        },
      ],
    },
    'nested field': {
      'records': [
        {
          'collection': 'providers',
          'type': 'dev.adele.openai.api-key',
          'id': 'work',
          'values': {'display-name': <String>[]},
        },
      ],
    },
  }.entries) {
    test(
      'stock entrypoint rejects ${entry.key} records before ready',
      () async {
        final ready = ReceivePort();
        final responses = ReceivePort();
        addTearDown(ready.close);
        addTearDown(responses.close);
        final messages = <Object?>[];
        final subscription = ready.listen(messages.add);
        addTearDown(subscription.cancel);

        await expectLater(
          backend.main(const [], {
            'bootstrapPort': ready.sendPort,
            'responsePort': responses.sendPort,
            'defaultConfigurationContext': 'default',
            'startupArgumentsOnly': true,
            ...entry.value,
          }),
          throwsFormatException,
        );
        expect(messages, isEmpty);
      },
    );
  }

  for (final arguments in <List<String>>[
    const [],
    const ['--chatgpt-only'],
    [
      '--chatgpt-only',
      jsonEncode({
        'credentialFile': '/not-read-at-startup/credentials.json',
        'clientId': 'test-client',
      }),
    ],
  ]) {
    test(
      'valid records advertise independently of startup arguments $arguments',
      () async {
        final ready = ReceivePort();
        final responses = ReceivePort();
        addTearDown(ready.close);
        addTearDown(responses.close);
        final running = backend.main(arguments, {
          'bootstrapPort': ready.sendPort,
          'responsePort': responses.sendPort,
          'defaultConfigurationContext': 'default',
          'startupArgumentsOnly': true,
          'hostInfrastructureContext': 'generation-grant',
          'records': [
            for (final id in ['work', 'personal'])
              {
                'collection': 'providers',
                'type': 'dev.adele.openai.api-key',
                'id': id,
                'values': {'display-name': id},
              },
            {
              'collection': 'providers',
              'type': 'dev.adele.openai.api-key',
              'id': 'invalid-endpoint',
              'values': {
                'display-name': 'Invalid',
                'endpoint': 'http://external.test',
              },
            },
          ],
        });
        final message = await ready.first as Map;
        expect(message['kind'], 'ready');
        final exposures = message['capabilityExposures'] as List;
        final contexts = <String, String>{};
        for (final id in ['personal', 'work']) {
          final pair = exposures.cast<Map<Object?, Object?>>().where(
            (entry) => (entry['providerId'] as String).endsWith('.$id'),
          );
          expect(pair, hasLength(2));
          final context = pair.first['configurationContext'] as String;
          expect(context, matches(r'^dynamic:[0-9]+$'));
          expect(pair.last['configurationContext'], context);
          contexts[id] = context;
        }
        expect(contexts.values.toSet(), hasLength(2));
        expect(exposures, [
          if (arguments.length == 2)
            AdeleCapabilityExposure(
              providerId: 'dev.adele.openai.chatgpt-experimental',
              capabilityId: 'dev.adele.model.provider',
              capabilityMajorVersion: 1,
              serviceId: 'modelProvider',
              displayName: 'Experimental ChatGPT',
              configurationContext: 'chatgpt-experimental',
            ).toMap(),
          for (final id in ['personal', 'work']) ...[
            AdeleCapabilityExposure(
              providerId: 'dev.adele.openai.api-key.$id',
              capabilityId: 'dev.adele.model.provider',
              capabilityMajorVersion: 1,
              serviceId: 'modelProvider',
              displayName: id,
              configurationContext: contexts[id]!,
            ).toMap(),
            AdeleCapabilityExposure(
              providerId: 'dev.adele.openai.model-catalog.$id',
              capabilityId: 'dev.adele.model.catalog',
              capabilityMajorVersion: 1,
              serviceId: 'modelCatalog',
              displayName: id,
              configurationContext: contexts[id]!,
              association: AdeleProviderAssociation(
                capabilityId: 'dev.adele.model.provider',
                capabilityMajorVersion: 1,
                providerId: 'dev.adele.openai.api-key.$id',
              ),
            ).toMap(),
          ],
        ]);
        expect(message.keys.toSet(), {
          'kind',
          'commandPort',
          'pluginBackendProtocolVersion',
          'capabilityExposures',
        });
        (message['commandPort'] as SendPort).send({
          'method': 'shutdown',
          'requestId': 1,
        });
        expect((await responses.first as Map)['ok'], isTrue);
        await running;
      },
    );
  }
}
