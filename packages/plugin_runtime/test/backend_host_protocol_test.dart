import 'dart:convert';
import 'dart:typed_data';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('encoding failures do not stringify secret-bearing native errors', () {
    expect(
      () => encodeBackendHostFrame({'payload': _PrivateValue()}),
      throwsA(
        isA<BackendHostProtocolException>().having(
          (error) => error.toString(),
          'fixed diagnostic',
          'BackendHostProtocolException: Frame payload is not JSON serializable.',
        ),
      ),
    );
  });

  test(
    'decoding failures never retain or print malformed credential frames',
    () {
      for (final body in <List<int>>[
        utf8.encode('{"secret":"private-secret","broken":}'),
        [...utf8.encode('{"secret":"private-secret"}'), 0xff],
      ]) {
        final header = ByteData(4)..setUint32(0, body.length, Endian.big);
        expect(
          () => BackendHostFrameDecoder().add([
            ...header.buffer.asUint8List(),
            ...body,
          ]),
          throwsA(
            isA<BackendHostProtocolException>().having(
              (error) => error.toString(),
              'fixed diagnostic',
              'BackendHostProtocolException: Frame payload is not valid JSON.',
            ),
          ),
        );
      }
    },
  );

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

  test('wraps frame serialization failures', () {
    expect(
      () => encodeBackendHostFrame(<String, Object?>{'bad': Object()}),
      throwsA(
        isA<BackendHostProtocolException>().having(
          (BackendHostProtocolException error) => error.message,
          'message',
          contains('not JSON serializable'),
        ),
      ),
    );
  });

  test('wraps non-finite payload values as protocol failures', () {
    expect(
      () => encodeBackendHostFrame(<String, Object?>{'value': double.nan}),
      throwsA(isA<BackendHostProtocolException>()),
    );
  });

  test('preserves the frame size limit failure', () {
    expect(
      () => encodeBackendHostFrame(<String, Object?>{
        'value': 'x' * maximumBackendHostFrameLength,
      }),
      throwsA(
        isA<BackendHostProtocolException>().having(
          (BackendHostProtocolException value) => value.message,
          'message',
          'Frame is too large.',
        ),
      ),
    );
  });
}

final class _PrivateValue {
  Object toJson() => throw StateError('private-native-error');

  @override
  String toString() => 'private-secret';
}
