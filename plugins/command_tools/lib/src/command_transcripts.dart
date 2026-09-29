import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:command_tools_contract/command_tools_contract.dart';

import 'process_outcome.dart';

/// Plugin-owned SQL and observation. No output history is retained in RAM.
final class CommandTranscriptStore implements CommandOutputService {
  CommandTranscriptStore(this.storage);

  final ProjectStorageService storage;
  static const _access = ProjectStorageAccessMode.durableOrTemporary;
  static const int maximumBatchChunks = 4;
  static const int maximumBatchCodeUnits =
      maximumBatchChunks * commandOutputChunkCodeUnits;

  final _schemas = <String, Future<void>>{};
  final _writers = <(String, String, String), CommandCaptureWriter>{};
  final _failures =
      <
        (String, String, String),
        ({String message, String? termination, int? exitCode})
      >{};
  final _observers = <(String, String, String), Set<_CommandObserver>>{};
  bool _closed = false;

  int get activeCaptureCount => _writers.length;
  int get uncertainCaptureCount => _failures.length;
  int get observerCount =>
      _observers.values.fold(0, (n, set) => n + set.length);
  int get pendingBatchChunks =>
      _writers.values.fold(0, (n, w) => n + w.pendingChunks);

  void _requireOpen() {
    if (_closed) throw StateError('Command transcript backend is closed.');
  }

  Future<void> _schema(String sessionId) {
    _requireOpen();
    return _schemas.putIfAbsent(
      sessionId,
      () => storage.ensureSchemaForSession(sessionId, [_schemaSql], _access),
    );
  }

  Future<CommandCaptureWriter> begin({
    required ToolExecutionContext context,
    required String environmentId,
    required EnvironmentForegroundProcessRequest request,
  }) async {
    _requireOpen();
    final id = context.toolInvocationId;
    final key = (context.sessionId.value, context.runId.value, id);
    if (_writers.containsKey(key) || _failures.containsKey(key)) {
      throw StateError('This tool invocation already has an admitted capture.');
    }
    final writer = CommandCaptureWriter._(this, context);
    _writers[key] = writer;
    try {
      await _schema(context.sessionId.value);
      _requireOpen();
      final metadata = <String, Object?>{
        ':id': id,
        ':session': context.sessionId.value,
        ':run': context.runId.value,
        ':environment': environmentId,
        ':program': request.program,
        ':arguments': jsonEncode(request.arguments),
        ':directory': request.relativeWorkingDirectory,
        ':timeout': request.timeoutSeconds,
      };
      // Keep every accepted header individually readable under the host bound.
      if (utf8.encode(jsonEncode(metadata)).length > 128 * 1024) {
        throw ArgumentError('Command metadata exceeds 128 KiB encoded JSON.');
      }
      await storage.transactionForSession(context.sessionId.value, [
        RelationalStatement(
          sql: '''INSERT INTO adele_command_captures
            (invocation_id,session_id,run_id,environment_id,program,arguments_json,
             working_directory,timeout_seconds,state,version,high_water,total_code_units)
            VALUES (:id,:session,:run,:environment,:program,:arguments,:directory,
                    :timeout,'capturing',1,0,0)''',
          parameters: metadata,
          expectedRows: 1,
        ),
      ], _access);
      _requireOpen();
      writer._version = 1;
      _changed(key);
      return writer;
    } on Object {
      _writers.remove(key);
      // No producer was launched. A committed but unacknowledged header is
      // interrupted history; a rejected duplicate must not poison its old row.
      _changed(key);
      rethrow;
    }
  }

