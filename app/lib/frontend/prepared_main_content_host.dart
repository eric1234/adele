import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/resource_cleanup.dart';
import 'main_content_bridge.dart';
import 'prepared_frontend.dart';

/// Optional native resources selected once for an admitted pane. Each mounted
/// presentation receives a fresh bridge over that same captured owner.
final class PreparedMainContentPaneBinding {
  const PreparedMainContentPaneBinding({
    required this.createBridge,
    this.ready,
    this.requestFocus,
    this.release,
  });

  final PreparedFrontendBridge Function(bool Function() isActive) createBridge;
  final Future<void>? ready;
  final VoidCallback? requestFocus;
  final VoidCallback? release;
}

/// Initializes through a short-lived operation, then permits collection requests
/// only from mounted pane runtimes. With zero mounted panes there is no autonomous
/// updater; a new attachment is required to run initialization again.
final class PreparedMainContentHost {
  PreparedMainContentHost({this.createBinding});

  final PreparedMainContentPaneBinding? Function({
    required PreparedPluginInstallation installation,
    required PreparedMainContentPresentation descriptor,
    required Session session,
    required String paneId,
  })?
  createBinding;

  final Set<VoidCallback> _releases = {};
  bool _closed = false;
  Future<void>? _closing;

  MainContentContribution createContribution({
    required PreparedPluginInstallation installation,
    required PreparedFrontend generation,
    required PreparedMainContentPresentation descriptor,
    required bool Function() isActive,
  }) => MainContentContribution(
    order: descriptor.order,
    attach: (access) async {
      bool available() => !_closed && isActive() && access.isActive;
      void validate() {
        if (!available()) {
          throw StateError('Main Content attachment is retired.');
        }
      }

      void open(String id, String title, bool canClose) {
        validate();
        if (access.panes.any((pane) => pane.id == id)) {
          throw ArgumentError.value(id, 'id', 'Duplicate Main Content pane.');
        }
        final info = MainContentPaneInfo(
          id: id,
          title: title,
          canClose: canClose,
        );
        final identity = Object();
        PreparedMainContentPaneBinding? binding;
        Future<bool>? ready;
        var released = false;
        bool paneActive() => !released && available();
        void release() {
          if (released) return;
          released = true;
          _releases.remove(release);
          binding?.release?.call();
        }

        try {
          binding = createBinding?.call(
            installation: installation,
            descriptor: descriptor,
            session: access.session,
            paneId: id,
          );
          // Observe failure at admission, including panes never mounted. Keep
          // only readiness, not a diagnostic error or an evaluator callback.
          ready = binding?.ready?.then(
            (_) => true,
            onError: (Object _, StackTrace _) => false,
          );
          validate();
          // Metadata was validated before acquiring native resources. No eval
          // closure, widget, or return value survives initialization.
          final pane = MainContentPane(
            id: info.id,
            title: info.title,
            createPresentation: () {
              if (!paneActive()) {
                throw StateError('Main Content pane is retired.');
              }
              Widget present() => generation.createPresentation(
                key: ObjectKey(identity),
                library: descriptor.library,
                entrypoint: descriptor.entrypoint,
                createBridge: () {
                  if (!paneActive()) {
                    throw StateError('Main Content pane is retired.');
                  }
                  final collection = MainContentBridge(
                    access: access,
                    isActive: paneActive,
                    open: open,
                    paneId: id,
                  );
                  try {
                    return PreparedFrontendBridges([
                      collection,
                      if (binding case final native?)
                        native.createBridge(() => collection.isActive),
                    ]);
                  } on Object {
                    collection.invalidate();
                    rethrow;
                  }
                },
              );
              if (ready == null) return present();
              return FutureBuilder<bool>(
                future: ready,
                builder: (context, snapshot) {
                  if (!paneActive() || snapshot.data == false) {
                    return const Text('Frontend unavailable.');
                  }
                  if (snapshot.data != true) return const SizedBox.shrink();
                  return present();
                },
              );
            },
            onClose: canClose
                ? () {
                    if (paneActive()) access.remove(id);
                  }
                : null,
            requestFocus: binding?.requestFocus == null
                ? null
                : () {
                    if (paneActive()) binding!.requestFocus!();
                  },
            release: release,
          );
          _releases.add(release);
          access.open(pane);
        } on Object {
          release();
          rethrow;
        }
      }

      validate();
      await generation.invoke<void>(
        library: descriptor.library,
        entrypoint: descriptor.initialize,
        createBridge: () =>
            MainContentBridge(access: access, isActive: available, open: open),
        decodeResult: (value) {
          validate();
          if (value != null && value is! $null) {
            throw const FormatException(
              'Main Content initialization returns void.',
            );
          }
        },
      );
    },
  );

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = closeResources([
      for (final release in _releases.toList()) () async => release(),
    ]);
  }
}
