import 'package:adele_orchestration/adele_orchestration.dart'
    show ModelNativePresentation;
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';

final ExtensionPoint<ModelNativeActivityCompactPresentationContribution>
modelNativeActivityCompactPresentationContributions =
    ExtensionPoint<ModelNativeActivityCompactPresentationContribution>(
      'dev.adele.extension.model-native-activity-compact-presentations',
    );

/// A separate compact role receiving only safe presentation, never raw evidence.
final class ModelNativeActivityCompactPresentationContribution {
  const ModelNativeActivityCompactPresentationContribution({
    required this.presentationKind,
    required this.createPresentation,
  });

  final String presentationKind;
  final Widget Function(ModelNativePresentation) createPresentation;
}

final class ModelNativeActivityCompactPresentationResolver {
  const ModelNativeActivityCompactPresentationResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<ModelNativeActivityCompactPresentationContribution> resolve(
    String presentationKind,
  ) {
    final matches = [
      for (final binding in _registry.discover(
        modelNativeActivityCompactPresentationContributions,
      ))
        if (binding.value.presentationKind == presentationKind) binding,
    ];
    if (matches.isEmpty) {
      throw const ModelNativeActivityCompactPresentationUnavailable();
    }
    if (matches.length > 1) {
      throw AmbiguousModelNativeActivityCompactPresentation(
        matches.map((binding) => binding.id),
      );
    }
    return matches.single;
  }
}

final class ModelNativeActivityCompactPresentationUnavailable
    implements Exception {
  const ModelNativeActivityCompactPresentationUnavailable();

  @override
  String toString() =>
      'Model native activity compact presentation is unavailable.';
}

final class AmbiguousModelNativeActivityCompactPresentation
    implements Exception {
  AmbiguousModelNativeActivityCompactPresentation(
    Iterable<ExtensionId> extensionIds,
  ) : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'Model native activity compact presentation is ambiguous.';
}
