import 'dart:typed_data';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('handles partial and combined frames', () {
    final Uint8List first = encodeBackendHostFrame(<String, Object?>{
      'kind': 'one',
    });
    final Uint8List second = encodeBackendHostFrame(<String, Object?>{
      'kind': 'two',
    });
    final BackendHostFrameDecoder decoder = BackendHostFrameDecoder();
    expect(decoder.add(first.sublist(0, 3)), isEmpty);
    final List<Map<String, Object?>> messages = decoder.add(<int>[
      ...first.sublist(3),
      ...second,
    ]);
    expect(messages.map((value) => value['kind']), <Object?>['one', 'two']);
  });

  test('rejects malformed JSON', () {
    final ByteData header = ByteData(4)..setUint32(0, 1, Endian.big);
    expect(
      () => BackendHostFrameDecoder().add(<int>[
        ...header.buffer.asUint8List(),
        0xff,
      ]),
      throwsA(anything),
    );
  });
}
