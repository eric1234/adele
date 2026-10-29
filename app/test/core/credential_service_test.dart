import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:adele_credential_store/adele_credential_store.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _firstValue = 'test-only-first-credential-value';
const _secondValue = 'test-only-second-credential-value';
final _a = CredentialReference.parse('cred1_0123456789abcdef0123456789abcdef');
final _b = CredentialReference.parse('cred1_fedcba9876543210fedcba9876543210');

void main() {
  late _Storage storage;
  late CredentialService service;

  setUp(() {
    storage = _Storage();
    service = CredentialService(storage);
    addTearDown(service.close);
  });

  group('CredentialReference', () {
    test('generated references are unique and round-trip as opaque text', () {
      final references = List.generate(
        128,
        (_) => CredentialReference.generate(),
      );
      expect(references.toSet().length, references.length);
      for (final reference in references) {
        expect(reference.value, matches(r'^cred1_[0-9a-f]{32}$'));
        final serialized = jsonEncode({'credential': reference.value});
        final decoded = jsonDecode(serialized) as Map<String, dynamic>;
        final restored = CredentialReference.parse(
          decoded['credential'] as String,
        );
        expect(restored, reference);
        expect(restored.hashCode, reference.hashCode);
        expect(restored.toString(), reference.value);
        expect({reference, restored}, hasLength(1));
      }
      expect(_a, isNot(_b));
      expect(_a, isNot(_a.value));
      expect(storage.calls, isEmpty);
    });

    final invalid = <String, String>{
      'empty': '',
      'display name': 'Work account',
      'plugin identity': 'dev.example.provider',
      'record identity': 'work-provider',
      'relative path': '../credentials',
      'absolute path': '/tmp/credentials',
      'windows path': r'C:\credentials',
      'URI': 'file:///credentials',
      'path suffix': '${_a.value}/child',
      'path prefix': '../${_a.value}',
      'encoded separator': '${_a.value}%2fchild',
      'backslash': '${_a.value}\\child',
      'short': _a.value.substring(0, 37),
      'long': '${_a.value}0',
      'wrong version': _a.value.replaceFirst('cred1_', 'cred2_'),
      'uppercase prefix': _a.value.replaceFirst('cred1_', 'CRED1_'),
      'uppercase hex': _a.value.toUpperCase().replaceFirst('CRED1_', 'cred1_'),
      'nonhex': '${_a.value.substring(0, 37)}g',
      'wrong separator': _a.value.replaceFirst('_', '-'),
      'leading whitespace': ' ${_a.value}',
      'trailing whitespace': '${_a.value} ',
      'trailing newline': '${_a.value}\n',
      'embedded newline': '${_a.value.substring(0, 37)}\n',
      'NUL': '${_a.value.substring(0, 37)}\x00',
      'non-ASCII digit': '${_a.value.substring(0, 37)}\u0661',
    };
    for (final entry in invalid.entries) {
      test('rejects ${entry.key} without storage access', () async {
        await _expectFailure(
          () => service.store(
            CredentialReference.parse(entry.value),
            CredentialSecret(_firstValue),
          ),
          CredentialFailureKind.invalidReference,
          secret: _firstValue,
        );
        expect(storage.calls, isEmpty);
        expect(storage.values.isEmpty, isTrue);
      });
    }
  });

  group('CredentialSecret', () {
    test('host and native boundary share the portable byte bound', () {
      expect(CredentialSecret.maximumBytes, 2560);
      expect(NativeCredentialStore.maximumBytes, CredentialSecret.maximumBytes);
      expect(storage.calls, isEmpty);
    });
    test('reveals only deliberately and redacts nested diagnostics', () {
      final secret = CredentialSecret(_firstValue);
      _expectSecret(secret, _firstValue);
      final diagnostics = [
        secret.toString(),
        '$secret',
        [secret].toString(),
        {'credential': secret}.toString(),
      ];
      for (final diagnostic in diagnostics) {
        expect(
          diagnostic.contains(_firstValue),
          isFalse,
          reason: 'Secret leaked through diagnostics.',
        );
        expect(
          diagnostic.contains('[REDACTED]'),
          isTrue,
          reason: 'Secret diagnostic lacks redaction marker.',
        );
      }
      expect(storage.calls, isEmpty);
    });

    final valid = <String, String>{
      'whitespace remains opaque': ' \t\r\n ',
      'one ASCII byte': 'x',
      'ASCII just below limit': 'x' * 2559,
      'ASCII at limit': 'x' * 2560,
      'two-byte code points at limit': '\u00e9' * 1280,
      'three-byte code points at limit': '${'\u20ac' * 853}x',
      'surrogate pairs at limit': '\u{1f642}' * 640,
    };
    for (final entry in valid.entries) {
      test('accepts ${entry.key} without altering content', () async {
        expect(CredentialSecret.maximumBytes, 2560);
        final secret = CredentialSecret(entry.value);
        _expectSecret(secret, entry.value);
        await service.store(_a, secret);
        _expectStored(storage, _a, entry.value);
        _expectSecret(await service.read(_a), entry.value);
      });
    }

    for (final entry in _invalidSecrets().entries) {
      test('rejects ${entry.key} before store or replace', () async {
        storage.values[_b] = _firstValue;
        for (final replacing in [false, true]) {
          await _expectFailure(
            () => replacing
                ? service.replace(_b, CredentialSecret(entry.value))
                : service.store(_a, CredentialSecret(entry.value)),
            CredentialFailureKind.invalidSecret,
            secret: entry.value,
          );
          expect(storage.calls, isEmpty);
          expect(storage.values.containsKey(_a), isFalse);
          _expectStored(storage, _b, _firstValue);
        }
      });
    }
  });

  group('lifecycle', () {
    test(
      'independent associations survive renaming and reconstruction',
      () async {
        final records = [
          {'name': 'Shared name', 'credential': _a.value},
          {'name': 'Shared name', 'credential': _b.value},
        ];
        await service.store(_a, CredentialSecret(_firstValue));
        await service.store(_b, CredentialSecret(_secondValue));
        records.first['name'] = 'Renamed account';
        await service.replace(_a, CredentialSecret('replacement-credential'));
        _expectSecret(await service.read(_b), _secondValue);
        final serialized = jsonEncode(records);
        await service.close();

        final reopenedStorage = _Storage(values: storage.values);
        final reopened = CredentialService(reopenedStorage);
        addTearDown(reopened.close);
        expect(reopenedStorage.calls, isEmpty);
        final restored = (jsonDecode(serialized) as List<dynamic>)
            .map(
              (record) =>
                  CredentialReference.parse(record['credential'] as String),
            )
            .toList();
        expect(restored, [_a, _b]);
        expect(await reopened.contains(restored.first), isTrue);
        _expectSecret(
          await reopened.read(restored.first),
          'replacement-credential',
        );
        _expectSecret(await reopened.read(restored.last), _secondValue);
        await reopened.delete(restored.first);
        expect(await reopened.contains(restored.first), isFalse);
        expect(await reopened.read(restored.first) == null, isTrue);
        _expectSecret(await reopened.read(restored.last), _secondValue);
        expect(storage.values.keys, [_b]);
        expect(records.first['name'], 'Renamed account');
      },
    );

    test(
      'missing and present operations retain explicit preconditions',
      () async {
        expect(await service.contains(_a), isFalse);
        expect(await service.read(_a) == null, isTrue);
        await service.delete(_a);
        await _expectFailure(
          () => service.replace(_a, CredentialSecret(_firstValue)),
          CredentialFailureKind.missing,
          secret: _firstValue,
        );
        expect(storage.calls, [
          ('contains', _a),
          ('read', _a),
          ('contains', _a),
          ('contains', _a),
        ]);
        expect(storage.values.isEmpty, isTrue);
        await service.store(_a, CredentialSecret(_firstValue));
        storage.calls.clear();
        await _expectFailure(
          () => service.store(_a, CredentialSecret(_secondValue)),
          CredentialFailureKind.alreadyExists,
          secret: _secondValue,
        );
        expect(storage.calls, [('contains', _a)]);
        _expectStored(storage, _a, _firstValue);
        await service.replace(_a, CredentialSecret(_secondValue));
        _expectSecret(await service.read(_a), _secondValue);
        await service.delete(_a);
        storage.calls.clear();
        await service.delete(_a);
        expect(storage.calls, [('contains', _a)]);
        expect(storage.values.isEmpty, isTrue);
      },
    );

    test('reads and status are not cached', () async {
      expect(await service.contains(_a), isFalse);
      storage.values[_a] = _firstValue;
      expect(await service.contains(_a), isTrue);
      _expectSecret(await service.read(_a), _firstValue);
      storage.values[_a] = _secondValue;
      _expectSecret(await service.read(_a), _secondValue);
      storage.values.remove(_a);
      expect(await service.read(_a) == null, isTrue);
      expect(await service.contains(_a), isFalse);
    });
  });

  group('read and preflight failures', () {
    for (final operation in ['contains', 'read']) {
      for (final present in [false, true]) {
        for (final typed in [false, true]) {
          test('$operation failure, present=$present, typed=$typed', () async {
            if (present) storage.values[_a] = _firstValue;
            storage
                .actions(operation)
                .add(_Action(errorBefore: _storageError(typed)));
            await _expectFailure(
              () => operation == 'contains'
                  ? service.contains(_a)
                  : service.read(_a),
              typed
                  ? CredentialFailureKind.unavailable
                  : CredentialFailureKind.failed,
              secret: _firstValue,
            );
            expect(storage.calls, [(operation, _a)]);
            expect(storage.values.containsKey(_a), present);
            if (present) _expectStored(storage, _a, _firstValue);
            expect(await service.contains(_a), present);
            final read = await service.read(_a);
            if (present) {
              _expectSecret(read, _firstValue);
            } else {
              expect(read == null, isTrue);
            }
          });
        }
      }
    }

    for (final operation in ['store', 'replace', 'delete']) {
      for (final typed in [false, true]) {
        test(
          '$operation preflight failure prevents mutation, typed=$typed',
          () async {
            if (operation != 'store') storage.values[_a] = _firstValue;
            storage
                .actions('contains')
                .add(_Action(errorBefore: _storageError(typed)));
            await _expectFailure(
              () => _mutate(service, operation, _a),
              typed
                  ? CredentialFailureKind.unavailable
                  : CredentialFailureKind.failed,
              secret: _secondValue,
            );
            expect(storage.calls, [('contains', _a)]);
            if (operation == 'store') {
              expect(storage.values.isEmpty, isTrue);
            } else {
              _expectStored(storage, _a, _firstValue);
            }
            // No native mutation was invoked, so explicit reconciliation is unnecessary.
            await _mutate(service, operation, _a);
            if (operation == 'delete') {
              expect(storage.values.containsKey(_a), isFalse);
            } else {
              _expectStored(storage, _a, _secondValue);
            }
          },
        );
      }
    }

    for (final entry in _invalidSecrets().entries) {
      test('stored ${entry.key} is corrupt, not missing', () async {
        storage.values[_a] = entry.value;
        expect(await service.contains(_a), isTrue);
        await _expectFailure(
          () => service.read(_a),
          CredentialFailureKind.corruptData,
          secret: entry.value,
        );
        _expectStored(storage, _a, entry.value);
        expect(storage.calls, [('contains', _a), ('read', _a)]);
      });
    }
  });

  group('uncertain mutations', () {
    for (final operation in ['store', 'replace', 'delete']) {
      for (final fault in ['drop', 'throw before', 'throw after']) {
        test(
          '$operation $fault is not success or permission to retry',
          () async {
            if (operation != 'store') storage.values[_a] = _firstValue;
            storage.values[_b] = _firstValue;
            final nativeOperation = operation == 'delete' ? 'delete' : 'write';
            storage
                .actions(nativeOperation)
                .add(
                  _Action(
                    drop: fault == 'drop',
                    errorBefore: fault == 'throw before'
                        ? _storageError(false)
                        : null,
                    errorAfter: fault == 'throw after'
                        ? _storageError(false)
                        : null,
                  ),
                );
            await _expectFailure(
              () => _mutate(service, operation, _a),
              CredentialFailureKind.failed,
              uncertain: true,
              secret: _secondValue,
            );
            expect(storage.calls, [
              ('contains', _a),
              (nativeOperation, _a),
              if (fault == 'drop')
                (operation == 'delete' ? 'contains' : 'read', _a),
            ]);
            final changed = fault == 'throw after';
            if (operation == 'delete' && changed ||
                operation == 'store' && !changed) {
              expect(storage.values.containsKey(_a), isFalse);
            } else {
              _expectStored(storage, _a, changed ? _secondValue : _firstValue);
            }
            _expectStored(storage, _b, _firstValue);
            await _expectMutationsBlocked(service, storage);
            await service.replace(_b, CredentialSecret(_secondValue));
            _expectStored(storage, _b, _secondValue);
          },
        );
      }
    }

    for (final operation in ['store', 'replace']) {
      for (final corruption in [false, true]) {
        test(
          '$operation verifies written contents, corrupt=$corruption',
          () async {
            if (operation == 'replace') storage.values[_a] = _firstValue;
            storage
                .actions('write')
                .add(
                  _Action(
                    writtenValue: corruption ? 'corrupt\x00value' : _firstValue,
                  ),
                );
            await _expectFailure(
              () => _mutate(service, operation, _a),
              corruption
                  ? CredentialFailureKind.corruptData
                  : CredentialFailureKind.failed,
              uncertain: true,
              secret: _secondValue,
            );
            expect(storage.calls, [
              ('contains', _a),
              ('write', _a),
              ('read', _a),
            ]);
            await _expectMutationsBlocked(service, storage);
          },
        );
      }
    }

    for (final operation in ['store', 'replace', 'delete']) {
      for (final typed in [false, true]) {
        test(
          '$operation postverification failure is uncertain, typed=$typed',
          () async {
            if (operation != 'store') storage.values[_a] = _firstValue;
            final verification = operation == 'delete' ? 'contains' : 'read';
            if (operation == 'delete') {
              storage.actions('contains').add(const _Action());
            }
            storage
                .actions(verification)
                .add(_Action(errorBefore: _storageError(typed)));
            await _expectFailure(
              () => _mutate(service, operation, _a),
              typed
                  ? CredentialFailureKind.unavailable
                  : CredentialFailureKind.failed,
              uncertain: true,
              secret: _secondValue,
            );
            expect(storage.calls, [
              ('contains', _a),
              (operation == 'delete' ? 'delete' : 'write', _a),
              (verification, _a),
            ]);
            if (operation == 'delete') {
              expect(storage.values.containsKey(_a), isFalse);
            } else {
              _expectStored(storage, _a, _secondValue);
            }
            await _expectMutationsBlocked(service, storage);
          },
        );
      }
    }

    test(
      'present status and failed or corrupt reads cannot reconcile',
      () async {
        storage.actions('write').add(_Action(errorAfter: _storageError(false)));
        await _expectFailure(
          () => service.store(_a, CredentialSecret(_secondValue)),
          CredentialFailureKind.failed,
          uncertain: true,
          secret: _secondValue,
        );
        expect(await service.contains(_a), isTrue);
        await _expectMutationsBlocked(service, storage);
        for (final operation in ['contains', 'read']) {
          storage
              .actions(operation)
              .add(_Action(errorBefore: _storageError(true)));
          await _expectFailure(
            () => operation == 'contains'
                ? service.contains(_a)
                : service.read(_a),
            CredentialFailureKind.unavailable,
            secret: _secondValue,
          );
          await _expectMutationsBlocked(service, storage);
        }
        storage.values[_a] = 'corrupt\x00value';
        await _expectFailure(
          () => service.read(_a),
          CredentialFailureKind.corruptData,
          secret: 'corrupt\x00value',
        );
        await _expectMutationsBlocked(service, storage);
        storage.values[_a] = _secondValue;
        _expectSecret(await service.read(_a), _secondValue);
        await service.replace(_a, CredentialSecret(_firstValue));
        _expectStored(storage, _a, _firstValue);
        await service.delete(_a);
        expect(storage.values.isEmpty, isTrue);
      },
    );

    for (final reconciliation in [
      'read present',
      'read absent',
      'contains absent',
    ]) {
      test(
        'successful explicit $reconciliation permits mutation again',
        () async {
          storage.values[_a] = _firstValue;
          storage
              .actions('delete')
              .add(_Action(errorBefore: _storageError(false)));
          await _expectFailure(
            () => service.delete(_a),
            CredentialFailureKind.failed,
            uncertain: true,
            secret: _firstValue,
          );
          await _expectMutationsBlocked(service, storage);
          if (reconciliation == 'read present') {
            _expectSecret(await service.read(_a), _firstValue);
            await service.replace(_a, CredentialSecret(_secondValue));
          } else {
            storage.values.remove(_a);
            if (reconciliation == 'read absent') {
              expect(await service.read(_a) == null, isTrue);
            } else {
              expect(await service.contains(_a), isFalse);
            }
            await service.store(_a, CredentialSecret(_secondValue));
          }
          _expectStored(storage, _a, _secondValue);
        },
      );
    }
  });

  group('serialization and close', () {
    for (final operation in ['store', 'replace', 'delete']) {
      test('$operation cannot complete before postverification', () async {
        if (operation != 'store') storage.values[_a] = _firstValue;
        final gate = _Gate();
        final verification = operation == 'delete' ? 'contains' : 'read';
        if (operation == 'delete') {
          storage.actions('contains').add(const _Action());
        }
        storage.actions(verification).add(_Action(gate: gate));
        var completed = false;
        final mutation = _mutate(
          service,
          operation,
          _a,
        ).then((_) => completed = true);
        await gate.entered.future;
        expect(completed, isFalse);
        if (operation == 'delete') {
          expect(storage.values.containsKey(_a), isFalse);
        } else {
          _expectStored(storage, _a, _secondValue);
        }
        gate.release();
        await mutation;
        expect(completed, isTrue);
      });
    }

    test(
      'same-reference concurrent requests are FIFO despite precondition errors',
      () async {
        final gate = _Gate();
        storage.actions('contains').add(_Action(gate: gate));
        final equivalent = CredentialReference.parse(_a.value);
        final first = service.store(_a, CredentialSecret(_firstValue));
        final duplicate = _expectFailure(
          () => service.store(equivalent, CredentialSecret(_secondValue)),
          CredentialFailureKind.alreadyExists,
          secret: _secondValue,
        );
        final firstRead = service.read(equivalent);
        final replacement = service.replace(_a, CredentialSecret(_secondValue));
        final secondRead = service.read(equivalent);
        final deletion = service.delete(_a);
        final lastRead = service.read(equivalent);
        await gate.entered.future;
        expect(storage.calls, [('contains', _a)]);
        expect(storage.values.isEmpty, isTrue);
        gate.release();
        await first;
        await duplicate;
        _expectSecret(await firstRead, _firstValue);
        await replacement;
        _expectSecret(await secondRead, _secondValue);
        await deletion;
        expect(await lastRead == null, isTrue);
        expect(storage.calls, [
          ('contains', _a),
          ('write', _a),
          ('read', _a),
          ('contains', _a),
          ('read', _a),
          ('contains', _a),
          ('write', _a),
          ('read', _a),
          ('read', _a),
          ('contains', _a),
          ('delete', _a),
          ('contains', _a),
          ('read', _a),
        ]);
      },
    );

    test(
      'mutation errors do not poison queued reconciliation and later work',
      () async {
        final gate = _Gate();
        storage
            .actions('write')
            .add(_Action(gate: gate, errorAfter: _storageError(false)));
        final failed = _expectFailure(
          () => service.store(_a, CredentialSecret(_firstValue)),
          CredentialFailureKind.failed,
          uncertain: true,
          secret: _firstValue,
        );
        final blocked = _expectFailure(
          () => service.replace(_a, CredentialSecret(_secondValue)),
          CredentialFailureKind.verificationRequired,
          uncertain: true,
          secret: _secondValue,
        );
        final reconciliation = service.read(_a);
        final replacement = service.replace(_a, CredentialSecret(_secondValue));
        await gate.entered.future;
        expect(storage.calls, [('contains', _a), ('write', _a)]);
        gate.release();
        await failed;
        await blocked;
        _expectSecret(await reconciliation, _firstValue);
        await replacement;
        _expectStored(storage, _a, _secondValue);
        expect(storage.calls, [
          ('contains', _a),
          ('write', _a),
          ('read', _a),
          ('contains', _a),
          ('write', _a),
          ('read', _a),
        ]);
      },
    );

    test('construction and idempotent close do not access storage', () async {
      expect(storage.calls, isEmpty);
      final closing = service.close();
      expect(identical(service.close(), closing), isTrue);
      await _expectClosed(service);
      await closing;
      expect(identical(service.close(), closing), isTrue);
      await _expectClosed(service);
      expect(storage.calls, isEmpty);
      expect(storage.values.isEmpty, isTrue);
    });

    test(
      'close fences synchronously and drains all admitted gated operations',
      () async {
        final firstGate = _Gate();
        final verificationGate = _Gate();
        storage.actions('write').add(_Action(gate: firstGate));
        storage.actions('read').addAll([
          const _Action(),
          _Action(gate: verificationGate),
        ]);
        final first = service.store(_a, CredentialSecret(_firstValue));
        final second = service.replace(_a, CredentialSecret(_secondValue));
        await firstGate.entered.future;
        var closed = false;
        final closing = service.close();
        final observedClose = closing.then((_) => closed = true);
        expect(identical(service.close(), closing), isTrue);
        final before = List.of(storage.calls);
        await _expectClosed(service);
        expect(storage.calls, before);
        expect(closed, isFalse);
        firstGate.release();
        await verificationGate.entered.future;
        await first;
        expect(closed, isFalse);
        _expectStored(storage, _a, _secondValue);
        verificationGate.release();
        await second;
        await observedClose;
        expect(closed, isTrue);
        final drained = List.of(storage.calls);
        await _expectClosed(service);
        await service.close();
        expect(storage.calls, drained);
        expect(storage.calls, [
          ('contains', _a),
          ('write', _a),
          ('read', _a),
          ('contains', _a),
          ('write', _a),
          ('read', _a),
        ]);
      },
    );

    test(
      'close drains errors and remaining work without retry or cleanup I/O',
      () async {
        final gate = _Gate();
        storage
            .actions('write')
            .add(_Action(gate: gate, errorBefore: _storageError(false)));
        final failed = _expectFailure(
          () => service.store(_a, CredentialSecret(_firstValue)),
          CredentialFailureKind.failed,
          uncertain: true,
          secret: _firstValue,
        );
        final blocked = _expectFailure(
          () => service.delete(_a),
          CredentialFailureKind.verificationRequired,
          uncertain: true,
        );
        final remaining = service.store(_b, CredentialSecret(_secondValue));
        await gate.entered.future;
        final closing = service.close();
        await _expectClosed(service);
        gate.release();
        await failed;
        await blocked;
        await remaining;
        await closing;
        expect(storage.values.containsKey(_a), isFalse);
        _expectStored(storage, _b, _secondValue);
        expect(storage.calls, [
          ('contains', _a),
          ('write', _a),
          ('contains', _b),
          ('write', _b),
          ('read', _b),
        ]);
      },
    );
  });
}

