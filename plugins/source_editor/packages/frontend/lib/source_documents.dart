/// The public contribution bridge's data/resource operations, injected for policy
/// tests. No port grants a caller-selected Environment or an editor controller.
abstract class SourceDocumentPort {
  List<String> keys();
  Map<String, dynamic> read(String id);
  bool write(String id, Map<String, dynamic> data);
  bool remove(String id);
  String allocateId();
  Future<bool> createEditor(String id, String text, String language);

  /// Unavailable native access returns an empty map, matching the public bridge.
  Map<String, dynamic> editorState(String id);
  Map<String, dynamic> snapshot(String id);
  bool releaseEditor(String id);
  Future<Map<String, dynamic>> readFile(String path);
  Future<Map<String, dynamic>> replaceFile(
    String path,
    String text,
    String expectedRevision,
  );
  Future<bool> confirmDiscard(String message);
}

Map<String, dynamic> sourceFailure(String code, String message) =>
    <String, dynamic>{
      'ok': false,
      'failure': <String, dynamic>{
        'code': code,
        'message': message,
        'details': <String, dynamic>{},
      },
    };

String sourceFailureText(dynamic result) {
  final failure = result['failure'];
  if (failure == null) {
    final message = result['message'];
    if (message is String) return message;
    return 'Source operation is unavailable.';
  }
  final code = failure['code'];
  final message = failure['message'];
  return '$code: $message';
}

String sourceLanguage(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.dart')) return 'dart';
  if (lower.endsWith('.json')) return 'json';
  if (lower.endsWith('.py')) return 'python';
  return 'plain';
}

String sourceTitle(dynamic data) {
  final path = data['path'] as String;
  var title = '';
  if (data['dirty'] == true) title = '* ';
  for (var index = 0; index < path.length; index++) {
    final code = path.codeUnitAt(index);
    var character = path[index];
    if (code < 32 ||
        (code >= 127 && code <= 159) ||
        (code >= 8232 && code <= 8238) ||
        (code >= 8294 && code <= 8297)) {
      final hex = code.toRadixString(16).padLeft(4, '0');
      character = '\\u$hex';
    }
    if (title.length + character.length > 160) {
      if (title.length > 157) title = title.substring(0, 157);
      return '$title...';
    }
    title = '$title$character';
  }
  if (title.trim().isEmpty) return 'Source file';
  return title;
}

/// All durable-for-this-window policy lives in copied contribution records, not
/// this short-lived object or an evaluator's globals.
class SourceDocuments {
  SourceDocuments(this.port, this.environmentKey);

  final SourceDocumentPort port;
  final String environmentKey;

  Map<String, dynamic> document(String id) {
    final data = port.read(id);
    if (data['kind'] != 'source') return <String, dynamic>{};
    return data;
  }

  List<Map<String, dynamic>> documents(bool allEnvironments) {
    final records = <Map<String, dynamic>>[];
    for (final id in port.keys()) {
      final data = document(id);
      if (data.isNotEmpty &&
          (allEnvironments || data['environmentKey'] == environmentKey)) {
        final order = data['order'] as int;
        var position = 0;
        // Avoid the evaluator's boxed-list early-exit path.
        for (final existing in records) {
          final existingOrder = existing['order'] as int;
          if (existingOrder <= order) position++;
        }
        records.insert(position, data);
      }
    }
    return records;
  }

  String existingId(String path) {
    for (final data in documents(false)) {
      if (data['path'] == path) return data['id'] as String;
    }
    return '';
  }

  Map<String, dynamic> displayResult(String id) => <String, dynamic>{
    'ok': true,
    'id': id,
    'focus': id,
  };

