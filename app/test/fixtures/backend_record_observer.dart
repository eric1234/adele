import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_backend_records.dart';
import 'package:adele_plugin_backend_support/adele_backend_settings.dart';

// Test-only observer of the public decoder. The stock OpenAI backend has no
// corresponding observation method, readiness field, or registration.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final records = AdeleBackendRecords.fromBootstrap(bootstrapMessage).records;
  final settings = AdeleBackendSettings.fromBootstrap(bootstrapMessage).values;
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final requests = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  try {
    await for (final request in requests) {
      if (request is! Map) continue;
      final stopping = request['method'] == 'shutdown';
      responses.send({
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': stopping
            ? {'stopping': true}
            : request['method'] == 'settings'
            ? {...settings}
            : {
                'records': [
                  for (final record in records)
                    {
                      ...record,
                      'values': {...record['values'] as Map<String, Object>},
                    },
                ],
              },
      });
      if (stopping) break;
    }
  } finally {
    requests.close();
  }
}
