import 'package:adele_ui/directory_picker_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native imports do not provide interpreted directory picker authority',
    () {
      expect(pickDirectory, throwsUnsupportedError);
    },
  );
}
