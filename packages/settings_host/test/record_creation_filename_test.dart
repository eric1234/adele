@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_credential_store/credential_reference.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

import '../../configuration_store/test/support.dart';

void main() {
  final primary = RecordTypeId('org.example.naming.primary');
  final alternate = RecordTypeId('org.example.naming.alternate');
  final archived = RecordTypeId('org.example.naming.archived');
  final entries = RecordCollectionId('entries');
  final archive = RecordCollectionId('archive');
  final first = ConfigurationRecordId('record-alpha');
  final second = ConfigurationRecordId('record-beta');
  final conflict = throwsA(isA<ConfigurationConflictException>());
  late Directory fixtures, installations, temporary;
  late ConfigurationStore store;
  late RecordCatalog catalog;
  late ConfigurationRecordStore host;

  setUpAll(() async {
    fixtures = Directory.systemTemp.createTempSync('adele-record-naming-');
    addTearDown(() => fixtures.deleteSync(recursive: true));
    installations = Directory(p.join(fixtures.path, 'installations'));
    final plugin = Directory(p.join(installations.path, 'naming'))
      ..createSync(recursive: true);
    File(
      p.join(plugin.path, 'adele_plugin.installation.json'),
    ).writeAsStringSync(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'org.example.naming',
          'version': '1',
          'displayName': 'Naming',
        },
        'components': <String, Object?>{},
        'recordsSchema': 'records.json',
      }),
    );
    File(p.join(plugin.path, 'records.json')).writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'recordTypes': [
          for (final (type, collection) in [
            (primary, entries),
            (alternate, entries),
            (archived, archive),
          ])
            {
              'id': type.value,
              'collection': collection.value,
              'collectionLabel': collection.value,
              'label': type.value,
              'displayField': 'display-name',
              'filenameField': 'title',
              'fields': [
                for (final field in ['display-name', 'title'])
                  {
                    'id': field,
                    'label': field,
                    'type': 'string',
                    'required': true,
                  },
              ],
              'credentialSlots': [
                {'id': 'token', 'label': 'Token', 'kind': 'secret-text'},
              ],
            },
        ],
      }),
    );
    final prepared = await PreparedPluginCatalog.discover(installations.path);
    expect(prepared.issues, isEmpty);
    catalog = prepared.records;
  });

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('adele-record-creation-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    store = ConfigurationStore(rootsAt(temporary.path));
    host = ConfigurationRecordStore(store: store, catalog: catalog);
  });

  Map<String, String> values(String title) => {
    'display-name': 'Shared label',
    'title': title,
  };
  File file(String name, [RecordCollectionId? collection]) => File(
    store
        .recordFile(collectionId: (collection ?? entries).value, fileName: name)
        .filePath,
  );
  Iterable<String> names() =>
      file('example.toml').parent.listSync().map((e) => p.basename(e.path));

  test(
    'headless create writes the derived basename and preserves the authored value and ID',
    () async {
      final desired = values('  OpenAI / Work  ');
      final created = await host.create(primary, first, desired);
      expect(created.fileName, 'openai-work.toml');
      expect(names(), ['openai-work.toml']);
      final disk = store
          .recordFile(collectionId: entries.value, fileName: 'openai-work.toml')
          .load()
          .document;
      expect(disk.readScalar(['recordVersion']), 2);
      expect(disk.readScalar(['recordId']), first.value);
      expect(disk.readScalar(['recordType']), primary.value);
      expect(disk.readScalar(['values', 'title']), desired['title']);
      expect((await host.load(entries, first)).values, desired);
      await expectLater(
        host.load(entries, ConfigurationRecordId('openai-work')),
        throwsA(isA<ConfigurationRecordNotFound>()),
      );
    },
  );

  test(
    'invalid headless creates preserve siblings and never fall back to another path',
    () async {
      final sibling = file('external.toml');
      sibling.parent.createSync(recursive: true);
      sibling.writeAsStringSync('# unrelated TOML\n');
      final before = sibling.readAsBytesSync();
      for (final title in ['---', 'CON', '9 lives', 'A\u00e9', 'a' * 65]) {
        await expectLater(
          host.create(primary, first, values(title)),
          throwsA(
            isA<InvalidRecordValue>().having(
              (e) => e.fieldId,
              'field',
              RecordFieldId('title'),
            ),
          ),
        );
      }
      await expectLater(
        host.create(primary, first, {
          ...values('Valid'),
          'fileName': 'custom.toml',
        }),
        throwsA(isA<ConfigurationRecordFormatException>()),
      );
      expect(names(), ['external.toml']);
      expect(sibling.readAsBytesSync(), before);
      expect(File(store.lockPath).existsSync(), isFalse);
    },
  );

  test(
    'different types share both name and ID reservations only within a collection',
    () async {
      await host.create(primary, first, values('API / Work'));
      final original = file('api-work.toml').readAsBytesSync();
      for (final type in [primary, alternate]) {
        await expectLater(
          host.create(type, second, values('API -- WORK')),
          conflict,
        );
      }
      await expectLater(
        host.create(alternate, first, values('Unused')),
        conflict,
      );
      expect(names(), ['api-work.toml']);
      expect(file('api-work.toml').readAsBytesSync(), original);
      final independent = await host.create(
        archived,
        first,
        values('Api WORK'),
      );
      expect(independent.fileName, 'api-work.toml');
      expect((await host.load(archive, first)).values, values('Api WORK'));
      expect(file('api-work.toml').readAsBytesSync(), original);
    },
  );

  test(
    'malformed, unknown-type, aliased and symlinked destinations are never replaced',
    () async {
      final desired = values('New Entry');
      final target = file('new-entry.toml');
      target.parent.createSync(recursive: true);
      for (final bytes in [
        <int>[0xff],
        utf8.encode('malformed = ['),
        utf8.encode(
          'recordVersion = 2\nrecordId = "$second"\nrecordType = "org.absent.type"\n[values]\n',
        ),
      ]) {
        target.writeAsBytesSync(bytes);
        await expectLater(host.create(primary, first, desired), conflict);
        expect(target.readAsBytesSync(), bytes);
        expect(names(), ['new-entry.toml']);
      }
      target.deleteSync();
      final alias = File(p.join(target.parent.path, 'New-Entry.TOML. '))
        ..writeAsStringSync('external');
      await expectLater(
        host.create(primary, first, desired),
        throwsA(isA<ConfigurationRecordFormatException>()),
      );
      expect(names(), ['New-Entry.TOML. ']);
      expect(alias.readAsStringSync(), 'external');
      alias.deleteSync();
      final outside = File(p.join(temporary.path, 'outside'))
        ..writeAsStringSync('outside');
      final link = Link(target.path)..createSync(outside.path);
      await expectLater(
        host.create(primary, first, desired),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      expect(names(), ['new-entry.toml']);
      expect(link.targetSync(), outside.path);
      expect(outside.readAsStringSync(), 'outside');
    },
  );

  test(
    'a rename frees only the old filename; fresh operations use the observed path',
    () async {
      var original = await host.create(primary, first, values('Original'));
      // Ordinary string values need not be admissible as new filenames.
      original = await host.update(original, values('CON'));
      expect(original.fileName, 'original.toml');
      expect((await host.load(entries, first)).values, values('CON'));
      final moved = file(
        'original.toml',
      ).renameSync(file('external.toml').path);
      final listing = await host.enumerate(entries);
      expect(listing.diagnostics, isEmpty);
      expect(listing.records.single.fileName, 'external.toml');
      await expectLater(
        host.create(primary, first, values('Original')),
        conflict,
      );
      await expectLater(host.update(original, values('Stale')), conflict);
      expect(names(), ['external.toml']);
      await host.create(primary, second, values('ORIGINAL'));
      final siblingBytes = file('original.toml').readAsBytesSync();
      final slot = RecordCredentialSlotId('token');
      final reference = CredentialReference.generate();
      var current = await host.load(entries, first);
      current = await host.setCredentialReference(current, slot, reference);
      current = await host.update(current, values('Unrelated'));
      expect(current.fileName, 'external.toml');
      final reloaded = await host.load(entries, first);
      expect(reloaded.credentials[slot], reference);
      expect(reloaded.values, values('Unrelated'));
      expect(moved.readAsStringSync(), contains('Unrelated'));
      await host.delete(
        await host.setCredentialReference(reloaded, slot, null),
      );
      expect(names(), ['original.toml']);
      expect(file('original.toml').readAsBytesSync(), siblingBytes);
      expect((await host.load(entries, second)).values, values('ORIGINAL'));
    },
  );

  group('cooperating process creates', () {
    late String kernel;
    setUpAll(() async {
      kernel = await prepareWriter(
        fixtures,
        source: 'test/fixtures/record_reader.dart',
      );
    });

    Future<ConfigurationWriter> creator(
      ConfigurationRecordId id,
      String title,
    ) => ConfigurationWriter.start(
      kernel,
      temporary.path,
      'host-create',
      jsonEncode(values(title)),
      id.value,
      primary.value,
      installations.path,
    );

    for (final (scenario, otherId, otherTitle, bothSucceed) in [
      ('same ID, different filenames', first, 'Other', false),
      ('different IDs, same filename', second, 'aPI / Work', false),
      ('different IDs and filenames', second, 'Other', true),
    ]) {
      test(scenario, () async {
        final a = await creator(first, 'API Work');
        await a.expectLine('before-lock');
        final b = await creator(otherId, otherTitle);
        await b.expectLine('before-lock');

        // Both creates reached the exclusive lock, neither has acquired it. An
        // unlocked ID scan would already have admitted both on the empty root.
        a.process.stdin.writeln('lock');
        await a.expectLine('staged');
        final probe = await ConfigurationWriter.start(
          kernel,
          temporary.path,
          'probe',
        );
        await probe.expectLine('locked');
        await probe.expectExit();
        b.process.stdin.writeln('lock');
        a.process.stdin.writeln('publish');
        await a.expectLine('created:$first:api-work.toml');
        if (bothSucceed) {
          await b.expectLine('staged');
          b.process.stdin.writeln('publish');
          await b.expectLine('created:$otherId:other.toml');
        } else {
          await b.expectLine('conflict');
        }
        await a.expectExit();
        await b.expectExit();

        expect(
          names(),
          unorderedEquals(['api-work.toml', if (bothSucceed) 'other.toml']),
        );
        final listing = await host.enumerate(entries);
        expect(listing.diagnostics, isEmpty);
        expect(
          listing.records.map((r) => (r.id, r.fileName, r.values['title'])),
          [
            (first, 'api-work.toml', 'API Work'),
            if (bothSucceed) (otherId, 'other.toml', otherTitle),
          ],
        );
      });
    }
  });
}
