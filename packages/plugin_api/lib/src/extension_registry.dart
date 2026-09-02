import 'public_id.dart';

/// Typed identity for one extension domain.
final class ExtensionPoint<T extends Object> {
  factory ExtensionPoint(String value) {
    validateAdelePublicId(value, label: 'extension point ID');
    return ExtensionPoint<T>._(value);
  }

  const ExtensionPoint._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExtensionPoint<T> && other.value == value;

  @override
  int get hashCode => Object.hash(T, value);

  @override
  String toString() => value;
}

/// Stable identity for one contribution within an extension point.
final class ExtensionId {
  factory ExtensionId(String value) {
    validateAdelePublicId(value, label: 'extension ID');
    return ExtensionId._(value);
  }

  const ExtensionId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ExtensionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ExtensionRegistry {
  final Map<ExtensionPoint<Object>, Map<ExtensionId, _ActiveExtension<Object>>>
  _extensions =
      <ExtensionPoint<Object>, Map<ExtensionId, _ActiveExtension<Object>>>{};

  ExtensionRegistration register<T extends Object>({
    required ExtensionPoint<T> point,
    required ExtensionId id,
    required T value,
  }) {
    final ExtensionPoint<Object> erasedPoint = _erasePoint(point);
    final Map<ExtensionId, _ActiveExtension<Object>> registrations = _extensions
        .putIfAbsent(
          erasedPoint,
          () => <ExtensionId, _ActiveExtension<Object>>{},
        );
    if (registrations.containsKey(id)) {
      throw ExtensionRegistrationException(
        'Extension $id is already active at $point.',
      );
    }
    final _ActiveExtension<Object> active = _ActiveExtension<Object>(
      point: erasedPoint,
      id: id,
      value: value,
    );
    registrations[id] = active;
    return ExtensionRegistration._(this, active);
  }

  List<ExtensionBinding<T>> discover<T extends Object>(
    ExtensionPoint<T> point,
  ) {
    final Map<ExtensionId, _ActiveExtension<Object>>? registrations =
        _extensions[_erasePoint(point)];
    if (registrations == null) return <ExtensionBinding<T>>[];
    return List<ExtensionBinding<T>>.unmodifiable(
      registrations.values.map(
        (_ActiveExtension<Object> active) => ExtensionBinding<T>._(active),
      ),
    );
  }

  void _remove(_ActiveExtension<Object> active) {
    if (!active.active) return;
    active.active = false;
    final Map<ExtensionId, _ActiveExtension<Object>>? registrations =
        _extensions[active.point];
    if (identical(registrations?[active.id], active)) {
      registrations!.remove(active.id);
      if (registrations.isEmpty) _extensions.remove(active.point);
    }
  }
}

final class ExtensionBinding<T extends Object> {
  ExtensionBinding._(this._active);

  final _ActiveExtension<Object> _active;

  ExtensionId get id => _active.id;

  T get value {
    if (!_active.active) throw StaleExtensionBinding(id);
    final Object value = _active.value;
    if (value is! T) {
      throw ExtensionRegistrationException(
        'Extension $id has an unexpected value type.',
      );
    }
    return value;
  }

  void validate() {
    if (!_active.active) throw StaleExtensionBinding(id);
  }
}

final class ExtensionRegistration {
  ExtensionRegistration._(this._registry, this._active);

  final ExtensionRegistry _registry;
  final _ActiveExtension<Object> _active;

  bool get isClosed => !_active.active;

  Future<void> close() async => _registry._remove(_active);
}

final class ExtensionRegistrationGroup {
  final List<ExtensionRegistration> _registrations = <ExtensionRegistration>[];
  bool _closed = false;

  void add(ExtensionRegistration registration) {
    if (_closed) {
      throw const ExtensionRegistrationException(
        'A closed extension registration group cannot accept registrations.',
      );
    }
    _registrations.add(registration);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final ExtensionRegistration registration in _registrations.reversed) {
      await registration.close();
    }
  }
}

final class StaleExtensionBinding implements Exception {
  const StaleExtensionBinding(this.id);

  final ExtensionId id;

  @override
  String toString() => 'StaleExtensionBinding: Extension $id is retired.';
}

final class ExtensionRegistrationException implements Exception {
  const ExtensionRegistrationException(this.message);

  final String message;

  @override
  String toString() => 'ExtensionRegistrationException: $message';
}

final class _ActiveExtension<T extends Object> {
  _ActiveExtension({
    required this.point,
    required this.id,
    required this.value,
  });

  final ExtensionPoint<Object> point;
  final ExtensionId id;
  final T value;
  bool active = true;
}

ExtensionPoint<Object> _erasePoint<T extends Object>(ExtensionPoint<T> point) =>
    ExtensionPoint<Object>._(point.value);