Map<String, String> _invalidSecrets() => {
  'empty': '',
  'NUL only': '\x00',
  'embedded NUL': 'before\x00after',
  'trailing NUL': 'value\x00',
  'unpaired high surrogate': String.fromCharCode(0xd800),
  'unpaired low surrogate': String.fromCharCode(0xdc00),
  'high surrogate followed by ASCII': String.fromCharCodes([0xd800, 0x61]),
  'embedded low surrogate': String.fromCharCodes([0x61, 0xdfff, 0x62]),
  'reversed surrogate pair': String.fromCharCodes([0xdc00, 0xd800]),
  'two high surrogates': String.fromCharCodes([0xd800, 0xdbff]),
  'valid pair then unpaired surrogate': String.fromCharCodes([
    0xd83d,
    0xde42,
    0xd800,
  ]),
  'ASCII above limit': 'x' * 2561,
  'two-byte above limit': '${'\u00e9' * 1280}x',
  'three-byte above limit': '${'\u20ac' * 853}xx',
  'surrogate pairs above limit': '${'\u{1f642}' * 640}x',
};

void _expectSecret(CredentialSecret? actual, String expected) {
  expect(
    actual?.reveal() == expected,
    isTrue,
    reason: 'Retrieved secret differs.',
  );
}

void _expectStored(
  _Storage storage,
  CredentialReference reference,
  String expected,
) {
  expect(
    storage.values[reference] == expected,
    isTrue,
    reason: 'Stored secret differs.',
  );
}

