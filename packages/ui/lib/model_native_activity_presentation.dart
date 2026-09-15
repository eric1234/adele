import 'package:adele_orchestration/adele_orchestration.dart'
    show ModelNativePresentation;
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';

final ExtensionPoint<ModelNativeActivityPresentationContribution>
modelNativeActivityPresentationContributions =
    ExtensionPoint<ModelNativeActivityPresentationContribution>(
      'dev.adele.extension.model-native-activity-presentations',
    );

/// Exactly one contribution may inspect an exact safe presentation kind.
/// Factories never receive raw provider-native evidence for classification.
final class ModelNativeActivityPresentationContribution {
  const ModelNativeActivityPresentationContribution({
    required this.presentationKind,
    required this.createInspection,
  });

  final String presentationKind;
  final Widget Function(ModelNativePresentation) createInspection;
}

final class ModelNativeActivityPresentationResolver {
  const ModelNativeActivityPresentationResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<ModelNativeActivityPresentationContribution> resolve(
    String presentationKind,
  ) {
    final matches = [
      for (final binding in _registry.discover(
        modelNativeActivityPresentationContributions,
      ))
        if (binding.value.presentationKind == presentationKind) binding,
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
      'match this presentation kind.';
}
