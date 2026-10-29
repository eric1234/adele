import 'package:adele_credential_store/credential_reference.dart';
import 'package:test/test.dart';

void main() {
  const value = 'cred1_0123456789abcdef0123456789abcdef';

  test('pure identity roundtrips with value equality and hashing', () {
    final reference = CredentialReference.parse(value);
    final same = CredentialReference.parse(value);
    expect(reference.value, value);
    expect(reference.toString(), value);
    expect(reference, same);
    expect(reference.hashCode, same.hashCode);
    expect({reference, same}, hasLength(1));
    expect(reference, isNot(CredentialReference.parse('cred1_${'0' * 32}')));
    expect(reference, isNot(value));
  });

  test('secure generation yields independent exact-format identities', () {
    final references = {
      for (var index = 0; index < 100; index++) CredentialReference.generate(),
    };
    expect(references, hasLength(100));
    for (final reference in references) {
      expect(reference.value, matches(r'^cred1_[0-9a-f]{32}$'));
      expect(reference.value.length, 38);
      expect(CredentialReference.parse(reference.value), reference);
    }
  });

  test('invalid input is rejected without retaining diagnostic payload', () {
    for (final invalid in [
      '',
      'secret-canary-do-not-retain',
      '../private',
      '$value\n',
      ' $value',
      '${value}a',
      value.substring(1),
      value.toUpperCase(),
      'cred2_${'0' * 32}',
      'cred1_${'0' * 31}g',
      'cred1_${'0' * 31}\x00',
      'cred1_${'0' * 31}\u00e9',
      'cred1_${'0' * 31}\n',
      String.fromCharCode(0xd800),
    ]) {
      expect(
        () => CredentialReference.parse(invalid),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.message,
                'message',
                'Invalid credential reference.',
              )
              .having((error) => error.source, 'source', isNull)
              .having((error) => error.offset, 'offset', isNull)
              .having(
                (error) => error.toString(),
                'diagnostic',
                'FormatException: Invalid credential reference.',
              ),
        ),
      );
    }
  });
}
