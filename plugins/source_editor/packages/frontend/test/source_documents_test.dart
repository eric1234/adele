import 'dart:async';
import 'dart:convert';

import 'package:source_editor_frontend/source_documents.dart';
import 'package:test/test.dart';

void main() {
  late _Port port;
  late SourceDocuments documents;

  setUp(() {
    port = _Port();
    documents = SourceDocuments(port, 'environment-a');
  });

  Future<String> open([String path = 'lib/main.dart']) async {
    final result = await documents.display(path);
    expect(result['ok'], isTrue);
    expect(result['focus'], result['id']);
    return result['id'] as String;
  }

  test(
    'publishes only after complete read and successful native initialization',
    () async {
      final read = Completer<Map<String, dynamic>>();
      final create = Completer<bool>();
      port.onRead = (path) => read.future;
      port.onCreate = (id) => create.future;
      final operation = documents.display('lib/main.dart');
      expect(port.records, isEmpty);
      expect(port.editors, isEmpty);
      expect(port.allocated, 0);
      read.complete(_file('lib/main.dart', 'complete text'));
      await Future<void>.delayed(Duration.zero);
      expect(port.allocated, 1);
      expect(port.records, isEmpty);
      create.complete(true);
      final result = await operation;
      final id = result['id'] as String;
      expect(port.records[id]!['baseline'], 'complete text');
      expect(port.editors[id]!['text'], 'complete text');
    },
  );

  test(
    'read and initialization failures never publish partial documents',
    () async {
      final failure = <String, dynamic>{
        'ok': false,
        'failure': <String, dynamic>{
          'code': 'file_too_large',
          'message': 'Complete file exceeds provider limit.',
          'details': <String, dynamic>{'limitBytes': 1048576},
        },
      };
      port.onRead = (path) async => failure;
      expect(await documents.display('large.dart'), same(failure));
      expect(port.allocated, 0);
      port.onRead = null;
      port.onCreate = (id) async => false;
      expect((await documents.display('main.dart'))['ok'], isFalse);
      expect(port.records, isEmpty);
      expect(port.editors, isEmpty);
    },
  );

  test(
    'deduplicates aliases only after a complete provider-normalized read',
    () async {
      port.onRead = (path) async => _file('lib/main.dart', 'original');
      final id = await open('./lib/main.dart');
      port.edit(id, 'unsaved native text');
      final before = documents.document(id);
      port.onRead = (path) async => _file('lib/main.dart', 'changed on disk');
      expect(await open('lib//main.dart'), id);
      expect(port.reads, ['./lib/main.dart', 'lib//main.dart']);
      expect(port.allocated, 1);
      expect(documents.document(id), before);
      expect(port.editors[id]!['text'], 'unsaved native text');
      expect(port.editors[id]!['revision'], 1);
    },
  );

  test(
    'exact retained path focuses without reading or refreshing edited text',
    () async {
      final id = await open();
      port.edit(id, 'unsaved native text');
      final before = documents.document(id);
      port.onRead = (path) async =>
          sourceFailure('binding_stale', 'Provider retired.');
      final cold = SourceDocuments(port, 'environment-a');
      expect(await cold.display('lib/main.dart'), {
        'ok': true,
        'id': id,
        'focus': id,
      });
      expect(port.reads, ['lib/main.dart']);
      expect(port.allocated, 1);
      expect(port.released, isEmpty);
      expect(documents.document(id), before);
      expect(port.editors[id]!['text'], 'unsaved native text');
      expect(port.editors[id]!['revision'], 1);
    },
  );

  test(
    'overlapping native initialization releases only the losing provisional editor',
    () async {
      final slow = Completer<bool>();
      port.onCreate = (id) {
        if (id == 'document-1') return slow.future;
        return Future<bool>.value(true);
      };
      final first = documents.display('main.dart');
      await Future<void>.delayed(Duration.zero);
      final winner = await open('main.dart');
      expect(winner, 'document-2');
      port.edit(winner, 'winner has edits and undo');
      slow.complete(true);
      final result = await first;
      expect(result['id'], winner);
      expect(port.released, ['document-1']);
      expect(port.records.keys, [winner]);
      expect(port.editors[winner]!['text'], 'winner has edits and undo');
    },
  );

  test(
    'same normalized path in separate Environments has independent identity',
    () async {
      final first = await open();
      final other = SourceDocuments(port, 'environment-b');
      final second = await other.display('lib/main.dart');
      expect(second['id'], isNot(first));
      expect(documents.documents(false).length, 1);
      expect(other.documents(false).length, 1);
      expect(documents.documents(true).length, 2);
      final wrongSave = await other.save(first);
      final wrongClose = await other.close(first);
      expect(wrongSave['failure']['code'], 'document_unavailable');
      expect(wrongClose['failure']['code'], 'document_unavailable');
      expect(port.replacements, isEmpty);
      expect(port.released, isEmpty);
    },
  );

  test(
    'order is retained in records, scoped to Environment, and restored cold',
    () async {
      final first = await open('a.dart');
      final second = await open('b.json');
      final other = SourceDocuments(port, 'environment-b');
      final hidden = await other.display('hidden.py');
      expect(documents.move(second, -1), isTrue);
      expect(documents.move(second, -1), isFalse);
      final cold = SourceDocuments(port, 'environment-a');
      expect(cold.documents(false).map((data) => data['id']), [second, first]);
      expect(other.documents(false).single['id'], hidden['id']);
      final third = await open('c.txt');
      expect(cold.documents(false).map((data) => data['id']), [
        second,
        first,
        third,
      ]);
    },
  );

  test(
    'only supported languages are requested, with explicit plain fallback',
    () {
      expect(sourceLanguage('main.DART'), 'dart');
      expect(sourceLanguage('settings.json'), 'json');
      expect(sourceLanguage('script.py'), 'python');
      expect(sourceLanguage('main.js'), 'plain');
      expect(sourceLanguage('Dockerfile'), 'plain');
    },
  );

  test(
    'save is one flight with one snapshot and advances baseline to saved text only',
    () async {
      final id = await open();
      port.edit(id, 'snapshot to save');
      final write = Completer<Map<String, dynamic>>();
      port.onReplace = (path, text, revision) => write.future;
      final save = documents.save(id);
      expect(documents.document(id)['saving'], isTrue);
      expect((await documents.save(id))['failure']['code'], 'document_busy');
      expect((await documents.close(id))['failure']['code'], 'document_busy');
      expect((await documents.exit())['accepted'], isFalse);
      expect(port.replacements, [
        {
          'path': 'lib/main.dart',
          'text': 'snapshot to save',
          'revision': 'revision-0',
        },
      ]);
      expect(port.snapshots[id], 1);
      port.edit(id, 'newer text remains dirty');
      write.complete({'ok': true, 'revision': 'provider-opaque-next'});
      expect((await save)['ok'], isTrue);
      final current = documents.document(id);
      expect(current['saving'], isFalse);
      expect(current['baseline'], 'snapshot to save');
      expect(current['providerRevision'], 'provider-opaque-next');
      expect(current['dirty'], isTrue);
      expect(port.editors[id]!['text'], 'newer text remains dirty');
      expect(port.snapshots[id], 1);
    },
  );

  test(
    'pane titles are bounded without changing the normalized resource path',
    () {
      final path = '${'segment/' * 50}main.dart';
      final data = <String, dynamic>{'path': path, 'dirty': false};
      expect(sourceTitle(data).length, lessThanOrEqualTo(160));
      expect(sourceTitle(data), endsWith('...'));
      data['dirty'] = true;
      expect(sourceTitle(data), startsWith('* '));
      expect(sourceTitle(data).length, lessThanOrEqualTo(160));
      expect(data['path'], path);
      expect(sourceTitle({'path': 'a' * 160, 'dirty': false}), 'a' * 160);
      expect(sourceTitle({'path': 'a' * 160, 'dirty': true}).length, 160);
    },
  );

  test(
    'pane titles escape controls and direction marks rather than reject files',
    () {
      final controls = String.fromCharCodes([
        ...List.generate(32, (index) => index),
        ...List.generate(33, (index) => index + 127),
        ...List.generate(7, (index) => index + 8232),
        ...List.generate(4, (index) => index + 8294),
      ]);
      for (final character in controls.split('')) {
        final title = sourceTitle({'path': 'a${character}b', 'dirty': false});
        expect(title, startsWith(r'a\u'));
        expect(title, endsWith('b'));
        expect(title, isNot(contains(character)));
        expect(title.length, lessThanOrEqualTo(160));
      }
      expect(sourceTitle({'path': '   ', 'dirty': false}), 'Source file');
      expect(sourceTitle({'path': 'main.dart', 'dirty': true}), '* main.dart');
    },
  );

  test(
    'failed save preserves structured conflict, baseline and revision without retry',
    () async {
      final id = await open();
      port.edit(id, 'unsaved');
      final failure = <String, dynamic>{
        'ok': false,
        'failure': <String, dynamic>{
          'code': 'revision_conflict',
          'message': 'The file changed.',
          'details': <String, dynamic>{
            'path': 'lib/main.dart',
            'actual': 'other',
          },
        },
      };
      port.onReplace = (path, text, revision) async => failure;
      expect(await documents.save(id), same(failure));
      final current = documents.document(id);
      expect(current['baseline'], 'original');
      expect(current['providerRevision'], 'revision-0');
      expect(current['saving'], isFalse);
      expect(current['dirty'], isTrue);
      expect(current['conflict'], isTrue);
      expect(current['failure'], failure['failure']);
      expect(port.replacements.length, 1);
      expect(port.editors[id]!['text'], 'unsaved');
      port.onReplace = null;
      await documents.save(id);
      expect(documents.document(id)['conflict'], isFalse);
      expect(documents.document(id)['failure'], isEmpty);
    },
  );

  test(
    'oversized replacement failure retains the complete larger local buffer',
    () async {
      final id = await open();
      final largerText = 'a' * (1048576 + 1);
      port.edit(id, largerText);
      final failure = <String, dynamic>{
        'ok': false,
        'failure': <String, dynamic>{
          'code': 'file_too_large',
          'message': 'Replacement exceeds the provider bound.',
          'details': <String, dynamic>{'limitBytes': 1048576},
        },
      };
      port.onReplace = (path, text, revision) async {
        expect(text, largerText);
        expect(revision, 'revision-0');
        return failure;
      };
      expect(await documents.save(id), same(failure));
      final current = documents.document(id);
      expect(current['baseline'], 'original');
      expect(current['providerRevision'], 'revision-0');
      expect(current['saving'], isFalse);
      expect(current['dirty'], isTrue);
      expect(port.editors[id]!['text'], largerText);
      expect(port.replacements, hasLength(1));
    },
  );

  test(
    'unavailable snapshot clears save flight without writing or losing data',
    () async {
      final id = await open();
      port.editors[id]!['ready'] = false;
      final result = await documents.save(id);
      expect(result['failure']['code'], 'editor_unavailable');
      expect(documents.document(id)['saving'], isFalse);
      expect(documents.document(id)['providerRevision'], 'revision-0');
      expect(port.replacements, isEmpty);
      expect((await documents.close(id))['ok'], isFalse);
      expect((await documents.exit())['accepted'], isFalse);
      expect(port.released, isEmpty);
    },
  );

  test('empty native snapshot leaves Save retryable', () async {
    final id = await open();
    port.emptySnapshot = true;
    expect((await documents.save(id))['failure']['code'], 'editor_unavailable');
    expect(documents.document(id)['saving'], isFalse);
    expect(port.replacements, isEmpty);
    port.emptySnapshot = false;
    expect((await documents.save(id))['ok'], isTrue);
  });

  test(
    'native state failure after acknowledged Save does not strand the flight',
    () async {
      final id = await open();
      port.edit(id, 'saved text');
      port.onReplace = (path, text, revision) async {
        port.emptyState = true;
        return {'ok': true, 'revision': 'acknowledged'};
      };
      expect((await documents.save(id))['ok'], isTrue);
      final data = documents.document(id);
      expect(data['baseline'], 'saved text');
      expect(data['providerRevision'], 'acknowledged');
      expect(data['saving'], isFalse);
      expect(data['dirty'], isTrue);
    },
  );

  test(
    'native notification invalidates conservatively; remount compares actual text',
    () async {
      final id = await open();
      port.edit(id, 'original');
      documents.invalidate(id, port.editorState(id));
      expect(documents.document(id)['dirty'], isTrue);
      expect(port.snapshots, isEmpty);
      documents.observeSnapshot(id, port.snapshot(id));
      expect(documents.document(id)['dirty'], isFalse);
      expect(documents.document(id)['checkedRevision'], 1);
    },
  );

  test(
    'close compares actual text, including undo to baseline, without false prompt',
    () async {
      final id = await open();
      port.edit(id, 'changed');
      documents.invalidate(id, port.editorState(id));
      port.edit(id, 'original');
      expect(documents.document(id)['dirty'], isTrue);
      expect((await documents.close(id))['ok'], isTrue);
      expect(port.confirmations, isEmpty);
      expect(port.released, [id]);
      expect(port.records, isEmpty);
    },
  );

  test(
    'dirty close cancellation retains hidden text; confirmed close releases it',
    () async {
      final id = await open();
      port.edit(id, 'hidden unsaved text');
      port.acceptDiscard = false;
      expect((await documents.close(id))['failure']['code'], 'cancelled');
      expect(documents.document(id)['dirty'], isTrue);
      expect(documents.document(id)['closing'], isFalse);
      expect(port.editors[id]!['text'], 'hidden unsaved text');
      expect(port.confirmations.single, contains('lib/main.dart'));
      port.acceptDiscard = true;
      expect((await documents.close(id))['ok'], isTrue);
      expect(port.released, [id]);
      expect(port.records, isEmpty);
    },
  );

  test(
    'close confirmation serializes Save and rejects changed text after await',
    () async {
      final id = await open();
      port.edit(id, 'reviewed');
      final confirmation = Completer<bool>();
      port.onConfirm = (message) => confirmation.future;
      final close = documents.close(id);
      expect(documents.document(id)['closing'], isTrue);
      expect((await documents.save(id))['failure']['code'], 'document_busy');
      expect((await documents.close(id))['failure']['code'], 'document_busy');
      port.edit(id, 'not reviewed');
      confirmation.complete(true);
      expect((await close)['failure']['code'], 'document_changed');
      expect(documents.document(id)['closing'], isFalse);
      expect(port.released, isEmpty);
    },
  );

  test(
    'exit has no Environment and inspects every hidden editor with one aggregate prompt',
    () async {
      final first = await open('a.dart');
      final other = SourceDocuments(port, 'environment-b');
      final second = (await other.display('b.py'))['id'] as String;
      port.edit(first, 'dirty a');
      port.edit(second, 'dirty b');
      final exit = SourceDocuments(port, '');
      expect(await exit.exit(), {'accepted': true});
      expect(port.confirmations.length, 1);
      expect(port.confirmations.single, contains('a.dart (environment-a)'));
      expect(port.confirmations.single, contains('b.py (environment-b)'));
      expect(port.records.length, 2);
      expect(port.editors.length, 2);
      expect(port.released, isEmpty);
    },
  );

  test(
    'exit cancellation retains everything and unchanged exit needs no prompt',
    () async {
      final id = await open();
      expect(await documents.exit(), {'accepted': true});
      expect(port.confirmations, isEmpty);
      port.edit(id, 'dirty');
      port.acceptDiscard = false;
      expect(await documents.exit(), {'accepted': false});
      expect(port.released, isEmpty);
      expect(port.records.length, 1);
    },
  );

  test(
    'exit rejects edits and newly opened records during aggregate confirmation',
    () async {
      final id = await open();
      port.edit(id, 'reviewed');
      var confirmation = Completer<bool>();
      port.onConfirm = (message) => confirmation.future;
      var exit = documents.exit();
      port.edit(id, 'not reviewed');
      confirmation.complete(true);
      expect(await exit, {'accepted': false});
      confirmation = Completer<bool>();
      exit = documents.exit();
      await open('new.dart');
      confirmation.complete(true);
      expect(await exit, {'accepted': false});
      expect(port.released, isEmpty);
    },
  );

  test(
    'exit refuses a hidden save started while aggregate confirmation awaits',
    () async {
      final first = await open();
      port.edit(first, 'dirty');
      final other = SourceDocuments(port, 'environment-b');
      final second = (await other.display('hidden.py'))['id'] as String;
      final confirmation = Completer<bool>();
      port.onConfirm = (message) => confirmation.future;
      final exit = documents.exit();
      final replacement = Completer<Map<String, dynamic>>();
      port.onReplace = (path, text, revision) => replacement.future;
      final save = other.save(second);
      confirmation.complete(true);
      expect(await exit, {'accepted': false});
      replacement.complete({'ok': true, 'revision': 'next'});
      await save;
      expect(port.released, isEmpty);
    },
  );

  test('revoked publication releases its provisional native editor', () async {
    port.allowWrites = false;
    expect(
      (await documents.display('main.dart'))['failure']['code'],
      'retired',
    );
    expect(port.records, isEmpty);
    expect(port.editors, isEmpty);
    expect(port.released, ['document-1']);
  });

  test('empty Environment never reads or writes files', () async {
    final unavailable = SourceDocuments(port, '');
    expect((await unavailable.display('main.dart'))['ok'], isFalse);
    expect(port.reads, isEmpty);
    expect((await documents.display(''))['ok'], isFalse);
    expect(port.reads, isEmpty);
  });
}

