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