  Future<Map<String, dynamic>> display(String path) async {
    if (environmentKey.isEmpty) {
      return sourceFailure(
        'environment_unavailable',
        'No captured Environment.',
      );
    }
    if (path.isEmpty) {
      return sourceFailure(
        'invalid_path',
        'Enter an existing relative file path.',
      );
    }
    var existing = existingId(path);
    if (existing.isNotEmpty) return displayResult(existing);
    final file = await port.readFile(path);
    if (file['ok'] != true) return file;
    final normalizedPath = file['path'] as String;
    existing = existingId(normalizedPath);
    if (existing.isNotEmpty) return displayResult(existing);

    final id = port.allocateId();
    final text = file['text'] as String;
    final language = sourceLanguage(normalizedPath);
    final created = await port.createEditor(id, text, language);
    if (!created) {
      return sourceFailure(
        'editor_unavailable',
        'The native editor did not open.',
      );
    }
    // Native initialization yields. Another admitted display may have won while
    // this provisional editor was being created; never replace the winning text.
    existing = existingId(normalizedPath);
    if (existing.isNotEmpty) {
      port.releaseEditor(id);
      return displayResult(existing);
    }
    var order = 0;
    for (final data in documents(true)) {
      final previousOrder = data['order'] as int;
      if (previousOrder >= order) order = previousOrder + 1;
    }
    final state = port.editorState(id);
    if (state['ready'] != true) {
      port.releaseEditor(id);
      return sourceFailure(
        'editor_unavailable',
        'The native editor is not ready.',
      );
    }
    final record = <String, dynamic>{
      'kind': 'source',
      'id': id,
      'environmentKey': environmentKey,
      'path': normalizedPath,
      'language': language,
      'order': order,
      'baseline': text,
      'providerRevision': file['revision'],
      'checkedRevision': state['revision'],
      'dirty': false,
      'saving': false,
      'closing': false,
      'conflict': false,
      'failure': <String, dynamic>{},
    };
    if (!port.write(id, record)) {
      port.releaseEditor(id);
      return sourceFailure('retired', 'Source Editor is no longer available.');
    }
    return displayResult(id);
  }

  bool belongsHere(dynamic data) =>
      environmentKey.isNotEmpty && data['environmentKey'] == environmentKey;

  Map<String, dynamic> unavailable() => sourceFailure(
    'document_unavailable',
    'This Source Document is not in the captured Environment.',
  );

  Map<String, dynamic> busy() => sourceFailure(
    'document_busy',
    'Wait for the pending Save or Close operation, then try again.',
  );

  /// A snapshot is a deliberate text comparison. Component notification counters
  /// only invalidate that observation; they never establish text equality.
  void observeSnapshot(String id, dynamic snapshot) {
    final data = document(id);
    if (data.isEmpty || snapshot['text'] is! String) return;
    final dirty = snapshot['text'] != data['baseline'];
    final revision = snapshot['revision'];
    if (data['dirty'] == dirty && data['checkedRevision'] == revision) return;
    data['dirty'] = dirty;
    data['checkedRevision'] = revision;
    port.write(id, data);
  }

  void invalidate(String id, dynamic state) {
    final data = document(id);
    if (data.isEmpty || data['dirty'] == true) return;
    if (state['ready'] != true ||
        state['revision'] != data['checkedRevision']) {
      data['dirty'] = true;
      port.write(id, data);
    }
  }

  Map<String, dynamic> takeSnapshot(String id) {
    final state = port.editorState(id);
    if (state['ready'] != true) return <String, dynamic>{};
    return port.snapshot(id);
  }

  Map<String, dynamic> snapshotFailure() => sourceFailure(
    'editor_unavailable',
    'The native text could not be inspected. The document has been retained.',
  );

  Future<Map<String, dynamic>> save(String id) async {
    final data = document(id);
    if (!belongsHere(data)) return unavailable();
    if (data['saving'] == true || data['closing'] == true) return busy();
    // Acquire the per-document flight before the first await, across evaluators.
    data['saving'] = true;
    if (!port.write(id, data)) return unavailable();
    final snapshot = takeSnapshot(id);
    if (snapshot['text'] is! String) {
      final failure = snapshotFailure();
      data['saving'] = false;
      data['failure'] = failure['failure'];
      port.write(id, data);
      return failure;
    }
    final text = snapshot['text'] as String;
    final expectedRevision = data['providerRevision'] as String;
    final path = data['path'] as String;
    final result = await port.replaceFile(path, text, expectedRevision);
    final current = document(id);
    if (current.isEmpty) return result;
    current['saving'] = false;
    if (result['ok'] == true) {
      current['baseline'] = text;
      current['providerRevision'] = result['revision'];
      current['checkedRevision'] = snapshot['revision'];
      final state = port.editorState(id);
      current['dirty'] =
          state['ready'] != true || state['revision'] != snapshot['revision'];
      current['conflict'] = false;
      current['failure'] = <String, dynamic>{};
    } else {
      // Failure is not proof of rollback. Keep the prior opaque file revision
      // and baseline, expose the provider's structured facts, and never retry.
      final failure = result['failure'];
      current['failure'] = failure;
      if (failure['code'] == 'revision_conflict') current['conflict'] = true;
      current['checkedRevision'] = snapshot['revision'];
      final state = port.editorState(id);
      current['dirty'] =
          text != current['baseline'] ||
          state['ready'] != true ||
          state['revision'] != snapshot['revision'];
    }
    port.write(id, current);
    return result;
  }

