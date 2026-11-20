import 'dart:async';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:model_configuration_backend/model_configuration_backend.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  late _Storage storage;
  late _Catalog catalog;
  late ModelPresetSelectionBackend selection;
  setUp(() {
    storage = _Storage();
    catalog = _Catalog();
    selection = ModelPresetSelectionBackend(storage, catalog);
  });
  test('absent selection reads no catalog and creates no row', () async {
    final empty = await selection.readSessionSelection('session');
    expect(
      (empty.sessionId, empty.selectedPresetId, empty.revision),
      ('session', null, 0),
    );
    expect(catalog.reads, 0);
    expect(storage.writes, isEmpty);
  });

  test(
    'validate request and stored identity before catalog or mutation',
    () async {
      for (final (session, id, revision) in [
        ('', null, 0),
        (' session', null, 0),
        ('session', 'con', 0),
        ('session', null, -1),
        ('session', null, 2147483648),
      ]) {
        await expectLater(
          selection.updateSessionSelection(session, id, revision),
          throwsA(_failure('invalid_request')),
        );
      }
      expect(storage.queries, 0);
      await expectLater(
        selection.readSessionSelection('unknown'),
        throwsA(_failure('storage_unavailable')),
      );
      final valid = _row(null, 1).values;
      for (final rows in [
        [_row(null, 1), _row(null, 1)],
        for (final values in [
          {...valid, 'session_id': 'wrong'},
          {...valid}..remove('selected_preset_id'),
          {...valid, 'selected_preset_id': '../private'},
          {...valid, 'selected_preset_id': 12},
          {...valid, 'revision': 0},
          {...valid, 'revision': '1'},
          {...valid, 'revision': 2147483648},
          {...valid, 'extra': 1},
        ])
          [RelationalRow(values: values)],
      ]) {
        storage.rows = rows;
        await expectLater(
          selection.readSessionSelection('session'),
          throwsA(_failure('corrupt_state')),
        );
        await expectLater(
          selection.updateSessionSelection('session', null, 1),
          throwsA(_failure('corrupt_state')),
        );
      }
      expect(catalog.reads, 0);
      expect(storage.writes, isEmpty);
    },
  );

  test(
    'non-null writes need positive evidence and store only ID and revision',
    () async {
      for (final complete in [true, false]) {
        catalog.result = _snapshot(complete: complete);
        await expectLater(
          selection.updateSessionSelection('session', 'work', 0),
          throwsA(
            _failure(complete ? 'preset_not_found' : 'catalog_incomplete'),
          ),
        );
      }
      catalog.result = null;
      await expectLater(
        selection.updateSessionSelection('session', 'work', 0),
        throwsA(_failure('catalog_unavailable')),
      );
      expect(storage.writes, isEmpty);
      catalog.result = _snapshot(complete: false, visible: true);
      final first = await selection.updateSessionSelection(
        'session',
        'work',
        0,
      );
      expect((first.selectedPresetId, first.revision), ('work', 1));
      final insert = storage.writes.single;
      expect(insert.sql, contains('INSERT INTO adele_model_preset_selections'));
      expect(insert.parameters, {
        ':session': 'session',
        ':preset': 'work',
        ':next': 1,
      });
      storage.rows = [_row('work', 1)];
      catalog.result = _snapshot(complete: true);
      expect(
        (await selection.readSessionSelection('session')).selectedPresetId,
        'work',
      );
      await expectLater(
        selection.updateSessionSelection('session', 'work', 1),
        throwsA(_failure('preset_not_found')),
      );
      catalog.result = _snapshot(complete: true, visible: true);
      expect(
        (await selection.updateSessionSelection('session', 'work', 1)).revision,
        2,
      );
      final update = storage.writes.last;
      expect(
        update.sql,
        contains('WHERE session_id = :session AND revision = :expected'),
      );
      expect(update.parameters, {
        ':session': 'session',
        ':preset': 'work',
        ':next': 2,
        ':expected': 1,
      });
    },
  );

  test(
    'clears, stale revisions and exhausted revisions need no catalog',
    () async {
      catalog.result = null;
      for (final (id, revision) in [(null, 0), ('work', 1), (null, 2)]) {
        storage.rows = [if (revision > 0) _row(id, revision)];
        final cleared = await selection.updateSessionSelection(
          'session',
          null,
          revision,
        );
        expect(
          (cleared.selectedPresetId, cleared.revision),
          (null, revision + 1),
        );
        expect(storage.writes.last.parameters[':preset'], isNull);
      }
      storage.rows = [_row(null, ModelPresetSelectionLimits.maxRevision)];
      await expectLater(
        selection.updateSessionSelection('session', 'work', 2),
        throwsA(_failure('stale_revision')),
      );
      await expectLater(
        selection.updateSessionSelection(
          'session',
          'work',
          ModelPresetSelectionLimits.maxRevision,
        ),
        throwsA(_failure('revision_exhausted')),
      );
      expect(catalog.reads, 0);
      expect(storage.writes, hasLength(3));
    },
  );

  test(
    'overlapping writes use independent conditional transactions and acknowledgments',
    () async {
      storage.rows = [_row(null, 3)];
      final both = Completer<void>();
      final acks = <Completer<void>>[];
      storage.commit = () {
        final ack = Completer<void>();
        acks.add(ack);
        if (acks.length == 2) both.complete();
        return ack.future;
      };
      final a = selection.updateSessionSelection('session', null, 3);
      final b = selection.updateSessionSelection('session', null, 3);
      final rejected = expectLater(b, throwsA(_failure('outcome_uncertain')));
      await both.future;
      expect(storage.writes.map((s) => s.parameters[':expected']), [3, 3]);
      acks.last.completeError(StateError('CAS failure /private/path'));
      acks.first.complete();
      expect((await a).revision, 4);
      await rejected;
      expect(storage.queries, 2);
      expect(storage.writes, hasLength(2));
    },
  );

  test(
    'lost commit reply is uncertain even when next explicit read sees the change',
    () async {
      storage.commit = () async {
        storage.rows = [_row(null, 1)];
        throw StateError('Lost acknowledgment /private/path');
      };
      await expectLater(
        selection.updateSessionSelection('session', null, 0),
        throwsA(_failure('outcome_uncertain')),
      );
      expect(storage.queries, 1);
      expect((await selection.readSessionSelection('session')).revision, 1);
      expect(storage.writes, hasLength(1));
    },
  );
}

