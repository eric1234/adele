import 'package:adele_plugin_api/adele_plugin_api.dart';

/// Stable setting identity, independent of its presentation or stored value.
final class SettingId {
  factory SettingId(String value) {
    validateAdelePublicId(value, label: 'setting ID');
    return SettingId._(value);
  }

  const SettingId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SettingId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Declaration ownership, not plugin identity, runtime identity, or authority.
final class SettingOwnerId {
  factory SettingOwnerId(String value) {
    validateAdelePublicId(value, label: 'setting owner ID');
    return SettingOwnerId._(value);
  }

  const SettingOwnerId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SettingOwnerId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Closed, data-only scalar declarations. No caller-supplied validation behavior.
sealed class SettingType<T extends Object> {
  const SettingType._();

  T _validate(SettingId id, Object? value) {
    switch (this) {
      case BooleanSettingType():
        if (value is! bool) {
          throw InvalidSettingValue(id, 'Expected a boolean.');
        }
      case IntegerSettingType(:final minimum, :final maximum):
        if (value is! int) {
          throw InvalidSettingValue(id, 'Expected a native Dart int.');
        }
        if (minimum != null && value < minimum) {
          throw InvalidSettingValue(id, 'Must be at least $minimum.');
        }
        if (maximum != null && value > maximum) {
          throw InvalidSettingValue(id, 'Must be at most $maximum.');
        }
      case StringSettingType():
        if (value is! String) {
          throw InvalidSettingValue(id, 'Expected a string.');
        }
      case EnumSettingType(:final options):
        if (value is! String ||
            !options.any((option) => option.value == value)) {
          throw InvalidSettingValue(id, 'Expected a declared enum string.');
        }
    }
    return value as T;
  }
}

final class BooleanSettingType extends SettingType<bool> {
  const BooleanSettingType() : super._();
}

/// A native Dart signed 64-bit integer (-2^63 through 2^63 - 1), without coercion.
///
/// Optional bounds are inclusive. This contract targets the native Dart runtime,
/// not JavaScript's integer representation; doubles, BigInts, and strings fail.
final class IntegerSettingType extends SettingType<int> {
  IntegerSettingType({this.minimum, this.maximum}) : super._() {
    if (minimum != null && maximum != null && minimum! > maximum!) {
      throw ArgumentError('minimum must not exceed maximum.');
    }
  }

  final int? minimum;
  final int? maximum;
}

/// An unconstrained string value, distinct from single-line display metadata.
final class StringSettingType extends SettingType<String> {
  const StringSettingType() : super._();
}

/// A stable string value with an optional single-line display label.
final class SettingEnumOption {
  SettingEnumOption(this.value, {this.label}) {
    _validatePresentation(value, 'value');
    if (value.trim() != value) {
      throw ArgumentError.value(value, 'value', 'Must be trimmed.');
    }
    if (label != null) _validatePresentation(label!, 'label');
  }

  final String value;
  final String? label;
}

/// A finite set of stable strings, not a distinct persistence scalar type.
final class EnumSettingType extends SettingType<String> {
  EnumSettingType(Iterable<SettingEnumOption> options)
    : options = List<SettingEnumOption>.unmodifiable(options),
      super._() {
    if (this.options.isEmpty) {
      throw ArgumentError.value(options, 'options', 'Must not be empty.');
    }
    final values = <String>{};
    for (final option in this.options) {
      if (!values.add(option.value)) {
        throw ArgumentError.value(
          option.value,
          'options',
          'Duplicate enum value.',
        );
      }
    }
  }

  final List<SettingEnumOption> options;
}

/// Immutable semantic declaration with a validated, non-null default.
final class SettingDefinition<T extends Object> {
  SettingDefinition({
    required this.id,
    required this.owner,
    required this.label,
    required this.category,
    required this.section,
    this.description,
    required this.type,
    required Object? defaultValue,
  }) : defaultValue = type._validate(id, defaultValue) {
    if (!id.value.startsWith('${owner.value}.')) {
      throw ArgumentError.value(id, 'id', 'Must be within owner $owner.');
    }
    _validatePresentation(label, 'label');
    _validatePresentation(category, 'category');
    _validatePresentation(section, 'section');
  }