  @override
  Future<CommandCaptureState> getState(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) async {
    if (sessionId.isEmpty || runId.isEmpty || toolInvocationId.isEmpty) {
      throw _failure(
        'invalid_identity',
        'Command associations must be nonempty.',
      );
    }
    await _schema(sessionId);
    final key = (sessionId, runId, toolInvocationId);
    // The query may return an earlier committed snapshot after its writer has
    // sealed and detached. Do not reinterpret that snapshot as interrupted.
    final writerWasActive = _writers.containsKey(key);
    // Invocation IDs are Run-local. An absent exact key says nothing about
    // another Run that happens to use the same invocation string.
    final rows = await storage.queryForSession(
      sessionId,
      'SELECT * FROM adele_command_captures WHERE invocation_id=:id AND run_id=:run',
      {':id': toolInvocationId, ':run': runId},
      _access,
    );
    _requireOpen();
    if (rows.isEmpty) {
      return CommandCaptureState(
        sessionId: sessionId,
        runId: runId,
        toolInvocationId: toolInvocationId,
        state: 'absent',
        version: 0,
        highWater: 0,
        totalCodeUnits: 0,
        program: null,
        argumentsJson: null,
        workingDirectory: null,
        environmentId: null,
        timeoutSeconds: null,
        termination: null,
        exitCode: null,
        failure: null,
      );
    }
    final row = rows.single.values;
    if (row['session_id'] != sessionId || row['run_id'] != runId) {
      throw _failure(
        'association_mismatch',
        'The command belongs to another Session or Run.',
      );
    }
    final storedState = row['state'];
    if (!['capturing', 'complete', 'failed'].contains(storedState) ||
        row['high_water'] is! int ||
        (row['high_water']! as int) < 0 ||
        row['total_code_units'] is! int ||
        (row['total_code_units']! as int) < 0 ||
        row['version'] is! int ||
        (row['version']! as int) < 1 ||
        row['program'] is! String ||
        row['arguments_json'] is! String ||
        row['working_directory'] is! String ||
        row['environment_id'] is! String ||
        row['timeout_seconds'] is! int) {
      throw _failure('corrupt_capture', 'Invalid stored command header.');
    }
    try {
      final arguments = jsonDecode(row['arguments_json']! as String);
      if (arguments is! List<Object?> ||
          arguments.any((Object? value) => value is! String)) {
        throw const FormatException('Invalid stored argv.');
      }
      EnvironmentForegroundProcessRequest(
        program: row['program']! as String,
        arguments: List<String>.from(arguments),
        relativeWorkingDirectory: row['working_directory']! as String,
        timeoutSeconds: row['timeout_seconds']! as int,
      );
      final directory = row['working_directory']! as String;
      if ((row['high_water'] == 0) != (row['total_code_units'] == 0) ||
          (row['total_code_units']! as int) < (row['high_water']! as int) ||
          (row['total_code_units']! as int) >
              (row['high_water']! as int) * commandOutputChunkCodeUnits ||
          (row['environment_id']! as String).isEmpty ||
          (directory.isNotEmpty &&
              directory
                  .split('/')
                  .any(
                    (part) => part.isEmpty || part == '.' || part == '..',
                  )) ||
          parseCommandProcessOutcome(row['termination'], row['exit_code']) ==
              null ||
          (row['failure'] != null && row['failure'] is! String) ||
          (storedState == 'complete' &&
              (row['termination'] == null || row['failure'] != null)) ||
          (storedState == 'capturing' &&
              (row['termination'] != null ||
                  row['exit_code'] != null ||
                  row['failure'] != null)) ||
          (storedState == 'failed' &&
              (row['failure'] is! String ||
                  (row['failure']! as String).isEmpty))) {
        throw const FormatException(
          'Invalid stored capture outcome or extent.',
        );
      }
    } on Object {
      throw _failure(
        'corrupt_capture',
        'Invalid stored command metadata or outcome.',
      );
    }
    final liveFailure = _failures[key];
    final state = liveFailure != null
        ? 'failed'
        : storedState == 'capturing' &&
              !writerWasActive &&
              !_writers.containsKey(key)
        ? 'interrupted'
        : storedState! as String;
    return CommandCaptureState(
      sessionId: sessionId,
      runId: runId,
      toolInvocationId: toolInvocationId,
      state: state,
      version: row['version']! as int,
      highWater: row['high_water']! as int,
      totalCodeUnits: row['total_code_units']! as int,
      program: row['program']! as String,
      argumentsJson: row['arguments_json']! as String,
      workingDirectory: row['working_directory']! as String,
      environmentId: row['environment_id']! as String,
      timeoutSeconds: row['timeout_seconds']! as int,
      termination: liveFailure?.termination ?? row['termination'] as String?,
      exitCode: liveFailure?.exitCode ?? row['exit_code'] as int?,
      failure: liveFailure?.message ?? row['failure'] as String?,
    );
  }