Map<String, dynamic> _file(String path, String text) => {
  'ok': true,
  'path': path,
  'text': text,
  'sizeBytes': utf8.encode(text).length,
  'revision': 'revision-0',
};

class _Port extends SourceDocumentPort {
  final records = <String, Map<String, dynamic>>{};
  final editors = <String, Map<String, dynamic>>{};
  final reads = <String>[];
  final released = <String>[];
  final replacements = <Map<String, String>>[];
  final confirmations = <String>[];
  final snapshots = <String, int>{};
  int allocated = 0;
  bool allowWrites = true;
  bool acceptDiscard = true;
  bool emptySnapshot = false;
  bool emptyState = false;
  Future<Map<String, dynamic>> Function(String path)? onRead;
  Future<bool> Function(String id)? onCreate;
  Future<Map<String, dynamic>> Function(String, String, String)? onReplace;
  Future<bool> Function(String message)? onConfirm;

  Map<String, dynamic> copy(Map<String, dynamic> data) =>
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

  void edit(String id, String text) {
    final editor = editors[id]!;
    editor['text'] = text;
    editor['revision'] = (editor['revision'] as int) + 1;
  }

  @override
  List<String> keys() => records.keys.toList();

  @override
  Map<String, dynamic> read(String id) => copy(records[id] ?? {});