RelationalRow _row(String? id, int revision) => RelationalRow(
  values: {
    'session_id': 'session',
    'selected_preset_id': id,
    'revision': revision,
  },
);
Matcher _failure(String code) => isA<ModelPresetSelectionFailure>()
    .having((f) => f.code, 'code', code)
    .having((f) => f.message, 'message', isNot(contains('private')))
    .having((f) => f.details, 'details', isEmpty);

ModelPresetCatalogSnapshot _snapshot({
  required bool complete,
  bool visible = false,
}) => ModelPresetCatalogSnapshot(
  presets: [
    if (visible)
      ModelPresetDefinition(
        presetId: 'work',
        name: 'Editable',
        description: null,
        providerId: 'not-running',
        modelId: 'Unknown',
        reasoningEffort: null,
      ),
  ],
  isComplete: complete,
);

final class _Catalog implements ModelPresetCatalogService {
  int reads = 0;
  ModelPresetCatalogSnapshot? result;
  @override
  Future<ModelPresetCatalogSnapshot> readPresets() async {
    reads++;
    return result ??
        (throw const ModelPresetCatalogFailure(
          code: 'unavailable',
          message: 'Unavailable.',
        ));
  }
}

// Scripts host observations and acknowledgments; the AOT suite exercises SQLite.
final class _Storage implements ProjectStorageService {
  List<RelationalRow> rows = [];
  int queries = 0;
  final writes = <RelationalStatement>[];
  Future<void> Function() commit = () async {};

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    if (sessionId != 'session') {
      throw StateError('Unknown Session /private/path');
    }
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    expect(
      migrations.single,
      contains('REFERENCES adele_product_sessions(id)'),
    );
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    expect(sessionId, 'session');
    expect(parameters, {':session': 'session'});
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    queries++;
    return rows;
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) {
    expect(sessionId, 'session');
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    expect(statements.single.expectedRows, 1);
    writes.add(statements.single);
    return commit();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected storage operation');
}
