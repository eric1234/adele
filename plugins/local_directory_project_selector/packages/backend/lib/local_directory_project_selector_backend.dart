import 'dart:io';

import 'package:adele_core_extensions/adele_core_extensions.dart';

const String localDirectoryProjectProviderId =
    'dev.adele.project.local-directory';

/// Describes local backing placement without filesystem effects or schema work.
final class LocalDirectoryProjectProviderService
    implements ProjectProviderService {
  const LocalDirectoryProjectProviderService();

  @override
  Future<ProjectBacking> prepareSource(Uri sourceLocation) async {
    // Network authorities and UNC paths are deliberately unsupported: this
    // provider describes local storage, not network filesystem database access.
    if (sourceLocation.scheme != 'file' ||
        sourceLocation.authority.isNotEmpty ||
        sourceLocation.hasQuery ||
        sourceLocation.hasFragment ||
        !sourceLocation.path.startsWith('/') ||
        sourceLocation.path.startsWith('//')) {
      throw const FormatException(
        'Expected an absolute local file directory URI.',
      );
    }
    final segments = sourceLocation.pathSegments;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      if ((segment.isEmpty && index != segments.length - 1) ||
          segment == '.' ||
          segment == '..' ||
          RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(segment)) {
        throw const FormatException('Invalid local directory URI path.');
      }
    }
    final path = sourceLocation.toFilePath(windows: Platform.isWindows);
    if (Platform.isWindows && !RegExp(r'^[A-Za-z]:\\').hasMatch(path)) {
      throw const FormatException(
        'Expected an absolute local Windows drive path.',
      );
    }
    return ProjectBacking(
      sourceLocation: sourceLocation,
      databaseRelativePath: '.adele/data.db',
    );
  }
}
