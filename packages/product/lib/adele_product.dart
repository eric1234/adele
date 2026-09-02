/// Canonical ADELE product-domain values and identities.
library;

import 'dart:collection';

import 'package:adele_capabilities/adele_capabilities.dart';

final class ProjectId {
  ProjectId(String value) : value = _requireId(value, 'Project ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProjectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class TaskId {
  TaskId(String value) : value = _requireId(value, 'Task ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TaskId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class EnvironmentId {
  EnvironmentId(String value) : value = _requireId(value, 'Environment ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is EnvironmentId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class SessionId {
  SessionId(String value) : value = _requireId(value, 'Session ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class Project {
  Project({required this.id, required this.sourceLocation}) {
    if (!sourceLocation.hasScheme) {
      throw ArgumentError.value(
        sourceLocation,
        'sourceLocation',
        'Project source locations must be absolute URIs.',
      );
    }
  }

  final ProjectId id;
  final Uri sourceLocation;
}

final class Task {
  Task({required this.id, required this.projectId, required this.title}) {
    if (title.trim().isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Task title must not be blank.',
      );
    }
  }

  final TaskId id;
  final ProjectId projectId;
  final String title;
}

enum EnvironmentRole { primary, additional }

final class Environment {
  Environment({
    required this.id,
    required this.taskId,
    required this.role,
    required this.providerId,
    required Map<String, Object?>? providerState,
  }) : providerState = providerState == null
           ? null
           : _snapshotJsonMap(providerState);

  final EnvironmentId id;
  final TaskId taskId;
  final EnvironmentRole role;
  final ProviderId providerId;

  /// Provider-owned structured state retained opaquely by core.
  final Map<String, Object?>? providerState;
}

String _requireId(String value, String label) {
  if (value.isEmpty || value.trim() != value) {
    throw FormatException('$label must be non-empty and have no outer space.');
  }
  return value;
}

Map<String, Object?> _snapshotJsonMap(Map<String, Object?> source) =>
    _snapshotJsonValue(source, 0, HashSet<Object>.identity())!
        as Map<String, Object?>;

Object? _snapshotJsonValue(Object? value, int depth, Set<Object> active) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Provider-state doubles must be finite.');
    }
    return value;
  }
  if (depth >= 64) {
    throw const FormatException('Provider state exceeds maximum depth 64.');
  }
  if (value is List<Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Provider state must not contain cycles.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map(
          (Object? item) => _snapshotJsonValue(item, depth + 1, active),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Provider state must not contain cycles.');
    }
    try {
      return Map<String, Object?>.unmodifiable(
        value.map(
          (String key, Object? item) => MapEntry<String, Object?>(
            key,
            _snapshotJsonValue(item, depth + 1, active),
          ),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  throw FormatException(
    'Unsupported provider-state value: ${value.runtimeType}.',
  );
}
