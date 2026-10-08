import 'dart:convert';
import 'dart:math';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'backend_invocation_bridge.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/capability_bridge.dart';

/// Compile-time ABI only; interpreted clients compile the public channel source.
class CapabilityAccessDeclarations implements EvalPlugin {
  const CapabilityAccessDeclarations();

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
    const key = [
      BridgeParameter('capabilityId', string, false),
      BridgeParameter(
        'majorVersion',
        BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)),
        false,
      ),
    ];
    const invocation = [
      BridgeParameter('handle', string, false),
      BridgeParameter('method', string, false),
      BridgeParameter('payload', structuredBridgeMapType, false),
    ];
    for (final (name, returns, parameters) in [
      (
        'discoverCapabilityProviders',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.list, [structuredBridgeMapType]),
          nullable: true,
        ),
        key,
      ),
      (
        'resolveCapabilityProvider',
        nullableString,
        const [
          ...key,
          BridgeParameter('serviceId', string, false),
          BridgeParameter('providerId', nullableString, false),
        ],
      ),
      (
        'releaseCapabilityProvider',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        const [BridgeParameter('handle', string, false)],
      ),
      (
        'requestCapability',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future, [object])),
        invocation,
      ),
      (
        'streamCapability',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.stream, [object])),
        invocation,
      ),
      (
        'settleCapabilityOperation',
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
    'Use a presentation-scoped CapabilityAccessBridge.',
  );
}

/// Presentation-local access bookkeeping, never another provider registry.
/// Selection delegates to the registry; invocation retains the selected binding.
final class CapabilityAccessBridge extends CapabilityAccessDeclarations
    implements PreparedFrontendBridge {
  CapabilityAccessBridge({
    required CapabilityRegistry? registry,
    required Iterable<CapabilityKey> capabilities,
    required bool Function() isActive,
  }) : _registry = registry,
       _capabilities = Set.unmodifiable(capabilities),
       _isActive = isActive;

  static const maxHandles = 64;
  final CapabilityRegistry? _registry;
  final Set<CapabilityKey> _capabilities;
  final bool Function() _isActive;
  final Map<String, _CapabilityAccess> _handles = {};
  final String _scope = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  int _nextHandle = 0;
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
      throw StateError('Capability presentation access is retired.');
    }
  }

  CapabilityKey _authorize(String id, int majorVersion) {
    _validate();
    final key = CapabilityKey(id: CapabilityId(id), majorVersion: majorVersion);
    if (!_capabilities.contains(key)) {
      throw StateError('Capability access is not declared.');
    }
    return key;
  }

  List<Map<String, Object?>>? discover(String id, int majorVersion) {
    try {
      final key = _authorize(id, majorVersion);
      final registry = _registry;
      if (registry == null) return null;
      return [
        for (final provider in registry.providersFor(key))
          {
            'providerId': provider.id.value,
            'pluginId': provider.pluginId,
            'displayName': provider.displayName,
            'serviceId': provider.serviceId,
          },
      ];
    } on Object {
      return null;
    }
  }

  String? resolve(
    String id,
    int majorVersion,
    String serviceId,
    String? providerId,
  ) {
    try {
      final key = _authorize(id, majorVersion);
      if (_handles.length >= maxHandles) return null;
      final binding = _registry?.resolve(
        key,
        providerId: providerId == null ? null : ProviderId(providerId),
      );
      if (binding == null) return null;
      if (binding.provider.serviceId != serviceId) return null;
      // This also rejects endpoints without the supported generated transport.
      final channel = binding.requestChannel;
      final handle = '$_scope:${_nextHandle++}';
      final transport = BackendInvocationBridge(
        channelFor: (route) {
          if (route != handle) throw StateError('Foreign Capability access.');
          binding.endpointAs<CapabilityEndpoint>();
          return channel;
        },
        validateAdmission: _validate,
        validateSettlement: _validate,
        validateStream: () {
          _validate();
          binding.endpointAs<CapabilityEndpoint>();
        },
        isPresentationActive: () => isActive,
      );
      final detach = binding.onRetire(transport.retireStreams);
      _handles[handle] = _CapabilityAccess(transport, detach);
      return handle;
    } on Object {
      return null;
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

  Stream<Object?> stream(String handle, String method, Object? payload) =>
      _transport(handle).stream(handle, method, payload);

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Capability bridge is already bound.');
    _configured = true;
    runtime
      ..registerBridgeFunc(_library, 'discoverCapabilityProviders', (
        _,
        _,
        args,
      ) {
        return wrapStructuredBridgeData(
          discover(args[0]!.$value as String, args[1]!.$value as int),
        );
      })
      ..registerBridgeFunc(_library, 'resolveCapabilityProvider', (_, _, args) {
        return wrapStructuredBridgeData(
          resolve(
            args[0]!.$value as String,
            args[1]!.$value as int,
            args[2]!.$value as String,
            args[3]!.$value as String?,
          ),
        );
      })
      ..registerBridgeFunc(_library, 'releaseCapabilityProvider', (_, _, args) {
        return $bool(release(args[0]!.$value as String));
      })
      ..registerBridgeFunc(_library, 'requestCapability', (_, _, args) {
        return _transport(args[0]!.$value as String).evalRequest(runtime, args);
      })
      ..registerBridgeFunc(_library, 'streamCapability', (_, _, args) {
        return _transport(args[0]!.$value as String).evalStream(runtime, args);
      })
      ..registerBridgeFunc(_library, 'settleCapabilityOperation', (_, _, args) {
        return BackendInvocationBridge.settleOperation(runtime, args);
      });
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
  }
}

final class _CapabilityAccess {
  _CapabilityAccess(this.transport, this.detach);
  final BackendInvocationBridge transport;
  final void Function() detach;

  void close() {
    detach();
    transport.invalidate();
  }
}
