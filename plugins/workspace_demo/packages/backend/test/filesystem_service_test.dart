import 'dart:io';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_backend/workspace_demo_backend.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  late Directory root;
  late WorkspaceDemoFileService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adele-workspace-backend-');
    await Directory('${root.path}/beta').create();
    await Directory('${root.path}/Alpha').create();
    await File('${root.path}/zeta.txt').writeAsString('zeta');
    await File('${root.path}/Bravo.txt').writeAsString('hello');
    service = WorkspaceDemoFileService(root);
  });

  tearDown(() => root.delete(recursive: true));

  test('lists immediate children with deterministic ordering', () async {
    final DirectoryListing listing = await service.listDirectory(
      ResourceRef(uri: root.uri),
    );
    expect(listing.entries.map((DirectoryEntry entry) => entry.name), <String>[
      'Alpha',
      'beta',
      'Bravo.txt',
      'zeta.txt',
    ]);
    expect(listing.entries.first.kind, DirectoryEntryKind.directory);
    expect(listing.entries.last.kind, DirectoryEntryKind.file);
  });

  test('reads strict UTF-8 text', () async {
    final TextFileContents contents = await service.readTextFile(
      ResourceRef(uri: File('${root.path}/Bravo.txt').uri),
    );
    expect(contents.text, 'hello');
  });

  test('rejects invalid UTF-8', () async {
    final File binary = File('${root.path}/binary.txt');
    await binary.writeAsBytes(<int>[0xff, 0xfe]);
    await expectLater(
      service.readTextFile(ResourceRef(uri: binary.uri)),
      throwsA(
        isA<WorkspaceDemoFailure>().having(
          (WorkspaceDemoFailure error) => error.code,
          'code',
          'not_text',
        ),
      ),
    );
  });

  test('rejects wrong kinds, missing, and outside-root resources', () async {
    await expectLater(
      service.readTextFile(ResourceRef(uri: root.uri)),
      throwsA(_failureCode('not_a_file')),
    );
    await expectLater(
      service.listDirectory(
        ResourceRef(uri: File('${root.path}/Bravo.txt').uri),
      ),
      throwsA(_failureCode('not_a_directory')),
    );
    await expectLater(
      service.readTextFile(ResourceRef(uri: File('${root.path}/missing').uri)),
      throwsA(_failureCode('not_found')),
    );
    final File outside = await File(
      '${root.parent.path}/outside-${root.path.hashCode}.txt',
    ).writeAsString('outside');
    addTearDown(() => outside.delete());
    await expectLater(
      service.readTextFile(ResourceRef(uri: outside.uri)),
      throwsA(_failureCode('outside_development_root')),
    );
  });

  test('does not follow a symlink outside the development root', () async {
    if (Platform.isWindows) return;
    final File outside = await File(
      '${root.parent.path}/outside-link-${root.path.hashCode}.txt',
    ).writeAsString('outside');
    addTearDown(() => outside.delete());
    final Link link = Link('${root.path}/linked.txt');
    await link.create(outside.path);
    await expectLater(
      service.readTextFile(ResourceRef(uri: link.uri)),
      throwsA(_failureCode('outside_development_root')),
    );
  });
}

Matcher _failureCode(String code) => isA<WorkspaceDemoFailure>().having(
  (WorkspaceDemoFailure error) => error.code,
  'code',
  code,
);
