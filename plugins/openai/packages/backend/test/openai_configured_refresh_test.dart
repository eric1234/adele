import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:test/test.dart';

const _private = 'private-native-diagnostic-canary';
const _secret = 'secret-key-canary';
const _endpoint = 'https://private-endpoint.invalid/secret-path/responses';

void main() {
  test('empty startup can publish its first configured pair', () async {
    final fixture = _Fixture([]);
    expect(fixture.manager.initialExposures, isEmpty);
    fixture.host.records = [_record('work')];
    _expectResult(await fixture.refresh('work'), 'applied', 'added');
    expect(fixture.host.methods, ['captureCurrentConfiguration', 'publish']);
    _expectPair(fixture.host.lastExposures, 'work');
    expect(fixture.manager.activeRevisionCount, 1);
    expect(fixture.manager.retainedCaptureCount, 1);
    expect(fixture.host.keyReads, isEmpty);
  });

  test('replacements never retire independent constructor routes', () async {
    final fixture = _Fixture([_record('work')]);
    for (var i = 0; i < 12; i++) {
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      for (final context in ['default', openAiChatGptConfigurationContext]) {
        await fixture.expectRoute(context);
        expect((await fixture.catalog(context))['ok'], isTrue);
      }
    }
  });

  test(
    'more than 64 startup accounts adopt only the affected pair lazily',
    () async {
      final fixture = _Fixture([
        for (var i = 0; i < 65; i++) _record('account-$i'),
      ]);
      final initial = fixture.manager.initialExposures;
      expect(initial, hasLength(130));
      expect(fixture.host.requests, isEmpty);
      expect(fixture.manager.retainedCaptureCount, 0);
      final contexts = <String>{};
      for (var i = 0; i < 65; i++) {
        final pair = fixture.pair('account-$i');
        _expectPair(pair, 'account-$i');
        contexts.add(pair.first.configurationContext);
      }
      expect(contexts, hasLength(65));
      fixture.host.records = [_record('account-17', name: 'Fresh name')];
      _expectResult(await fixture.refresh('account-17'), 'applied', 'replaced');
      expect(fixture.host.methods, [
        'captureCurrentConfiguration',
        'adoptAdvertised',
        'replace',
      ]);
      expect(fixture.host.payloads('adoptAdvertised').single, {
        'exposures': [
          for (final entry in fixture.pair('account-17')) entry.toMap(),
        ],
      });
      final replacement = fixture.host.lastExposures;
      _expectPair(replacement, 'account-17');
      expect(replacement.first.displayName, 'Fresh name');
      expect(contexts, isNot(contains(replacement.first.configurationContext)));
      expect(fixture.manager.activeRevisionCount, 65);
      await fixture.expectRoute(fixture.context('account-17'), active: false);
      await fixture.expectRoute(fixture.context('account-18'));
      expect(fixture.host.keyReads, isEmpty);
    },
  );

  test(
    'refresh captures fresh records without reading keys until routed use',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final httpRequests = <(String, String?)>[];
      final subscription = server.listen((request) async {
        httpRequests.add((
          request.uri.path,
          request.headers.value(HttpHeaders.authorizationHeader),
        ));
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'object': 'list',
            'data': [
              {'object': 'model', 'id': 'fresh-model'},
            ],
          }),
        );
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });
      final origin = 'http://${server.address.address}:${server.port}';
      final fixture = _Fixture([
        _record('work', endpoint: '$origin/startup/responses'),
        _record('personal', endpoint: '$origin/personal/responses'),
      ]);
      fixture.host.records = [
        _record('work', name: 'Renamed', endpoint: '$origin/fresh/responses'),
        _record(
          'personal',
          name: 'Not applied',
          endpoint: '$origin/ignored/responses',
        ),
      ];
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      expect(fixture.host.keyReads, isEmpty);
      expect(httpRequests, isEmpty);
      final fresh = fixture.host.lastExposures.first.configurationContext;
      fixture.host.keyResponse = {'secret': _secret};
      for (var i = 0; i < 2; i++) {
        expect((await fixture.catalog(fresh))['ok'], isTrue);
      }
      expect(
        (await fixture.catalog(fixture.context('personal')))['ok'],
        isTrue,
      );
      expect(httpRequests, [
        ('/fresh/models', 'Bearer $_secret'),
        ('/fresh/models', 'Bearer $_secret'),
        ('/personal/models', 'Bearer $_secret'),
      ]);
      final reads = fixture.host.keyReads;
      expect(reads.map((entry) => entry['method']), [
        'readCapturedCredential',
        'readCapturedCredential',
        'readCredential',
      ]);
      final capture = fixture.host.captures.single;
      for (final read in reads.take(2)) {
        expect(read['payload'], {'capture': capture, ..._selectors('work')});
      }
      expect(reads.last['payload'], _selectors('personal'));
      expect(fixture.host.payloads('adoptAdvertised'), hasLength(1));
      // Identical ordinary fields cannot establish unchanged credential authority.
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      expect(fixture.host.keyReads, hasLength(3));
      expect(fixture.host.payloads('adoptAdvertised'), hasLength(1));
      expect(
        fixture.host.lastExposures.first.configurationContext,
        isNot(fresh),
      );
      await fixture.expectRoute(fresh, active: false);
    },
  );

  test(
    'refresh serializes capture and publication, not only final mutation',
    () async {
      final fixture = _Fixture([_record('work'), _record('personal')]);
      final capture = fixture.host.hold('captureCurrentConfiguration');
      final publication = fixture.host.hold('replace');
      final first = fixture.refresh('work');
      await capture.entered.future;
      final second = fixture.refresh('personal');
      await _pump();
      expect(fixture.host.methods, ['captureCurrentConfiguration']);
      capture.release.complete();
      await publication.entered.future;
      expect(fixture.host.methods, [
        'captureCurrentConfiguration',
        'adoptAdvertised',
        'replace',
      ]);
      await _pump();
      expect(
        fixture.host.payloads('captureCurrentConfiguration'),
        hasLength(1),
      );
      publication.release.complete();
      _expectResult(await first, 'applied', 'replaced');
      _expectResult(await second, 'applied', 'replaced');
      expect(fixture.host.methods, [
        'captureCurrentConfiguration',
        'adoptAdvertised',
        'replace',
        'captureCurrentConfiguration',
        'adoptAdvertised',
        'replace',
      ]);
      expect(fixture.host.keyReads, isEmpty);
    },
  );

  test(
    'pre-readiness adoption refusal preserves the healthy startup route',
    () async {
      final fixture = _Fixture([_record('work')]);
      fixture.host.replies['adoptAdvertised'] = {'failure': 'notReady'};
      _expectResult(
        await fixture.refresh('work'),
        'unavailable',
        'publication_not_ready',
      );
      await _pump();
      expect(fixture.host.methods, [
        'captureCurrentConfiguration',
        'adoptAdvertised',
        'releaseCapture',
      ]);
      expect(fixture.manager.activeRevisionCount, 1);
      expect(fixture.manager.retainedCaptureCount, 0);
      await fixture.expectRoute(fixture.context('work'));
      expect(
        _error(await fixture.catalog(fixture.context('work'))),
        'unavailable',
      );
      expect(fixture.host.keyReads.single['method'], 'readCredential');
      // Only a new explicit refresh retries the rejected adoption.
      fixture.host.replies.remove('adoptAdvertised');
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      expect(fixture.host.payloads('adoptAdvertised'), hasLength(2));
    },
  );

  test('refresh admission is bounded while capture is pending', () async {
    final fixture = _Fixture([_record('work')]);
    final gate = fixture.host.hold('captureCurrentConfiguration');
    final pending = [fixture.refresh('work')];
    await gate.entered.future;
    pending.addAll([for (var i = 1; i < 32; i++) fixture.refresh('work')]);
    _expectResult(
      await fixture.refresh('work'),
      'unavailable',
      'refresh_capacity',
    );
    expect(fixture.host.methods, ['captureCurrentConfiguration']);
    gate.release.complete();
    for (final result in await Future.wait(pending)) {
      _expectResult(result, 'applied', 'replaced');
    }
    await _pump();
    expect(fixture.manager.activeRevisionCount, 1);
    expect(fixture.manager.drainingRevisionCount, 0);
    expect(fixture.manager.retainedCaptureCount, 1);
  });

  test(
    'cleanup failure never replaces the primary configuration failure',
    () async {
      final fixture = _Fixture([_record('work')]);
      fixture.host.records = [_record('work', endpoint: 'not-an-endpoint')];
      fixture.host.replies['releaseCapture'] = {'failure': _private};
      final result = await fixture.refresh('work');
      _expectResult(result, 'failed', 'invalid_configuration');
      expect(result['cleanupPending'], isTrue);
      await fixture.expectRoute(fixture.context('work'));
      expect(fixture.host.payloads('adoptAdvertised'), isEmpty);
      expect(fixture.host.keyReads, isEmpty);
    },
  );

  test(
    'malformed IDs and payloads cannot exercise control authority',
    () async {
      final fixture = _Fixture([_record('work')]);
      for (final id in <Object?>[
        null,
        1,
        true,
        {},
        [],
        '',
        'Work',
        'work ',
        'work\n',
        'a/b',
        '../work',
        'work.id',
        'work_id',
        'con',
        'lpt9',
        'a' * 65,
        'work-\u00e9',
      ]) {
        _expectResult(await fixture.refresh(id), 'failed', 'invalid_record_id');
      }
      for (final payload in <Object?>[
        null,
        [],
        'work',
        {},
        {'recordId': 'work', 'endpoint': _endpoint},
        {'recordId': 'work', 'capture': _private},
        {'recordId': 'work', 'secret': _secret},
      ]) {
        final response = await fixture.control({'payload': payload});
        _expectResult(response['payload'], 'failed', 'invalid_request');
      }
      for (final change in <Map<String, Object?>>[
        {'configurationContext': fixture.context('work')},
        {'configurationContext': 'api-key-record:work'},
        {'configurationContext': null},
        {'hostInvocationContext': 'forged-operation'},
        {'hostInvocationContext': null},
        {'method': 'refreshAll'},
      ]) {
        final response = await fixture.control(change);
        _expectResult(response['payload'], 'failed', 'invalid_request');
      }
      final streaming = await fixture.control({'kind': 'streamOpen'});
      expect(streaming['kind'], 'streamFailure');
      expect(_error(streaming), 'invalid_request');
      expect(fixture.host.requests, isEmpty);
      final valid = await fixture.control({});
      expect(valid['kind'], 'response');
      expect(valid['ok'], isTrue);
      _expectResult(valid['payload'], 'applied', 'replaced');
    },
  );

  for (final grants in [(false, true), (true, false), (false, false)]) {
    test('missing grants $grants do not capture or disturb startup', () async {
      final fixture = _Fixture(
        [_record('work')],
        credentials: grants.$1,
        publisher: grants.$2,
      );
      _expectResult(
        await fixture.refresh('work'),
        'unavailable',
        'host_grants_unavailable',
      );
      expect(fixture.host.requests, isEmpty);
      await fixture.expectRoute(fixture.context('work'));
    });
  }

  for (final (failure, code) in [
    ('notAuthorized', 'not_authorized'),
    ('notConfigured', 'not_configured'),
    ('missingLocally', 'missing_locally'),
    ('storageUnavailable', 'storage_unavailable'),
    ('invalidCredentialBinding', 'invalid_credential_binding'),
    ('reconciliationRequired', 'reconciliation_required'),
    ('staleConfiguration', 'stale_configuration'),
    ('generationUnavailable', 'generation_unavailable'),
    ('credentialAccessFailed', 'credential_access_failed'),
  ]) {
    test('capture $failure preserves old route without publication', () async {
      final fixture = _Fixture([_record('work')]);
      fixture.host.replies['captureCurrentConfiguration'] = {
        'failure': failure,
      };
      final unavailable =
          failure == 'notAuthorized' || failure == 'generationUnavailable';
      _expectResult(
        await fixture.refresh('work'),
        unavailable ? 'unavailable' : 'failed',
        'credential_capture_$code',
      );
      expect(fixture.host.methods, ['captureCurrentConfiguration']);
      expect(fixture.manager.retainedCaptureCount, 0);
      await fixture.expectRoute(fixture.context('work'));
    });
  }

  test(
    'eight retained captures refuse further refresh until admitted work drains',
    () async {
      final fixture = _Fixture([_record('work')]);
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      final pending = <Future<Map<String, Object?>>>[];
      final reads = <_Gate>[];
      for (var i = 0; i < 7; i++) {
        final read = fixture.host.hold('readCapturedCredential');
        reads.add(read);
        pending.add(
          fixture.catalog(
            fixture.host.lastExposures.first.configurationContext,
          ),
        );
        await read.entered.future;
        final result = await fixture.refresh('work');
        _expectResult(result, 'applied', 'replaced');
        expect(result['cleanupPending'], isTrue);
      }
      expect(fixture.manager.retainedCaptureCount, 8);
      expect(fixture.manager.drainingRevisionCount, 7);
      expect(fixture.host.captures, hasLength(8));
      final current = fixture.host.lastExposures.first.configurationContext;
      final publications = fixture.host.payloads('replace').length;
      _expectResult(
        await fixture.refresh('work'),
        'failed',
        'credential_capture_credential_access_failed',
      );
      expect(fixture.host.payloads('replace'), hasLength(publications));
      await fixture.expectRoute(current);
      for (final read in reads) {
        read.release.complete();
      }
      await Future.wait(pending);
      await _pump();
      expect(fixture.manager.retainedCaptureCount, 1);
      expect(fixture.manager.drainingRevisionCount, 0);
      expect(fixture.host.captures, hasLength(1));
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      expect(fixture.host.maximumCaptures, 8);
    },
  );

  for (final (failure, code) in [
    ('capacityExceeded', 'capacity_exceeded'),
    ('rejected', 'rejected'),
  ]) {
    test(
      'publication $failure preserves the old exact route and permits explicit retry',
      () async {
        final fixture = _Fixture([_record('work')]);
        fixture.host.replies['replace'] = {'failure': failure};
        _expectResult(
          await fixture.refresh('work'),
          'failed',
          'publication_$code',
        );
        await _pump();
        final candidate = fixture.host.lastExposures.first.configurationContext;
        await fixture.expectRoute(candidate, active: false);
        await fixture.expectRoute(fixture.context('work'));
        expect(fixture.manager.activeRevisionCount, 1);
        expect(fixture.manager.retainedCaptureCount, 0);
        expect(fixture.host.captures, isEmpty);
        expect(fixture.host.payloads('replace'), hasLength(1));
        fixture.host.replies.remove('replace');
        _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
        expect(fixture.host.payloads('adoptAdvertised'), hasLength(1));
        expect(fixture.host.payloads('replace'), hasLength(2));
      },
    );
  }

  test(
    'local publication preflight rejects an oversized name before replacement',
    () async {
      final fixture = _Fixture([_record('work')]);
      fixture.host.records = [_record('work', name: 'n' * 1025)];
      _expectResult(
        await fixture.refresh('work'),
        'failed',
        'publication_invalid_request',
      );
      await _pump();
      expect(fixture.host.payloads('replace'), isEmpty);
      expect(fixture.host.payloads('adoptAdvertised'), hasLength(1));
      expect(fixture.manager.retainedCaptureCount, 0);
      await fixture.expectRoute(fixture.context('work'));
    },
  );

  test(
    'post-retirement replacementUnavailable fences old and candidate routes',
    () async {
      final fixture = _Fixture([_record('work'), _record('personal')]);
      fixture.host.replies['replace'] = {'failure': 'replacementUnavailable'};
      _expectResult(
        await fixture.refresh('work'),
        'unavailable',
        'publication_replacement_unavailable',
      );
      await _pump();
      await fixture.expectRoute(fixture.context('work'), active: false);
      await fixture.expectRoute(
        fixture.host.lastExposures.first.configurationContext,
        active: false,
      );
      await fixture.expectRoute(fixture.context('personal'));
      expect(fixture.manager.activeRevisionCount, 1);
      expect(fixture.manager.retainedCaptureCount, 0);
      fixture.host.replies.remove('replace');
      _expectResult(await fixture.refresh('work'), 'applied', 'added');
      expect(fixture.host.payloads('publish'), hasLength(1));
      expect(fixture.host.payloads('replace'), hasLength(1));
    },
  );

  for (final method in ['adoptAdvertised', 'publish', 'replace', 'retire']) {
    test(
      '$method outcomeUnknown never retries automatically or on later refresh',
      () async {
        final fixture = _Fixture(method == 'publish' ? [] : [_record('work')]);
        fixture.host.records = method == 'retire' ? [] : [_record('work')];
        fixture.host.replies[method] = {
          'group': _private,
          'secret': _secret,
          'endpoint': _endpoint,
        };
        _expectResult(
          await fixture.refresh('work'),
          'unavailable',
          'publication_outcome_unknown',
        );
        await _pump();
        final requests = fixture.host.requests.length;
        await _pump();
        expect(fixture.host.requests, hasLength(requests));
        fixture.host.replies.clear();
        for (final id in ['work', 'personal', 'work']) {
          _expectResult(
            await fixture.refresh(id),
            'unavailable',
            'publication_outcome_unknown',
          );
        }
        expect(fixture.host.requests, hasLength(requests));
        expect(fixture.host.captures, isEmpty);
        if (method != 'publish') {
          await fixture.expectRoute(
            fixture.context('work'),
            active: method == 'adoptAdvertised',
          );
        }
      },
    );
  }

  test(
    'unknown acknowledgment fences candidate admission without waiting for its drain',
    () async {
      final fixture = _Fixture([_record('work')]);
      fixture.host.replies['replace'] = {'failure': 'outcomeUnknown'};
      final publication = fixture.host.hold('replace');
      final refreshing = fixture.refresh('work');
      await publication.entered.future;
      final candidate = fixture.host.lastExposures.first.configurationContext;
      final read = fixture.host.hold('readCapturedCredential');
      final admitted = fixture.catalog(candidate);
      await read.entered.future;
      publication.release.complete();
      final result = await refreshing.timeout(const Duration(seconds: 2));
      _expectResult(result, 'unavailable', 'publication_outcome_unknown');
      expect(result['cleanupPending'], isTrue);
      expect(fixture.manager.retainedCaptureCount, 1);
      expect(fixture.host.captures, hasLength(1));
      expect(read.release.isCompleted, isFalse);
      await fixture.expectRoute(candidate, active: false);
      await fixture.expectRoute(fixture.context('work'), active: false);
      _expectResult(
        await fixture.refresh('work'),
        'unavailable',
        'publication_outcome_unknown',
      );
      expect(fixture.host.payloads('replace'), hasLength(1));
      read.release.complete();
      expect(_error(await admitted), 'unavailable');
      await _pump();
      expect(fixture.manager.retainedCaptureCount, 0);
      expect(fixture.manager.drainingRevisionCount, 0);
      expect(fixture.host.captures, isEmpty);
    },
  );

  test(
    'invalid endpoints and partial absence never imply deletion or default fallback',
    () async {
      final fixture = _Fixture([_record('work')]);
      for (final endpoint in [
        'http://external.invalid/private',
        'https://user:$_secret@host.invalid/responses',
        'https://host.invalid/responses#$_private',
        'https://[invalid',
        '',
      ]) {
        fixture.host.records = [_record('work', endpoint: endpoint)];
        _expectResult(
          await fixture.refresh('work'),
          'failed',
          'invalid_configuration',
        );
        expect(fixture.host.payloads('adoptAdvertised'), isEmpty);
        expect(fixture.host.captures, isEmpty);
        await fixture.expectRoute(fixture.context('work'));
      }
      fixture.host.records = [];
      fixture.host.isComplete = false;
      for (final id in ['work', 'absent']) {
        _expectResult(
          await fixture.refresh(id),
          'failed',
          'incomplete_observation',
        );
      }
      expect(fixture.host.payloads('retire'), isEmpty);
      await fixture.expectRoute(fixture.context('work'));
      fixture.host.isComplete = true;
      _expectResult(await fixture.refresh('work'), 'applied', 'retired');
      await fixture.expectRoute(fixture.context('work'), active: false);
      _expectResult(
        await fixture.refresh('work'),
        'noChange',
        'already_absent',
      );
      expect(fixture.host.payloads('retire'), hasLength(1));
      expect(fixture.manager.activeRevisionCount, 0);
      expect(fixture.host.keyReads, isEmpty);
      expect(fixture.host.captures, isEmpty);
    },
  );

  test(
    'more than eight sequential replacements release exact scopes after route drain',
    () async {
      final fixture = _Fixture([_record('work')]);
      _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
      final contexts = <String>{fixture.context('work')};
      for (var i = 0; i < 12; i++) {
        final old = fixture.host.lastExposures.first.configurationContext;
        expect(contexts.add(old), isTrue);
        final oldCapture = fixture.host.captures.single;
        final read = fixture.host.hold('readCapturedCredential');
        final admitted = fixture.catalog(old);
        await read.entered.future;
        _expectResult(await fixture.refresh('work'), 'applied', 'replaced');
        expect(fixture.manager.drainingRevisionCount, 1);
        expect(fixture.manager.retainedCaptureCount, 2);
        expect(fixture.host.captures, contains(oldCapture));
        await fixture.expectRoute(old, active: false);
        await fixture.expectRoute(
          fixture.host.lastExposures.first.configurationContext,
        );
        read.release.complete();
        expect(_error(await admitted), 'unavailable');
        await _pump();
        expect(fixture.manager.drainingRevisionCount, 0);
        expect(fixture.manager.retainedCaptureCount, 1);
        expect(fixture.host.captures, hasLength(1));
        expect(fixture.host.captures, isNot(contains(oldCapture)));
        expect(
          fixture.host
              .payloads('releaseCapture')
              .where((payload) => payload['capture'] == oldCapture),
          hasLength(1),
        );
      }
      expect(fixture.host.maximumCaptures, 2);
      expect(fixture.host.payloads('adoptAdvertised'), hasLength(1));
      fixture.host.records = [];
      _expectResult(await fixture.refresh('work'), 'applied', 'retired');
      await _pump();
      expect(fixture.manager.activeRevisionCount, 0);
      expect(fixture.manager.retainedCaptureCount, 0);
      expect(fixture.host.captures, isEmpty);
      for (final context in contexts) {
        await fixture.expectRoute(context, active: false);
      }
    },
  );

  for (final method in ['captureCurrentConfiguration', 'adoptAdvertised']) {
    test('shutdown while $method waits settles after mux revocation', () async {
      final fixture = _Fixture([_record('work')]);
      final gate = fixture.host.hold(method);
      final pending = fixture.refresh('work');
      await gate.entered.future;
      final queued = fixture.refresh('work');
      fixture.host.mux.close();
      final closing = fixture.manager.close();
      expect(identical(fixture.manager.close(), closing), isTrue);
      await closing.timeout(const Duration(seconds: 2));
      _expectResult(await pending, 'unavailable', 'shutdown');
      _expectResult(await queued, 'unavailable', 'shutdown');
      expect(gate.release.isCompleted, isFalse);
      expect(fixture.manager.activeRevisionCount, 0);
      expect(fixture.manager.drainingRevisionCount, 0);
      expect(fixture.manager.retainedCaptureCount, 0);
      expect(fixture.host.payloads('replace'), isEmpty);
      await fixture.expectRoute(fixture.context('work'), active: false);
      _expectResult(await fixture.refresh('work'), 'unavailable', 'shutdown');
      gate.release.complete();
      await gate.returned.future;
      expect(fixture.manager.activeRevisionCount, 0);
    });
  }
}

