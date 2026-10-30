import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _collection = RecordCollectionId('jobs');
final _single = RecordTypeId('dev.example.credentials.single');
final _multiple = RecordTypeId('dev.example.credentials.multiple');
final _plain = RecordTypeId('dev.example.credentials.plain');
final _token = RecordCredentialSlotId('token');
final _transferred = CredentialReference.parse(
  'cred1_0123456789abcdef0123456789abcdef',
);
const _firstSecret = 'test-only-first-credential';
const _secondSecret = 'test-only-second-credential';
const _replacement = 'test-only-replacement-credential';
const _nativeDiagnostic = 'test-only-private-native-diagnostic';
const _unchecked = 'Credential status not checked';
const _noReference = 'No credential configured';
const _missing = 'Credential missing on this machine';
const _stored = 'Credential stored locally';
const _unavailable = 'Secure storage unavailable or locked';
const _invalid = 'Stored credential or binding invalid';
const _failed = 'Could not determine credential status';
const _uncertain = 'Previous operation needs reconciliation';

void main() {
  late Directory temporary;
  late PlatformStorageRoots roots;
  late GlobalSettingsService settings;
  late _Storage storage;
  late CredentialService credentials;
  late RecordCredentialService coordinator;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('adele-credential-dialog-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    settings = GlobalSettingsService(
      catalog: SettingsCatalog([]),
      records: _catalog(),
      roots: roots,
    );
    storage = _Storage();
    credentials = CredentialService(storage);
    coordinator = RecordCredentialService(
      settings: settings,
      credentials: credentials,
    );
  });

  tearDown(() async {
    await coordinator.close();
    await settings.close();
    await credentials.close();
    temporary.deleteSync(recursive: true);
  });

  // Real workers and native TOML need runAsync; no test constructs a native vault.
  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(
      name,
      (tester) => tester.runAsync(() async {
        try {
          await body(tester);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      }),
      skip: !Platform.isLinux,
    );
  }

  File file(String id) => File('${roots.configurationRoot}/jobs/$id.toml');

  CredentialReference? reference(String id, [String slot = 'token']) {
    final document = ConfigurationStore(roots)
        .recordFile(collectionId: 'jobs', recordId: id)
        .load()
        .document
        .ensureTable(['credentials']); // Snapshot-only, never persisted.
    if (!document.tableKeys(['credentials']).contains(slot)) {
      return null;
    }
    return CredentialReference.parse(
      document.readScalar(['credentials', slot]) as String,
    );
  }

  Future<RecordView> seed(
    String id, {
    RecordTypeId? type,
    String? secret,
    bool transferred = false,
  }) async {
    var record = await settings.createRecord(
      type ?? _single,
      ConfigurationRecordId(id),
      {'caption': 'Title $id'},
    );
    if (secret != null) {
      record = (await coordinator.attach(
        record,
        _token,
        CredentialSecret(secret),
      )).record;
    }
    if (transferred) {
      file(id).writeAsStringSync(
        '${file(id).readAsStringSync()}\n[credentials]\n'
        'token = "${_transferred.value}"\n',
      );
    }
    return record;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GlobalSettingsDialog(
                  service: () async => settings,
                  credentialAssociations: () => coordinator,
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    await _until(tester, () => _enabled(tester, _key('settings-reload')));
    await _section(tester, 'Jobs');
    await _loaded(tester);
  }

  Future<void> submit(
    WidgetTester tester,
    String id,
    String action, {
    String slot = 'token',
    String secret = _firstSecret,
  }) async {
    await _tap(tester, _action(action, id, slot));
    final field = tester.widget<TextField>(_action('input', id, slot));
    expect(field.obscureText, isTrue);
    expect(field.controller!.text, isEmpty);
    await _enter(tester, _action('input', id, slot), secret);
    await _tap(tester, _action('submit', id, slot));
    await _loaded(tester);
    expect(_action('input', id, slot), findsNothing);
    expect(field.controller!.text, isEmpty);
    _expectRedacted(tester, file(id));
  }

  Future<void> check(
    WidgetTester tester,
    String id, [
    String slot = 'token',
  ]) async {
    await _tap(tester, _action('check', id, slot));
    await _loaded(tester);
  }

  Future<void> forget(WidgetTester tester, String id) async {
    await _tap(tester, _action('forget', id));
    expect(find.text('Forget credential?'), findsOneWidget);
    await _tap(tester, _action('forget-confirm', id));
    await _loaded(tester);
  }

  scenario(
    'declarations render zero, one and multiple slots without vault reads',
    (tester) async {
      await seed('plain', type: _plain);
      await seed('single', secret: _firstSecret);
      await seed('multiple', type: _multiple);
      storage.calls.clear();
      await mount(tester);
      expect(storage.calls, isEmpty);
      for (final id in ['plain', 'single', 'multiple']) {
        await _expand(tester, id);
      }
      expect(_slot('plain'), findsNothing);
      expect(_slot('single'), findsOneWidget);
      expect(_slot('single', 'backup'), findsNothing);
      expect(_slot('multiple'), findsOneWidget);
      expect(_slot('multiple', 'backup'), findsOneWidget);
      expect(find.text('Access token'), findsNWidgets(2));
      expect(find.text('Recovery passphrase'), findsOneWidget);
      expect(find.text('Secret text'), findsNWidgets(3));
      expect(find.text(_unchecked), findsNWidgets(3));
      for (final id in ['single', 'multiple']) {
        _expectActions(id, const ['check']);
        await _tap(tester, _key('record-edit-jobs-$id'));
        expect(_editInput(id), findsOneWidget);
        expect(_key('record-input-jobs-$id-token'), findsNothing);
        expect(_key('record-presence-jobs-$id-token'), findsNothing);
      }
      expect(storage.calls, isEmpty);
      await check(tester, 'multiple');
      _expectStatus('multiple', _noReference);
      _expectActions('multiple', const ['check', 'set']);
      expect(storage.calls, isEmpty);
      await check(tester, 'single');
      _expectStatus('single', _stored);
      _expectActions('single', const ['check', 'replace', 'forget']);
      expect(storage.calls, [('read', reference('single')!)]);
      _expectRedacted(tester, file('single'));
    },
  );

  scenario('fresh creation handle can attach before any collection Reload', (
    tester,
  ) async {
    await mount(tester);
    await _tap(tester, _key('records-add-jobs'));
    await _choose(tester, _key('record-type-jobs'), 'Single credential');
    await _enter(tester, _key('record-id-jobs'), 'created');
    await _tap(tester, _key('record-presence-jobs-caption'));
    await _enter(tester, _key('record-input-jobs-caption'), 'New account');
    expect(_slot('created'), findsNothing);
    await _tap(tester, _key('record-create-jobs'));
    await _loaded(tester);
    await _expand(tester, 'created');
    _expectStatus('created', _unchecked);
    expect(storage.calls, isEmpty);
    await check(tester, 'created');
    await submit(tester, 'created', 'set');
    _expectStatus('created', _stored);
    final ref = reference('created')!;
    _expectSecret(storage, ref, _firstSecret);
    expect(file('created').readAsStringSync(), contains('New account'));
    await _tap(tester, _key('record-edit-jobs-created'));
    await _enter(tester, _editInput('created'), 'Renamed account');
    await _tap(tester, _key('record-save-jobs-created'));
    await _loaded(tester);
    _expectStatus('created', _unchecked);
    expect(reference('created'), ref);
    expect(file('created').readAsStringSync(), contains('Renamed account'));
  });

  scenario(
    'records keep independent references and replacement never prefills a secret',
    (tester) async {
      await seed('first');
      await seed('second');
      await mount(tester);
      for (final id in ['first', 'second']) {
        await _expand(tester, id);
        await check(tester, id);
        await submit(
          tester,
          id,
          'set',
          secret: id == 'first' ? _firstSecret : _secondSecret,
        );
      }
      final first = reference('first')!;
      final second = reference('second')!;
      expect(first, isNot(second));
      final original = file('first').readAsBytesSync();
      final sibling = file('second').readAsBytesSync();
      await submit(tester, 'first', 'replace', secret: _replacement);
      expect(reference('first'), first);
      expect(file('first').readAsBytesSync(), original);
      expect(file('second').readAsBytesSync(), sibling);
      _expectSecret(storage, first, _replacement);
      _expectSecret(storage, second, _secondSecret);
      _expectStatus('second', _stored);
    },
  );

  scenario(
    'credential revisions preserve scalar drafts and invalidate only sibling-slot status',
    (tester) async {
      await seed('multiple', type: _multiple);
      await seed('sibling');
      await mount(tester);
      for (final id in ['multiple', 'sibling']) {
        await _expand(tester, id);
        await _tap(tester, _key('record-edit-jobs-$id'));
        await _enter(tester, _editInput(id), 'Draft $id');
        await check(tester, id);
      }
      await check(tester, 'multiple', 'backup');
      final draft = tester
          .widget<TextField>(_editInput('multiple'))
          .controller!;
      final sibling = tester
          .widget<TextField>(_editInput('sibling'))
          .controller!;
      await submit(tester, 'multiple', 'set');
      expect(
        tester.widget<TextField>(_editInput('multiple')).controller,
        same(draft),
      );
      expect(draft.text, 'Draft multiple');
      expect(sibling.text, 'Draft sibling');
      _expectStatus('multiple', _stored);
      _expectStatus('multiple', _unchecked, 'backup');
      _expectStatus('sibling', _noReference);
      await check(tester, 'multiple', 'backup');
      await submit(
        tester,
        'multiple',
        'set',
        slot: 'backup',
        secret: _secondSecret,
      );
      _expectStatus('multiple', _unchecked);
      _expectStatus('multiple', _stored, 'backup');
      await _tap(tester, _key('record-save-jobs-multiple'));
      await _loaded(tester);
      expect(file('multiple').readAsStringSync(), contains('Draft multiple'));
      _expectStatus('multiple', _unchecked);
      _expectStatus('multiple', _unchecked, 'backup');
      await _tap(tester, _key('record-save-jobs-sibling'));
      await _loaded(tester);
      expect(file('sibling').readAsStringSync(), contains('Draft sibling'));
      await check(tester, 'multiple');
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
      await _ensureExpanded(tester, 'multiple');
      _expectStatus('multiple', _unchecked);
      _expectStatus('multiple', _unchecked, 'backup');
    },
  );

  for (final action in ['set', 'replace', 'establish']) {
    scenario('$action cancel discards input without touching either store', (
      tester,
    ) async {
      await seed(
        'cancelled',
        secret: action == 'replace' ? _firstSecret : null,
        transferred: action == 'establish',
      );
      await mount(tester);
      await _expand(tester, 'cancelled');
      await check(tester, 'cancelled');
      final before = file('cancelled').readAsBytesSync();
      storage.calls.clear();
      await _tap(tester, _action(action, 'cancelled'));
      final field = tester.widget<TextField>(_action('input', 'cancelled'));
      expect(field.obscureText, isTrue);
      expect(field.controller!.text, isEmpty);
      await _enter(tester, _action('input', 'cancelled'), _replacement);
      expect(field.controller!.toString(), isNot(contains(_replacement)));
      expect(field.toStringDeep(), isNot(contains(_replacement)));
      final staleSubmit = _callback(tester, _action('submit', 'cancelled'));
      await _tap(tester, _action('cancel', 'cancelled'));
      expect(_action('input', 'cancelled'), findsNothing);
      expect(field.controller!.text, isEmpty);
      staleSubmit();
      await tester.pump();
      expect(storage.calls, isEmpty);
      expect(file('cancelled').readAsBytesSync(), before);
      await _tap(tester, _action(action, 'cancelled'));
      final fresh = tester.widget<TextField>(_action('input', 'cancelled'));
      expect(fresh.controller, isNot(same(field.controller)));
      expect(fresh.controller!.text, isEmpty);
      expect(fresh.obscureText, isTrue);
    });
  }

  for (final navigation in [false, true]) {
    scenario(
      '${navigation ? 'section navigation' : 'collapse'} discards secrets but retains scalar drafts and status',
      (tester) async {
        await seed('draft');
        await mount(tester);
        await _expand(tester, 'draft');
        await _tap(tester, _key('record-edit-jobs-draft'));
        await _enter(tester, _editInput('draft'), 'Retained scalar draft');
        final scalar = tester
            .widget<TextField>(_editInput('draft'))
            .controller!;
        await check(tester, 'draft');
        await _tap(tester, _action('set', 'draft'));
        await _enter(tester, _action('input', 'draft'), _firstSecret);
        final secret = tester
            .widget<TextField>(_action('input', 'draft'))
            .controller!;
        final staleSubmit = _callback(tester, _action('submit', 'draft'));
        if (navigation) {
          await _section(tester, 'Preferences');
        } else {
          await _expand(tester, 'draft');
        }
        expect(_action('input', 'draft'), findsNothing);
        expect(secret.text, isEmpty);
        await _expectNoCredentialFocus(tester);
        staleSubmit();
        await tester.pump();
        expect(storage.calls, isEmpty);
        if (navigation) {
          await _section(tester, 'Jobs');
        } else {
          await _expand(tester, 'draft');
        }
        expect(
          tester.widget<TextField>(_editInput('draft')).controller,
          same(scalar),
        );
        expect(scalar.text, 'Retained scalar draft');
        _expectStatus('draft', _noReference);
        expect(_action('input', 'draft'), findsNothing);
        await _tap(tester, _action('set', 'draft'));
        expect(
          tester.widget<TextField>(_action('input', 'draft')).controller!.text,
          isEmpty,
        );
      },
    );
  }

  scenario(
    'dialog close discards unsubmitted secret and reopening does not inspect',
    (tester) async {
      await seed('closed', secret: _firstSecret);
      await mount(tester);
      await _expand(tester, 'closed');
      await check(tester, 'closed');
      await _tap(tester, _action('replace', 'closed'));
      await _enter(tester, _action('input', 'closed'), _replacement);
      final input = tester
          .widget<TextField>(_action('input', 'closed'))
          .controller!;
      final staleSubmit = _callback(tester, _action('submit', 'closed'));
      final staleCancel = _callback(tester, _action('cancel', 'closed'));
      storage.calls.clear();
      await _close(tester);
      expect(input.text, isEmpty);
      staleSubmit();
      staleCancel();
      await tester.pump();
      expect(storage.calls, isEmpty);
      await _reopen(tester);
      await _expand(tester, 'closed');
      _expectStatus('closed', _unchecked);
      expect(storage.calls, isEmpty);
      await check(tester, 'closed');
      await _tap(tester, _action('replace', 'closed'));
      expect(
        tester.widget<TextField>(_action('input', 'closed')).controller!.text,
        isEmpty,
      );
    },
  );

  scenario(
    'transferred reference is established locally without replacing TOML identity',
    (tester) async {
      await seed('transferred', transferred: true);
      final before = file('transferred').readAsBytesSync();
      await mount(tester);
      await _expand(tester, 'transferred');
      expect(storage.calls, isEmpty);
      await check(tester, 'transferred');
      _expectStatus('transferred', _missing);
      _expectActions('transferred', const ['check', 'establish', 'forget']);
      expect(find.text('Set credential on this machine'), findsOneWidget);
      await submit(tester, 'transferred', 'establish');
      _expectStatus('transferred', _stored);
      expect(reference('transferred'), _transferred);
      expect(file('transferred').readAsBytesSync(), before);
      _expectSecret(storage, _transferred, _firstSecret);
      await submit(tester, 'transferred', 'replace', secret: _replacement);
      _expectSecret(storage, _transferred, _replacement);
    },
  );

  scenario('Forget missing local credential detaches without native deletion', (
    tester,
  ) async {
    await seed('missing', transferred: true);
    await mount(tester);
    await _expand(tester, 'missing');
    await check(tester, 'missing');
    await forget(tester, 'missing');
    _expectStatus('missing', _noReference);
    expect(reference('missing'), isNull);
    expect(storage.calls.where((call) => call.$1 == 'delete'), isEmpty);
    expect(file('missing').existsSync(), isTrue);
  });

  for (final state in ['unavailable', 'failed', 'corrupt']) {
    scenario(
      'explicit check distinguishes $state from local absence and redacts diagnostics',
      (tester) async {
        await seed('status', secret: _firstSecret);
        final ref = reference('status')!;
        final protected = storage.values[ref]!;
        if (state == 'corrupt') {
          storage.values[ref] = '$_nativeDiagnostic $_firstSecret';
        } else {
          storage
              .actions('read')
              .add(_Action(errorBefore: _storageError(state == 'unavailable')));
        }
        storage.calls.clear();
        final before = file('status').readAsBytesSync();
        await mount(tester);
        await _expand(tester, 'status');
        _expectStatus('status', _unchecked);
        expect(storage.calls, isEmpty);
        await check(tester, 'status');
        _expectStatus('status', switch (state) {
          'unavailable' => _unavailable,
          'corrupt' => _invalid,
          _ => _failed,
        });
        _expectActions('status', [
          'check',
          if (state != 'corrupt') 'reconcile',
        ]);
        expect(storage.calls, [('read', ref)]);
        expect(file('status').readAsBytesSync(), before);
        _expectRedacted(tester, file('status'));
        storage.values[ref] = protected;
        await check(tester, 'status');
        _expectStatus('status', _stored);
      },
    );
  }

  for (final target in ['record', 'type', 'slot']) {
    scenario(
      'a reference copied to another $target cannot expose mutation actions',
      (tester) async {
        await seed('source', type: _multiple, secret: _firstSecret);
        final ref = reference('source')!;
        final id = target == 'slot' ? 'source' : 'copied';
        final slot = target == 'slot' ? 'backup' : 'token';
        if (target != 'slot') {
          await seed(id, type: target == 'type' ? _single : _multiple);
        }
        file(id).writeAsStringSync(
          '${file(id).readAsStringSync()}\n'
          '${target == 'slot' ? '' : '[credentials]\n'}'
          '$slot = "${ref.value}"\n',
        );
        final before = file(id).readAsBytesSync();
        storage.calls.clear();
        await mount(tester);
        await _expand(tester, id);
        await check(tester, id, slot);
        _expectStatus(id, _invalid, slot);
        _expectActions(id, const ['check'], slot);
        expect(storage.calls, [('read', ref)]);
        expect(file(id).readAsBytesSync(), before);
        _expectSecret(storage, ref, _firstSecret);
        _expectRedacted(tester, file(id));
      },
    );
  }

  for (final state in ['unavailable', 'failed', 'corrupt', 'missing']) {
    scenario(
      'replacement rechecks $state storage and closes failed input without overwriting',
      (tester) async {
        await seed('changed', secret: _firstSecret);
        final ref = reference('changed')!;
        final protected = storage.values[ref]!;
        final before = file('changed').readAsBytesSync();
        await mount(tester);
        await _expand(tester, 'changed');
        await check(tester, 'changed');
        storage.calls.clear();
        switch (state) {
          case 'corrupt':
            storage.values[ref] = '$_nativeDiagnostic $_firstSecret';
          case 'missing':
            storage.values.remove(ref);
          default:
            storage
                .actions('read')
                .add(
                  _Action(errorBefore: _storageError(state == 'unavailable')),
                );
        }
        await submit(tester, 'changed', 'replace', secret: _replacement);
        _expectStatus('changed', switch (state) {
          'unavailable' => _unavailable,
          'corrupt' => _invalid,
          'missing' => _missing,
          _ => _failed,
        });
        expect(storage.calls, [('read', ref)]);
        expect(file('changed').readAsBytesSync(), before);
        expect(_enabled(tester, _key('record-edit-jobs-changed')), isTrue);
        expect(_enabled(tester, _key('record-delete-jobs-changed')), isTrue);
        storage.values[ref] = protected;
        await check(tester, 'changed');
        await submit(tester, 'changed', 'replace', secret: _replacement);
        _expectStatus('changed', _stored);
        _expectSecret(storage, ref, _replacement);
      },
    );
  }

  scenario(
    'establish never overwrites a credential that appeared after the check',
    (tester) async {
      await seed('appeared', secret: _firstSecret);
      final ref = reference('appeared')!;
      final protected = storage.values.remove(ref)!;
      final before = file('appeared').readAsBytesSync();
      await mount(tester);
      await _expand(tester, 'appeared');
      await check(tester, 'appeared');
      _expectStatus('appeared', _missing);
      storage.values[ref] = protected;
      storage.calls.clear();
      await submit(tester, 'appeared', 'establish', secret: _replacement);
      expect(
        find.textContaining('protected value already exists'),
        findsOneWidget,
      );
      expect(storage.calls, [('read', ref)]);
      expect(file('appeared').readAsBytesSync(), before);
      _expectSecret(storage, ref, _firstSecret);
      await check(tester, 'appeared');
      _expectStatus('appeared', _stored);
    },
  );

  scenario(
    'closed coordinator reports shutdown without leaking or fencing ordinary editing',
    (tester) async {
      await seed('closed-owner');
      await mount(tester);
      await _expand(tester, 'closed-owner');
      await coordinator.close();
      await check(tester, 'closed-owner');
      _expectStatus('closed-owner', _failed);
      expect(find.textContaining('ADELE is shutting down'), findsOneWidget);
      expect(storage.calls, isEmpty);
      expect(_enabled(tester, _key('record-edit-jobs-closed-owner')), isTrue);
      await _tap(tester, _key('record-edit-jobs-closed-owner'));
      await _enter(
        tester,
        _editInput('closed-owner'),
        'Ordinary owner still open',
      );
      await _tap(tester, _key('record-save-jobs-closed-owner'));
      await _loaded(tester);
      expect(
        file('closed-owner').readAsStringSync(),
        contains('Ordinary owner still open'),
      );
    },
  );

  for (final (label, secret) in [
    ('empty', ''),
    ('NUL', 'invalid\x00secret'),
    ('unpaired surrogate', String.fromCharCode(0xd800)),
    ('oversized input', 'x' * (CredentialSecret.maximumBytes + 1)),
  ]) {
    scenario(
      '$label secret closes and clears input without persistence or vault I/O',
      (tester) async {
        await seed('invalid');
        final before = file('invalid').readAsBytesSync();
        await mount(tester);
        await _expand(tester, 'invalid');
        await check(tester, 'invalid');
        if (label == 'unpaired surrogate') {
          await _tap(tester, _action('set', 'invalid'));
          final field = tester.widget<TextField>(_action('input', 'invalid'));
          // Flutter's paragraph engine itself rejects malformed UTF-16. Submit
          // the controller value before a frame so this exercises UI validation.
          field.controller!.text = secret;
          _callback(tester, _action('submit', 'invalid'))();
          await _loaded(tester);
          expect(_action('input', 'invalid'), findsNothing);
          expect(field.controller!.text, isEmpty);
        } else {
          await submit(tester, 'invalid', 'set', secret: secret);
        }
        expect(
          find.textContaining(
            'Credential not stored: enter nonempty valid text',
          ),
          findsOneWidget,
        );
        expect(storage.calls, isEmpty);
        expect(file('invalid').readAsBytesSync(), before);
        _expectStatus('invalid', _noReference);
        await submit(tester, 'invalid', 'set');
        _expectStatus('invalid', _stored);
      },
    );
  }

  for (final (label, secret) in [
    ('binding overhead', 'x' * CredentialSecret.maximumBytes),
    ('JSON quotes', '"' * 1300),
    ('JSON backslashes', '\\' * 1300),
    ('UTF-8 bytes', '\u00e9' * 1250),
  ]) {
    scenario('full envelope rejects $label before attaching a reference', (
      tester,
    ) async {
      await seed('bounded');
      final before = file('bounded').readAsBytesSync();
      await mount(tester);
      await _expand(tester, 'bounded');
      await check(tester, 'bounded');
      await submit(tester, 'bounded', 'set', secret: secret);
      expect(
        find.textContaining('complete protected credential'),
        findsOneWidget,
      );
      expect(storage.calls, isEmpty);
      expect(storage.values, isEmpty);
      expect(reference('bounded'), isNull);
      expect(file('bounded').readAsBytesSync(), before);
      await check(tester, 'bounded');
      _expectStatus('bounded', _noReference);
      await submit(tester, 'bounded', 'set');
      _expectStatus('bounded', _stored);
    });
  }

  scenario(
    'replacement accepts the exact full-envelope limit but rejects one extra byte',
    (tester) async {
      await seed('limit', secret: _firstSecret);
      final ref = reference('limit')!;
      final envelope = jsonDecode(storage.values[ref]!) as Map<String, dynamic>;
      envelope['secret'] = '';
      final overhead = utf8.encode(jsonEncode(envelope)).length;
      final secret = 'x' * (CredentialSecret.maximumBytes - overhead);
      final before = file('limit').readAsBytesSync();
      await mount(tester);
      await _expand(tester, 'limit');
      await check(tester, 'limit');
      storage.calls.clear();
      await submit(tester, 'limit', 'replace', secret: '${secret}x');
      expect(
        find.textContaining('complete protected credential'),
        findsOneWidget,
      );
      expect(storage.calls, isEmpty);
      _expectSecret(storage, ref, _firstSecret);
      await check(tester, 'limit');
      await submit(tester, 'limit', 'replace', secret: secret);
      _expectStatus('limit', _stored);
      expect(
        utf8.encode(storage.values[ref]!).length,
        CredentialSecret.maximumBytes,
      );
      _expectSecret(storage, ref, secret);
      expect(reference('limit'), ref);
      expect(file('limit').readAsBytesSync(), before);
    },
  );

  for (final unavailable in [false, true]) {
    scenario(
      'partial attach ${unavailable ? 'locked' : 'failed'} adopts latest handle and retains scalar draft',
      (tester) async {
        await seed('partial', type: _multiple);
        await seed('independent');
        await mount(tester);
        await _expand(tester, 'partial');
        await _tap(tester, _key('record-edit-jobs-partial'));
        await _enter(
          tester,
          _editInput('partial'),
          'Retained through partial attach',
        );
        final draft = tester
            .widget<TextField>(_editInput('partial'))
            .controller!;
        await check(tester, 'partial');
        await check(tester, 'partial', 'backup');
        storage
            .actions('contains')
            .add(_Action(errorBefore: _storageError(unavailable)));
        await submit(tester, 'partial', 'set');
        _expectStatus('partial', unavailable ? _unavailable : _failed);
        _expectStatus('partial', _unchecked, 'backup');
        final ref = reference('partial')!;
        expect(storage.calls, [('contains', ref)]);
        expect(storage.values, isEmpty);
        expect(
          tester.widget<TextField>(_editInput('partial')).controller,
          same(draft),
        );
        expect(draft.text, 'Retained through partial attach');
        expect(_enabled(tester, _key('record-save-jobs-partial')), isTrue);
        expect(_enabled(tester, _key('records-add-jobs')), isTrue);
        await check(tester, 'partial');
        _expectStatus('partial', _missing);
        await submit(tester, 'partial', 'establish', secret: _replacement);
        expect(reference('partial'), ref);
        _expectSecret(storage, ref, _replacement);
        await _tap(tester, _key('record-save-jobs-partial'));
        await _loaded(tester);
        expect(
          file('partial').readAsStringSync(),
          contains('Retained through partial attach'),
        );
        await _expand(tester, 'independent');
        await check(tester, 'independent');
        await submit(tester, 'independent', 'set', secret: _secondSecret);
        _expectStatus('independent', _stored);
      },
    );
  }

  for (final configurationFailure in [false, true]) {
    scenario(
      '${configurationFailure ? 'configuration failure' : 'external change'} fences only its record until explicit Reload',
      (tester) async {
        await seed('stale');
        await seed('independent');
        await mount(tester);
        await _expand(tester, 'stale');
        await _tap(tester, _key('record-edit-jobs-stale'));
        await _enter(tester, _editInput('stale'), 'Retained stale draft');
        final draft = tester.widget<TextField>(_editInput('stale')).controller!;
        await check(tester, 'stale');
        final oldCheck = _callback(tester, _action('check', 'stale'));
        final oldSave = _callback(tester, _key('record-save-jobs-stale'));
        if (configurationFailure) {
          Directory(roots.localStateRoot).deleteSync(recursive: true);
          File(roots.localStateRoot).writeAsStringSync(_nativeDiagnostic);
        } else {
          file('stale').writeAsStringSync(
            '${file('stale').readAsStringSync()}# external edit\n',
          );
        }
        final before = file('stale').readAsBytesSync();
        try {
          await submit(tester, 'stale', 'set');
          expect(
            find.textContaining('Reload is required before another operation'),
            findsOneWidget,
          );
          expect(storage.calls, isEmpty);
          expect(file('stale').readAsBytesSync(), before);
          expect(draft.text, 'Retained stale draft');
          expect(_enabled(tester, _key('record-save-jobs-stale')), isFalse);
          expect(_enabled(tester, _key('record-delete-jobs-stale')), isFalse);
          expect(_enabled(tester, _action('check', 'stale')), isFalse);
          oldCheck();
          oldSave();
          await tester.pump();
          expect(storage.calls, isEmpty);
        } finally {
          if (configurationFailure) File(roots.localStateRoot).deleteSync();
        }
        await _expand(tester, 'independent');
        await check(tester, 'independent');
        await submit(tester, 'independent', 'set', secret: _secondSecret);
        _expectStatus('independent', _stored);
        await _tap(tester, _key('records-reload-jobs'));
        await _tap(tester, _key('records-reload-confirm-jobs'));
        await _loaded(tester);
        await _ensureExpanded(tester, 'stale');
        _expectStatus('stale', _unchecked);
        expect(_enabled(tester, _key('record-edit-jobs-stale')), isTrue);
        await check(tester, 'stale');
        await submit(tester, 'stale', 'set');
        _expectStatus('stale', _stored);
      },
    );
  }

  for (final action in ['set', 'replace', 'establish', 'forget']) {
    for (final published in [false, true]) {
      scenario(
        '$action ${published ? 'lost acknowledgement' : 'dropped mutation'} requires explicit reconciliation without retry',
        (tester) async {
          await seed(
            'uncertain',
            secret: action == 'replace' || action == 'forget'
                ? _firstSecret
                : null,
            transferred: action == 'establish',
          );
          await mount(tester);
          await _expand(tester, 'uncertain');
          await check(tester, 'uncertain');
          storage.calls.clear();
          final native = action == 'forget' ? 'delete' : 'write';
          storage
              .actions(native)
              .add(
                _Action(
                  drop: !published,
                  errorAfter: published ? _storageError(false) : null,
                ),
              );
          if (action == 'forget') {
            await forget(tester, 'uncertain');
          } else {
            await submit(tester, 'uncertain', action, secret: _replacement);
          }
          _expectStatus('uncertain', _uncertain);
          _expectActions('uncertain', const ['check', 'reconcile']);
          expect(
            find.textContaining('Reconciliation does not retry the operation'),
            findsOneWidget,
          );
          final ref = reference('uncertain')!;
          final before = file('uncertain').readAsBytesSync();
          final calls = List.of(storage.calls);
          expect(calls.where((call) => call.$1 == native), [(native, ref)]);
          expect(credentials.requiresReconciliation(ref), isTrue);
          await check(tester, 'uncertain');
          _expectStatus('uncertain', _uncertain);
          expect(storage.calls, calls);
          await _tap(tester, _action('reconcile', 'uncertain'));
          await _loaded(tester);
          final missing = action == 'forget'
              ? published
              : action == 'replace'
              ? false
              : !published;
          _expectStatus('uncertain', missing ? _missing : _stored);
          expect(storage.calls.skip(calls.length), [('read', ref)]);
          expect(storage.calls.where((call) => call.$1 == native), [
            (native, ref),
          ]);
          expect(credentials.requiresReconciliation(ref), isFalse);
          expect(file('uncertain').readAsBytesSync(), before);
          if (action == 'forget') {
            await forget(tester, 'uncertain');
            _expectStatus('uncertain', _noReference);
            expect(reference('uncertain'), isNull);
          } else {
            await submit(
              tester,
              'uncertain',
              missing ? 'establish' : 'replace',
            );
            _expectSecret(storage, ref, _firstSecret);
            expect(reference('uncertain'), ref);
          }
          _expectRedacted(tester, file('uncertain'));
        },
      );
    }
  }

  scenario(
    'failed reconciliation retains uncertainty and never retries the write',
    (tester) async {
      await seed('reconcile');
      await mount(tester);
      await _expand(tester, 'reconcile');
      await check(tester, 'reconcile');
      storage.actions('write').add(_Action(errorAfter: _storageError(false)));
      await submit(tester, 'reconcile', 'set');
      final ref = reference('reconcile')!;
      final protected = storage.values[ref]!;
      for (final corrupt in [false, true]) {
        if (corrupt) {
          storage.values[ref] = '$_firstSecret\x00';
        } else {
          storage
              .actions('read')
              .add(_Action(errorBefore: _storageError(true)));
        }
        await _tap(tester, _action('reconcile', 'reconcile'));
        await _loaded(tester);
        _expectStatus('reconcile', corrupt ? _invalid : _unavailable);
        expect(credentials.requiresReconciliation(ref), isTrue);
        final calls = List.of(storage.calls);
        await check(tester, 'reconcile');
        _expectStatus('reconcile', _uncertain);
        expect(storage.calls, calls);
      }
      storage.values[ref] = protected;
      await _tap(tester, _action('reconcile', 'reconcile'));
      await _loaded(tester);
      _expectStatus('reconcile', _stored);
      expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
      _expectSecret(storage, ref, _firstSecret);
    },
  );

  scenario(
    'Forget confirmation defaults to Cancel, Escape is modal-only, and delete succeeds after Forget',
    (tester) async {
      await seed('target', secret: _firstSecret);
      await seed('sibling', secret: _secondSecret);
      final sibling = file('sibling').readAsBytesSync();
      final target = file('target').readAsBytesSync();
      await mount(tester);
      await _expand(tester, 'target');
      await _tap(tester, _key('record-delete-jobs-target'));
      await _tap(tester, _key('record-delete-confirm-jobs-target'));
      await _loaded(tester);
      expect(
        find.textContaining('credential associations must be removed first'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Forget credential for declared slots'),
        findsOneWidget,
      );
      expect(file('target').readAsBytesSync(), target);
      await check(tester, 'target');
      storage.calls.clear();
      final open = _callback(tester, _action('forget', 'target'));
      open();
      open();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Forget credential?'), findsOneWidget);
      final message = tester
          .widget<Text>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('Record ID: target'),
            ),
          )
          .data!;
      expect(message, contains('Access token'));
      expect(message, contains('ordinary'));
      expect(message, contains('not Delete Record'));
      expect(
        tester.widget<TextButton>(_action('forget-cancel', 'target')).autofocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _loaded(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(storage.calls, isEmpty);
      expect(file('target').readAsBytesSync(), target);
      await _tap(tester, _action('forget', 'target'));
      await tester.pumpAndSettle();
      final staleConfirm = _callback(
        tester,
        _action('forget-confirm', 'target'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _loaded(tester);
      expect(find.byType(GlobalSettingsDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      staleConfirm();
      await tester.pump();
      expect(storage.calls, isEmpty);
      await forget(tester, 'target');
      _expectStatus('target', _noReference);
      expect(reference('target'), isNull);
      expect(file('target').existsSync(), isTrue);
      expect(file('target').readAsStringSync(), contains('Title target'));
      expect(storage.values.keys, [reference('sibling')!]);
      expect(file('sibling').readAsBytesSync(), sibling);
      await _tap(tester, _key('record-delete-jobs-target'));
      await _tap(tester, _key('record-delete-confirm-jobs-target'));
      await _loaded(tester);
      expect(file('target').existsSync(), isFalse);
      expect(_key('record-jobs-target'), findsNothing);
      _expectSecret(storage, reference('sibling')!, _secondSecret);
    },
  );

  for (final unknown in [
    'future-slot = "opaque-future-value"\n',
    '[credentials.future-slot]\nvalue = "unknown"\n',
  ]) {
    scenario(
      'unknown credential entry prevents deletion with manual TOML guidance: $unknown',
      (tester) async {
        await seed('unknown', type: _plain);
        file('unknown').writeAsStringSync(
          '${file('unknown').readAsStringSync()}\n[credentials]\n$unknown',
        );
        final before = file('unknown').readAsBytesSync();
        await mount(tester);
        await _expand(tester, 'unknown');
        expect(_slot('unknown'), findsNothing);
        await _tap(tester, _key('record-delete-jobs-unknown'));
        await _tap(tester, _key('record-delete-confirm-jobs-unknown'));
        await _loaded(tester);
        expect(
          find.textContaining('credential associations must be removed first'),
          findsOneWidget,
        );
        expect(
          find.textContaining('unknown credential entries'),
          findsOneWidget,
        );
        expect(find.textContaining('manual TOML correction'), findsOneWidget);
        expect(file('unknown').readAsBytesSync(), before);
        expect(storage.calls, isEmpty);
        expect(_enabled(tester, _key('record-edit-jobs-unknown')), isTrue);
        await _tap(tester, _key('record-edit-jobs-unknown'));
        await _enter(
          tester,
          _editInput('unknown'),
          'Ordinary edits remain usable',
        );
        await _tap(tester, _key('record-save-jobs-unknown'));
        await _loaded(tester);
        expect(file('unknown').readAsStringSync(), contains(unknown));
        expect(
          file('unknown').readAsStringSync(),
          contains('Ordinary edits remain usable'),
        );
      },
    );
  }

  scenario(
    'admitted credential write gates repeated clicks and all collection mutations',
    (tester) async {
      await seed('pending');
      await seed('sibling');
      await mount(tester);
      for (final id in ['pending', 'sibling']) {
        await _expand(tester, id);
        await _tap(tester, _key('record-edit-jobs-$id'));
        await _enter(tester, _editInput(id), 'Draft $id');
        await check(tester, id);
      }
      final save = _callback(tester, _key('record-save-jobs-sibling'));
      final remove = _callback(tester, _key('record-delete-jobs-sibling'));
      final add = _callback(tester, _key('records-add-jobs'));
      final reload = _callback(tester, _key('records-reload-jobs'));
      final siblingCheck = _callback(tester, _action('check', 'sibling'));
      await _tap(tester, _key('records-add-jobs'));
      await _choose(tester, _key('record-type-jobs'), 'Single credential');
      await _enter(tester, _key('record-id-jobs'), 'not-admitted');
      await _tap(tester, _key('record-presence-jobs-caption'));
      await _enter(tester, _key('record-input-jobs-caption'), 'Creation draft');
      final create = _callback(tester, _key('record-create-jobs'));
      await _tap(tester, _action('set', 'pending'));
      await _enter(tester, _action('input', 'pending'), _firstSecret);
      final input = tester
          .widget<TextField>(_action('input', 'pending'))
          .controller!;
      final commit = _callback(tester, _action('submit', 'pending'));
      final gate = _Gate();
      storage.actions('write').add(_Action(gate: gate));
      try {
        commit();
        commit();
        save();
        remove();
        add();
        create();
        reload();
        siblingCheck();
        await gate.entered.future;
        await tester.pump();
        expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
        expect(storage.values, isEmpty);
        expect(input.text, isEmpty);
        expect(_action('input', 'pending'), findsNothing);
        expect(find.text('Credential operation pending'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        for (final finder in [
          _key('record-save-jobs-pending'),
          _key('record-save-jobs-sibling'),
          _key('record-delete-jobs-sibling'),
          _key('records-add-jobs'),
          _key('record-create-jobs'),
          _key('records-reload-jobs'),
          _action('check', 'sibling'),
        ]) {
          expect(_enabled(tester, finder), isFalse);
        }
        expect(file('sibling').readAsStringSync(), contains('Title sibling'));
        expect(file('not-admitted').existsSync(), isFalse);
      } finally {
        gate.release();
      }
      await _loaded(tester);
      _expectStatus('pending', _stored);
      expect(_enabled(tester, _key('record-save-jobs-sibling')), isTrue);
      expect(_enabled(tester, _key('record-create-jobs')), isTrue);
      expect(
        tester
            .widget<TextField>(_key('record-input-jobs-caption'))
            .controller!
            .text,
        'Creation draft',
      );
      await _tap(tester, _key('record-save-jobs-sibling'));
      await _loaded(tester);
      expect(file('sibling').readAsStringSync(), contains('Draft sibling'));
      expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
    },
  );

  for (final fails in [false, true]) {
    scenario(
      'closing Settings does not cancel an admitted ${fails ? 'uncertain' : 'successful'} write',
      (tester) async {
        await seed('closed');
        await mount(tester);
        await _expand(tester, 'closed');
        await check(tester, 'closed');
        await _tap(tester, _action('set', 'closed'));
        await _enter(tester, _action('input', 'closed'), _firstSecret);
        final commit = _callback(tester, _action('submit', 'closed'));
        final gate = _Gate();
        storage
            .actions('write')
            .add(
              _Action(
                gate: gate,
                errorAfter: fails ? _storageError(false) : null,
              ),
            );
        try {
          commit();
          await gate.entered.future;
          await tester.pump();
          await _close(tester);
          commit();
          await tester.pump();
          expect(storage.values, isEmpty);
        } finally {
          gate.release();
        }
        // A real queued Settings operation waits for the entire admitted workflow.
        await settings.load();
        expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
        _expectSecret(storage, reference('closed')!, _firstSecret);
        storage.calls.clear();
        await _reopen(tester);
        await _expand(tester, 'closed');
        _expectStatus('closed', _unchecked);
        expect(storage.calls, isEmpty);
        await check(tester, 'closed');
        _expectStatus('closed', fails ? _uncertain : _stored);
        if (fails) {
          expect(storage.calls, isEmpty);
          await _tap(tester, _action('reconcile', 'closed'));
          await _loaded(tester);
          _expectStatus('closed', _stored);
        }
      },
    );
  }

  scenario(
    'narrow secret entry remains masked, disables suggestions and submits from the keyboard',
    (tester) async {
      await seed('narrow', type: _multiple);
      await mount(tester);
      await tester.binding.setSurfaceSize(const Size(400, 700));
      await tester.pumpAndSettle();
      await _expand(tester, 'narrow');
      await check(tester, 'narrow', 'backup');
      await _tap(tester, _action('set', 'narrow', 'backup'));
      final input = _action('input', 'narrow', 'backup');
      final field = tester.widget<TextField>(input);
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
      await _enter(tester, input, _firstSecret);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await _loaded(tester);
      expect(input, findsNothing);
      expect(field.controller!.text, isEmpty);
      _expectStatus('narrow', _stored, 'backup');
      expect(tester.getSize(find.byType(Dialog)).width, lessThanOrEqualTo(400));
      _expectSecret(storage, reference('narrow', 'backup')!, _firstSecret);
      _expectRedacted(tester, file('narrow'));
    },
  );
}

RecordCatalog _catalog() => RecordCatalog([
  for (final (type, label, slots) in [
    (_single, 'Single credential', ['token']),
    (_multiple, 'Multiple credentials', ['token', 'backup']),
    (_plain, 'Plain record', <String>[]),
  ])
    RecordTypeDefinition(
      id: type,
      owner: PluginId('dev.example.credentials'),
      collection: _collection,
      collectionLabel: 'Jobs',
      label: label,
      displayField: RecordFieldId('caption'),
      fields: [
        RecordFieldDefinition(
          id: RecordFieldId('caption'),
          label: 'Caption',
          type: const StringSettingType(),
          required: true,
        ),
      ],
      credentialSlots: [
        for (final slot in slots)
          RecordCredentialSlotDefinition(
            id: RecordCredentialSlotId(slot),
            label: slot == 'token' ? 'Access token' : 'Recovery passphrase',
            kind: RecordCredentialKind.secretText,
          ),
      ],
    ),
]);

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _slot(String id, [String slot = 'token']) =>
    _key('credential-slot-jobs-$id-$slot');
Finder _action(String action, String id, [String slot = 'token']) =>
    _key('credential-$action-jobs-$id-$slot');
Finder _editInput(String id) => _key('record-input-jobs-$id-caption');

void _expectStatus(String id, String text, [String slot = 'token']) => expect(
  find.descendant(of: _slot(id, slot), matching: find.text(text)),
  findsOneWidget,
);

void _expectActions(String id, List<String> actions, [String slot = 'token']) {
  for (final action in [
    'check',
    'set',
    'replace',
    'establish',
    'forget',
    'reconcile',
  ]) {
    expect(
      _action(action, id, slot),
      actions.contains(action) ? findsOneWidget : findsNothing,
    );
  }
}

void _expectSecret(
  _Storage storage,
  CredentialReference reference,
  String secret,
) {
  final envelope =
      jsonDecode(storage.values[reference]!) as Map<String, dynamic>;
  expect(
    envelope['secret'] == secret,
    isTrue,
    reason: 'Protected secret differs.',
  );
  expect(envelope['reference'], reference.value);
}

void _expectRedacted(WidgetTester tester, File file) {
  final text = tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .join('\n');
  final toml = file.readAsStringSync();
  for (final secret in [
    _firstSecret,
    _secondSecret,
    _replacement,
    _nativeDiagnostic,
  ]) {
    expect(
      text.contains(secret),
      isFalse,
      reason: 'Private value appeared in presentation.',
    );
    expect(
      toml.contains(secret),
      isFalse,
      reason: 'Private value appeared in TOML.',
    );
  }
  expect(text, isNot(contains('cred1_')));
  expect(text, isNot(contains('"secret":')));
}

Future<void> _expand(WidgetTester tester, String id) async {
  await _tap(
    tester,
    find
        .descendant(
          of: _key('record-jobs-$id'),
          matching: find.byType(ListTile),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _ensureExpanded(WidgetTester tester, String id) async {
  if (_slot(id).evaluate().isEmpty) await _expand(tester, id);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _enter(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pump();
}

Future<void> _choose(WidgetTester tester, Finder finder, String label) async {
  await _tap(tester, finder);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pump();
  await _until(
    tester,
    () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

Future<void> _section(WidgetTester tester, String label) =>
    _choose(tester, _key('settings-section'), label);

VoidCallback _callback(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed!;

bool _enabled(WidgetTester tester, Finder finder) =>
    finder.evaluate().isNotEmpty &&
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> _loaded(WidgetTester tester) =>
    _until(tester, () => _enabled(tester, _key('records-reload-jobs')));

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Credential operation did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
  await tester.pumpAndSettle();
}

Future<void> _reopen(WidgetTester tester) async {
  await tester.tap(find.text('Open settings'));
  await tester.pump();
  await _until(tester, () => _enabled(tester, _key('settings-reload')));
  await _section(tester, 'Jobs');
  await _loaded(tester);
}

Future<void> _expectNoCredentialFocus(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
      element,
    ) {
      final key = element.widget.key;
      expect(
        key is ValueKey<String> && key.value.startsWith('credential-'),
        isFalse,
      );
      return true;
    });
  }
}

Object _storageError(bool unavailable) => unavailable
    ? const CredentialFailure(CredentialFailureKind.unavailable)
    : StateError('$_nativeDiagnostic: $_firstSecret / $_replacement');

final class _Gate {
  final entered = Completer<void>();
  final released = Completer<void>();
  Future<void> wait() {
    entered.complete();
    return released.future;
  }

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

final class _Action {
  const _Action({
    this.gate,
    this.errorBefore,
    this.errorAfter,
    this.drop = false,
  });
  final _Gate? gate;
  final Object? errorBefore;
  final Object? errorAfter;
  final bool drop;

  void finish() {
    if (errorAfter case final error?) throw error;
  }
}

// Only the OS boundary is controlled; Settings and both credential owners are real.
final class _Storage implements CredentialStorageAdapter {
  final values = <CredentialReference, String>{};
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
    if (action.errorBefore case final error?) throw error;
    return action;
  }

  @override
  Future<bool> contains(CredentialReference reference) async {
    (await _begin('contains', reference)).finish();
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    (await _begin('read', reference)).finish();
    return values[reference];
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    final action = await _begin('write', reference);
    if (!action.drop) values[reference] = secret.reveal();
    action.finish();
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    final action = await _begin('delete', reference);
    if (!action.drop) values.remove(reference);
    action.finish();
  }
}
