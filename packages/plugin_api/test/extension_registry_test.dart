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
}

final class _Greeting {
  const _Greeting(this.text);

  final String text;
}
