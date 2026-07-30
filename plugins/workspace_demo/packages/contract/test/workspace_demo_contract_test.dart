import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test('preserves nested resource identity and immutable entries', () {
    final ResourceRef root = ResourceRef(uri: Uri.file('/demo'));
    final List<DirectoryEntry> source = <DirectoryEntry>[
      DirectoryEntry(
        resource: ResourceRef(
          uri: Uri.file('/demo/readme.txt'),
          mediaType: 'text/plain',
        ),
        name: 'readme.txt',
        kind: DirectoryEntryKind.file,
      ),
    ];
    final DirectoryListing listing = DirectoryListing(
      directory: root,
      entries: source,
    );
    source.clear();

    expect(listing.directory.uri, Uri.file('/demo'));
    expect(listing.entries.single.name, 'readme.txt');
    expect(listing.entries.single.resource.mediaType, 'text/plain');
    expect(() => listing.entries.clear(), throwsUnsupportedError);
  });
}