  @override
  Future<CommandOutputPage> readAfter(
    String sessionId,
    String runId,
    String toolInvocationId,
    int afterCursor,
    int maxChunks,
    int maxCodeUnits,
  ) => _read(
    sessionId,
    runId,
    toolInvocationId,
    afterCursor,
    false,
    maxChunks,
    maxCodeUnits,
  );

  @override
  Future<CommandOutputPage> readBefore(
    String sessionId,
    String runId,
    String toolInvocationId,
    int? beforeCursor,
    int maxChunks,
    int maxCodeUnits,
  ) => _read(
    sessionId,
    runId,
    toolInvocationId,
    beforeCursor,
    true,
    maxChunks,
    maxCodeUnits,
  );

  Future<CommandOutputPage> _read(
    String sessionId,
    String runId,
    String id,
    int? cursor,
    bool backward,
    int maxChunks,
    int maxCodeUnits,
  ) async {
    if ((cursor != null && cursor < 0) ||
        maxChunks < 1 ||
        maxChunks > commandOutputPageChunks ||
        maxCodeUnits < commandOutputChunkCodeUnits ||
        maxCodeUnits > commandOutputPageCodeUnits) {
      throw _failure(
        'invalid_page',
        'Invalid command-output cursor or page bounds.',
      );
    }
    final state = await getState(sessionId, runId, id);
    if (state.state == 'absent') {
      return CommandOutputPage(state: state, chunks: []);
    }
    final limit = math.min(
      maxChunks,
      maxCodeUnits ~/ commandOutputChunkCodeUnits,
    );
    final rows = await storage.queryForSession(
      sessionId,
      '''SELECT position,stream,text FROM adele_command_chunks
         WHERE invocation_id=:id AND run_id=:run AND position ${backward ? '<' : '>'} :cursor
           AND position<=:highWater
         ORDER BY position ${backward ? 'DESC' : 'ASC'} LIMIT :limit''',
      {
        ':id': id,
        ':run': runId,
        ':cursor': cursor ?? state.highWater + 1,
        ':highWater': state.highWater,
        ':limit': limit,
      },
      _access,
    );
    _requireOpen();
    final chunks = <CommandOutputChunk>[];
    int? previous;
    for (final row in rows) {
      final position = row.values['position'];
      final stream = row.values['stream'];
      final text = row.values['text'];
      if (position is! int ||
          position < 1 ||
          position > state.highWater ||
          (previous != null && position != previous + (backward ? -1 : 1)) ||
          (stream != 'stdout' && stream != 'stderr') ||
          text is! String ||
          text.isEmpty ||
          text.length > commandOutputChunkCodeUnits) {
        throw _failure('corrupt_capture', 'Invalid stored command chunk.');
      }
      previous = position;
      chunks.add(
        CommandOutputChunk(
          cursor: position,
          stream: stream! as String,
          text: text,
        ),
      );
    }
    final expectedFirst = backward
        ? math.min((cursor ?? state.highWater + 1) - 1, state.highWater)
        : cursor! + 1;
    final expectedCount = expectedFirst < 1 || expectedFirst > state.highWater
        ? 0
        : math.min(
            limit,
            backward ? expectedFirst : state.highWater - expectedFirst + 1,
          );
    if ((expectedFirst >= 1 && expectedFirst <= state.highWater) &&
        (chunks.length != expectedCount ||
            chunks.first.cursor != expectedFirst)) {
      throw _failure('corrupt_capture', 'Committed output contains a gap.');
    }
    return CommandOutputPage(
      state: state,
      chunks: backward ? chunks.reversed.toList() : chunks,
    );
  }

  @override
  Stream<CommandCaptureState> watch(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) {
    late final _CommandObserver observer;
    late final StreamController<CommandCaptureState> controller;
    controller = StreamController<CommandCaptureState>(
      onListen: () {
        observer = _CommandObserver(
          this,
          controller,
          sessionId,
          runId,
          toolInvocationId,
        );
        if (_closed) {
          controller.addError(
            StateError('Command transcript backend is closed.'),
          );
          unawaited(controller.close());
          return;
        }
        // Register before reading so admission racing an absent snapshot leaves
        // the observer dirty and delivers the newly committed state.
        (_observers[(sessionId, runId, toolInvocationId)] ??= {}).add(observer);
        observer.changed();
      },
      onPause: () => observer.paused = true,
      onResume: () {
        observer.paused = false;
        observer.changed();
      },
      onCancel: () => observer.close(),
    );
    return controller.stream;
  }

