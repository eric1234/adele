import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_product/adele_product.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import '../core/environment_capability_invocation.dart';
import '../core/environment_capability_selection.dart';
import '../core/product_lifecycle.dart';
import 'backend_invocation_bridge.dart';
import 'environment_capability_diagnostics.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/environment_capability_bridge.dart';

/// Compile-time ABI only. The request-only channel is ordinary interpreted code.
class EnvironmentCapabilityAccessDeclarations implements EvalPlugin {
  const EnvironmentCapabilityAccessDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const nullableString = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.string),
      nullable: true,
    );
    const object = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.object),
      nullable: true,
    );
    for (final (name, returns, parameters) in [
      for (final name in [
        'resolveEnvironmentCapabilityProvider',
        'resolveEnvironmentBufferedProcessCapabilityProvider',
      ])
        (
          name,
          const BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [nullableString]),
          ),
          const [
            BridgeParameter('capabilityId', string, false),
            BridgeParameter(
              'majorVersion',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)),
              false,
            ),
            BridgeParameter('serviceId', string, false),
            BridgeParameter('providerId', nullableString, false),
          ],
        ),
      (
        'releaseEnvironmentCapabilityProvider',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        const [BridgeParameter('handle', string, false)],
      ),
      (
        'requestEnvironmentCapability',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future, [object])),
        const [
          BridgeParameter('handle', string, false),
          BridgeParameter('method', string, false),
          BridgeParameter('payload', structuredBridgeMapType, false),
        ],
      ),
      (
        'settleEnvironmentCapabilityOperation',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.future, [
            BridgeTypeAnnotation(
              BridgeTypeRef(CoreTypes.list, [
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
              ]),
            ),
          ]),
        ),
        const [
          BridgeParameter(
            'operation',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
            false,
          ),
          BridgeParameter('handle', nullableString, true),
        ],
      ),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(returns: returns, params: parameters),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped EnvironmentCapabilityAccessBridge.',
  );
}

