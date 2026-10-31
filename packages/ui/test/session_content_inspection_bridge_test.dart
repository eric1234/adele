import 'package:adele_ui/session_content_inspection_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native imports grant no Session content Inspection access', () {
    final Map<String, dynamic> Function() read =
        readSessionContentInspectionContext;
    expect(read, throwsUnsupportedError);
  });
}
