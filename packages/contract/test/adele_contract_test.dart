import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

void main() {
  test('remote failure preserves structured details', () {
    const AdeleRemoteFailure failure = AdeleRemoteFailure(
      code: 'denied',
      message: 'Denied.',
      details: <String, Object?>{'path': '/tmp/example'},
    );

    expect(failure.code, 'denied');
    expect(failure.details['path'], '/tmp/example');
    expect(failure.toString(), 'AdeleRemoteFailure(denied): Denied.');
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
