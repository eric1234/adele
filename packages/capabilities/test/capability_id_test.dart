import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:test/test.dart';

void main() {
  test('CapabilityId has value equality and string behavior', () {
    final CapabilityId first = CapabilityId('dev.adele.edit-resource');
    final CapabilityId equal = CapabilityId('dev.adele.edit-resource');
    final CapabilityId different = CapabilityId('dev.adele.view-resource');

    expect(first, equal);
    expect(first.hashCode, equal.hashCode);
    expect(first, isNot(different));
    expect(first.toString(), 'dev.adele.edit-resource');
  });

  test('CapabilityId rejects identifiers outside the public grammar', () {
    for (final String value in <String>[
      '',
      'single',
      '.dev.adele',
      'dev..adele',
      'dev.adele.',
      'dev.adele bad',
      'dev.adele_bad',
      'dev.adele.-bad',
      'dev.adele.bad-',
      'dev.adèle.bad',
      'Dev.adele.bad',
    ]) {
      expect(
        () => CapabilityId(value),
        throwsA(isA<InvalidCapabilityIdentity>()),
        reason: value,
      );
    }
  });
}