Map<String, Object?> _record(String id, {String? name, String? endpoint}) => {
  'collection': 'providers',
  'type': openAiApiKeyProviderId,
  'id': id,
  'values': {'display-name': name ?? id, 'endpoint': ?endpoint},
};

Map<String, Object?> _selectors(String id) => {
  'collection': 'providers',
  'recordType': openAiApiKeyProviderId,
  'recordId': id,
  'slot': 'api-key',
};

void _expectPair(List<AdeleCapabilityExposure> pair, String id) {
  expect(pair, hasLength(2));
  expect(pair.map((entry) => entry.serviceId), [
    modelProviderServiceId,
    modelCatalogServiceId,
  ]);
  expect(pair.map((entry) => entry.providerId), [
    '$openAiApiKeyProviderId.$id',
    'dev.adele.openai.model-catalog.$id',
  ]);
  expect(pair.first.configurationContext, matches(r'^dynamic:[0-9]+$'));
  expect(pair.last.configurationContext, pair.first.configurationContext);
  expect(pair.last.association?.providerId, pair.first.providerId);
}

void _expectResult(Object? value, String status, String code) {
  expect(value, {
    'status': status,
    'code': code,
    'cleanupPending': isA<bool>(),
  });
  expect(code, matches(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$'));
  final encoded = jsonEncode(value);
  for (final private in [
    _private,
    _secret,
    _endpoint,
    'generation-grant',
    'dynamic:',
    'group',
  ]) {
    expect(encoded, isNot(contains(private)));
  }
  expect(encoded, isNot(matches(r'[0-9a-f]{32}-[0-9a-f]{16}')));
}

String? _error(Map<String, Object?> response) =>
    (response['error'] as Map?)?['code'] as String?;
Future<void> _pump() => Future<void>.delayed(Duration.zero);

final class _Fixture {
  _Fixture(
    List<Map<String, Object?>> startup, {
    bool credentials = true,
    bool publisher = true,
  }) {
    host.records = startup;
    manager = OpenAiConfiguredProviders(
      router: router,
      defaultConfigurationContext: 'default',
      credentials: credentials
          ? AdeleCredentialClient(
              hostRequests: host.mux,
              hostInfrastructureContext: 'generation-grant',
            )
          : null,
      publisher: publisher
          ? AdeleCapabilityPublisher(
              hostRequests: host.mux,
              hostInfrastructureContext: 'generation-grant',
            )
          : null,
      configurations: OpenAiApiKeyConfiguration.fromRecords(
        AdeleBackendRecords(startup),
      ),
    );
    addTearDown(() async {
      host.mux.close();
      await manager.close();
      host.releaseGates();
    });
  }

  final host = _ScriptedHost();
  final router = AdeleConfigurationContextRouter(
    contexts: {
      for (final context in ['default', openAiChatGptConfigurationContext])
        context: {
          modelCatalogServiceId: ModelCatalogServiceDispatcher(
            _IndependentCatalog(),
          ),
        },
    },
  );
  late final OpenAiConfiguredProviders manager;
  int _requestId = 0;

  List<AdeleCapabilityExposure> pair(String id) => manager.initialExposures
      .where((entry) => entry.providerId.endsWith('.$id'))
      .toList();
  String context(String id) => pair(id).first.configurationContext;
  Future<Map<String, Object?>> refresh(Object? id) =>
      manager.refreshConfiguredProvider(id);

  Future<Map<String, Object?>> control(Map<String, Object?> changes) async {
    final responses = <Map<String, Object?>>[];
    await manager.handleControl({
      'kind': 'request',
      'requestId': ++_requestId,
      'configurationContext': 'default',
      'serviceId': openAiConfigurationServiceId,
      'method': 'refreshConfiguredProvider',
      'payload': {'recordId': 'work'},
      ...changes,
    }, responses.add);
    expect(responses, hasLength(1));
    return responses.single;
  }

  Future<Map<String, Object?>> catalog(
    String context, {
    String method = modelCatalogServiceListModelsId,
  }) async {
    final responses = <Map<String, Object?>>[];
    await router.handle({
      'kind': 'request',
      'requestId': ++_requestId,
      'configurationContext': context,
      'serviceId': modelCatalogServiceId,
      'method': method,
      'payload': <String, Object?>{},
    }, responses.add);
    expect(responses, hasLength(1));
    return responses.single;
  }

  Future<void> expectRoute(String context, {bool active = true}) async {
    expect(
      _error(await catalog(context, method: 'probe')),
      active ? 'unknown_method' : 'configuration_context_unavailable',
    );
  }
}

final class _IndependentCatalog implements ModelCatalogService {
  @override
  Future<ModelCatalogSnapshot> listModels() async =>
      ModelCatalogSnapshot(models: []);
}

final class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  final returned = Completer<void>();
}

// Script only the reverse transport. Credential and publication validation and
// route admission/draining are the real backend implementations.
final class _ScriptedHost {
  _ScriptedHost() {
    mux = AdeleHostRequestMultiplexer(
      send: (request) {
        requests.add(request);
        expect(request['kind'], 'hostRequest');
        expect(request['hostContextKind'], 'infrastructure');
        expect(request['hostContext'], 'generation-grant');
        final method = request['method'] as String;
        final credential = [
          'captureCurrentConfiguration',
          'releaseCapture',
          'readCredential',
          'readCapturedCredential',
        ].contains(method);
        expect(
          request['serviceId'],
          credential
              ? backendCredentialServiceId
              : backendCapabilityPublicationServiceId,
        );
        final payload = request['payload'] as Map<String, Object?>;
        if (payload['exposures'] != null) {
          lastExposures = adeleDecodeCapabilityPublication(
            payload['exposures'],
          );
        }
        final response = replies.containsKey(method)
            ? replies[method]
            : _respond(method, payload);
        final gate = _gates.remove(method);
        if (gate == null) {
          _reply(request, response);
        } else {
          gate.entered.complete();
          unawaited(
            gate.release.future.then((_) {
              _reply(request, response);
              gate.returned.complete();
            }),
          );
        }
      },
    );
  }

  late final AdeleHostRequestMultiplexer mux;
  final requests = <Map<String, Object?>>[];
  final replies = <String, Object?>{};
  final captures = <String>{};
  final _gates = <String, _Gate>{};
  final _allGates = <_Gate>[];
  List<Map<String, Object?>> records = [];
  List<AdeleCapabilityExposure> lastExposures = [];
  Map<String, Object?> keyResponse = {'failure': 'notConfigured'};
  bool isComplete = true;
  int maximumCaptures = 0;
  int _nextCapture = 0;
  int _nextGroup = 0;

  List<String> get methods => [
    for (final request in requests) request['method'] as String,
  ];
  List<Map<String, Object?>> get keyReads => requests
      .where(
        (request) =>
            request['method'] == 'readCredential' ||
            request['method'] == 'readCapturedCredential',
      )
      .toList();
  List<Map<String, Object?>> payloads(String method) => [
    for (final request in requests)
      if (request['method'] == method)
        request['payload'] as Map<String, Object?>,
  ];

  _Gate hold(String method) {
    expect(_gates, isNot(contains(method)));
    final gate = _Gate();
    _gates[method] = gate;
    _allGates.add(gate);
    return gate;
  }

  void releaseGates() {
    for (final gate in _allGates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
  }

  Object _respond(String method, Map<String, Object?> payload) {
    switch (method) {
      case 'captureCurrentConfiguration':
        expect(payload, isEmpty);
        if (captures.length == 8) return {'failure': 'credentialAccessFailed'};
        final handle =
            '${'a' * 32}-${(++_nextCapture).toRadixString(16).padLeft(16, '0')}';
        captures.add(handle);
        if (captures.length > maximumCaptures) {
          maximumCaptures = captures.length;
        }
        return {
          'capture': handle,
          'records': records,
          'isComplete': isComplete,
        };
      case 'releaseCapture':
        expect(captures.remove(payload['capture']), isTrue);
        return {'released': true};
      case 'readCredential':
        expect(payload, _selectors(payload['recordId'] as String));
        return keyResponse;
      case 'readCapturedCredential':
        expect(captures, contains(payload['capture']));
        expect(payload, {
          'capture': payload['capture'],
          ..._selectors(payload['recordId'] as String),
        });
        return keyResponse;
      case 'adoptAdvertised':
      case 'publish':
      case 'replace':
        return {
          'group':
              '${'b' * 32}-${(++_nextGroup).toRadixString(16).padLeft(16, '0')}',
        };
      case 'retire':
        return {'retired': true};
      default:
        throw StateError('Unexpected reverse method: $method');
    }
  }

  void _reply(Map<String, Object?> request, Object? response) {
    mux.handleResponse({
      'kind': 'hostResponse',
      'requestId': request['requestId'],
      'ok': true,
      'payload': response,
    });
  }
}
