import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:test/test.dart';

void main() {
  final location = Uri.parse('file:///source/project%20one/');
  late _Provider provider;
  late ProjectProviderServiceDispatcher dispatcher;

  setUp(() {
    provider = _Provider();
    dispatcher = ProjectProviderServiceDispatcher(provider);
  });
  tearDown(() => dispatcher.close());

  test('capability and generated wire identifiers are stable', () {
    expect(projectProviderCapability.id.value, 'dev.adele.project.provider');
    expect(projectProviderCapability.majorVersion, 1);
    expect(projectProviderServiceId, 'dev.adele.project.provider');
    expect(
      projectProviderServicePrepareSourceId,
      'dev.adele.project.provider.prepareSource',
    );
  });

  test(
    'generated client and dispatcher reconstruct an immutable backing',
    () async {
      final channel = _Channel(dispatcher);
      final result = await ProjectProviderServiceClient(
        channel,
      ).prepareSource(location);
      expect(channel.method, projectProviderServicePrepareSourceId);
      expect(channel.payload, {'sourceLocation': location.toString()});
      expect(provider.source, location);
      expect(result.sourceLocation, location);
      expect(result.databaseRelativePath, '.adele/data.db');
      expect(result, isNot(same(provider.result)));
      final dynamic immutable = result;
      expect(
        () => immutable.sourceLocation = Uri.parse('file:///replacement/'),
        throwsNoSuchMethodError,
      );
      expect(
        () => immutable.databaseRelativePath = 'replacement.db',
        throwsNoSuchMethodError,
      );
    },
  );

  test(
    'dispatcher rejects malformed arguments before invoking provider',
    () async {
      for (final payload in <Map<String, Object?>>[
        {},
        {'sourceLocation': null},
        {'sourceLocation': 1},
        {'sourceLocation': 'relative/path'},
        {'sourceLocation': 'https://[invalid'},
        {'sourceLocation': location.toString(), 'projectId': 'forged'},
      ]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': projectProviderServicePrepareSourceId,
          'payload': payload,
        });
        expect(response['ok'], isFalse);
        expect((response['error']! as Map)['code'], 'invalid_request');
        expect(provider.source, isNull);
      }
    },
  );

  test(
    'client rejects malformed backing fields and unexpected authority',
    () async {
      final valid = <String, Object?>{
        'sourceLocation': location.toString(),
        'databaseRelativePath': '.adele/data.db',
      };
      for (final payload in <Object?>[
        null,
        {...valid}..remove('sourceLocation'),
        {...valid}..remove('databaseRelativePath'),
        {...valid, 'sourceLocation': 'relative/path'},
        {...valid, 'sourceLocation': 'https://[invalid'},
        {...valid, 'databaseRelativePath': null},
        {...valid, 'databaseRelativePath': 1},
        {...valid, 'projectId': 'forged'},
      ]) {
        await expectLater(
          ProjectProviderServiceClient(
            _ResponseChannel(payload),
          ).prepareSource(location),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test('provider failures remain opaque transport failures', () async {
    provider.failure = StateError('private filesystem information');
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': projectProviderServicePrepareSourceId,
      'payload': {'sourceLocation': location.toString()},
    });
    expect(response['ok'], isFalse);
    expect((response['error']! as Map)['code'], 'internal_error');
    expect(jsonEncode(response), isNot(contains('private filesystem')));
  });
}

final class _Provider implements ProjectProviderService {
  Uri? source;
  ProjectBacking? result;
  Object? failure;

  @override
  Future<ProjectBacking> prepareSource(Uri sourceLocation) async {
    source = sourceLocation;
    if (failure case final Object error) throw error;
    return result = ProjectBacking(
      sourceLocation: sourceLocation,
      databaseRelativePath: '.adele/data.db',
    );
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final ProjectProviderServiceDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': jsonDecode(jsonEncode(payload)),
    });
    expect(response['ok'], isTrue);
    return jsonDecode(jsonEncode(response['payload']));
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}
