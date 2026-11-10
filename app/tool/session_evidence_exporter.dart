import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  StreamIterator<String>? _preparing;
  Future<void>? _cancelling;
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
        label: 'Prepare Evaluation Handoff...',
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
    unawaited(_cancelPreparation());
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

  Future<void> _cancelPreparation() {
    final preparing = _preparing;
    if (preparing == null) return Future<void>.value();
    // StreamIterator drops its subscription on the first cancel. Retain that
    // cancellation future so retirement, close and finally join the same work.
    return _cancelling ??= preparing.cancel().catchError((Object _) {});
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
      backendServices: [sessionEvaluationHandoffServiceId],
      validatePresentation: _validateWindow,
    );
    final client = SessionEvaluationHandoffServiceClient(
      _HandoffChannel(channel),
    );
    _pending = true;
    changes.add(null);
    try {
      if (!await _confirm()) return;
      channel.validate();
      final completion = _preparing = StreamIterator(
        client.prepareSession(session.id.value),
      );
      final readmePath = await readSessionEvaluationHandoff(completion);
      channel.validate();
      _notify(
        'Evaluation handoff ready: ${File(readmePath).parent.path}',
        action: SnackBarAction(
          label: 'Copy README path',
          onPressed: () async {
            if (_closed || !context.isActive) return;
            try {
              await Clipboard.setData(ClipboardData(text: readmePath));
            } on Object {
              _notify('The handoff path could not be copied.');
            }
          },
        ),
      );
    } on Object {
      _notify('Evaluation handoff could not be prepared.');
    } finally {
      await _cancelPreparation();
      _preparing = null;
      _cancelling = null;
      _pending = false;
      final availability = _availabilityChanges;
      if (!_closed &&
          context.isActive &&
          availability != null &&
          !availability.isClosed) {
        availability.add(null);
      }
    }
  }

  Future<bool> _confirm() async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return false;
    final route = DialogRoute<bool>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: const Text('Prepare Evaluation Handoff'),
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

  void _notify(String message, {SnackBarAction? action}) {
    if (_closed || !context.isActive) return;
    final ui = navigatorKey.currentContext;
    if (ui == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ui);
    messenger?.removeCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: SelectableText(message),
        action: action,
        showCloseIcon: action != null,
        duration: action == null
            ? const Duration(seconds: 4)
            : const Duration(days: 1),
      ),
    );
  }

  /// Fence UI immediately and cancel only this captured handoff observation.
  /// Backend cancellation owns best-effort cleanup of unpublished output.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _retireCommand();
    final route = _confirmation;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    return _closing = Future.wait<void>([
      _changes.cancel(),
      if (_cancelling case final cancelling?)
        cancelling.timeout(const Duration(seconds: 2), onTimeout: () {}),
    ]).then((_) {});
  }
}

final class _HandoffChannel implements AdeleStreamChannel {
  const _HandoffChannel(this.owner);
  final OwningBackendChannel owner;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      owner.request(sessionEvaluationHandoffServiceId, method, payload);

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      owner.stream(sessionEvaluationHandoffServiceId, method, payload);
}
