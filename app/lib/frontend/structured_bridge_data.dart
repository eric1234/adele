import 'dart:collection';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

/// Copies primitive data without reifying arbitrary eval instances. In particular,
/// recursive collection reification must not run before cycle validation.
Object? copyStructuredBridgeData(Object? value) {
  final visiting = HashSet<Object>.identity();
  int remaining = 100000;
  Object? copy(Object? value, int depth) {
    if (depth > 128 || --remaining < 0) {
      throw const FormatException('Structured bridge data is too large.');
    }
    value = switch (value) {
      $null() => null,
      $String() => value.$value,
      $bool() => value.$value,
      $int() => value.$value,
      $double() => value.$value,
      $Map() => value.$value,
      $List() => value.$value,
      _ => value,
    };
    if (value == null || value is String || value is bool || value is int) {
      return value;
    }
    if (value is double && value.isFinite) return value;
    if (value is! Map && value is! List) {
      throw const FormatException('Expected primitive structured bridge data.');
    }
    if (!visiting.add(value)) {
      throw const FormatException('Cyclic structured bridge data.');
    }
    try {
      if (value is List) {
        return List<Object?>.unmodifiable([
          for (final item in value) copy(item, depth + 1),
        ]);
      }
      final result = <String, Object?>{};
      for (final entry in (value as Map).entries) {
        final key = entry.key is $String
            ? (entry.key as $String).$value
            : entry.key;
        if (key is! String) {
          throw const FormatException('Structured map keys must be strings.');
        }
        result[key] = copy(entry.value, depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    } finally {
      visiting.remove(value);
    }
  }

  return copy(value, 0);
}

$Value wrapStructuredBridgeData(Object? value) {
  $Value wrap(Object? value) => switch (value) {
    null => const $null(),
    bool() => $bool(value),
    String() => $String(value),
    int() => $int(value),
    double() => $double(value),
    List<Object?>() => $List.wrap(List<$Value>.unmodifiable(value.map(wrap))),
    Map<String, Object?>() => $Map.wrap(
      Map<$Value, $Value>.unmodifiable(
        value.map((key, value) => MapEntry($String(key), wrap(value))),
      ),
    ),
    _ => throw const FormatException('Invalid structured bridge data.'),
  };
  return wrap(copyStructuredBridgeData(value));
}

const structuredBridgeMapType = BridgeTypeAnnotation(
  BridgeTypeRef(CoreTypes.map, [
    BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
    BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.object), nullable: true),
  ]),
);
