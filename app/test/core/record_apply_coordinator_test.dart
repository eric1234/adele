import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/prepared_records.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/record_apply_coordinator.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'test.records';
const _peer = '$_owner.child';
const _publicationUnknown = 'publication_outcome_unknown';
const _ackUnknown = 'apply_acknowledgement_unknown';
const _testDeadline = Duration(minutes: 3);
const _private = '/private/example/account-token';

RecordApplyKey _key({String owner = _owner, String id = 'work'}) => (
  collection: RecordCollectionId('jobs'),
  type: RecordTypeId('$owner.record'),
  id: ConfigurationRecordId(id),
);

Map<String, Object> _result(
  String status,
  String code, {
  bool pending = false,
}) => {'status': status, 'code': code, 'cleanupPending': pending};

void main() {
  final key = _key();
  final peerKey = _key(owner: _peer);

  test('routes only the exact declared type to its installation', () async {
    final f = await _Fixture.start();
    final apply = f.apply;
    for (final unsupported in <RecordApplyKey>[
      (collection: RecordCollectionId('other'), type: key.type, id: key.id),
      (
        collection: key.collection,
        type: RecordTypeId('$_owner.passive'),
        id: key.id,
      ),
    ]) {
      expect(apply.supports(unsupported), isFalse);
      apply.saved(unsupported);
      apply.retry(unsupported);
      expect(apply.outcome(unsupported), isNull);
    }
    expect(await f.count(), 0);

    // Even a matching collection and record ID cannot select another type's owner.
    for (final (index, target, owner) in [
      (0, key, _owner),
      (1, peerKey, _peer),
    ]) {
      expect(apply.supports(target), isTrue);
      expect(apply.outcome(target), isNull);
      apply.saved(target);
      final request = await f.call(index);
      expect(request['pluginId'], owner);
      expect(request['configurationContext'], 'default');
      expect(request['serviceId'], '$owner.apply');
      expect(request['method'], _method(owner));
      expect(request['payload'], {'recordId': target.id.value});
      expect(request.containsKey('hostInvocationContext'), isFalse);
      expect(apply.outcome(target)!.status, RecordApplyStatus.applying);
      await f.reply(index, _result('applied', 'replaced', pending: true));
      final outcome = await f.status(target, RecordApplyStatus.applied);
      expect(outcome.code, 'replaced');
      expect(outcome.cleanupPending, isTrue);
      apply.retry(target); // Pending cleanup is not a reason to publish again.
    }
    expect(await f.count(), 2);
  });

  test(
    'a declared but unavailable owner never falls back to a sibling',
    () async {
      final f = await _Fixture.start(failOwner: true);
      expect(f.apply.supports(key), isTrue);
      f.apply.saved(key);
      final unavailable = await f.status(key, RecordApplyStatus.unavailable);
      expect(unavailable.code, 'backend_unavailable');
      f.apply.retry(key);
      await f.status(key, RecordApplyStatus.unavailable);
      expect(await f.count(), 0);
    },
  );

  final good = _result('applied', 'added', pending: true);
  final malformed = <String, Object?>{
    'non-object result': _private,
    'unknown status': {...good, 'status': _private},
    'invalid code': {...good, 'code': _private},
    'oversized code': {...good, 'code': 'a' * 65},
    'non-boolean cleanupPending': {...good, 'cleanupPending': 'true'},
    'unexpected field': {...good, 'detail': _private},
    'missing cleanupPending': {'status': 'applied', 'code': 'added'},
    'publication unknown marked applied': {
      ...good,
      'code': _publicationUnknown,
    },
  };
  for (final problem in <String, Map<String, Object?>>{
    for (final entry in malformed.entries)
      entry.key: {'ok': true, 'payload': entry.value},
    'wrong pluginId': {'ok': true, 'pluginId': _peer, 'payload': good},
    'wrong kind': {'ok': true, 'kind': 'pluginReady', 'payload': good},
    for (final code in ['private_account_token', 'response_encoding_failed'])
      'transport error $code': {
        'ok': false,
        'error': {
          'code': code,
          'message': _private,
          'details': {'stack': _private},
        },
      },
  }.entries) {
    test('${problem.key} is not an apply acknowledgement', () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      await f.respond(0, problem.value);
      final result = await f.status(key, RecordApplyStatus.restartRequired);
      expect(result.code, _ackUnknown);
      expect(result.cleanupPending, isFalse);
      f.apply.retry(key);
      final other = _key(id: 'other');
      f.apply.saved(other);
      expect(
        (await f.status(other, RecordApplyStatus.restartRequired)).code,
        _ackUnknown,
      );
      expect(await f.count(), 1);
    });
  }

  test(
    'new saves coalesce behind the held attempt without publishing stale results',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      final observed = <RecordApplyStatus>[];
      f.apply.addListener(() => observed.add(f.apply.outcome(key)!.status));
      f.apply.saved(key);
      f.apply.saved(key, deleted: true);
      expect(f.apply.recentDeletion(key.collection), key);
      expect(await f.count(), 1);

      await f.reply(0, _result('failed', 'invalid_configuration'));
      final latest = await f.call(1);
      expect(latest['payload'], {'recordId': key.id.value});
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.applying);
      await f.reply(1, _result('noChange', 'already_absent'));
      final result = await f.status(key, RecordApplyStatus.noChange);
      expect(result.code, 'already_absent');
      expect(result.cleanupPending, isFalse);
      expect(f.apply.recentDeletion(key.collection), key);
      expect(observed, isNot(contains(RecordApplyStatus.failed)));
      expect(f.apply.outcome(key, deleted: true), same(result));
      expect(f.apply.outcome(key, deleted: false), isNull);
      expect(await f.count(), 2);
    },
  );

  test(
    'reconciliation is not an acknowledgement and needs explicit retry',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      f.apply.reconciled(key);
      await f.status(key, RecordApplyStatus.notApplied);
      await f.reply(0, _result('applied', 'added'));
      expect(await f.count(), 1);
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.notApplied);
      for (final (i, status, code) in [
        (1, RecordApplyStatus.failed, 'invalid_configuration'),
        (2, RecordApplyStatus.unavailable, 'refresh_capacity'),
      ]) {
        f.apply.retry(key);
        await f.call(i);
        await f.reply(i, _result(status.name, code));
        expect((await f.status(key, status)).code, code);
        expect(await f.count(), i + 1);
      }
      f.apply.retry(key);
      await f.call(3);
      await f.reply(3, _result('applied', 'replaced'));
      await f.status(key, RecordApplyStatus.applied);
      expect(await f.count(), 4);
    },
  );

  test(
    'unconfirmed persistence suppresses late results without a new call',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      f.apply.unconfirmed(key);
      await f.reply(0, _result('applied', 'replaced'));
      expect(f.apply.outcome(key), isNull);
      f.apply.retry(key);
      expect(await f.count(), 1);
    },
  );

  test(
    'bounded admission preserves pending records during status eviction',
    () async {
      final f = await _Fixture.start();
      for (var i = 0; i < 16; i++) {
        f.apply.saved(_key(id: 'held-$i'));
      }
      await f.call(15);
      final oldest = _key(id: 'overflow-0');
      f.apply.saved(oldest, deleted: true);
      final full = await f.status(oldest, RecordApplyStatus.unavailable);
      expect(full.code, 'apply_capacity');
      for (var i = 1; i <= 128; i++) {
        f.apply.saved(_key(id: 'overflow-$i'));
      }
      expect(f.apply.outcome(oldest), isNull);
      expect(f.apply.recentDeletion(oldest.collection), isNull);
      expect(await f.count(), 16);
      await f.reply(0, _result('applied', 'added'));
      await f.status(_key(id: 'held-0'), RecordApplyStatus.applied);
      final newest = _key(id: 'overflow-128');
      f.apply.retry(newest);
      expect((await f.call(16))['payload'], {'recordId': 'overflow-128'});
      await f.reply(16, _result('applied', 'added'));
      await f.status(newest, RecordApplyStatus.applied);
    },
  );

  for (final cause in [_ackUnknown, _publicationUnknown]) {
    test('$cause on a superseded apply fences its live generation', () async {
      final f = await _Fixture.start();
      final expire = f.saveWithControlledDeadline(key);
      await f.call(0);
      // The child publishes the record without replying to the original request.
      expect(await f.commit(0), [key.id.value]);
      final held = _key(id: 'held');
      f.apply.saved(held);
      await f.call(1);
      final recovered = _key(id: 'recovered');
      f.apply.reconciled(recovered);
      f.apply.saved(key);
      expect(await f.count(), 2);
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.applying);
      if (cause == _ackUnknown) {
        expire();
      } else {
        await f.reply(0, _result('unavailable', _publicationUnknown));
      }
      final unknown = await f.status(key, RecordApplyStatus.restartRequired);
      expect(unknown.code, cause);
      expect(f.backend(_owner).state, InstalledBackendState.active);
      if (cause == _ackUnknown) await f.reply(0, good); // Late success.
      await f.reply(1, good);
      for (final affected in [key, held, recovered]) {
        final result = await f.status(
          affected,
          RecordApplyStatus.restartRequired,
        );
        expect(result.code, cause);
        expect(result.cleanupPending, isFalse);
      }
      f.apply.retry(key);
      f.apply.saved(key);
      final other = _key(id: 'other');
      f.apply.saved(other);
      expect(
        (await f.status(other, RecordApplyStatus.restartRequired)).code,
        cause,
      );
      f.apply.retry(other);
      expect(await f.count(), 2);
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.restartRequired);

      f.apply.saved(peerKey);
      expect((await f.call(2))['pluginId'], _peer);
      await f.reply(2, _result('applied', 'added'));
      await f.status(peerKey, RecordApplyStatus.applied);
      expect(await f.count(), 3);
    });
  }

  for (final retire in [true, false]) {
    test(
      '${retire ? 'retirement' : 'shutdown'} discards pending and late apply results',
      () async {
        final f = await _Fixture.start();
        f.apply.saved(key);
        await f.call(0);
        f.apply.saved(key);
        if (retire) {
          await f.backend(_owner).connection!.close();
        } else {
          f.apply.close();
        }
        await f.status(key, RecordApplyStatus.unavailable);
        // The independent peer still has a live connection to the scripted host.
        await f.reply(0, _result('applied', 'replaced', pending: true));
        f.apply.retry(key);
        expect(await f.count(), 1);
        final outcome = f.apply.outcome(key)!;
        expect(outcome.status, RecordApplyStatus.unavailable);
        expect(outcome.code, 'backend_unavailable');
        expect(outcome.cleanupPending, isFalse);
      },
    );
  }
}

