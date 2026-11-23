import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
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
    const observation = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.list, [structuredBridgeMapType]),
      nullable: true,
    );
    const handle = [BridgeParameter('handle', string, false)];
    const invocation = [
      BridgeParameter('handle', string, false),
      BridgeParameter('method', string, false),
      BridgeParameter('payload', structuredBridgeMapType, false),
    ];
    for (final (name, returns, parameters) in [
      ('discoverCapabilityProviders', observation, key),
      (
        'observeAssociatedProviders',
        observation,
        const [
          ...key,
          BridgeParameter('serviceId', string, false),
          BridgeParameter('associatedCapabilityId', string, false),
          BridgeParameter(
            'associatedMajorVersion',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)),
            false,
          ),
          BridgeParameter('associatedServiceId', string, false),
          BridgeParameter(
            'capture',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
            false,
          ),
        ],
      ),
      (
        'isCapabilityProviderCurrent',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        handle,
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
        handle,
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
          BridgeParameter('declaredFailureType', nullableString, true),
          BridgeParameter('failureCode', nullableString, true),
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
    Iterable<PreparedAssociatedCapabilityAccess> associatedAccess = const [],
    InstalledBackendActivation? Function(ProviderBinding)? backendForProvider,
  }) : _registry = registry,
       _capabilities = Set.unmodifiable(capabilities),
       _associatedAccess = List.unmodifiable(associatedAccess),
       _backendForProvider = backendForProvider,
       _isActive = isActive;

  static const maxHandles = 64;
  static const maxAssociatedPending = 8;
  static const maxObservedProviders = 1024;
  static const maxMetadataLength = 1024;
  final CapabilityRegistry? _registry;
  final Set<CapabilityKey> _capabilities;
  final List<PreparedAssociatedCapabilityAccess> _associatedAccess;
  final InstalledBackendActivation? Function(ProviderBinding)?
  _backendForProvider;
  final bool Function() _isActive;
  final Map<String, _CapabilityAccess> _handles = {};
  final String _scope = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  int _nextHandle = 0;
  int _associatedPending = 0;
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
      _handles[handle] = _CapabilityAccess(transport, detach, () {
        binding.endpointAs<CapabilityEndpoint>();
      });
      return handle;
    } on Object {
      return null;
    }
  }

  List<Map<String, Object?>>? observeAssociatedProviders(
    String capabilityId,
    int majorVersion,
    String serviceId,
    String associatedCapabilityId,
    int associatedMajorVersion,
    String associatedServiceId,
    bool capture,
  ) {
    try {
      _validate();
      final grant = _associatedAccess
          .where(
            (grant) =>
                grant.capability.id.value == capabilityId &&
                grant.capability.majorVersion == majorVersion &&
                grant.serviceId == serviceId &&
                grant.associatedCapability.id.value == associatedCapabilityId &&
                grant.associatedCapability.majorVersion ==
                    associatedMajorVersion &&
                grant.associatedServiceId == associatedServiceId,
          )
          .firstOrNull;
      final registry = _registry;
      if (registry == null || grant == null) return null;
      final providers = registry
          .providersFor(grant.capability)
          .where(
            (p) =>
                p.serviceId == grant.serviceId &&
                p.id.value.length <= maxMetadataLength,
          )
          .take(maxObservedProviders + 1)
          .toList();
      // Do not publish a truncated observation as the complete provider set.
      if (providers.length > maxObservedProviders) return null;
      return [
        for (final provider in providers)
          {
            'providerId': provider.id.value,
            'displayName': provider.displayName.length <= maxMetadataLength
                ? provider.displayName
                : provider.id.value,
            if (capture) ..._captureAssociated(registry, grant, provider),
          },
      ];
    } on Object {
      return null;
    }
  }

  Map<String, Object?> _captureAssociated(
    CapabilityRegistry registry,
    PreparedAssociatedCapabilityAccess grant,
    ProviderDescriptor provider,
  ) {
    try {
      final observed = registry.resolveExact(grant.capability, provider.id);
      if (!identical(observed.provider, provider)) {
        return const {'status': 'stale'};
      }
      final owner = _backendForProvider?.call(observed);
      if (owner == null) return const {'status': 'missing'};
      List<ProviderBinding> matches() {
        owner.validateProviderOwnership(observed);
        final matches = <ProviderBinding>[];
        for (final candidate in registry.providersFor(
          grant.associatedCapability,
        )) {
          if (candidate.serviceId != grant.associatedServiceId) continue;
          try {
            final binding = registry.resolveExact(
              grant.associatedCapability,
              candidate.id,
            );
            if (owner.associationFor(binding)?.isSameRegistration(observed) ==
                true) {
              matches.add(binding);
              if (matches.length == 2) break;
            }
          } on ProviderUnavailable {
            // A sibling can outlive its own retired target.
            continue;
          } on ProviderEndpointUnavailable {
            continue;
          }
        }
        return matches;
      }

      final eligible = matches();
      if (eligible.isEmpty) return const {'status': 'missing'};
      if (eligible.length > 1) return const {'status': 'ambiguous'};
      final binding = eligible.single;
      final channel = binding.requestChannel;
      _validate();
      if (_handles.length >= maxHandles) return const {'status': 'limit'};
      final handle = '$_scope:${_nextHandle++}';
      var retired = false;
      void validate() {
        _validate();
        if (!retired) {
          try {
            final current = matches();
            if (current.length == 1 &&
                current.single.isSameRegistration(binding) &&
                owner.associationFor(binding)?.isSameRegistration(observed) ==
                    true &&
                !retired &&
                isActive) {
              return;
            }
          } on Object {
            // Neither loss of exact ownership nor ambiguity may heal this handle.
          }
          retired = true;
        }
        throw StateError('Associated Capability access is no longer current.');
      }

      final guarded = _AssociatedRequestChannel((method, payload) async {
        adeleValidateServiceId(method);
        if (!method.startsWith('${grant.associatedServiceId}.')) {
          throw StateError('Method outside the captured service.');
        }
        // Payload copying precedes this admission. Released handles do not free
        // pending slots: independently owned backend work can still be running.
        validate();
        if (_associatedPending >= maxAssociatedPending) {
          throw StateError('Associated Capability request capacity exceeded.');
        }
        _associatedPending++;
        try {
          return await channel.request(method, payload);
        } on AdeleRemoteFailure catch (error) {
          validate();
          final type = error.declaredFailureType;
          if (type != null &&
              type.length <= maxMetadataLength &&
              error.code.length <= maxMetadataLength) {
            throw _AssociatedFailure(handle, type, error.code);
          }
          throw StateError('Associated Capability request failed.');
        } on Object {
          throw StateError('Associated Capability request failed.');
        } finally {
          _associatedPending--;
        }
      });
      final transport = BackendInvocationBridge(
        channelFor: (route) => route == handle ? guarded : null,
        validateAdmission: validate,
        validateSettlement: validate,
        isPresentationActive: () => isActive,
      );
      // Registrations and their association targets are immutable. The runtime
      // publishes association-closed groups, so no new callable can join the
      // old anchor between async change notifications. Latch observed failures
      // rather than allowing later uniqueness to revive a capture.
      final changes = registry.changes.listen((_) {
        if (retired) return;
        try {
          validate();
        } on Object {
          retired = true;
        }
      });
      _handles[handle] = _CapabilityAccess(transport, () {
        retired = true;
        unawaited(changes.cancel());
      }, validate);
      return {'status': 'ready', 'handle': handle};
    } on Object {
      return const {'status': 'stale'};
    }
  }

  bool isCapabilityProviderCurrent(String handle) {
    try {
      _validate();
      final access = _handles[handle];
      if (access == null) return false;
      access.validate();
      return true;
    } on Object {
      return false;
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
      ..registerBridgeFunc(_library, 'observeAssociatedProviders', (
        _,
        _,
        args,
      ) {
        return wrapStructuredBridgeData(
          observeAssociatedProviders(
            args[0]!.$value as String,
            args[1]!.$value as int,
            args[2]!.$value as String,
            args[3]!.$value as String,
            args[4]!.$value as int,
            args[5]!.$value as String,
            args[6]!.$value as bool,
          ),
        );
      })
      ..registerBridgeFunc(_library, 'isCapabilityProviderCurrent', (
        _,
        _,
        args,
      ) {
        return $bool(isCapabilityProviderCurrent(args[0]!.$value as String));
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
        final type = args.length > 1 ? args[1]?.$value : null;
        final code = args.length > 2 ? args[2]?.$value : null;
        return BackendInvocationBridge.settleOperation(
          runtime,
          args,
          matchFailureCode: (error) =>
              error is _AssociatedFailure &&
                  type is String &&
                  code is String &&
                  type == error._type &&
                  code == error._code &&
                  isCapabilityProviderCurrent(error._handle)
              ? code
              : null,
        );
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
  _CapabilityAccess(this.transport, this.detach, this.validate);
  final BackendInvocationBridge transport;
  final void Function() detach;
  final void Function() validate;

  void close() {
    detach();
    transport.invalidate();
  }
}

/// Deliberately request-only, even if the captured backend also streams.
final class _AssociatedRequestChannel implements AdeleRequestChannel {
  const _AssociatedRequestChannel(this.invoke);
  final Future<Object?> Function(String, Map<String, Object?>) invoke;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      invoke(method, payload);
}

final class _AssociatedFailure implements Exception {
  const _AssociatedFailure(this._handle, this._type, this._code);
  final String _handle;
  final String _type;
  final String _code;
}
