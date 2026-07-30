import 'dart:typed_data';

import 'package:plugin_backend_host/plugin_backend_host.dart';
import 'package:test/test.dart';

void main() {
  test('decodes a frame split across partial reads', () {
    final Uint8List frame = encodeBackendHostFrame(<String, Object?>{
      'protocolVersion': 1,
      'kind': 'hostHello',
    });
    final BackendHostFrameDecoder decoder = BackendHostFrameDecoder();
    expect(decoder.add(frame.sublist(0, 2)), isEmpty);
    expect(decoder.add(frame.sublist(2, 7)), isEmpty);
    expect(decoder.add(frame.sublist(7)).single['kind'], 'hostHello');
  });

  test('decodes multiple frames from one read', () {
    final Uint8List first = encodeBackendHostFrame(<String, Object?>{
      'kind': 'one',
    });
    final Uint8List second = encodeBackendHostFrame(<String, Object?>{
      'kind': 'two',
    });
    final List<Map<String, Object?>> messages = BackendHostFrameDecoder().add(
      <int>[...first, ...second],
    );
    expect(messages.map((value) => value['kind']), <Object?>['one', 'two']);
  });

  test('rejects oversized frames', () {
    final ByteData header = ByteData(4)
      ..setUint32(0, maximumBackendHostFrameLength + 1, Endian.big);
    expect(
      () => BackendHostFrameDecoder().add(header.buffer.asUint8List()),
      throwsA(isA<BackendHostProtocolException>()),
    );
  });
}
