import 'support/contract_generator_support.dart';

void main() {
  test(
    'generated concurrent admission, serial default, draining and stream control',
    () => runGeneratedFixture(_contract, _tests),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

const _contract = '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';

@AdeleService('unary')
abstract interface class UnaryService {
  @AdeleMethod('call') Future<String> call(int id, String authority);
}

@AdeleService('mixed')
abstract interface class MixedService {
  @AdeleMethod('call') Future<String> call(int id, String authority);
  @AdeleMethod('watch') Stream<String> watch(int id);
}
''';

const _tests = r'''
import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  for (final kind in ['unary', 'mixed']) {
    for (final concurrent in <bool?>[null, false, true]) {
      final label = '$kind concurrent=$concurrent';
      test('$label admits independently only when opted in', () async {
        final service = _Service();
        final dispatcher = _dispatcher(kind, service, concurrent);
        final blocked = service.gates[1] = Completer<String>();
        addTearDown(() async {
          if (!blocked.isCompleted) blocked.complete('first');
          await dispatcher.close();
        });
        final first = dispatcher.dispatch(_request(kind, 1));
        final responses = <Map<String, Object?>>[];
        final second = dispatcher.handle(_request(kind, 2), responses.add);
        await _turn();
        expect(service.entered, concurrent == true ? [1, 2] : [1]);
        expect(responses, concurrent == true ? [containsPair('payload', 'operation-2')] : isEmpty);
        blocked.complete('first');
        expect((await first)['payload'], 'first');
        await second;
        expect(service.entered, [1, 2]);
        expect(responses.single['requestId'], 2);
        expect(responses.single['payload'], 'operation-2');
      });

      test('$label close fences and drains every admission despite errors', () async {
        final service = _Service();
        final dispatcher = _dispatcher(kind, service, concurrent);
        for (final id in [1, 2, 3]) {
          service.gates[id] = Completer<String>();
        }
        addTearDown(() async {
          for (final gate in service.gates.values) {
            if (!gate.isCompleted) gate.complete('cleanup');
          }
          await dispatcher.close();
        });
        final first = dispatcher.dispatch(_request(kind, 1));
        final middle = dispatcher.dispatch(_request(kind, 2));
        final last = dispatcher.handle(_request(kind, 3), (_) {
          throw StateError('response sink failed');
        });
        final lastFailure = expectLater(last, throwsStateError);
        // Close before any admitted body starts, not just after service entry.
        final close = dispatcher.close();
        expect(identical(close, dispatcher.close()), isTrue);
        var closed = false;
        unawaited(close.then((_) => closed = true));
        await expectLater(dispatcher.dispatch(_request(kind, 4)), throwsStateError);
        await dispatcher.handle(_request(kind, 5), (_) => fail('late response'));
        await _turn();
        expect(closed, isFalse);
        expect(service.entered, concurrent == true ? [1, 2, 3] : [1]);
        service.gates[3]!.complete('last');
        if (concurrent == true) await lastFailure;
        service.gates[1]!.completeError(StateError('private backend detail'));
        final failed = await first;
        expect((failed['error'] as Map)['code'], 'internal_error');
        expect(failed.toString(), isNot(contains('private backend detail')));
        await _turn();
        // Neither the first failure nor the last settlement skips the middle.
        expect(closed, isFalse);
        service.gates[2]!.complete('middle');
        expect((await middle)['payload'], 'middle');
        await lastFailure;
        await close;
        expect(service.entered, [1, 2, 3]);
        expect(closed, isTrue);
      });
    }

    test('$kind concurrent admission retains decoding and operation authority', () async {
      final service = _Service();
      final dispatcher = _dispatcher(kind, service, true);
      final blocked = service.gates[1] = Completer<String>();
      addTearDown(() async {
        if (!blocked.isCompleted) blocked.complete('first');
        await dispatcher.close();
      });
      final first = dispatcher.dispatch(_request(kind, 1));
      for (final payload in <Map<String, Object?>>[
        {'id': '2', 'authority': 'operation-2'},
        {'id': 2},
        {'id': 2, 'authority': 'operation-2', 'extra': true},
      ]) {
        final invalid = await dispatcher.dispatch({..._request(kind, 2), 'payload': payload});
        expect((invalid['error'] as Map)['code'], 'invalid_request');
      }
      expect(service.entered, [1]);
      final unauthorized = await dispatcher.dispatch({
        ..._request(kind, 2),
        'payload': {'id': 2, 'authority': 'operation-1'},
      });
      expect((unauthorized['error'] as Map)['code'], 'internal_error');
      expect(service.entered, [1]);
      expect((await dispatcher.dispatch(_request(kind, 2)))['payload'], 'operation-2');
      blocked.complete('first');
      expect((await first)['payload'], 'first');
      expect(service.entered, [1, 2]);
    });

    test('$kind concurrent reentrant close includes the invoking operation', () async {
      final service = _Service();
      final dispatcher = _dispatcher(kind, service, true);
      final blocked = service.gates[1] = Completer<String>();
      late Future<void> close;
      var closed = false;
      service.onEntry = () {
        close = dispatcher.close();
        unawaited(close.then((_) => closed = true));
      };
      final first = dispatcher.dispatch(_request(kind, 1));
      await _turn();
      expect(closed, isFalse);
      blocked.complete('first');
      await first;
      await close;
      expect(closed, isTrue);
    });
  }

  for (final concurrent in [false, true]) {
    test('streams progress and cancel past blocked unary concurrent=$concurrent', () async {
      final service = _Service();
      final dispatcher = MixedServiceDispatcher(service, concurrent: concurrent);
      final events = <Map<String, Object?>>[];
      final delivered = Completer<void>();
      void send(Map<String, Object?> event) {
        events.add(event);
        if (event['kind'] == 'streamItem' && !delivered.isCompleted) delivered.complete();
      }
      for (final id in [10, 11]) {
        service.producers[id] = StreamController<String>();
        await dispatcher.handle(_open(id), send);
      }
      expect(service.opened, [10, 11]);
      await dispatcher.handle({'kind': 'streamCredit', 'requestId': 10, 'credit': 1}, send);
      final blocked = service.gates[1] = Completer<String>();
      final first = dispatcher.dispatch(_request('mixed', 1));
      addTearDown(() async {
        if (!blocked.isCompleted) blocked.complete('cleanup');
        await dispatcher.close();
        await Future.wait(service.producers.values.map((producer) => producer.close()));
      });
      await _turn();
      service.producers[11]!.add('second stream');
      await dispatcher.handle({'kind': 'streamCredit', 'requestId': 11, 'credit': 1}, send);
      await delivered.future.timeout(const Duration(seconds: 2));
      expect(events.single['requestId'], 11);
      expect(events.single['payload'], 'second stream');
      await dispatcher.handle({'kind': 'streamCancel', 'requestId': 10}, send)
          .timeout(const Duration(seconds: 2));
      expect(events.last, {'kind': 'streamCancelled', 'requestId': 10});
      expect(service.producers[10]!.hasListener, isFalse);
      expect(service.producers[11]!.hasListener, isTrue);
      final close = dispatcher.close();
      await _turn();
      expect(service.producers[11]!.hasListener, isFalse);
      blocked.complete('first');
      await first;
      await close;
      expect(events.where((event) => event['kind'] == 'streamItem').length, 1);
    });

    test('close drains all stream cancellation even on failure concurrent=$concurrent', () async {
      final service = _Service();
      final dispatcher = MixedServiceDispatcher(service, concurrent: concurrent);
      final cancelled = <int>[];
      final cleanup = Completer<void>();
      for (final id in [10, 11]) {
        service.producers[id] = StreamController<String>(onCancel: () {
          cancelled.add(id);
          if (id == 10) throw StateError('producer cancellation failed');
          return cleanup.future;
        });
        await dispatcher.handle(_open(id), (_) {});
        await dispatcher.handle({'kind': 'streamCredit', 'requestId': id, 'credit': 1}, (_) {});
      }
      final close = dispatcher.close();
      var closed = false;
      unawaited(close.then((_) => closed = true));
      await _turn();
      expect(cancelled, [10, 11]);
      expect(closed, isFalse);
      cleanup.complete();
      await close;
      await Future.wait(service.producers.values.map((producer) => producer.close()));
    });

    test('close fences queued stream opening concurrent=$concurrent', () async {
      final service = _Service();
      final dispatcher = MixedServiceDispatcher(service, concurrent: concurrent);
      final opening = dispatcher.handle(_open(10), (_) => fail('closed stream event'));
      final close = dispatcher.close();
      await dispatcher.handle(_open(11), (_) => fail('late stream event'));
      await opening;
      await close;
      expect(service.opened, isEmpty);
    });
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

AdeleBackendDispatcher _dispatcher(String kind, _Service service, bool? concurrent) {
  if (kind == 'unary') {
    return concurrent == null
        ? UnaryServiceDispatcher(service)
        : UnaryServiceDispatcher(service, concurrent: concurrent);
  }
  return concurrent == null
      ? MixedServiceDispatcher(service)
      : MixedServiceDispatcher(service, concurrent: concurrent);
}

Map<String, Object?> _request(String kind, int id) => {
  'kind': 'request', 'requestId': id, 'method': '$kind.call',
  'payload': {'id': id, 'authority': 'operation-$id'},
};

Map<String, Object?> _open(int id) => {
  'kind': 'streamOpen', 'requestId': id, 'method': 'mixed.watch', 'payload': {'id': id},
};

final class _Service implements UnaryService, MixedService {
  final gates = <int, Completer<String>>{};
  final entered = <int>[];
  final opened = <int>[];
  final producers = <int, StreamController<String>>{};
  void Function()? onEntry;

  @override
  Future<String> call(int id, String authority) {
    if (authority != 'operation-$id') throw StateError('Wrong operation authority.');
    entered.add(id);
    onEntry?.call();
    return gates[id]?.future ?? Future.value(authority);
  }

  @override
  Stream<String> watch(int id) {
    opened.add(id);
    return producers[id]!.stream;
  }
}
''';
