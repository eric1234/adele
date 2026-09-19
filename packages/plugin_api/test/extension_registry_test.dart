import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  final ExtensionPoint<_Greeting> point = ExtensionPoint<_Greeting>(
    'dev.adele.test.greetings',
  );

  test('zero, one, and multiple registrations can be discovered', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    expect(registry.discover(point), isEmpty);

    registry.register(
      point: point,
      id: ExtensionId('dev.adele.test.greeting.one'),
      value: const _Greeting('one'),
    );
    registry.register(
      point: point,
      id: ExtensionId('dev.adele.test.greeting.two'),
      value: const _Greeting('two'),
    );

    expect(
      registry.discover(point).map((binding) => binding.value.text),
      <String>['one', 'two'],
    );
  });

  test('retirement stales an old binding without retargeting it', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    final ExtensionId id = ExtensionId('dev.adele.test.greeting.replaceable');
    final ExtensionRegistration generationA = registry.register(
      point: point,
      id: id,
      value: const _Greeting('A'),
    );
    final ExtensionBinding<_Greeting> bindingA = registry
        .discover(point)
        .single;

    await generationA.close();
    expect(registry.discover(point), isEmpty);
    expect(() => bindingA.value, throwsA(isA<StaleExtensionBinding>()));

    registry.register(point: point, id: id, value: const _Greeting('B'));
    expect(registry.discover(point).single.value.text, 'B');
    expect(() => bindingA.validate(), throwsA(isA<StaleExtensionBinding>()));
  });

  test(
    'exact ownership survives rediscovery, never IDs or reused values',
    () async {
      final registry = ExtensionRegistry();
      final foreign = ExtensionRegistry();
      final id = ExtensionId('dev.adele.test.exact');
      const value = _Greeting('shared');
      final registration = registry.register(
        point: point,
        id: id,
        value: value,
      );
      foreign.register(point: point, id: id, value: value);
      final first = registry.discover(point).single;
      final second = registry.discover(point).single;
      final other = foreign.discover(point).single;
      expect(first, isNot(same(second)));
      expect(registration.owns(first), isTrue);
      expect(registration.owns(second), isTrue);
      expect(first.isSameRegistration(second), isTrue);
      expect(registration.owns(other), isFalse);
      expect(first.isSameRegistration(other), isFalse);
      await registration.close();
      registry.register(point: point, id: id, value: value);
      final replacement = registry.discover(point).single;
      expect(registration.owns(first), isTrue);
      expect(registration.owns(replacement), isFalse);
      expect(first.isSameRegistration(replacement), isFalse);
      expect(first.validate, throwsA(isA<StaleExtensionBinding>()));
    },
  );

  test(
    'changes broadcast asynchronously after registration and retirement',
    () async {
      final ExtensionRegistry registry = ExtensionRegistry();
      final List<int> first = <int>[];
      final List<int> second = <int>[];
      final StreamSubscription<void> firstSubscription = registry.changes
          .listen((_) => first.add(registry.discover(point).length));
      final StreamSubscription<void> secondSubscription = registry.changes
          .listen((_) => second.add(registry.discover(point).length));
      addTearDown(firstSubscription.cancel);
      addTearDown(secondSubscription.cancel);

      final ExtensionRegistration registration = registry.register(
        point: point,
        id: ExtensionId('dev.adele.test.notified-greeting'),
        value: const _Greeting('one'),
      );
      final ExtensionBinding<_Greeting> binding = registry
          .discover(point)
          .single;
      expect(first, isEmpty);
      expect(second, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(first, <int>[1]);
      expect(second, <int>[1]);

      final Future<void> closing = registration.close();
      expect(() => binding.validate(), throwsA(isA<StaleExtensionBinding>()));
      expect(first, <int>[1]);
      expect(second, <int>[1]);
      await closing;
      await Future<void>.delayed(Duration.zero);
      expect(first, <int>[1, 0]);
      expect(second, <int>[1, 0]);
    },
  );

  test(
    'discovery, failed registration, and repeated close do not notify',
    () async {
      final ExtensionRegistry registry = ExtensionRegistry();
      int changes = 0;
      final StreamSubscription<void> subscription = registry.changes.listen(
        (_) => changes++,
      );
      addTearDown(subscription.cancel);
      final ExtensionId id = ExtensionId('dev.adele.test.notified-greeting');
      registry.discover(point);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 0);

      final ExtensionRegistration registration = registry.register(
        point: point,
        id: id,
        value: const _Greeting('one'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      expect(
        () => registry.register(
          point: point,
          id: id,
          value: const _Greeting('two'),
        ),
        throwsA(isA<ExtensionRegistrationException>()),
      );
      expect(
        () => registry.register(
          point: ExtensionPoint<String>(point.value),
          id: ExtensionId('dev.adele.test.wrong-contract'),
          value: 'wrong',
        ),
        throwsA(isA<ExtensionContractException>()),
      );
      registry.discover(point);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);

      await registration.close();
      await registration.close();
      await Future<void>.delayed(Duration.zero);
      expect(changes, 2);
    },
  );

  test('changes are not replayed and listeners can unsubscribe', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    final ExtensionRegistration registration = registry.register(
      point: point,
      id: ExtensionId('dev.adele.test.notified-greeting'),
      value: const _Greeting('one'),
    );
    int changes = 0;
    final StreamSubscription<void> subscription = registry.changes.listen(
      (_) => changes++,
    );
    await Future<void>.delayed(Duration.zero);
    expect(changes, 0);
    await subscription.cancel();
    await registration.close();
    await Future<void>.delayed(Duration.zero);
    expect(changes, 0);
  });

  test('ExtensionPoint equality uses exact invariant contribution type', () {
    final ExtensionPoint<_BaseGreeting> base = ExtensionPoint<_BaseGreeting>(
      'dev.adele.test.typed-point',
    );
    final ExtensionPoint<_DerivedGreeting> derived =
        ExtensionPoint<_DerivedGreeting>('dev.adele.test.typed-point');
    final ExtensionPoint<_BaseGreeting> sameBase =
        ExtensionPoint<_BaseGreeting>('dev.adele.test.typed-point');
    final ExtensionPoint<_BaseGreeting> otherId = ExtensionPoint<_BaseGreeting>(
      'dev.adele.test.other-typed-point',
    );

    expect(base == derived, isFalse);
    expect(derived == base, isFalse);
    expect(base, sameBase);
    expect(base.hashCode, sameBase.hashCode);
    expect(base == otherId, isFalse);
  });

  test('one stable point ID retains one exact type contract', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    final ExtensionPoint<_BaseGreeting> base = ExtensionPoint<_BaseGreeting>(
      'dev.adele.test.registry-typed-point',
    );
    final ExtensionPoint<_DerivedGreeting> derived =
        ExtensionPoint<_DerivedGreeting>('dev.adele.test.registry-typed-point');
    registry.register(
      point: base,
      id: ExtensionId('dev.adele.test.base-greeting'),
      value: const _BaseGreeting(),
    );

    expect(
      () => registry.discover(derived),
      throwsA(isA<ExtensionContractException>()),
    );
    expect(
      () => registry.register(
        point: derived,
        id: ExtensionId('dev.adele.test.derived-greeting'),
        value: const _DerivedGreeting(),
      ),
      throwsA(isA<ExtensionContractException>()),
    );
    expect(registry.discover(base).single.value, isA<_BaseGreeting>());
  });

  test('covariant calls cannot insert a value outside the point contract', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    final ExtensionPoint<_DerivedGreeting> derived =
        ExtensionPoint<_DerivedGreeting>(
          'dev.adele.test.covariant-typed-point',
        );

    expect(
      () => registry.register<_BaseGreeting>(
        point: derived,
        id: ExtensionId('dev.adele.test.invalid-base-greeting'),
        value: const _BaseGreeting(),
      ),
      throwsA(isA<ExtensionContractException>()),
    );
    expect(registry.discover(derived), isEmpty);
  });
}

final class _Greeting {
  const _Greeting(this.text);

  final String text;
}

class _BaseGreeting {
  const _BaseGreeting();
}

final class _DerivedGreeting extends _BaseGreeting {
  const _DerivedGreeting();
}
