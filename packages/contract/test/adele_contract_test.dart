import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

void main() {
  test('remote failure preserves structured details', () {
    const AdeleRemoteFailure failure = _Failure(
      code: 'denied',
      message: 'Denied.',
      details: <String, Object?>{'path': '/tmp/example'},
    );

    expect(failure.code, 'denied');
    expect(failure.details['path'], '/tmp/example');
    expect(failure.toString(), '_Failure(denied): Denied.');
  });

  test('protocol exception implements FormatException', () {
    const AdeleProtocolException error = AdeleProtocolException(
      'Malformed value.',
      'source',
      2,
    );

    expect(error, isA<FormatException>());
    expect(error.source, 'source');
    expect(error.offset, 2);
  });
}

final class _Failure implements AdeleRemoteFailure {
  const _Failure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  @override
  final String code;
  @override
  final String message;
  @override
  final Map<String, Object?> details;
  @override
  String? get declaredFailureType => null;

  @override
  String toString() => '_Failure($code): $message';
}