  final SettingId id;
  final SettingOwnerId owner;
  final String label;
  final String category;
  final String section;

  /// Optional explanatory prose; unlike required display metadata, may span lines.
  final String? description;
  final SettingType<T> type;
  final T defaultValue;

  /// Returns the value unchanged or throws [InvalidSettingValue].
  T validate(Object? value) => type._validate(id, value);
}

/// Immutable declarations sorted by ID, with only default/global resolution.
final class SettingsCatalog {
  SettingsCatalog(Iterable<SettingDefinition<Object>> definitions)
    : definitions = List<SettingDefinition<Object>>.unmodifiable(
        List<SettingDefinition<Object>>.of(definitions)
          ..sort((a, b) => a.id.value.compareTo(b.id.value)),
      ) {
    for (final definition in this.definitions) {
      final previous = _byId[definition.id];
      if (previous != null) {
        throw DuplicateSettingId(
          definition.id,
          previous.owner,
          definition.owner,
        );
      }
      _byId[definition.id] = definition;
    }
  }

  final List<SettingDefinition<Object>> definitions;
  final Map<SettingId, SettingDefinition<Object>> _byId = {};

  /// Resolves declaration metadata by stable identity, independent of value type.
  SettingDefinition<Object> definition(SettingId id) {
    final result = _byId[id];
    if (result == null) throw SettingNotFound(id);
    return result;
  }

  /// Resolves one known setting. Unknown entries are ignored, not validated.
  ///
  /// Presence, including null, is explicit: an invalid known override throws
  /// [InvalidSettingOverride] rather than falling back to the default.
  ResolvedSetting<T> resolve<T extends Object>(
    SettingId id, {
    Map<SettingId, Object?> globalOverrides = const {},
  }) {
    final declared = definition(id);
    // A heterogeneous catalog can infer SettingDefinition<Object>. Its sealed
    // scalar type, not that contextual generic argument, owns the value type.
    if (declared.type is! SettingType<T>) {
      throw ArgumentError.value(
        id,
        'id',
        'Setting does not have value type $T.',
      );
    }
    final hasGlobalOverride = globalOverrides.containsKey(id);
    final T value;
    if (hasGlobalOverride) {
      try {
        value = declared.validate(globalOverrides[id]) as T;
      } on InvalidSettingValue catch (error) {
        throw InvalidSettingOverride(id, error.message);
      }
    } else {
      value = declared.defaultValue as T;
    }
    return ResolvedSetting._(
      id: id,
      value: value,
      source: hasGlobalOverride
          ? SettingValueSource.global
          : SettingValueSource.defaultValue,
      hasGlobalOverride: hasGlobalOverride,
    );
  }
}

enum SettingValueSource { defaultValue, global }

final class ResolvedSetting<T extends Object> {
  const ResolvedSetting._({
    required this.id,
    required this.value,
    required this.source,
    required this.hasGlobalOverride,
  });

  final SettingId id;
  final T value;
  final SettingValueSource source;

  /// Retains explicit override presence even when its value equals the default.
  final bool hasGlobalOverride;
}

final class InvalidSettingValue implements Exception {
  const InvalidSettingValue(this.id, this.message);

  final SettingId id;
  final String message;

  @override
  String toString() => 'InvalidSettingValue: $id: $message';
}

final class InvalidSettingOverride implements Exception {
  const InvalidSettingOverride(this.id, this.message);

  final SettingId id;
  final String message;

  @override
  String toString() => 'InvalidSettingOverride: $id: $message';
}

final class SettingNotFound implements Exception {
  const SettingNotFound(this.id);

  final SettingId id;

  @override
  String toString() => 'SettingNotFound: $id is not declared.';
}

final class DuplicateSettingId implements Exception {
  const DuplicateSettingId(this.id, this.firstOwner, this.secondOwner);

  final SettingId id;
  final SettingOwnerId firstOwner;
  final SettingOwnerId secondOwner;

  @override
  String toString() =>
      'DuplicateSettingId: $id is declared by $firstOwner and $secondOwner.';
}

void _validatePresentation(String value, String name) {
  if (value.trim().isEmpty ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      name,
      'Must be nonblank and contain no control characters or line breaks.',
    );
  }
}