  void _changed((String, String, String) key) {
    for (final observer in _observers[key]?.toList() ?? <_CommandObserver>[]) {
      observer.changed();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final observers in _observers.values.toList()) {
      for (final observer in observers.toList()) {
        observer.close();
        // A paused observer must not hold backend shutdown hostage.
        unawaited(observer.controller.close());
      }
    }
    final writers = _writers.values.toList();
    _writers.clear();
    _failures.clear();
    _schemas.clear();
    await Future.wait(
      writers.map((writer) async {
        await writer.cancelProducer?.call();
      }),
    );
  }
}

/// Exactly one writer is admitted for the existing host invocation. Every append
/// awaits one bounded transaction; no timer, queued Future chain, or cache exists.
final class CommandCaptureWriter {
  CommandCaptureWriter._(this._store, this.context);
  final CommandTranscriptStore _store;
  final ToolExecutionContext context;
  (String, String, String) get _key =>
      (context.sessionId.value, context.runId.value, context.toolInvocationId);
  Future<void> Function()? cancelProducer;
  int _version = 0;
  int _highWater = 0;
  int _totalCodeUnits = 0;
  int pendingChunks = 0;
  bool _finished = false;
  bool _writing = false;

  Future<void> append(EnvironmentProcessOutput output) async {
    if (_finished || _writing) {
      throw StateError('Capture writer is not available.');
    }
    _store._requireOpen();
    _writing = true;
    try {
      int offset = 0;
      while (offset < output.text.length) {
        final chunks = <String>[];
        int units = 0;
        while (offset < output.text.length &&
            chunks.length < CommandTranscriptStore.maximumBatchChunks) {
          int end = math.min(
            offset + commandOutputChunkCodeUnits,
            output.text.length,
          );
          if (end < output.text.length &&
              output.text.codeUnitAt(end - 1) >= 0xd800 &&
              output.text.codeUnitAt(end - 1) <= 0xdbff) {
            end--;
          }
          final text = output.text.substring(offset, end);
          chunks.add(text);
          units += text.length;
          offset = end;
        }
        pendingChunks = chunks.length;
        final statements = <RelationalStatement>[
          RelationalStatement(
            sql: '''UPDATE adele_command_captures SET high_water=:next,
              total_code_units=:units,version=version+1
              WHERE invocation_id=:id AND run_id=:run AND state='capturing'
                AND high_water=:prior AND version=:version''',
            parameters: {
              ':next': _highWater + chunks.length,
              ':units': _totalCodeUnits + units,
              ':id': context.toolInvocationId,
              ':run': context.runId.value,
              ':prior': _highWater,
              ':version': _version,
            },
            expectedRows: 1,
          ),
          for (int i = 0; i < chunks.length; i++)
            RelationalStatement(
              sql:
                  'INSERT INTO adele_command_chunks (invocation_id,run_id,position,stream,text) VALUES (:id,:run,:position,:stream,:text)',
              parameters: {
                ':id': context.toolInvocationId,
                ':run': context.runId.value,
                ':position': _highWater + i + 1,
                ':stream': output.stream.name,
                ':text': chunks[i],
              },
              expectedRows: 1,
            ),
        ];
        await _store.storage.transactionForSession(
          context.sessionId.value,
          statements,
          CommandTranscriptStore._access,
        );
        _highWater += chunks.length;
        _totalCodeUnits += units;
        _version++;
        pendingChunks = 0;
        _store._changed(_key);
        _store._requireOpen();
      }
    } finally {
      pendingChunks = 0;
      _writing = false;
    }
  }

  Future<void> seal(EnvironmentProcessCompleted completed) async {
    if (_finished || _writing) {
      throw StateError('Capture writer is not available.');
    }
    _store._requireOpen();
    final complete = !completed.stdoutTruncated && !completed.stderrTruncated;
    await _finish(
      complete ? 'complete' : 'failed',
      completed.termination.name,
      completed.exitCode,
      complete ? null : 'The provider reported incomplete output.',
    );
    _finished = true;
    _store._writers.remove(_key);
    _store._changed(_key);
  }

