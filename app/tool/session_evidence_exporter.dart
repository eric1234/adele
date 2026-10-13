import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import 'session_evaluation_handoff.dart';

final exportSessionEvidenceCommandId = CommandId(
  'dev.adele.session-evaluator.export-session-evidence',
);

/// Development-only native consumer; no presentation or execution contribution.
final class SessionEvidenceExporter {
  SessionEvidenceExporter({
    required this.runtime,
    required this.context,
    required this.navigatorKey,
    this.outputRoot,
  }) {
    _changes = runtime.plugins.changes.listen((_) => _reconcile());
    _reconcile();
  }

  final AdeleRuntime runtime;
  final WindowSessionContext context;
  final GlobalKey<NavigatorState> navigatorKey;
  final Directory? outputRoot;
  late final StreamSubscription<ApplicationPluginState> _changes;
  InstalledBackendActivation? _backend;
  ExtensionRegistration? _registration;
  StreamController<void>? _availabilityChanges;
  void Function()? _detachBackend;
  DialogRoute<bool>? _confirmation;
  bool _pending = false;
  bool _closed = false;
  Future<Directory>? _writing;
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
      final handoff = SessionEvaluationHandoff.capture(runtime.store, session);
      final document = await readSessionEvidence(client, session.id.value);
      channel.validate();
      final bytes = utf8.encode(jsonEncode(document));
      if (bytes.length > sessionEvidenceMaxBytes) {
        throw const FormatException('Session evidence exceeds its byte bound.');
      }
      var root = outputRoot;
      if (root == null) {
        final roots = PlatformStorageRoots.resolve(
          operatingSystem: Platform.operatingSystem,
          environment: Platform.environment,
        );
        root = Directory(
          '${roots.localStateRoot}${Platform.pathSeparator}evaluations',
        );
      }
      final destination = await (_writing = writeSessionEvaluationHandoff(
        root,
        bytes,
        readme: handoff.readme(DateTime.now().toUtc()),
        validate: channel.validate,
        excludedDirectories: [
          if (handoff.project.sourceLocation.scheme == 'file')
            Directory.fromUri(handoff.project.sourceLocation),
          if (handoff.worktreeRoot case final path?) Directory(path),
        ],
      ));
      channel.validate();
      _notify(
        'Evaluation handoff ready: ${destination.path}',
        action: SnackBarAction(
          label: 'Copy path',
          onPressed: () async {
            if (_closed || !context.isActive) return;
            try {
              await Clipboard.setData(ClipboardData(text: destination.path));
            } on Object {
              _notify('The handoff path could not be copied.');
            }
          },
        ),
      );
    } on Object {
      _notify('Evaluation handoff could not be prepared.');
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

  /// Fence immediately. Never join confirmation or collection futures.
  /// A submitted write may finish, but no later phase or UI publication starts.
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
            .then<void>((_) {}, onError: (Object _) {})
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

/// Write only to a newly allocated private directory, never a previous handoff.
/// Failure cleanup is best effort, not crash recovery or power-loss durability.
Future<Directory> writeSessionEvaluationHandoff(
  Directory outputRoot,
  List<int> bytes, {
  required String readme,
  required void Function() validate,
  required Iterable<Directory> excludedDirectories,
}) async {
  if (bytes.length > sessionEvidenceMaxBytes) {
    throw const FormatException('Session evidence exceeds its byte bound.');
  }
  final excluded = excludedDirectories
      .map((directory) => Directory(_resolvedOutputPath(directory)))
      .toList();
  void validateLocation(Directory directory) {
    final path = _resolvedOutputPath(directory);
    // Reject any enclosing checkout, not just a selected nested source scope.
    var ancestor = Directory(path);
    while (true) {
      if (FileSystemEntity.typeSync(
            '${ancestor.path}${Platform.pathSeparator}.git',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw StateError('Evaluation output must be outside source checkouts.');
      }
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) break;
      ancestor = parent;
    }
    final segments = Directory(path).uri.pathSegments;
    if (excluded.any(
          (root) =>
              path == root.path ||
              path.startsWith(
                root.path.endsWith(Platform.pathSeparator)
                    ? root.path
                    : '${root.path}${Platform.pathSeparator}',
              ),
        ) ||
        List.generate(segments.length - 1, (index) => index).any(
          (index) =>
              segments[index] == '.adele' && segments[index + 1] == 'worktrees',
        )) {
      throw StateError('Evaluation output must be outside source checkouts.');
    }
    validate();
  }

  Directory? destination;
  var complete = false;
  try {
    validateLocation(outputRoot);
    final root = Directory(_resolvedOutputPath(outputRoot));
    await root.create(recursive: true);
    validateLocation(root);
    destination = await root.createTemp('session-');
    validateLocation(destination);
    if (Platform.isLinux || Platform.isMacOS) {
      // Dart's createTemp uses the umask, not necessarily owner-only access.
      final permissions = await Process.run('chmod', ['700', destination.path]);
      if (permissions.exitCode != 0) {
        throw FileSystemException('Could not protect the handoff directory.');
      }
      validateLocation(destination);
    }
    await File(
      '${destination.path}${Platform.pathSeparator}evidence.json',
    ).writeAsBytes(bytes, flush: true);
    validateLocation(destination);
    await File(
      '${destination.path}${Platform.pathSeparator}README.md',
    ).writeAsBytes(utf8.encode(readme), flush: true);
    validateLocation(destination);
    complete = true;
    return destination;
  } finally {
    if (!complete && destination != null) {
      try {
        await destination.delete(recursive: true);
      } on FileSystemException {
        // Never report success for incomplete output, even if cleanup fails.
      }
    }
  }
}

// Resolve existing ancestors before creating anything, including output aliases
// into a checkout. Missing final components are appended without filesystem I/O.
String _resolvedOutputPath(Directory directory) {
  var absolute = Directory.fromUri(directory.absolute.uri.normalizePath());
  // A trailing separator makes lstat follow a directory symlink on POSIX.
  // Inspect the entry itself so a dangling alias is not treated as absent.
  if (absolute.path.endsWith(Platform.pathSeparator) &&
      absolute.parent.path != absolute.path) {
    absolute = Directory(absolute.path.substring(0, absolute.path.length - 1));
  }
  if (FileSystemEntity.typeSync(absolute.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return absolute.resolveSymbolicLinksSync();
  }
  final parent = absolute.parent;
  if (parent.path == absolute.path) {
    throw FileSystemException('Missing output filesystem root.');
  }
  final name = absolute.uri.pathSegments.where((part) => part.isNotEmpty).last;
  return Directory.fromUri(
    Directory(
      _resolvedOutputPath(parent),
    ).uri.resolveUri(Uri(pathSegments: [name, ''])),
  ).path;
}
