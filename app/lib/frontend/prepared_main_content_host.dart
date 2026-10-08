import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/commands.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import '../core/product_lifecycle.dart';
import '../core/resource_cleanup.dart';
import '../ui/main_content/main_content_host.dart';
import 'capability_access_bridge.dart';
import 'code_editor_bridge.dart';
import 'contribution_bridge.dart';
import 'environment_access_bridge.dart';
import 'environment_capability_access_bridge.dart';
import 'environment_text_files.dart';
import 'main_content_bridge.dart';
import 'prepared_frontend.dart';
import 'prepared_session_services.dart';
import 'session_presentation_lifecycle_bridge.dart';
import 'structured_bridge_data.dart';

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

/// Prepared contribution hosting. Opt-in opaque data and native owners outlive
/// attachments; only ordinary views and admitted finite operations run eval.
final class PreparedMainContentHost {
  PreparedMainContentHost({
    this.createBinding,
    this.environmentRuntime,
    this.confirm,
    MainContentActionCoordinator? actionCoordinator,
  }) : actionCoordinator = actionCoordinator ?? MainContentActionCoordinator();

  final MainContentActionCoordinator actionCoordinator;
  final EnvironmentRuntime? environmentRuntime;
  final Future<bool> Function(Map<String, Object?> request)? confirm;
  final _metadata = Expando<(PreparedPluginInstallation, PreparedFrontend)>();
  final Map<PreparedMainContentPresentation, _RetainedMainContent> _retained =
      {};
  final Set<Future<Map<String, Object?>>> _operations = {};
  final Map<
    PreparedMainContentPresentation,
    Set<EnvironmentCapabilityAccessBridge>
  >
  _contextualAccess = {};
  bool _accepting = true;
  bool _preflighting = false;

  final PreparedMainContentPaneBinding? Function({
    required PreparedPluginInstallation installation,
    required PreparedMainContentPresentation descriptor,
    required Session session,
    required String paneId,
  })?
  createBinding;

  final Map<VoidCallback, Session> _releases = {};
  final Map<
    Object,
    (Session, bool Function(), SessionPresentationLifecycleBridge)
  >
  _lifecycles = {};
  bool _closed = false;
  Future<void>? _closing;