/// Mounted-pane selections over one host-captured canonical Session. A handle
/// retains eligibility, not authority: each request opens its own single-kind
/// operation grant.
final class EnvironmentCapabilityAccessBridge
    extends EnvironmentCapabilityAccessDeclarations
    implements PreparedFrontendBridge {
  EnvironmentCapabilityAccessBridge({
    required Session? session,
    required EnvironmentRuntime? environmentRuntime,
    required ApplicationPluginBootstrap? backends,
    required Iterable<CapabilityKey> capabilities,
    Iterable<CapabilityKey> bufferedProcessCapabilities = const [],
    required bool Function() isActive,
    void Function()? onInvalidate,
  }) : _session = session,
       _environmentRuntime = environmentRuntime,
       _backends = backends,
       _capabilities = Set.unmodifiable(capabilities),
       _bufferedProcessCapabilities = Set.unmodifiable(
         bufferedProcessCapabilities,
       ),
       _isActive = isActive,
       _onInvalidate = onInvalidate;

  static const maxHandles = 64;
  final Session? _session;
  final EnvironmentRuntime? _environmentRuntime;
  final ApplicationPluginBootstrap? _backends;
  final Set<CapabilityKey> _capabilities;
  final Set<CapabilityKey> _bufferedProcessCapabilities;
  final bool Function() _isActive;
  final void Function()? _onInvalidate;
  final Zone _nativeZone = Zone.current;
  final Map<String, _EnvironmentCapabilityAccess> _handles = {};
  final String _scope = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  int _nextHandle = 0;
  int _resolving = 0;
  bool _active = true;
  bool _configured = false;
  late final BackendInvocationBridge _unavailable = BackendInvocationBridge(
    channelFor: (_) => null,
    validateAdmission: _validate,
    validateSettlement: _validate,
    isPresentationActive: () => isActive,
  );

  bool get isActive {
    if (!_active) return false;
    try {
      if (_isActive()) return true;
    } on Object {
      // A failed presentation check cannot become live again later.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!isActive) {
      throw StateError('Contextual Capability presentation access is retired.');
    }
  }

  void _authorize(CapabilityKey key, _EnvironmentCapabilityGrant grant) {
    _validate();
    final declared = switch (grant) {
      _EnvironmentCapabilityGrant.read => _capabilities,
      _EnvironmentCapabilityGrant.bufferedProcess =>
        _bufferedProcessCapabilities,
    };
    if (!declared.contains(key)) {
      throw StateError(
        'Environment ${grant.name} Capability access is not declared.',
      );
    }
  }

  Future<String?> resolve(
    String id,
    int majorVersion,
    String serviceId,
    String? providerId,
  ) => _resolve(
    id,
    majorVersion,
    serviceId,
    providerId,
    _EnvironmentCapabilityGrant.read,
  );

  Future<String?> resolveBufferedProcess(
    String id,
    int majorVersion,
    String serviceId,
    String? providerId,
  ) => _resolve(
    id,
    majorVersion,
    serviceId,
    providerId,
    _EnvironmentCapabilityGrant.bufferedProcess,
  );

  Future<String?> _resolve(
    String id,
    int majorVersion,
    String serviceId,
    String? providerId,
    _EnvironmentCapabilityGrant grant,
  ) async {
    var reserved = false;
    try {
      final key = CapabilityKey(
        id: CapabilityId(id),
        majorVersion: majorVersion,
      );
      _authorize(key, grant);
      final session = _session;
      final environmentRuntime = _environmentRuntime;
      final backends = _backends;
      if (session == null || environmentRuntime == null || backends == null) {
        return null;
      }
      if (_handles.length + _resolving >= maxHandles) return null;
      final provider = providerId == null ? null : ProviderId(providerId);
      _resolving++;
      reserved = true;
      // Fresh explicit resolution, but never re-resolution behind a handle.
      // Construction captures the canonical association before any suspension.
      final capture = CapturedEnvironmentCapabilities(
        environmentRuntime: environmentRuntime,
        backends: backends,
        session: session,
      );
      final selection = await capture.resolve(key, providerId: provider);
      _authorize(key, grant);
      if (selection.binding.provider.serviceId != serviceId) return null;
      if (grant == _EnvironmentCapabilityGrant.bufferedProcess) {
        final owner = backends.backendForProvider(selection.binding);
        if (owner == null ||
            !owner.allowsEnvironmentHostService(
              selection.binding,
              AdeleEnvironmentHostService.bufferedProcess,
            )) {
          return null;
        }
      }
      selection.binding.requestChannel;
      final handle = '$_scope:${_nextHandle++}';
      _handles[handle] = _EnvironmentCapabilityAccess(
        handle: handle,
        selection: selection,
        backends: backends,
        serviceId: serviceId,
        grant: grant,
        validatePresentation: () => _authorize(key, grant),
        isPresentationActive: () => isActive,
      );
      return handle;
    } on Object {
      return null;
    } finally {
      if (reserved) _resolving--;
    }
  }

  bool release(String handle) {
    final access = _handles.remove(handle);
    if (access == null) return false;
    access.close();
    return true;
  }

  BackendInvocationBridge _transport(String handle) =>
      _handles[handle]?.transport ?? _unavailable;

  Future<Object?> request(String handle, String method, Object? payload) =>
      _transport(handle).request(handle, method, payload);

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) {
      throw StateError('Environment Capability bridge is bound.');
    }
    _configured = true;
    for (final (name, resolveProvider) in [
      ('resolveEnvironmentCapabilityProvider', resolve),
      (
        'resolveEnvironmentBufferedProcessCapabilityProvider',
        resolveBufferedProcess,
      ),
    ]) {
      runtime.registerBridgeFunc(_library, name, (_, _, args) {
        final completion = Completer<$Value>();
        _nativeZone.run(() {
          resolveProvider(
            args[0]!.$value as String,
            args[1]!.$value as int,
            args[2]!.$value as String,
            args[3]!.$value as String?,
          ).then((handle) {
            completion.complete(
              wrapStructuredBridgeData(isActive ? handle : null),
            );
          });
        });
        return $Future<$Value>.wrap(completion.future);
      });
    }
    runtime
      ..registerBridgeFunc(
        _library,
        'releaseEnvironmentCapabilityProvider',
        (_, _, args) => $bool(release(args[0]!.$value as String)),
      )
      ..registerBridgeFunc(_library, 'requestEnvironmentCapability', (
        _,
        _,
        args,
      ) {
        return _transport(args[0]!.$value as String).evalRequest(runtime, args);
      })
      ..registerBridgeFunc(
        _library,
        'settleEnvironmentCapabilityOperation',
        (_, _, args) => BackendInvocationBridge.settleOperation(
          runtime,
          args,
          diagnostic: args.length > 1
              ? _handles[args[1]?.$value]?.settlementDiagnostic
              : null,
        ),
      );
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    for (final access in _handles.values) {
      access.close();
    }
    _handles.clear();
    _unavailable.invalidate();
    _onInvalidate?.call();
  }
}

