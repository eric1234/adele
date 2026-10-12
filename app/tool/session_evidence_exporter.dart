import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

final exportSessionEvidenceCommandId = CommandId(
  'dev.adele.session-evaluator.export-session-evidence',
);

/// Development-only native consumer; no presentation or execution contribution.
final class SessionEvidenceExporter {
  SessionEvidenceExporter({
    required this.runtime,
    required this.context,
    required this.navigatorKey,
  }) {
    _changes = runtime.plugins.changes.listen((_) => _reconcile());
    _reconcile();
  }

  final AdeleRuntime runtime;
  final WindowSessionContext context;
  final GlobalKey<NavigatorState> navigatorKey;
  late final StreamSubscription<ApplicationPluginState> _changes;
  InstalledBackendActivation? _backend;
  ExtensionRegistration? _registration;
  StreamController<void>? _availabilityChanges;
  void Function()? _detachBackend;
  DialogRoute<bool>? _confirmation;
  bool _pending = false;
  bool _closed = false;
  Future<void>? _writing;
  Future<void>? _closing;

  void _reconcile() {
    if (_closed || !context.isActive) return;
    InstalledBackendActivation? ready;
    try {
      final installation = runtime.plugins.catalog?.installations
          .where((item) => item.metadata.id == sessionEvaluatorPluginId)
          .singleOrNull;
      if (installation != null) {
        ready = runtime.plugins.backendForInstallation(installation);
      }
    } on Object {
      // A missing, failed, or retired evaluator never affects other plugins.
    }
    if (identical(ready, _backend)) return;
    _retireCommand();
    if (ready == null) return;
    final backend = _backend = ready;
    final changes = _availabilityChanges = StreamController<void>.broadcast();
    _detachBackend = backend.onRetire(_retireCommand);
    _registration = runtime.extensions.register(
      point: commandContributions,
      id: ExtensionId(exportSessionEvidenceCommandId.value),
      value: CommandContribution(
        id: exportSessionEvidenceCommandId,
        label: 'Export Session Evidence...',
        availability: () => _availability(backend),
        availabilityChanges: changes.stream,
        invoke: () => _export(backend, changes),
      ),
    );
  }

  CommandAvailability _availability(InstalledBackendActivation backend) {
    if (_closed || !context.isActive) return CommandAvailability.hidden;
    final session = context.snapshot.session;
    if (session == null) return CommandAvailability.hidden;
    try {
      backend.validate();
      if (!identical(runtime.store.session(session.id), session)) {
        return CommandAvailability.disabled;
      }
    } on Object {
      return CommandAvailability.hidden;
    }
    return _pending
        ? CommandAvailability.disabled
        : CommandAvailability.enabled;
  }

  void _retireCommand() {
    _detachBackend?.call();
    _detachBackend = null;
    _backend = null;
    final registration = _registration;
    _registration = null;
    if (registration != null) unawaited(registration.close());
    final changes = _availabilityChanges;
    _availabilityChanges = null;
    if (changes != null) unawaited(changes.close());
  }

  void _validateWindow() {
    if (_closed || !context.isActive) {
      throw StateError('The exporter is closed.');
    }
  }

  Future<void> _export(
    InstalledBackendActivation backend,
    StreamController<void> changes,
  ) async {
    // Capture both selection epoch and route synchronously at Command admission.
    _validateWindow();
    if (_pending) throw StateError('An export is already pending.');
    final snapshot = context.snapshot;
    final session = snapshot.session;
    if (session == null ||
        !identical(runtime.store.session(session.id), session)) {
      throw StateError('The selected Session is unavailable.');
    }
    final channel = backend.openPresentationChannel(
      backendServices: [sessionEvaluatorServiceId],
      validatePresentation: _validateWindow,
    );
    final client = SessionEvaluatorServiceClient(_EvidenceChannel(channel));
    _pending = true;
    changes.add(null);
    try {
      if (!await _confirm()) return;
      channel.validate();
      final destination = await getSaveLocation(
        suggestedName: 'session-evidence.json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON evidence', extensions: ['json']),
        ],
      );
      channel.validate();
      if (destination == null) return;
      final document = await readSessionEvidence(client, session.id.value);
      channel.validate();
      final bytes = utf8.encode(jsonEncode(document));
      if (bytes.length > sessionEvidenceMaxBytes) {
        throw const FormatException('Session evidence exceeds its byte bound.');
      }
      await (_writing = writeSessionEvidenceFile(
        File(destination.path),
        bytes,
        validate: channel.validate,
      ));
      _notify('Session evidence exported.');
    } on Object {
      _notify('Session evidence could not be exported.');
    } finally {
      _writing = null;
      _pending = false;
      if (!_closed && context.isActive && !changes.isClosed) changes.add(null);
    }
  }

  Future<bool> _confirm() async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return false;
    final route = DialogRoute<bool>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: const Text('Export Session Evidence'),
        content: const Text(
          'Evidence may contain conversation prompts and responses, source code '
          'and tool arguments, full command stdout/stderr that may include '
          'secrets, model usage and provider details, and other potentially '
          'sensitive development information. Continue only if you '
          'intend to save this information locally.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    _confirmation = route;
    try {
      return await navigator.push(route) == true;
    } finally {
      _confirmation = null;
    }
  }

  void _notify(String message) {
    if (_closed || !context.isActive) return;
    final ui = navigatorKey.currentContext;
    if (ui == null) return;
    ScaffoldMessenger.maybeOf(
      ui,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Fence immediately. Never join confirmation, picker, or collection futures.
  /// A submitted rename may finish, but no later phase or UI publication starts.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _retireCommand();
    final route = _confirmation;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    return _closing = Future.wait<void>([
      _changes.cancel(),
      if (_writing case final writing?)
        writing
            .catchError((Object _) {})
            .timeout(const Duration(seconds: 2), onTimeout: () {}),
    ]).then((_) {});
  }
}

final class _EvidenceChannel implements AdeleStreamChannel {
  const _EvidenceChannel(this.owner);
  final OwningBackendChannel owner;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      owner.request(sessionEvaluatorServiceId, method, payload);

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      owner.stream(sessionEvaluatorServiceId, method, payload);
}

/// Stage a complete bounded document beside its destination, then POSIX rename.
/// No delete-before-replace fallback, cross-volume copy, or durability guarantee.
Future<void> writeSessionEvidenceFile(
  File destination,
  List<int> bytes, {
  required void Function() validate,
}) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    throw UnsupportedError('Safe evidence replacement is unsupported.');
  }
  if (bytes.length > sessionEvidenceMaxBytes) {
    throw const FormatException('Session evidence exceeds its byte bound.');
  }
  Directory? staging;
  try {
    validate();
    staging = await destination.parent.createTemp('.adele-session-evidence-');
    validate();
    final file = File('${staging.path}/evidence.json');
    await file.writeAsBytes(bytes, flush: true);
    validate();
    await file.rename(destination.path);
  } finally {
    if (staging != null) {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // Best effort after failure or commit; never touch the destination here.
      }
    }
  }
}
