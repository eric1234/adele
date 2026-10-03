import 'package:adele_plugin_api/adele_plugin_api.dart';

/// Displays an existing source file through an explicitly resolved UI provider.
/// Zero providers are unavailable and multiple providers require selection.
final ExtensionPoint<DisplaySourceFileContribution>
displaySourceFileContributions = ExtensionPoint<DisplaySourceFileContribution>(
  'dev.adele.extension.display-source-file',
);

final class DisplaySourceFileContribution {
  const DisplaySourceFileContribution({required this.display});

  /// The host adapter captures its current approved Session attachment before
  /// asynchronous work. The caller supplies no Environment or Session authority.
  final Future<Map<String, Object?>> Function(String relativePath) display;
}

final class DisplaySourceFileResolver {
  const DisplaySourceFileResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<DisplaySourceFileContribution> resolve({
    ExtensionId? select,
  }) {
    final matches = _registry
        .discover(displaySourceFileContributions)
        .where((binding) => select == null || binding.id == select)
        .toList();
    if (matches.isEmpty) throw DisplaySourceFileUnavailable(select: select);
    if (matches.length > 1) {
      throw AmbiguousDisplaySourceFile(matches.map((binding) => binding.id));
    }
    return matches.single;
  }

  /// Captures one exact registration for this call. Retirement rejects its result
  /// without retrying against a replacement; it does not cancel admitted work.
  Future<Map<String, Object?>> display(
    String relativePath, {
    ExtensionId? select,
  }) async {
    final binding = resolve(select: select);
    final result = await binding.value.display(relativePath);
    binding.validate();
    return result;
  }
}

final class DisplaySourceFileUnavailable implements Exception {
  const DisplaySourceFileUnavailable({this.select});

  final ExtensionId? select;

  @override
  String toString() => select == null
      ? 'DisplaySourceFileUnavailable: No source file display is available.'
      : 'DisplaySourceFileUnavailable: Source file display $select is unavailable.';
}

final class AmbiguousDisplaySourceFile implements Exception {
  AmbiguousDisplaySourceFile(Iterable<ExtensionId> extensionIds)
    : extensionIds = List.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'AmbiguousDisplaySourceFile: Multiple source file displays: '
      '${extensionIds.join(', ')}.';
}
