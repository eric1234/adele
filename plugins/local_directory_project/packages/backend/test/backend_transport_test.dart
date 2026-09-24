import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:local_directory_project_backend/local_directory_project_backend.dart';
import 'package:test/test.dart';

import '../bin/local_directory_project_backend.dart' as backend;

void main() {
  test(
    'backend advertises and routes generated requests in its context',
    () async {
      final bootstrap = ReceivePort();
      final responses = ReceivePort();
      final events = StreamIterator<Object?>(responses);
      addTearDown(bootstrap.close);
      addTearDown(responses.close);
      addTearDown(events.cancel);
      final stopped = backend.main([], {
        'bootstrapPort': bootstrap.sendPort,
        'responsePort': responses.sendPort,
        'defaultConfigurationContext': 'local-directory-test',
      });
      final ready = await bootstrap.first as Map;
      final commands = ready['commandPort'] as SendPort;
      addTearDown(() async {
        commands.send({'method': 'shutdown', 'requestId': 99});
        await stopped;
      });
      expect(
        ready['pluginBackendProtocolVersion'],
        adelePluginBackendProtocolVersion,
      );
      final exposure = AdeleCapabilityExposure.fromReady(ready).single;
      expect(exposure.providerId, localDirectoryProjectProviderId);
      expect(exposure.capabilityId, projectProviderCapability.id.value);
      expect(exposure.capabilityMajorVersion, 1);
      expect(exposure.serviceId, projectProviderServiceId);
      expect(exposure.configurationContext, 'local-directory-test');
      expect(AdeleExtensionExposure.fromReady(ready), isEmpty);

      final client = ProjectProviderServiceClient(_Channel(commands, events));
      final source = Directory.systemTemp.uri.resolve('uncreated-project/');
      final backing = await client.prepareSource(source);
      expect(backing.sourceLocation, source);
      expect(backing.databaseRelativePath, '.adele/data.db');
      await expectLater(
        client.prepareSource(Uri.parse('file://server/share/')),
        throwsA(
          isA<AdeleRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'internal_error',
          ),
        ),
      );

      for (final route in [
        {
          'configurationContext': 'foreign',
          'serviceId': projectProviderServiceId,
        },
        {
          'configurationContext': 'local-directory-test',
          'serviceId': 'foreign',
        },
      ]) {
        commands.send({
          'kind': 'request',
          'requestId': 3,
          ...route,
          'method': projectProviderServicePrepareSourceId,
          'payload': {'sourceLocation': source.toString()},
        });
        expect(await events.moveNext(), isTrue);
        expect((events.current! as Map)['ok'], isFalse);
      }
    },
  );

  test('backend rejects missing metadata and unexpected arguments', () async {
    await expectLater(backend.main([], null), throwsArgumentError);
    await expectLater(backend.main(['unexpected'], {}), throwsArgumentError);
    await expectLater(backend.main([], {}), throwsArgumentError);
  });
}

final class _Channel implements AdeleRequestChannel {
  const _Channel(this.commands, this.events);
  final SendPort commands;
  final StreamIterator<Object?> events;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    commands.send({
      'kind': 'request',
      'requestId': 1,
      'configurationContext': 'local-directory-test',
      'serviceId': projectProviderServiceId,
      'method': method,
      'payload': payload,
    });
    expect(await events.moveNext(), isTrue);
    final response = events.current! as Map;
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map);
    }
    return response['payload'];
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
