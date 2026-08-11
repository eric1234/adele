import 'dart:convert';
import 'dart:typed_data';

const int backendHostProtocolVersion = 2;
const int backendHostStreamWindow = 1;
const int maximumBackendHostFrameLength = 8 * 1024 * 1024;

final class BackendHostProtocolException implements Exception {
  const BackendHostProtocolException(this.message);

  final String message;

  @override
  String toString() => 'BackendHostProtocolException: $message';
}

Uint8List encodeBackendHostFrame(Map<String, Object?> message) {
  late final Uint8List payload;
  try {
    payload = utf8.encode(jsonEncode(message));
  } on Object catch (error) {
    throw BackendHostProtocolException(
      'Frame payload is not JSON serializable: $error',
    );
  }
  if (payload.length > maximumBackendHostFrameLength) {
    throw const BackendHostProtocolException('Frame is too large.');
  }
  final ByteData header = ByteData(4)..setUint32(0, payload.length, Endian.big);
  return Uint8List.fromList(<int>[...header.buffer.asUint8List(), ...payload]);
}

final class BackendHostFrameDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  List<Map<String, Object?>> add(List<int> bytes) {
    _buffer.add(bytes);
    final Uint8List available = _buffer.takeBytes();
    int offset = 0;
    final List<Map<String, Object?>> messages = <Map<String, Object?>>[];
    while (available.length - offset >= 4) {
      final int length = ByteData.sublistView(
        available,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      if (length > maximumBackendHostFrameLength) {
        throw BackendHostProtocolException(
          'Frame length $length is too large.',
        );
      }
      if (available.length - offset - 4 < length) break;
      final String encoded = utf8.decode(
        available.sublist(offset + 4, offset + 4 + length),
        allowMalformed: false,
      );
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw const BackendHostProtocolException(
          'Frame payload is not an object.',
        );
      }
      final Map<String, Object?> message = <String, Object?>{};
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        if (entry.key is! String) {
          throw const BackendHostProtocolException(
            'Frame key is not a string.',
          );
        }
        message[entry.key as String] = entry.value;
      }
      messages.add(message);
      offset += 4 + length;
    }
    if (offset < available.length) _buffer.add(available.sublist(offset));
    return messages;
  }
}
