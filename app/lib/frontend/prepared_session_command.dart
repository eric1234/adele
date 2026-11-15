import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import 'command_bridge.dart';
import 'owning_backend_bridge.dart';
import 'prepared_frontend.dart';

/// One ordinary Command registration, with generation-owned finite operations.
final class PreparedSessionCommand {
  PreparedSessionCommand({
    required this.installation,
    required this.generation,
    required this.descriptor,
    required this.sessionContext,
    required this.backends,
    this.showFeedback,
    required bool Function() isRegistered,
  }) : _isRegistered = isRegistered {
    if (sessionContext case final context? when context.isActive) {
      _detachSelection = context.observe((_) => _notify());
    }
    if (descriptor.backendServices.isNotEmpty) {
      _backendChanges = backends?.changes.listen((_) => _notify());
    }
  }

  final PreparedPluginInstallation installation;
  final PreparedFrontend generation;
  final PreparedSessionCommandExtension descriptor;
  final WindowSessionContext? sessionContext;
  final ApplicationPluginBootstrap? backends;
  final void Function(String)? showFeedback;
  final bool Function() _isRegistered;
  final _changes = StreamController<void>.broadcast();
  final _operations = <void Function()>{};
  void Function()? _detachSelection;
  StreamSubscription<ApplicationPluginState>? _backendChanges;
  bool _active = true;

  late final contribution = CommandContribution(
    id: descriptor.commandId,
    label: descriptor.label,
    availability: _availability,
    availabilityChanges: _changes.stream,
    invoke: _invoke,
  );

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  CommandAvailability _availability() {
    if (!_active || !_isRegistered()) return CommandAvailability.disabled;
    final context = sessionContext;
    if (context == null ||
        !context.isActive ||
        context.snapshot.session == null) {
      return CommandAvailability.hidden;
    }
    if (descriptor.backendServices.isNotEmpty &&
        backends?.backendForInstallation(installation) == null) {
      return CommandAvailability.disabled;
    }
    if (_operations.isNotEmpty) return CommandAvailability.disabled;
    return CommandAvailability.enabled;
  }

  void _validateOperation() {
    // Selection revisions and registration-only retirement are not the lifetime
    // of admitted work. Window shutdown and actual generation retirement are.
    if (!_active || !(sessionContext?.isActive ?? false)) {
      throw StateError('The Session Command operation is retired.');
    }
  }

  Future<void> _invoke() {
    if (_availability() != CommandAvailability.enabled) {
      throw StateError('The Session Command is unavailable.');
    }
    final sessionId = sessionContext!.snapshot.session!.id.value;
    final owner = descriptor.backendServices.isEmpty
        ? null
        : backends!.backendForInstallation(installation);
    if (descriptor.backendServices.isNotEmpty && owner == null) {
      throw StateError('The Session Command owning backend is unavailable.');
    }
    final channel = owner?.openPresentationChannel(
      backendServices: descriptor.backendServices,
      validatePresentation: _validateOperation,
    );
    void validateAccess() {
      _validateOperation();
      channel?.validate();
    }

    final bridge = PreparedFrontendBridges([
      if (channel != null)
        OwningBackendBridge.channel(
          channel,
          validateBinding: _validateOperation,
        ),
      if (descriptor.clipboardWrite || descriptor.feedback)
        CommandBridge(
          clipboardWrite: descriptor.clipboardWrite,
          feedback: descriptor.feedback,
          validateOperation: validateAccess,
          showFeedback: showFeedback,
        ),
    ]);
    final ended = Completer<void>();
    void end() {
      try {
        bridge.invalidate();
      } finally {
        if (!ended.isCompleted) ended.complete();
      }
    }

    final detachOwner = owner?.onRetire(end);
    _operations.add(end);
    _notify();
    return generation
        .invoke<void>(
          library: descriptor.library,
          entrypoint: descriptor.entrypoint,
          arguments: [$String(sessionId)],
          createBridge: () => bridge,
          accessEnded: ended.future,
          decodeResult: (value) {
            _validateOperation();
            channel?.validate();
            if (value != null && value is! $null) {
              throw const FormatException(
                'A prepared Command must return void or null.',
              );
            }
          },
        )
        .whenComplete(() {
          detachOwner?.call();
          _operations.remove(end);
          end();
          _notify();
        });
  }

  /// Stops discovery observation, not operations already admitted by the Command.
  void retireRegistration() {
    _detachSelection?.call();
    _detachSelection = null;
    unawaited(_backendChanges?.cancel());
    _backendChanges = null;
    unawaited(_changes.close());
  }

  /// Synchronously revokes access before window/generation teardown awaits work.
  void close() {
    if (!_active) return;
    _active = false;
    for (final end in _operations.toList()) {
      end();
    }
    _operations.clear();
    retireRegistration();
  }
}
