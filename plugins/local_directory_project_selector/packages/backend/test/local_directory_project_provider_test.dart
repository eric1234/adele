import 'dart:io';

import 'package:local_directory_project_selector_backend/local_directory_project_selector_backend.dart';
import 'package:test/test.dart';

void main() {
  const provider = LocalDirectoryProjectProviderService();

  test('provider identity is independent from the installation identity', () {
    expect(
      localDirectoryProjectProviderId,
      'dev.adele.project.local-directory',
    );
  });

  test(
    'describes placement without requiring or creating a directory',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'project provider ',
      );
      addTearDown(() => temporary.delete(recursive: true));
      for (final source in [
        temporary.uri,
        temporary.uri.resolve('missing%20project/'),
      ]) {
        final result = await provider.prepareSource(source);
        expect(result.sourceLocation, source);
        expect(result.databaseRelativePath, '.adele/data.db');
        expect(await temporary.list().toList(), isEmpty);
      }
    },
  );

  test(
    'accepts native absolute paths including escaped filename characters',
    () async {
      for (final path
          in Platform.isWindows
              ? [
                  r'C:\',
                  r'C:\Projects\one #two%',
                  'D:\\Projects\\Unicode-\u00e9',
                ]
              : ['/', '/projects/one #two%', '/projects/Unicode-\u00e9']) {
        final location = Uri.directory(path, windows: Platform.isWindows);
        expect(
          (await provider.prepareSource(location)).sourceLocation,
          location,
        );
      }
    },
  );

  test(
    'does not reinterpret a local file URI as a remote authority or UNC',
    () async {
      for (final location in [
        Uri.parse('file://server/share/project/'),
        Uri.parse('file://localhost/project/'),
        Uri.directory(r'\\server\share\project', windows: true),
        Uri.parse('file:////server/share/project/'),
        Uri.parse('file:///project/%5C%5Cserver/'),
      ]) {
        await expectLater(
          provider.prepareSource(location),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects unsupported and invalid source URIs', () async {
    for (final value in [
      'https://example.com/project/',
      'ssh://example.com/project/',
      'catalog:project/one',
      '/project/',
      'relative/project/',
      'file:///',
      'file:///project/?query',
      'file:///project/?',
      'file:///project/#fragment',
      'file:///project/#',
      'file:///project/%00/',
      'file:///project/%0A/',
      'file:///project/%2Fescape/',
      'file:///project/%5Cescape/',
      'file:///project/%FF/',
      'file:///project//nested/',
      if (Platform.isWindows) ...[
        'file:///project/',
        'file:///C:relative/',
        'file:///C:/invalid%3Fname/',
      ],
    ]) {
      // The POSIX filesystem root is itself a valid absolute local directory.
      if (value == 'file:///' && !Platform.isWindows) continue;
      await expectLater(
        provider.prepareSource(Uri.parse(value)),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