  Future<void> fail(
    String message, {
    String? termination,
    int? exitCode,
  }) async {
    if (_finished) return;
    final outcome = parseCommandProcessOutcome(termination, exitCode);
    _finished = true;
    final bounded = message.length <= 1024
        ? message
        : message.substring(0, 1024);
    if (!_store._closed) {
      _store._failures[_key] = (
        message: bounded,
        termination: outcome?.termination,
        exitCode: outcome?.exitCode,
      );
    }
    try {
      _store._requireOpen();
      // One best-effort marker, conditional on our last acknowledged extent.
      // An uncertain committed append cannot be overwritten or retried here.
      await _finish('failed', outcome?.termination, outcome?.exitCode, bounded);
      _store._failures.remove(_key);
    } on Object {
      // Live failure remains visible; reopened capturing rows are interrupted.
    } finally {
      _store._writers.remove(_key);
      _store._changed(_key);
    }
  }

  Future<void> _finish(
    String state,
    String? termination,
    int? exitCode,
    String? failure,
  ) async {
    await _store.storage.transactionForSession(context.sessionId.value, [
      RelationalStatement(
        sql:
            '''UPDATE adele_command_captures SET state=:state,termination=:termination,
          exit_code=:exitCode,failure=:failure,version=version+1
          WHERE invocation_id=:id AND run_id=:run AND state='capturing'
            AND high_water=:prior AND version=:version''',
        parameters: {
          ':state': state,
          ':termination': termination,
          ':exitCode': exitCode,
          ':failure': failure,
          ':id': context.toolInvocationId,
          ':run': context.runId.value,
          ':prior': _highWater,
          ':version': _version,
        },
        expectedRows: 1,
      ),
    ], CommandTranscriptStore._access);
    _version++;
  }
}

final class _CommandObserver {
  _CommandObserver(
    this.store,
    this.controller,
    this.session,
    this.run,
    this.id,
  );
  final CommandTranscriptStore store;
  final StreamController<CommandCaptureState> controller;
  final String session;
  final String run;
  final String id;
  bool paused = false;
  bool closed = false;
  bool reading = false;
  bool dirty = false;

  void changed() {
    dirty = true;
    if (!reading && !paused && !closed) unawaited(_read());
  }

  Future<void> _read() async {
    reading = true;
    try {
      while (dirty && !paused && !closed) {
        dirty = false;
        final state = await store.getState(session, run, id);
        if (closed) return;
        if (paused) {
          dirty = true;
          return;
        }
        controller.add(state);
        // Yield to the subscriber's pause before admitting another snapshot.
        await Future<void>.delayed(Duration.zero);
      }
    } on Object catch (error, stack) {
      if (!closed) {
        controller.addError(error, stack);
        close();
        unawaited(controller.close());
      }
    } finally {
      reading = false;
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    final key = (session, run, id);
    final observers = store._observers[key];
    observers?.remove(this);
    if (observers?.isEmpty ?? false) store._observers.remove(key);
  }
}

CommandOutputFailure _failure(String code, String message) =>
    CommandOutputFailure(code: code, message: message, details: const {});

const _schemaSql = '''
CREATE TABLE adele_command_captures (
  invocation_id TEXT NOT NULL,
  session_id TEXT NOT NULL REFERENCES adele_product_sessions(id),
  run_id TEXT NOT NULL,
  environment_id TEXT NOT NULL,
  program TEXT NOT NULL,
  arguments_json TEXT NOT NULL,
  working_directory TEXT NOT NULL,
  timeout_seconds INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('capturing','complete','failed')),
  version INTEGER NOT NULL CHECK (version>=1),
  high_water INTEGER NOT NULL CHECK (high_water>=0),
  total_code_units INTEGER NOT NULL CHECK (total_code_units>=0),
  termination TEXT,
  exit_code INTEGER,
  failure TEXT,
  PRIMARY KEY (invocation_id,run_id)
);
CREATE TABLE adele_command_chunks (
  invocation_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  position INTEGER NOT NULL CHECK (position>=1),
  stream TEXT NOT NULL CHECK (stream IN ('stdout','stderr')),
  text TEXT NOT NULL,
  PRIMARY KEY (invocation_id,run_id,position),
  FOREIGN KEY (invocation_id,run_id) REFERENCES adele_command_captures(invocation_id,run_id)
);
''';