// Capture first: a throwsA mismatch could otherwise print a raw adapter exception.
Future<void> _expectFailure(
  FutureOr<Object?> Function() operation,
  CredentialFailureKind kind, {
  bool uncertain = false,
  String? secret,
}) async {
  Object? caught;
  StackTrace? caughtStack;
  try {
    await operation();
  } on Object catch (error, stack) {
    caught = error;
    caughtStack = stack;
  }
  expect(caught != null, isTrue, reason: 'Expected operation failure.');
  final diagnostics = '$caught\n$caughtStack';
  if (secret != null && secret.isNotEmpty) {
    expect(
      diagnostics.contains(secret),
      isFalse,
      reason: 'Submitted secret leaked through error diagnostics.',
    );
  }
  expect(
    caught is CredentialFailure,
    isTrue,
    reason: 'Expected a typed safe failure.',
  );
  final failure = caught as CredentialFailure;
  expect(failure.kind, kind);
  expect(failure.outcomeUncertain, uncertain);
}

Future<void> _mutate(
  CredentialService service,
  String operation,
  CredentialReference reference,
) => switch (operation) {
  'store' => service.store(reference, CredentialSecret(_secondValue)),
  'replace' => service.replace(reference, CredentialSecret(_secondValue)),
  'delete' => service.delete(reference),
  _ => throw StateError('Unknown test operation.'),
};

