import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:test/test.dart';

void main() {
  test('CapabilityId has value equality and string behavior', () {
    const CapabilityId first = CapabilityId('dev.adele.edit-resource');
    const CapabilityId equal = CapabilityId('dev.adele.edit-resource');
    const CapabilityId different = CapabilityId('dev.adele.view-resource');

    expect(first, equal);
    expect(first.hashCode, equal.hashCode);
    expect(first, isNot(different));
    expect(first.toString(), 'dev.adele.edit-resource');
  });
}