  MainContentContribution createContribution({
    required ExtensionRegistry extensions,
    required PreparedPluginInstallation installation,
    required PreparedFrontend generation,
    required PreparedMainContentPresentation descriptor,
    required bool Function() isActive,
    PreparedSessionServices? services,
    CapabilityRegistry? capabilityRegistry,
    ApplicationPluginBootstrap? backends,
  }) {
    final retained =
        descriptor.retainedData ||
            descriptor.actions.isNotEmpty ||
            descriptor.operations.isNotEmpty
        ? _retained[descriptor] = _RetainedMainContent(
            owner: RetainedContribution(),
            generation: generation,
            descriptor: descriptor,
            isActive: () => !_closed && isActive(),
          )
        : null;
    late final MainContentContribution contribution;
    contribution = MainContentContribution(
      order: descriptor.order,
      actions: [
        for (final action in descriptor.actions)
          MainContentAction(
            id: action.id,
            label: action.label,
            createPresentation: (access) {
              final attachment = retained?.attachment;
              if (attachment == null ||
                  !identical(attachment.access, access) ||
                  !access.isActive) {
                throw StateError('Contribution action is unavailable.');
              }
              return generation.createPresentation(
                key: UniqueKey(),
                library: descriptor.library,
                entrypoint: action.entrypoint,
                createBridge: () => PreparedFrontendBridges([
                  MainContentBridge(
                    context: attachment.context,
                    isActive: () => access.isActive && isActive(),
                  ),
                  _dataBridge(
                    retained!,
                    attachment,
                    isActive: () => access.isActive && isActive(),
                  ),
                  EnvironmentAccessBridge(
                    isActive: () => access.isActive && isActive(),
                  ),
                ]),
              );
            },
          ),
      ],
      detach: (access) {
        if (identical(retained?.attachment?.access, access)) {
          retained!.attachment = null;
        }
      },
      attach: (access) async {
        bool available() => !_closed && isActive() && access.isActive;
        void validate() {
          if (!available()) {
            throw StateError('Main Content attachment is retired.');
          }
        }

        final context = _contextForSession(access.session);
        late final _MainContentAttachment attachment;

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
          PreparedFrontendBridges? bridges;
          Future<bool>? ready;
          var released = false;
          bool paneActive() => !released && available();
          void release() {
            if (released) return;
            released = true;
            _releases.remove(release);
            _releaseAll([?bridges?.invalidate, ?binding?.release]);
          }

          try {
            binding = createBinding?.call(
              installation: installation,
              descriptor: descriptor,
              session: access.session,
              paneId: id,
            );
            if (descriptor.nativeCodeEditor && retained != null) {
              if (binding != null) {
                throw StateError(
                  'A pane cannot have two native editor bindings.',
                );
              }
              final editor = retained.owner.editor(id);
              binding = PreparedMainContentPaneBinding(
                createBridge: (isActive) =>
                    CodeEditorBridge(editor: editor, isActive: isActive),
                requestFocus: editor.requestFocus,
              );
            }
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
                    bridges?.invalidate();
                    final collection = MainContentBridge(
                      access: access,
                      context: context,
                      isActive: paneActive,
                      open: open,
                      paneId: id,
                    );
                    late final SessionPresentationLifecycleBridge lifecycle;
                    lifecycle = SessionPresentationLifecycleBridge(
                      isActive: () => collection.isActive,
                      onInvalidate: () {
                        if (identical(_lifecycles[identity]?.$3, lifecycle)) {
                          _lifecycles.remove(identity);
                          // PreparedFrontend retains its inert display during exit;
                          // only that presentation may later discard its snapshots.
                          bridges = null;
                        }
                      },
                    );
                    late final EnvironmentCapabilityAccessBridge contextual;
                    contextual = EnvironmentCapabilityAccessBridge(
                      session: access.session,
                      environmentRuntime: environmentRuntime,
                      backends: backends,
                      capabilities: descriptor.environmentReadCapabilities,
                      isActive: () => collection.isActive,
                      onInvalidate: () {
                        final active = _contextualAccess[descriptor];
                        active?.remove(contextual);
                        if (active?.isEmpty ?? false) {
                          _contextualAccess.remove(descriptor);
                        }
                      },
                    );
                    (_contextualAccess[descriptor] ??= {}).add(contextual);
                    final acquired = <PreparedFrontendBridge>[
                      collection,
                      lifecycle,
                      contextual,
                      CapabilityAccessBridge(
                        registry: capabilityRegistry,
                        capabilities: descriptor.capabilities,
                        isActive: () => collection.isActive,
                      ),
                      EnvironmentAccessBridge(isActive: paneActive),
                      if (retained != null)
                        _dataBridge(retained, attachment, isActive: paneActive),
                    ];
                    try {
                      if (descriptor.sessionExecution ||
                          descriptor.backendServices.isNotEmpty ||
                          descriptor.strategyAffinity ==
                              PreparedStrategyAffinity.owningBackend) {
                        if (services == null) {
                          throw StateError(
                            'Prepared Session services are unavailable.',
                          );
                        }
                        final view = extensions
                            .discover(mainContentContributions)
                            .singleWhere(
                              (view) =>
                                  view.id == descriptor.extensionId &&
                                  identical(view.value, contribution),
                            );
                        // Freeze service display before revoking the collection
                        // liveness on which its captured authority depends.
                        acquired.insert(
                          0,
                          services.bind(
                            view,
                            session: access.session,
                            isActive: () => collection.isActive,
                          ),
                        );
                      }
                      if (binding case final native?) {
                        acquired.add(
                          native.createBridge(() => collection.isActive),
                        );
                      }
                      _lifecycles[identity] = (
                        access.session,
                        paneActive,
                        lifecycle,
                      );
                      return bridges = PreparedFrontendBridges(acquired);
                    } on Object {
                      try {
                        _releaseAll([
                          for (final bridge in acquired.reversed)
                            bridge.invalidate,
                        ]);
                      } on Object {
                        // Preserve the construction failure after rollback.
                      }
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
                      if (!paneActive()) return;
                      final close = descriptor.closeOperation;
                      if (close != null && retained != null) {
                        _invoke(retained, attachment, close, {
                          'id': id,
                        }).ignore();
                      } else {
                        access.remove(id);
                      }
                    }
                  : null,
              requestFocus: binding?.requestFocus == null
                  ? null
                  : () {
                      if (paneActive()) binding!.requestFocus!();
                    },
              release: release,
            );
            _releases[release] = access.session;
            access.open(pane);
          } on Object {
            try {
              release();
            } on Object {
              // Preserve the admission failure after releasing its resources.
            }
            rethrow;
          }
        }

        Future<void> initialize() async {
          if (!available()) return;
          await generation.invoke<void>(
            library: descriptor.library,
            entrypoint: descriptor.initialize,
            createBridge: () => PreparedFrontendBridges([
              MainContentBridge(
                access: access,
                context: context,
                isActive: available,
                open: open,
              ),
              EnvironmentAccessBridge(isActive: available),
              if (retained != null)
                _dataBridge(retained, attachment, isActive: available),
            ]),
            decodeResult: (value) {
              validate();
              if (value != null && value is! $null) {
                throw const FormatException(
                  'Main Content initialization returns void.',
                );
              }
            },
          );
        }

        attachment = _MainContentAttachment(
          access: access,
          context: context,
          initialize: initialize,
        );
        if (retained != null) retained.attachment = attachment;
        validate();
        await initialize();
      },
    );
    _metadata[contribution] = (installation, generation);
    services?.registerMetadata(contribution, installation, descriptor);
    return contribution;
  }

  /// Delegates to the mounted input host using the captured sibling, not IDs.
  CommandContribution createActionCommand({
    required PreparedPluginInstallation installation,
    required PreparedFrontend generation,
    required PreparedMainContentActionCommandExtension descriptor,
    required ExtensionBinding<MainContentContribution> owner,
    required bool Function() isActive,
  }) {
    final contribution = owner.value;
    final metadata = _metadata[contribution];
    if (metadata == null ||
        !identical(metadata.$1, installation) ||
        !identical(metadata.$2, generation) ||
        owner.id != descriptor.mainContentExtensionId) {
      throw StateError(
        'The Main Content action Command target is unavailable.',
      );
    }
    final action = contribution.actions.singleWhere(
      (action) => action.id == descriptor.actionId,
    );
    CommandAvailability availability() {
      if (_closed || !isActive()) return CommandAvailability.hidden;
      try {
        owner.validate();
      } on StaleExtensionBinding {
        return CommandAvailability.hidden;
      }
      if (!actionCoordinator.hasSession) return CommandAvailability.hidden;
      return actionCoordinator.canOpen(owner, action)
          ? CommandAvailability.enabled
          : CommandAvailability.disabled;
    }

    return CommandContribution(
      id: descriptor.commandId,
      label: action.label,
      availability: availability,
      invoke: () {
        if (availability() != CommandAvailability.enabled) {
          throw CommandUnavailable(descriptor.commandId);
        }
        actionCoordinator.open(owner, action);
      },
    );
  }

  ContributionBridge _dataBridge(
    _RetainedMainContent retained,
    _MainContentAttachment attachment, {
    required bool Function() isActive,
  }) => ContributionBridge(
    owner: retained.owner,
    isActive: () => retained.isActive() && isActive(),
    nativeCodeEditor: retained.descriptor.nativeCodeEditor,
    retainedData: retained.descriptor.retainedData,
    invoke: (operation, arguments) =>
        _invoke(retained, attachment, operation, arguments),
  );

  Map<String, Object?> _contextForSession(Session session) {
    final store = environmentRuntime?.store;
    if (store != null && !identical(store.session(session.id), session)) {
      throw StateError('Main Content context requires the canonical Session.');
    }
    return Map.unmodifiable({
      'sessionId': session.id.value,
      'strategyId': session.strategyId.value,
      'taskId': session.taskId.value,
      if (store != null)
        'environmentKey': store
            .requireSessionAuthority(session.id)
            .environmentId
            .value,
    });
  }

  /// Called by the public provider-neutral display registration, not a global
  /// command service. Only the current host-approved attachment can admit work.
  Future<Map<String, Object?>> displaySourceFile(
    PreparedMainContentPresentation descriptor,
    String relativePath,
  ) {
    final retained = _retained[descriptor];
    final attachment = retained?.attachment;
    final operation = descriptor.displaySourceFileOperation;
    if (retained == null || attachment == null || operation == null) {
      throw StateError('Source display is unavailable in the current context.');
    }
    return _invoke(retained, attachment, operation, {'path': relativePath});
  }

  Future<Map<String, Object?>> _invoke(
    _RetainedMainContent retained,
    _MainContentAttachment? attachment,
    String operation,
    Map<String, Object?> arguments, {
    bool preflight = false,
  }) {
    if (!_accepting ||
        (_preflighting && !preflight) ||
        !retained.isActive() ||
        (!preflight && (attachment == null || !attachment.access.isActive))) {
      return Future.error(StateError('Contribution operation is unavailable.'));
    }
    final entrypoint = retained.descriptor.operations[operation];
    if (entrypoint == null) {
      return Future.error(StateError('Undeclared contribution operation.'));
    }
    // Everything below is captured before eval can suspend. Presentation
    // departure does not revoke this finite operation's retained owner access.
    final context = attachment?.context ?? const <String, Object?>{};
    CapturedEnvironmentTextFiles? files;
    final runtime = environmentRuntime;
    if (retained.descriptor.environmentTextFiles &&
        attachment != null &&
        runtime != null) {
      try {
        files = CapturedEnvironmentTextFiles(
          session: attachment.access.session,
          environmentRuntime: runtime,
        );
        if (files.environmentKey != context['environmentKey']) {
          throw StateError(
            'The captured Session Environment association changed.',
          );
        }
      } on Object catch (error, stack) {
        return Future.error(error, stack);
      }
    }
    final capturedArguments =
        copyStructuredBridgeData(arguments) as Map<String, Object?>;
    late final Future<Map<String, Object?>> pending;
    pending = retained.generation
        .invoke<Map<String, Object?>>(
          library: retained.descriptor.library,
          entrypoint: entrypoint,
          createBridge: () => PreparedFrontendBridges([
            MainContentBridge(context: context, isActive: retained.isActive),
            ContributionBridge(
              owner: retained.owner,
              isActive: retained.isActive,
              arguments: capturedArguments,
              nativeCodeEditor: retained.descriptor.nativeCodeEditor,
              retainedData: retained.descriptor.retainedData,
              confirm: confirm,
            ),
            EnvironmentAccessBridge(files: files, isActive: retained.isActive),
          ]),
          decodeResult: (value) {
            if (!retained.isActive()) {
              throw StateError(
                'Contribution owner retired during the operation.',
              );
            }
            return copyStructuredBridgeData(value) as Map<String, Object?>;
          },
        )
        .then((result) async {
          final current = retained.attachment;
          if (current != null &&
              current.access.isActive &&
              retained.isActive()) {
            try {
              await current.refresh();
            } on Object {
              // View departure/failure cannot revoke the retained acknowledgement.
            }
            final focus = result['focus'];
            if (focus is String &&
                current.access.isActive &&
                current.context['environmentKey'] ==
                    context['environmentKey'] &&
                current.access.panes.any((pane) => pane.id == focus)) {
              current.access.focus(focus, keyboardFocus: true);
            }
          }
          return result;
        })
        .whenComplete(() => _operations.remove(pending));
    _operations.add(pending);
    return pending;
  }

  /// Reversible opt-in preflight, before frontend or execution shutdown. Hidden
  /// collections are checked by fresh operations without mounting their views.
  Future<bool> prepareToExit() async {
    if (_preflighting || !_accepting) return false;
    _preflighting = true;
    try {
      await drainOperations();
      for (final retained in _retained.values) {
        final operation = retained.descriptor.exitOperation;
        if (operation == null || !retained.isActive()) continue;
        final result = await _invoke(
          retained,
          null,
          operation,
          const {},
          preflight: true,
        );
        if (result['accepted'] != true) return false;
      }
      return true;
    } on Object {
      return false;
    } finally {
      _preflighting = false;
    }
  }

  Future<void> drainOperations() async {
    while (_operations.isNotEmpty) {
      await Future.wait([
        for (final operation in _operations.toList())
          operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ]);
    }
  }

  Future<void> stopOperations() {
    _accepting = false;
    return drainOperations();
  }

  void retire(PreparedMainContentPresentation descriptor) {
    revokeContextualAccess(descriptor);
    final retained = _retained.remove(descriptor);
    if (retained == null) return;
    retained.attachment = null;
    retained.owner.dispose();
  }

  /// Revocation precedes asynchronous frontend registration/view cleanup.
  void revokeContextualAccess(PreparedMainContentPresentation descriptor) {
    for (final bridge in _contextualAccess.remove(descriptor) ?? const {}) {
      bridge.invalidate();
    }
  }

  /// Settle only hooks belonging to currently mounted contributed panes. A
  /// rejected hook leaves every pane live so the user can repair and retry.
  Future<void> prepareToDeactivate(Session session) async {
    final cohort = {
      for (final entry in _lifecycles.entries)
        if (identical(entry.value.$1, session) && entry.value.$2())
          entry.key: entry.value,
    };
    for (final entry in cohort.entries) {
      final (owner, isActive, lifecycle) = entry.value;
      if (identical(owner, session) &&
          identical(_lifecycles[entry.key]?.$3, lifecycle) &&
          isActive()) {
        await lifecycle.prepareToDeactivate();
      }
    }
    if (_lifecycles.entries.any(
      (entry) =>
          identical(entry.value.$1, session) &&
          entry.value.$2() &&
          !identical(cohort[entry.key]?.$3, entry.value.$3),
    )) {
      throw StateError(
        'The workbench presentations changed during settlement.',
      );
    }
  }

  void unbind(Session session) {
    for (final retained in _retained.values) {
      final access = retained.attachment?.access;
      if (access != null &&
          (!access.isActive || identical(access.session, session))) {
        retained.attachment = null;
      }
    }
    _releaseAll([
      for (final entry in _releases.entries.toList())
        if (identical(entry.value, session)) entry.key,
    ]);
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    for (final descriptor in _contextualAccess.keys.toList()) {
      revokeContextualAccess(descriptor);
    }
    return _closing = closeResources([
      for (final release in _releases.keys.toList()) () async => release(),
      for (final retained in _retained.values)
        () async {
          retained.attachment = null;
          retained.owner.dispose();
        },
    ]);
  }
}

final class _RetainedMainContent {
  _RetainedMainContent({
    required this.owner,
    required this.generation,
    required this.descriptor,
    required this.isActive,
  });
  final RetainedContribution owner;
  final PreparedFrontend generation;
  final PreparedMainContentPresentation descriptor;
  final bool Function() isActive;
  _MainContentAttachment? attachment;
}

/// Transient host attachment only, never included in plugin retained records.
final class _MainContentAttachment {
  _MainContentAttachment({
    required this.access,
    required this.context,
    required this.initialize,
  });
  final MainContentAccess access;
  final Map<String, Object?> context;
  final Future<void> Function() initialize;
  Future<void>? _refreshing;
  bool _again = false;

  Future<void> refresh() {
    if (_refreshing case final pending?) {
      _again = true;
      return pending;
    }
    return _refreshing = () async {
      do {
        _again = false;
        await initialize();
      } while (_again && access.isActive);
    }().whenComplete(() => _refreshing = null);
  }
}

void _releaseAll(Iterable<VoidCallback> releases) {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final release in releases) {
    try {
      release();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
