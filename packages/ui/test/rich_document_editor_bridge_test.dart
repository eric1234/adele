import 'package:adele_ui/rich_document_editor_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native imports provide no interpreted rich document access', () {
    expect(
      () => createRichDocumentEditor('text', false),
      throwsUnsupportedError,
    );
    expect(() => buildRichDocumentEditor('fake'), throwsUnsupportedError);
    expect(() => snapshotRichDocumentEditor('fake'), throwsUnsupportedError);
    expect(
      () => setRichDocumentEditorEditingEnabled('fake', true),
      throwsUnsupportedError,
    );
    expect(
      () => subscribeRichDocumentEditor('fake', () {}),
      throwsUnsupportedError,
    );
    expect(
      () => unsubscribeRichDocumentEditor('fake', () {}),
      throwsUnsupportedError,
    );
    expect(() => releaseRichDocumentEditor('fake'), throwsUnsupportedError);
  });
}