  Future<Map<String, dynamic>> close(String id) async {
    var data = document(id);
    if (!belongsHere(data)) return unavailable();
    if (data['saving'] == true || data['closing'] == true) return busy();
    final snapshot = takeSnapshot(id);
    if (snapshot['text'] is! String) return snapshotFailure();
    observeSnapshot(id, snapshot);
    if (snapshot['text'] != data['baseline']) {
      data = document(id);
      data['closing'] = true;
      if (!port.write(id, data)) return unavailable();
      final path = data['path'];
      final accepted = await port.confirmDiscard(
        'Discard unsaved changes to $path and close this Source Document? '
        'Reopen the path to read the current file.',
      );
      data = document(id);
      if (data.isEmpty) return unavailable();
      data['closing'] = false;
      port.write(id, data);
      if (!accepted) {
        return sourceFailure('cancelled', 'The Source Document is still open.');
      }
      if (data['saving'] == true) return busy();
      final latest = takeSnapshot(id);
      if (latest['text'] is! String) return snapshotFailure();
      if (latest['text'] != snapshot['text']) {
        return sourceFailure(
          'document_changed',
          'Text changed during confirmation. Review it and close again.',
        );
      }
    }
    if (!port.releaseEditor(id)) return snapshotFailure();
    port.remove(id);
    return <String, dynamic>{'ok': true, 'id': id};
  }

  Future<Map<String, dynamic>> exit() async {
    final records = documents(true);
    final inspected = <String, dynamic>{};
    final changed = <String>[];
    for (final data in records) {
      if (data['saving'] == true || data['closing'] == true) {
        final result = busy();
        result['accepted'] = false;
        return result;
      }
      final id = data['id'] as String;
      final snapshot = takeSnapshot(id);
      if (snapshot['text'] is! String) {
        final result = snapshotFailure();
        result['accepted'] = false;
        return result;
      }
      observeSnapshot(id, snapshot);
      inspected[id] = snapshot['text'];
      if (snapshot['text'] != data['baseline']) {
        final path = data['path'];
        final environment = data['environmentKey'];
        changed.add('$path ($environment)');
      }
    }
    if (changed.isNotEmpty) {
      final count = changed.length;
      final paths = changed.join('\n');
      final accepted = await port.confirmDiscard(
        'Discard unsaved changes in $count Source Document(s) and exit?\n$paths',
      );
      if (!accepted) return <String, dynamic>{'accepted': false};
      final current = documents(true);
      if (current.length != records.length) {
        return <String, dynamic>{'accepted': false};
      }
      for (final data in current) {
        if (data['saving'] == true || data['closing'] == true) {
          return <String, dynamic>{'accepted': false};
        }
        final id = data['id'] as String;
        final snapshot = takeSnapshot(id);
        if (snapshot['text'] is! String ||
            !inspected.containsKey(id) ||
            snapshot['text'] != inspected[id]) {
          return <String, dynamic>{'accepted': false};
        }
      }
    }
    // Acceptance is advice only. The host owns final shutdown, which may still
    // be cancelled by another contribution; do not dispose or erase anything.
    return <String, dynamic>{'accepted': true};
  }

  bool move(String id, int direction) {
    final records = documents(false);
    for (var index = 0; index < records.length; index++) {
      final data = records[index];
      if (data['id'] == id) {
        final target = index + direction;
        if (target < 0 || target >= records.length) return false;
        final other = records[target];
        final order = data['order'];
        data['order'] = other['order'];
        other['order'] = order;
        if (!port.write(id, data)) return false;
        final otherId = other['id'] as String;
        return port.write(otherId, other);
      }
    }
    return false;
  }
}
