import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/window_session_context.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

import '../fixtures/window_session_command.dart';

void main() {
  group('WindowSessionContextHost', () {
    late WindowSessionContextHost host;
    late WindowSessionContext context;
    late Session a;
    late Session b;

    setUp(() {
      host = WindowSessionContextHost();
      context = host.context;
      a = _session('a');
      b = _session('b');
      addTearDown(host.close);
    });

    test(
      'starts empty at revision zero behind a separate read-only facade',
      () {
        expect(context, same(host.context));
        expect(context, isNot(same(host)));
        expect(context, isNot(isA<WindowSessionContextHost>()));
        expect(context.isActive, isTrue);
        expect(context.snapshot.session, isNull);
        expect(context.snapshot.revision, 0);
        expect(host.session, isNull);
        expect(context.snapshot, same(context.snapshot));
        expect(
          () => (context as dynamic).presentSession(a),
          throwsNoSuchMethodError,
        );
        expect(() => (context as dynamic).close(), throwsNoSuchMethodError);
      },
    );

    test(
      'publishes canonical A, null, B and fresh A synchronously in order',
      () {
        final initial = context.snapshot;
        final changes = <WindowSessionSnapshot>[];
        final detach = context.observe((snapshot) {
          expect(context.snapshot, same(snapshot));
          expect(host.session, same(snapshot.session));
          changes.add(snapshot);
        });
        addTearDown(detach);
        expect(changes, isEmpty);

        host.presentSession(null);
        expect(context.snapshot, same(initial));
        expect(changes, isEmpty);
        for (final session in <Session?>[a, null, b, a]) {
          host.presentSession(session);
          expect(changes.last, same(context.snapshot));
          expect(changes.last.session, same(session));
          final committed = context.snapshot;
          final count = changes.length;
          host.presentSession(session);
          expect(context.snapshot, same(committed));
          expect(changes, hasLength(count));
        }

        expect(changes.map((snapshot) => snapshot.revision), [1, 2, 3, 4]);
        expect(changes.map((snapshot) => snapshot.session), [a, null, b, a]);
        expect(changes.first, isNot(same(changes.last)));
        expect(initial.session, isNull);
        expect(initial.revision, 0);
      },
    );

    test('no-op comparison uses canonical object identity, not Session ID', () {
      final changes = <WindowSessionSnapshot>[];
      context.observe(changes.add);
      host.presentSession(a);
      final sameId = _session('a');
      expect(sameId.id, a.id);
      expect(sameId, isNot(same(a)));

      host.presentSession(sameId);
      expect(context.snapshot.session, same(sameId));
      expect(host.session, same(sameId));
      expect(changes.map((snapshot) => snapshot.revision), [1, 2]);
    });

    test('late observation reads the current snapshot without replay', () {
      host.presentSession(a);
      final current = context.snapshot;
      final changes = <WindowSessionSnapshot>[];
      final detach = context.observe(changes.add);
      expect(context.snapshot, same(current));
      expect(current.session, same(a));
      expect(current.revision, 1);
      expect(changes, isEmpty);

      host.presentSession(a);
      expect(changes, isEmpty);
      host.presentSession(b);
      expect(changes.single, same(context.snapshot));
      expect(changes.single.session, same(b));
      expect(changes.single.revision, 2);
      detach();
      detach();
      host.presentSession(null);
      expect(changes, hasLength(1));
    });

    test(
      'captured snapshots remain immutable after navigation and closure',
      () {
        const empty = WindowSessionSnapshot(session: null, revision: 0);
        host.presentSession(a);
        final captured = context.snapshot;
        expect(
          () => (captured as dynamic).session = b,
          throwsNoSuchMethodError,
        );
        expect(
          () => (captured as dynamic).revision = 99,
          throwsNoSuchMethodError,
        );

        host.presentSession(null);
        host.presentSession(b);
        host.close();
        expect(empty.session, isNull);
        expect(empty.revision, 0);
        expect(captured.session, same(a));
        expect(captured.session!.id, a.id);
        expect(captured.session!.taskId, a.taskId);
        expect(captured.session!.strategyId, a.strategyId);
        expect(captured.revision, 1);
      },
    );

    test('duplicate callbacks have independent idempotent detach handles', () {
      final changes = <WindowSessionSnapshot>[];
      final listener = changes.add;
      final detachFirst = context.observe(listener);
      final detachSecond = context.observe(listener);
      detachFirst();
      detachFirst();
      host.presentSession(a);
      expect(changes.single, same(context.snapshot));
      detachSecond();
      detachSecond();
      host.presentSession(b);
      expect(changes, hasLength(1));
      host.close();
      expect(detachFirst, returnsNormally);
      expect(detachSecond, returnsNormally);
    });

    test(
      'detach suppresses pending listeners and adds wait for next change',
      () {
        final calls = <String>[];
        late void Function() detachFirst;
        late void Function() detachSecond;
        detachFirst = context.observe((snapshot) {
          calls.add('first:${snapshot.revision}');
          detachFirst();
          detachSecond();
          context.observe((next) => calls.add('late:${next.revision}'));
        });
        detachSecond = context.observe(
          (snapshot) => calls.add('second:${snapshot.revision}'),
        );
        context.observe((snapshot) => calls.add('third:${snapshot.revision}'));

        host.presentSession(a);
        expect(calls, ['first:1', 'third:1']);
        host.presentSession(b);
        expect(calls, ['first:1', 'third:1', 'third:2', 'late:2']);
      },
    );

    test(
      'listener failures stay in their registration Zones without rollback',
      () {
        final firstError = StateError('first listener');
        const secondError = 'second listener';
        final firstErrors = <Object>[];
        final secondErrors = <Object>[];
        final publisherErrors = <Object>[];
        final listenerZones = <Object?>[];
        final delivered = <WindowSessionSnapshot>[];
        runZonedGuarded(
          () => context.observe((snapshot) {
            listenerZones.add(Zone.current[#listener]);
            throw firstError;
          }),
          (error, stack) => firstErrors.add(error),
          zoneValues: {#listener: 'first'},
        );
        runZonedGuarded(
          () => context.observe((snapshot) {
            listenerZones.add(Zone.current[#listener]);
            throw secondError;
          }),
          (error, stack) => secondErrors.add(error),
          zoneValues: {#listener: 'second'},
        );
        context.observe(delivered.add);

        for (final session in [a, b]) {
          runZonedGuarded(
            () => host.presentSession(session),
            (error, stack) => publisherErrors.add(error),
            zoneValues: {#listener: 'publisher'},
          );
          expect(delivered.last, same(context.snapshot));
          expect(host.session, same(session));
        }
        expect(listenerZones, ['first', 'second', 'first', 'second']);
        expect(firstErrors, [same(firstError), same(firstError)]);
        expect(secondErrors, [secondError, secondError]);
        expect(publisherErrors, isEmpty);
        expect(delivered.map((snapshot) => snapshot.revision), [1, 2]);
      },
    );

    test('rejects all reentrant publication without skipping revisions', () {
      final changes = <WindowSessionSnapshot>[];
      final detach = context.observe((snapshot) {
        for (final session in <Session?>[b, null, a]) {
          expect(() => host.presentSession(session), throwsStateError);
          expect(context.snapshot, same(snapshot));
          expect(host.session, same(a));
        }
      });
      context.observe(changes.add);

      host.presentSession(a);
      expect(changes.single.session, same(a));
      expect(changes.single.revision, 1);
      detach();
      host.presentSession(b);
      expect(changes.map((snapshot) => snapshot.revision), [1, 2]);
      expect(changes.last.session, same(b));
    });

    test(
      'uncaught reentrant failure is isolated like other observer errors',
      () {
        final errors = <Object>[];
        final changes = <WindowSessionSnapshot>[];
        final detach = runZonedGuarded(
          () => context.observe((_) => host.presentSession(b)),
          (error, stack) => errors.add(error),
        )!;
        context.observe(changes.add);

        expect(() => host.presentSession(a), returnsNormally);
        expect(errors, [isA<StateError>()]);
        expect(changes.single, same(context.snapshot));
        expect(changes.single.session, same(a));
        expect(changes.single.revision, 1);
        detach();
        host.presentSession(b);
        expect(changes.last.revision, 2);
        expect(errors, hasLength(1));
      },
    );

    test(
      'close clears the source and fences reads without a synthetic event',
      () {
        final changes = <WindowSessionSnapshot>[];
        final detach = context.observe(changes.add);
        host.presentSession(a);
        final captured = context.snapshot;
        host.close();

        expect(context.isActive, isFalse);
        expect(host.session, isNull);
        expect(() => context.snapshot, throwsStateError);
        expect(() => context.observe((_) {}), throwsStateError);
        expect(() => host.presentSession(b), throwsStateError);
        expect(() => host.presentSession(null), throwsStateError);
        expect(host.close, returnsNormally);
        expect(detach, returnsNormally);
        expect(detach, returnsNormally);
        expect(changes, [same(captured)]);
        expect(captured.session, same(a));
        expect(captured.revision, 1);
      },
    );

    test('close during notification suppresses observers not yet called', () {
      final changes = <WindowSessionSnapshot>[];
      context.observe((snapshot) {
        changes.add(snapshot);
        host.close();
      });
      final later = <WindowSessionSnapshot>[];
      final detach = context.observe(later.add);

      expect(() => host.presentSession(a), returnsNormally);
      expect(context.isActive, isFalse);
      expect(host.session, isNull);
      expect(changes.single.session, same(a));
      expect(changes.single.revision, 1);
      expect(later, isEmpty);
      expect(() => context.snapshot, throwsStateError);
      expect(detach, returnsNormally);
    });

    test('two windows isolate selection, revisions, observers and closure', () {
      final other = WindowSessionContextHost();
      addTearDown(other.close);
      final changes = <WindowSessionSnapshot>[];
      final otherChanges = <WindowSessionSnapshot>[];
      context.observe(changes.add);
      other.context.observe(otherChanges.add);

      host.presentSession(a);
      expect(other.context.snapshot.revision, 0);
      expect(other.session, isNull);
      expect(otherChanges, isEmpty);
      other.presentSession(b);
      expect(host.session, same(a));
      expect(context.snapshot.revision, 1);
      host.presentSession(null);
      host.close();
      expect(other.context.isActive, isTrue);
      expect(other.session, same(b));
      expect(other.context.snapshot.revision, 1);
      other.presentSession(a);

      expect(changes.map((snapshot) => snapshot.session), [a, null]);
      expect(changes.map((snapshot) => snapshot.revision), [1, 2]);
      expect(otherChanges.map((snapshot) => snapshot.session), [b, a]);
      expect(otherChanges.map((snapshot) => snapshot.revision), [1, 2]);
      expect(context.isActive, isFalse);
      expect(() => context.snapshot, throwsStateError);
    });
  });

  group('window Session semantic Command', () {
    late WindowSessionContextHost host;
    late ExtensionRegistry registry;
    late Session a;
    late Session b;

    setUp(() {
      host = WindowSessionContextHost();
      registry = ExtensionRegistry();
      a = _session('a');
      b = _session('b');
      addTearDown(host.close);
    });

    test(
      'is hidden without a Session and rechecks invocation availability',
      () async {
        final fixture = WindowSessionCommandFixture(
          context: host.context,
          registry: registry,
        );
        addTearDown(fixture.close);
        final resolver = CommandResolver(registry);
        expect(
          resolver.discover().single.binding.value,
          same(fixture.contribution),
        );
        expect(fixture.initialSnapshot.session, isNull);
        expect(fixture.initialSnapshot.revision, 0);
        expect(fixture.changes, isEmpty);
        expect(fixture.command.availability, CommandAvailability.hidden);
        await expectLater(
          fixture.command.invoke(),
          throwsA(isA<CommandUnavailable>()),
        );

        host.presentSession(a);
        expect(fixture.command.availability, CommandAvailability.enabled);
        host.presentSession(null);
        await expectLater(
          fixture.command.invoke(),
          throwsA(isA<CommandUnavailable>()),
        );
        expect(fixture.command.availability, CommandAvailability.hidden);
        expect(fixture.captured, isEmpty);
        expect(fixture.completed, isEmpty);
        expect(fixture.changes.map((snapshot) => snapshot.session), [a, null]);
      },
    );

    test(
      'captures at invocation, not discovery or an earlier availability read',
      () async {
        host.presentSession(a);
        final fixture = WindowSessionCommandFixture(
          context: host.context,
          registry: registry,
        );
        addTearDown(fixture.close);
        expect(fixture.initialSnapshot.session, same(a));
        expect(fixture.command.availability, CommandAvailability.enabled);

        host.presentSession(b);
        final current = host.context.snapshot;
        final pending = fixture.command.invoke();
        expect(fixture.captured, [same(current)]);
        await pending;
        expect(fixture.completed, [same(current)]);
        expect(fixture.completed.single.session, same(b));
        expect(fixture.completed.single.revision, 2);
      },
    );

    test(
      'captures before an async gate and never redirects A work to B',
      () async {
        final gate = Completer<void>();
        final fixture = WindowSessionCommandFixture(
          context: host.context,
          registry: registry,
          gate: gate,
        );
        addTearDown(fixture.close);
        host.presentSession(a);
        final firstA = host.context.snapshot;
        final pending = fixture.command.invoke();
        expect(fixture.captured, [same(firstA)]);
        expect(fixture.completed, isEmpty);

        host.presentSession(b);
        expect(host.context.snapshot.session, same(b));
        expect(fixture.captured.single.session, same(a));
        expect(fixture.completed, isEmpty);
        gate.complete();
        await pending;
        expect(fixture.completed, [same(firstA)]);
        expect(host.session, same(b));

        host.presentSession(a);
        final freshA = host.context.snapshot;
        expect(freshA.session, same(a));
        expect(freshA.revision, 3);
        expect(freshA, isNot(same(firstA)));
        await fixture.command.invoke();
        expect(fixture.captured, [same(firstA), same(freshA)]);
        expect(fixture.completed, [same(firstA), same(freshA)]);
        expect(firstA.revision, 1);
      },
    );

    test(
      'binding retirement detaches observation without migrating admitted work',
      () async {
        final gate = Completer<void>();
        final fixture = WindowSessionCommandFixture(
          context: host.context,
          registry: registry,
          gate: gate,
        );
        addTearDown(fixture.close);
        host.presentSession(a);
        final captured = host.context.snapshot;
        final pending = fixture.command.invoke();
        expect(fixture.captured, [same(captured)]);

        final retiring = fixture.registration.close();
        host.presentSession(b);
        expect(fixture.changes, [same(captured)]);
        expect(fixture.command.availability, CommandAvailability.disabled);
        await retiring;
        await expectLater(
          fixture.command.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        final replacement = WindowSessionCommandFixture(
          context: host.context,
          registry: registry,
        );
        addTearDown(replacement.close);
        expect(replacement.initialSnapshot.session, same(b));
        expect(replacement.changes, isEmpty);
        expect(
          fixture.command.binding.isSameRegistration(
            replacement.command.binding,
          ),
          isFalse,
        );
        expect(fixture.command.availability, CommandAvailability.disabled);
        await expectLater(
          fixture.command.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );

        gate.complete();
        await pending;
        expect(fixture.completed, [same(captured)]);
        expect(replacement.captured, isEmpty);
        host.presentSession(a);
        await replacement.command.invoke();
        expect(replacement.changes.single, same(host.context.snapshot));
        expect(replacement.completed.single, same(host.context.snapshot));
        expect(replacement.completed.single.revision, 3);
        expect(fixture.changes, [same(captured)]);
        expect(fixture.captured, [same(captured)]);
      },
    );

    test(
      'a closed host and fresh host never retarget a stale consumer',
      () async {
        final gate = Completer<void>();
        final fixture = WindowSessionCommandFixture(
          context: host.context,
          registry: registry,
          gate: gate,
        );
        addTearDown(fixture.close);
        host.presentSession(a);
        final captured = host.context.snapshot;
        final pending = fixture.command.invoke();
        host.close();
        expect(fixture.registration.isClosed, isFalse);
        expect(fixture.context.isActive, isFalse);
        expect(fixture.command.availability, CommandAvailability.disabled);
        await expectLater(
          fixture.command.invoke(),
          throwsA(isA<CommandUnavailable>()),
        );

        final freshHost = WindowSessionContextHost();
        addTearDown(freshHost.close);
        final fresh = WindowSessionCommandFixture(
          context: freshHost.context,
          registry: ExtensionRegistry(),
        );
        addTearDown(fresh.close);
        expect(fresh.initialSnapshot.session, isNull);
        expect(fresh.initialSnapshot.revision, 0);
        freshHost.presentSession(b);
        await fresh.command.invoke();
        expect(fresh.completed.single.session, same(b));
        expect(fresh.completed.single.revision, 1);
        expect(fixture.context.isActive, isFalse);
        expect(() => fixture.context.snapshot, throwsStateError);
        expect(fixture.command.availability, CommandAvailability.disabled);
        await expectLater(
          fixture.command.invoke(),
          throwsA(isA<CommandUnavailable>()),
        );

        gate.complete();
        await pending;
        expect(fixture.completed, [same(captured)]);
        expect(fixture.captured, [same(captured)]);
        expect(fixture.changes, [same(captured)]);
        expect(captured.session, same(a));
        expect(freshHost.session, same(b));
        expect(host.session, isNull);
      },
    );
  });
}

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task-$id'),
  strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
);
