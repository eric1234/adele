/// Provisional read-only development-source capability and transport contract.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'development_source_contract.g.dart';

final capabilities.CapabilityKey developmentSourceCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.source.development'),
      majorVersion: 1,
    );

@AdeleValue('developmentSource.textFile')
final class DevelopmentSourceTextFile {
  const DevelopmentSourceTextFile({
    required this.relativePath,
    required this.text,
    required this.sizeBytes,
  });

  final String relativePath;
  final String text;
  final int sizeBytes;
}

@AdeleValue('developmentSource.searchMatch')
final class DevelopmentSourceSearchMatch {
  const DevelopmentSourceSearchMatch({
    required this.relativePath,
    required this.lineNumber,
    required this.snippet,
  });

  final String relativePath;
  final int lineNumber;
  final String snippet;
}

@AdeleValue('developmentSource.searchResult')
final class DevelopmentSourceSearchResult {
  const DevelopmentSourceSearchResult({
    required this.matches,
    required this.truncated,
  });

  final List<DevelopmentSourceSearchMatch> matches;
  final bool truncated;
}

@AdeleService('developmentSource')
abstract interface class DevelopmentSourceService {
  @AdeleMethod('readTextFile')
  Future<DevelopmentSourceTextFile> readTextFile(String relativePath);

  @AdeleMethod('searchText')
  Future<DevelopmentSourceSearchResult> searchText(String literalText);
}

@AdeleFailure('developmentSource.failure')
final class DevelopmentSourceFailure implements Exception {
  const DevelopmentSourceFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'DevelopmentSourceFailure($code): $message';
}