  @override
  bool write(String id, Map<String, dynamic> data) {
    if (!allowWrites) return false;
    records[id] = copy(data);
    return true;
  }

  @override
  bool remove(String id) => records.remove(id) != null;

  @override
  String allocateId() => 'document-${++allocated}';

  @override
  Future<bool> createEditor(String id, String text, String language) async {
    if (editors.containsKey(id)) return false;
    if (onCreate != null && !await onCreate!(id)) return false;
    editors[id] = {
      'text': text,
      'revision': 0,
      'ready': true,
      'language': language,
      'readOnly': false,
    };
    return true;
  }

  @override
  Map<String, dynamic> editorState(String id) {
    if (emptyState) return {};
    final editor = editors[id];
    if (editor == null) return {};
    return {
      'revision': editor['revision'],
      'ready': editor['ready'],
      'language': editor['language'],
      'readOnly': false,
    };
  }

  @override
  Map<String, dynamic> snapshot(String id) {
    if (emptySnapshot) return {};
    snapshots[id] = (snapshots[id] ?? 0) + 1;
    final editor = editors[id];
    if (editor == null) return {};
    return {'text': editor['text'], 'revision': editor['revision']};
  }

  @override
  bool releaseEditor(String id) {
    released.add(id);
    return editors.remove(id) != null;
  }

  @override
  Future<Map<String, dynamic>> readFile(String path) async {
    reads.add(path);
    if (onRead != null) return onRead!(path);
    return _file(path, 'original');
  }

  @override
  Future<Map<String, dynamic>> replaceFile(
    String path,
    String text,
    String expectedRevision,
  ) async {
    replacements.add({
      'path': path,
      'text': text,
      'revision': expectedRevision,
    });
    if (onReplace != null) return onReplace!(path, text, expectedRevision);
    return {'ok': true, 'path': path, 'revision': 'revision-next'};
  }

  @override
  Future<bool> confirmDiscard(String message) async {
    confirmations.add(message);
    if (onConfirm != null) return onConfirm!(message);
    return acceptDiscard;
  }
}
