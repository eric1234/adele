import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  test('binds, resolves, unbinds, and clears arbitrary live objects', () {
    final LiveObjectRegistry<_FixtureId, _Fixture> registry =
        LiveObjectRegistry<_FixtureId, _Fixture>();
    const _FixtureId firstId = _FixtureId('first');
    const _FixtureId secondId = _FixtureId('second');
    const _Fixture first = _Fixture(1);
    const _Fixture second = _Fixture(2);

    expect(() => registry.resolve(firstId), throwsStateError);
    registry.bind(firstId, first);
    expect(registry.resolve(firstId), same(first));
    expect(registry.contains(firstId), isTrue);
    expect(() => registry.bind(firstId, second), throwsStateError);

    expect(registry.unbind(firstId), same(first));
    expect(registry.unbind(firstId), isNull);
    expect(() => registry.resolve(firstId), throwsStateError);

    registry.bind(firstId, first);
    registry.bind(secondId, second);
    registry.clear();
    expect(registry.length, 0);
    expect(() => registry.resolve(secondId), throwsStateError);
  });
}

final class _FixtureId {
  const _FixtureId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _FixtureId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class _Fixture {
  const _Fixture(this.value);

  final int value;
}