enum _EnvironmentCapabilityGrant { read, bufferedProcess }

final class _EnvironmentCapabilityAccess implements AdeleRequestChannel {
  _EnvironmentCapabilityAccess({
    required String handle,
    required this.selection,
    required this.backends,
    required this.serviceId,
    required this.grant,
    required this.validatePresentation,
    required bool Function() isPresentationActive,
  }) {
    transport = BackendInvocationBridge(
      channelFor: (route) {
        if (route != handle) throw StateError('Foreign contextual access.');
        return this;
      },
      validateAdmission: validate,
      validateSettlement: validate,
      isPresentationActive: isPresentationActive,
      beginDiagnostic: (method) {
        _requests++;
        if (_requests > 1) _diagnostic?.suppressSettlement();
        return _diagnostic = EnvironmentCapabilityDiagnostics.native.begin(
          service: serviceId,
          method: method,
          provider: selection.binding.provider.id.value,
          environmentProvider:
              selection.materialization.binding.provider.id.value,
          grant: grant.name,
        );
      },
    );
  }

  final EnvironmentCapabilitySelection selection;
  final ApplicationPluginBootstrap backends;
  final String serviceId;
  final _EnvironmentCapabilityGrant grant;
  final void Function() validatePresentation;
  late final BackendInvocationBridge transport;
  final Set<void Function()> _retirements = {};
  bool _active = true;
  int _requests = 0;
  EnvironmentCapabilityDiagnostic? _diagnostic;

  EnvironmentCapabilityDiagnostic? get settlementDiagnostic =>
      _requests == 1 ? _diagnostic : null;

  void validate() {
    validatePresentation();
    if (!_active) {
      throw StateError('The contextual Capability handle is retired.');
    }
    selection.validate();
  }

  void Function() _onRetire(void Function() revoke) {
    if (!_active) {
      revoke();
      return () {};
    }
    _retirements.add(revoke);
    return () => _retirements.remove(revoke);
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    validate();
    final invoke = switch (grant) {
      _EnvironmentCapabilityGrant.read =>
        invokeEnvironmentCapabilityWithRead<Object?>,
      _EnvironmentCapabilityGrant.bufferedProcess =>
        invokeEnvironmentCapabilityWithBufferedProcess<Object?>,
    };
    return invoke(
      selection: selection,
      backends: backends,
      serviceId: serviceId,
      onRetire: _onRetire,
      invoke: (channel) => channel.request(method, payload),
    );
  }

  void close() {
    if (!_active) return;
    _active = false;
    for (final revoke in _retirements.toList()) {
      revoke();
    }
    _retirements.clear();
    transport.invalidate();
  }
}
