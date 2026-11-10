import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import 'session_evaluation_handoff.dart';
import 'session_evaluation_handoff_writer.dart';
import 'session_evaluation_summary.dart';
import 'session_evidence_collector.dart';

/// One effectful preparation at a time per backend generation. The output-root
/// resolver is a construction boundary, never caller-controlled service input.
final class SessionEvaluationHandoffServiceImpl
    implements SessionEvaluationHandoffService {
  SessionEvaluationHandoffServiceImpl(this.storage, {required this.outputRoot});

  final ProjectStorageService storage;
  final Future<Directory> Function() outputRoot;
  _Preparation? _active;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Stream<String> prepareSession(String sessionId) {
    final operation = _Preparation();
    operation.controller = StreamController<String>(
      onListen: () {
        if (_closed || _active != null) {
          operation.controller.addError(_failure);
          operation.finished.complete();
          operation.ending = true;
          unawaited(operation.controller.close());
          return;
        }
        _active = operation;
        unawaited(_prepare(operation, sessionId));
      },
      onCancel: () {
        // onCancel also runs on normal EOF. Never wait for controller.close()
        // from the worker: cancellation itself joins that worker's cleanup.
        if (!operation.ending) operation.cancelled = true;
        return operation.finished.future;
      },
    );
    return operation.controller.stream;
  }

  Future<void> _prepare(_Preparation operation, String sessionId) async {
    Directory? destination;
    var published = false;
    void validate() {
      if (_closed || operation.cancelled) throw _failure;
    }

    try {
      validate();
      final guardedStorage = _ReadStorage(storage, validate);
      final document = await readSessionEvidence(
        SessionEvidenceCollector(guardedStorage),
        sessionId,
      );
      validate();
      final handoff = await SessionEvaluationHandoff.capture(
        guardedStorage,
        document,
      );
      validate();
      final bytes = utf8.encode(jsonEncode(document));
      final summaryBytes = utf8.encode(
        jsonEncode(summarizeSessionEvidence(document)),
      );
      final root = await outputRoot();
      validate();
      destination = await writeSessionEvaluationHandoff(
        root,
        bytes,
        summaryBytes: summaryBytes,
        readme: handoff.readme(DateTime.now().toUtc()),
        validate: validate,
        excludedDirectories: [
          if (handoff.project.sourceLocation.scheme == 'file')
            Directory.fromUri(handoff.project.sourceLocation),
          if (handoff.worktreeRoot case final path?) Directory(path),
        ],
      );
      // A cancellation may win after the writer returns but before this
      // continuation. Settle queued local cancellation before the final fence.
      await Future<void>.value();
      validate();
      final readme = File.fromUri(destination.uri.resolve('README.md'));
      operation.controller.add(readme.absolute.path);
      published = true;
    } on Object {
      if (!operation.cancelled) operation.controller.addError(_failure);
    } finally {
      if (!published && destination != null) {
        try {
          await destination.delete(recursive: true);
        } on Object {
          // As with partial writes, cleanup is best effort; never publish.
        }
      }
      _active = null;
      operation.ending = true;
      operation.finished.complete();
      unawaited(operation.controller.close());
    }
  }

  /// Fence synchronously, then drain the admitted worker and its cleanup.
  /// Close reverse host calls after invoking this, before awaiting its result.
  Future<void> close() {
    _closed = true;
    _active?.cancelled = true;
    return _closing ??= _active?.finished.future ?? Future<void>.value();
  }
}

const _failure = SessionEvidenceFailure(
  code: 'handoff_unavailable',
  message: 'Evaluation handoff could not be prepared.',
);

final class _Preparation {
  late final StreamController<String> controller;
  final finished = Completer<void>();
  bool cancelled = false;
  bool ending = false;
}

/// Keeps the unchanged evidence collector and provenance reader read-only while
/// preventing another storage call after cancellation of this preparation.
final class _ReadStorage implements ProjectStorageService {
  const _ReadStorage(this.delegate, this.validate);
  final ProjectStorageService delegate;
  final void Function() validate;

  @override
  Future<bool> isDurableSession(String sessionId) async {
    validate();
    final result = await delegate.isDurableSession(sessionId);
    validate();
    return result;
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    validate();
    final result = await delegate.queryForSession(
      sessionId,
      sql,
      parameters,
      accessMode,
    );
    validate();
    return result;
  }

  @override
  Future<List<RelationalRow>> queryForEnvironment(
    String environmentId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    validate();
    final result = await delegate.queryForEnvironment(
      environmentId,
      sql,
      parameters,
      accessMode,
    );
    validate();
    return result;
  }

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Evaluation handoffs are read-only.');

  @override
  Future<void> ensureSchemaForEnvironment(
    String environmentId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Evaluation handoffs are read-only.');

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Evaluation handoffs are read-only.');

  @override
  Future<void> transactionForEnvironment(
    String environmentId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Evaluation handoffs are read-only.');
}
