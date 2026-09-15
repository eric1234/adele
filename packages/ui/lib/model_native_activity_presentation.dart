import 'dart:collection';

import 'package:adele_orchestration/adele_orchestration.dart'
    show ModelNativeOutput;
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';

/// Provider-approved presentation, not the opaque native output envelope.
/// Copies JSON-like data recursively; unsupported, cyclic and non-finite values
/// fail without printing their contents. Captured data outlives its presenter.
final class ModelNativeActivityProjection {
  ModelNativeActivityProjection({
    required this.compactText,
    required Map<String, Object?> data,
  }) : data =
           _freeze(data, HashSet<Object>.identity(), 0) as Map<String, Object?>;

  final String compactText;
  final Map<String, Object?> data;

  static Object? _freeze(Object? value, Set<Object> ancestors, int depth) {
    if (value == null || value is String || value is bool || value is int) {
      return value;
    }
    if (value is double && value.isFinite) return value;
    if (depth >= 64 || !ancestors.add(value)) {
      throw ArgumentError('Presentation data is cyclic or too deeply nested.');
    }
    try {
      if (value is List) {
        return List<Object?>.unmodifiable([
          for (final Object? item in value) _freeze(item, ancestors, depth + 1),
        ]);
      }
      if (value is Map) {
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          final Object? key = entry.key;
          if (key is! String) {
            throw ArgumentError('Presentation data requires string map keys.');
          }
          result[key] = _freeze(entry.value, ancestors, depth + 1);
        }
        return Map<String, Object?>.unmodifiable(result);
      }
      throw ArgumentError('Presentation data requires JSON-like values.');
    } finally {
      ancestors.remove(value);
    }
  }
}

final ExtensionPoint<ModelNativeActivityPresentationContribution>
modelNativeActivityPresentationContributions =
    ExtensionPoint<ModelNativeActivityPresentationContribution>(
      'dev.adele.extension.model-native-activity-presentations',
    );

/// Exactly one contribution may interpret an exact native kind. Its projector
/// may decline an individual output; multiple matches never run projectors.
final class ModelNativeActivityPresentationContribution {
  const ModelNativeActivityPresentationContribution({
    required this.nativeKind,
    required this.project,
    required this.createInspection,
  });

  final String nativeKind;
  final ModelNativeActivityProjection? Function(ModelNativeOutput) project;
  final Widget Function(ModelNativeActivityProjection) createInspection;
}

final class ResolvedModelNativeActivityPresentation {
  const ResolvedModelNativeActivityPresentation({
    required this.binding,
    required this.projection,
  });

  final ExtensionBinding<ModelNativeActivityPresentationContribution> binding;
  final ModelNativeActivityProjection projection;
}

final class ModelNativeActivityPresentationResolver {
  const ModelNativeActivityPresentationResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<ModelNativeActivityPresentationContribution> resolve(
    String nativeKind,
  ) {
    final matches = [
      for (final binding in _registry.discover(
        modelNativeActivityPresentationContributions,
      ))
        if (binding.value.nativeKind == nativeKind) binding,
    ];
    if (matches.isEmpty) {
      throw const ModelNativeActivityPresentationUnavailable();
    }
    if (matches.length > 1) {
      throw AmbiguousModelNativeActivityPresentation(
        matches.map((binding) => binding.id),
      );
    }
    return matches.single;
  }

  /// Returns no display for missing contributions or a declined output. Errors
  /// remain presentation-only, with no opaque payload or exception in diagnostics.
  ResolvedModelNativeActivityPresentation? project(ModelNativeOutput output) {
    final ExtensionBinding<ModelNativeActivityPresentationContribution> binding;
    try {
      binding = resolve(output.providerNativeMetadata.kind);
    } on ModelNativeActivityPresentationUnavailable {
      return null;
    }
    try {
      binding.validate();
      final projection = binding.value.project(output);
      binding.validate();
      return projection == null
          ? null
          : ResolvedModelNativeActivityPresentation(
              binding: binding,
              projection: projection,
            );
    } on Object {
      throw const ModelNativeActivityProjectionFailed();
    }
  }
}

final class ModelNativeActivityPresentationUnavailable implements Exception {
  const ModelNativeActivityPresentationUnavailable();

  @override
  String toString() => 'Model native activity presentation is unavailable.';
}

final class AmbiguousModelNativeActivityPresentation implements Exception {
  AmbiguousModelNativeActivityPresentation(Iterable<ExtensionId> extensionIds)
    : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'Model native activity presentation is ambiguous: multiple contributions '
      'match this native kind.';
}

final class ModelNativeActivityProjectionFailed implements Exception {
  const ModelNativeActivityProjectionFailed();

  @override
  String toString() => 'Model native activity could not be projected.';
}
