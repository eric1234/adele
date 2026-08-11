import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

void main() {
  test('bounds operations while stream controls remain responsive', () async {
    final dispatcher = _Dispatcher();
    final runner = AdeleBackendCommandRunner(
      dispatcher,
      (_) {},
      maxConcurrentOperations: 1,
    );
    final Future<void> first = runner.add({'kind': 'request'});
    await dispatcher.started.future;
    final Future<void> second = runner.add({'kind': 'request'});
    await runner.add({'kind': 'streamCancel'});
    expect(dispatcher.controlCount, 1);
    expect(dispatcher.requestCount, 1);
    dispatcher.release.complete();
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(dispatcher.maxActive, 1);
    await runner.close();
  });
}

final class _Dispatcher implements AdeleBackendDispatcher {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int requestCount = 0;
  int controlCount = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) async {
    if (command['kind'] == 'streamCancel') {
      controlCount++;
      return;
    }
    requestCount++;
    active++;
    maxActive = active > maxActive ? active : maxActive;
    if (!started.isCompleted) started.complete();
    await release.future;
    active--;
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async =>
      <String, Object?>{};

  @override
  Future<void> close() async {}
}