Future<void> _expectMutationsBlocked(
  CredentialService service,
  _Storage storage,
) async {
  final before = List.of(storage.calls);
  for (final operation in ['store', 'replace', 'delete']) {
    await _expectFailure(
      () => _mutate(service, operation, CredentialReference.parse(_a.value)),
      CredentialFailureKind.verificationRequired,
      uncertain: true,
      secret: _secondValue,
    );
  }
  expect(storage.calls, before);
}

Future<void> _expectClosed(CredentialService service) async {
  await _expectFailure(
    () => service.contains(_a),
    CredentialFailureKind.closed,
  );
  await _expectFailure(() => service.read(_a), CredentialFailureKind.closed);
  for (final operation in ['store', 'replace', 'delete']) {
    await _expectFailure(
      () => _mutate(service, operation, _a),
      CredentialFailureKind.closed,
      secret: _secondValue,
    );
  }
}

Object _storageError(bool typed) => typed
    ? const CredentialFailure(CredentialFailureKind.unavailable)
    : StateError('Native diagnostic: $_firstValue / $_secondValue');

final class _Gate {
  _Gate() {
    addTearDown(release);
  }

  final entered = Completer<void>();
  final _released = Completer<void>();

  Future<void> wait() {
    entered.complete();
    return _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

final class _Action {
  const _Action({
    this.gate,
    this.errorBefore,
    this.errorAfter,
    this.drop = false,
    this.writtenValue,
  });

  final _Gate? gate;
  final Object? errorBefore;
  final Object? errorAfter;
  final bool drop;
  final String? writtenValue;

  void finish() {
    final error = errorAfter;
    if (error != null) throw error;
  }
}

final class _Storage implements CredentialStorageAdapter {
  _Storage({Map<CredentialReference, String>? values}) : values = values ?? {};

  final Map<CredentialReference, String> values;
  final calls = <(String, CredentialReference)>[];
  final _actions = <String, Queue<_Action>>{};

  Queue<_Action> actions(String operation) =>
      _actions.putIfAbsent(operation, Queue<_Action>.new);

  Future<_Action> _begin(
    String operation,
    CredentialReference reference,
  ) async {
    calls.add((operation, reference));
    final pending = actions(operation);
    final action = pending.isEmpty ? const _Action() : pending.removeFirst();
    await action.gate?.wait();
    final error = action.errorBefore;
    if (error != null) throw error;
    return action;
  }

  @override
  Future<bool> contains(CredentialReference reference) async {
    final action = await _begin('contains', reference);
    action.finish();
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    final action = await _begin('read', reference);
    action.finish();
    return values[reference];
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    final action = await _begin('write', reference);
    if (!action.drop) {
      values[reference] = action.writtenValue ?? secret.reveal();
    }
    action.finish();
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    final action = await _begin('delete', reference);
    if (!action.drop) values.remove(reference);
    action.finish();
  }
}
