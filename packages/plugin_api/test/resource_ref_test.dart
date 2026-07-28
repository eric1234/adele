import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  test('ResourceRef preserves URI components and media type', () {
    final Uri uri = Uri.parse('git:///lib/main.dart?revision=abc123#selection');
    final ResourceRef resource = ResourceRef(
      uri: uri,
      mediaType: 'text/x-dart',
    );

    expect(resource.uri, same(uri));
    expect(resource.uri.query, 'revision=abc123');
    expect(resource.uri.fragment, 'selection');
    expect(resource.mediaType, 'text/x-dart');
  });
}