String _method(String owner) => owner == _owner ? 'refresh' : 'applyChange';

final class _Fixture {
  _Fixture(this.bootstrap)
    : apply = RecordApplyCoordinator(
        bootstrap,
        bootstrap.catalog!,
        acknowledgementTimeout: _testDeadline,
      );

  final ApplicationPluginBootstrap bootstrap;
  final RecordApplyCoordinator apply;

  static Future<_Fixture> start({bool failOwner = false}) async {
    final temp = await Directory.systemTemp.createTemp('record-apply-');
    addTearDown(() => temp.delete(recursive: true));
    final root = await Directory('${temp.path}/installations').create();
    for (final owner in [_owner, _peer]) {
      final dir = await Directory('${root.path}/$owner').create();
      await File('${dir.path}/backend.aot').writeAsString('unused');
      await File('${dir.path}/records.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'recordTypes': [
            for (final type in ['record', 'passive'])
              {
                'id': '$owner.$type',
                'collection': 'jobs',
                'collectionLabel': 'Jobs',
                'label': type,
                'fields': <Object?>[],
              },
          ],
        }),
      );
      await File('${dir.path}/adele_plugin.installation.json').writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': owner, 'version': '1', 'displayName': owner},
          'recordsSchema': 'records.json',
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              'consumesRecordTypes': ['$owner.record', '$owner.passive'],
              'appliesRecordTypes': [
                {
                  'recordType': '$owner.record',
                  'serviceId': '$owner.apply',
                  'method': _method(owner),
                },
              ],
            },
          },
        }),
      );
    }
    final script = await File(
      '${temp.path}/host.dart',
    ).writeAsString(_hostScript);
    final bootstrap = ApplicationPluginBootstrap(
      CapabilityRegistry(),
      ExtensionRegistry(),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: (catalog, installation) async =>
          StartupRecordsView.fromProjection(
            catalog,
            installation,
            records: const [],
          ),
    );
    addTearDown(bootstrap.close);
    await bootstrap.start(
      installationRoot: root.path,
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      hostArtifactPath: script.path,
      startupArguments: {
        if (failOwner) _owner: ['fail'],
      },
    );
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(bootstrap.catalog!.issues, isEmpty);
    final f = _Fixture(bootstrap);
    addTearDown(f.apply.close);
    expect(f.backend(_peer).state, InstalledBackendState.active);
    expect(
      f.backend(_owner).state,
      failOwner ? InstalledBackendState.failed : InstalledBackendState.active,
    );
    return f;
  }

  InstalledBackendActivation backend(String id) => bootstrap.backends
      .singleWhere((b) => b.installation.metadata.id.value == id);

  PluginBackendConnection get _control => backend(_peer).connection!;

  // Advance only this apply's acknowledgement timer. Child I/O, microtasks,
  // and the fixture's own watchdogs still run normally.
  void Function() saveWithControlledDeadline(RecordApplyKey key) {
    late void Function() expire;
    runZoned(
      () => apply.saved(key),
      zoneSpecification: ZoneSpecification(
        createTimer: (_, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (duration == _testDeadline) {
            expire = () {
              expect(timer.isActive, isTrue);
              timer.cancel();
              zone.run(callback);
            };
          }
          return timer;
        },
      ),
    );
    return () => expire();
  }

  Future<int> count() async {
    // Let any queued coordinator dispatch reach the transport before this barrier.
    await Future<void>.value();
    return (await _control.request('fixture.count', {}))! as int;
  }

  Future<Map<String, Object?>> call(int index) async =>
      (await _control
              .request('fixture.call', {'index': index})
              .timeout(const Duration(seconds: 5)))!
          as Map<String, Object?>;
  Future<Object?> commit(int index) =>
      _control.request('fixture.commit', {'index': index});

  Future<void> reply(int index, Object? payload) =>
      respond(index, {'ok': true, 'payload': payload});

  Future<void> respond(int index, Map<String, Object?> envelope) async {
    await _control.request('fixture.reply', {
      'index': index,
      'envelope': envelope,
    });
  }

  Future<RecordApplyOutcome> status(
    RecordApplyKey key,
    RecordApplyStatus expected,
  ) async {
    final done = Completer<RecordApplyOutcome>();
    void check() {
      final current = apply.outcome(key);
      if (!done.isCompleted &&
          current != null &&
          current.status != RecordApplyStatus.applying) {
        done.complete(current);
      }
    }

    check();
    if (!done.isCompleted) {
      apply.addListener(check);
      try {
        await done.future.timeout(const Duration(seconds: 5));
      } finally {
        apply.removeListener(check);
      }
    }
    final result = await done.future;
    expect(result.status, expected, reason: '${key.id.value}: ${result.code}');
    return result;
  }
}

