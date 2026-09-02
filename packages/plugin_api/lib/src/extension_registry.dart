import 'public_id.dart';

/// Typed identity for one extension domain.
final class ExtensionPoint<T extends Object> {
  factory ExtensionPoint(String value) {
    validateAdelePublicId(value, label: 'extension point ID');
    return ExtensionPoint<T>._(value);
  }

  const ExtensionPoint._(this.value);

  final String value;
  Type get _contributionType => T;

  bool _accepts(Object value) => value is T;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExtensionPoint<Object> &&
          other.runtimeType == runtimeType &&
          other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

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
  final Map<String, _ExtensionBucket> _extensions =
      <String, _ExtensionBucket>{};

  ExtensionRegistration register<T extends Object>({
    required ExtensionPoint<T> point,
    required ExtensionId id,
    required T value,
  }) {
    final _ExtensionBucket bucket = _requireBucket(point);
    if (!point._accepts(value)) {
      throw ExtensionContractException(
        'Extension $id does not satisfy the ${point._contributionType} '
        'contract declared by $point.',
      );
    }
    final Map<ExtensionId, _ActiveExtension<Object>> registrations =
        bucket.registrations;
    if (registrations.containsKey(id)) {
      throw ExtensionRegistrationException(
        'Extension $id is already active at $point.',
      );
    }
    final _ActiveExtension<Object> active = _ActiveExtension<Object>(
      pointId: point.value,
      id: id,
      value: value,
    );
    registrations[id] = active;
    return ExtensionRegistration._(this, active);
  }

  List<ExtensionBinding<T>> discover<T extends Object>(
    ExtensionPoint<T> point,
  ) {
    final Map<ExtensionId, _ActiveExtension<Object>> registrations =
        _requireBucket(point).registrations;
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
        _extensions[active.pointId]?.registrations;
    if (identical(registrations?[active.id], active)) {
      registrations!.remove(active.id);
    }
  }

  _ExtensionBucket _requireBucket<T extends Object>(ExtensionPoint<T> point) {
    final _ExtensionBucket? existing = _extensions[point.value];
    if (existing != null) {
      if (existing.contributionType != point._contributionType) {
        throw ExtensionContractException(
          'Extension point ${point.value} is already declared with '
          '${existing.contributionType}, not ${point._contributionType}.',
        );
      }
      return existing;
    }
    final _ExtensionBucket created = _ExtensionBucket(point._contributionType);
    _extensions[point.value] = created;
    return created;
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

final class ExtensionContractException implements Exception {
  const ExtensionContractException(this.message);

  final String message;

  @override
  String toString() => 'ExtensionContractException: $message';
}

final class _ExtensionBucket {
  _ExtensionBucket(this.contributionType);

  final Type contributionType;
  final Map<ExtensionId, _ActiveExtension<Object>> registrations =
      <ExtensionId, _ActiveExtension<Object>>{};
}

final class _ActiveExtension<T extends Object> {
  _ActiveExtension({
    required this.pointId,
    required this.id,
    required this.value,
  });

  final String pointId;
  final ExtensionId id;
  final T value;
  bool active = true;
}