// Like _exactHostScript in application_plugin_bootstrap_test, only the child is
// synthetic. Every apply is held; fixture commands observe and settle its real
// transport request ID, including after the owning activation has retired.
const _hostScript = r'''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void main() {
  final calls = <Map<String, dynamic>>[];
  final published = <String>{};
  final waiters = <int, Map<String, dynamic>>{};
  var buffer = <int>[];
  void send(Map<String, dynamic> message) {
    final body = utf8.encode(jsonEncode({'protocolVersion': 1, ...message}));
    final header = ByteData(4)..setUint32(0, body.length);
    stdout.add([...header.buffer.asUint8List(), ...body]);
  }
  void reply(Map request, Object? payload) => send({
    'kind': 'response', 'requestId': request['requestId'],
    'pluginId': request['pluginId'], 'ok': true, 'payload': payload,
  });
  send({'kind': 'hostHello'});
  stdin.listen((bytes) {
    buffer.addAll(bytes);
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(buffer), 0, 4).getUint32(0);
      if (buffer.length < 4 + length) break;
      final m = jsonDecode(utf8.decode(buffer.sublist(4, 4 + length))) as Map<String, dynamic>;
      buffer = buffer.sublist(4 + length);
      final route = {'requestId': m['requestId'], 'pluginId': m['pluginId']};
      switch (m['kind']) {
        case 'startPlugin':
          if ((m['arguments'] as List).contains('fail')) {
            send({'kind': 'pluginFailed', ...route, 'error': {'code': 'failed', 'message': 'private startup failure'}});
          } else {
            send({'kind': 'pluginReady', ...route});
          }
        case 'stopPlugin':
          send({'kind': 'pluginStopped', ...route});
        case 'request':
          final p = m['payload'] as Map;
          switch (m['method']) {
            case 'fixture.count': reply(m, calls.length);
            case 'fixture.call':
              final i = p['index'] as int;
              if (i < calls.length) { reply(m, calls[i]); } else { waiters[i] = m; }
            case 'fixture.commit':
              final call = calls[p['index'] as int];
              published.add(call['payload']['recordId'] as String);
              reply(m, published.toList());
            case 'fixture.reply':
              final call = calls[p['index'] as int];
              send({'kind': 'response', 'pluginId': call['pluginId'],
                ...p['envelope'] as Map<String, dynamic>, 'requestId': call['requestId']});
              reply(m, null);
            default:
              final waiter = waiters.remove(calls.length);
              calls.add(m);
              if (waiter != null) reply(waiter, m);
          }
        case 'shutdownHost':
          send({'kind': 'hostStopped', ...route});
          exit(0);
      }
    }
  });
}
''';
