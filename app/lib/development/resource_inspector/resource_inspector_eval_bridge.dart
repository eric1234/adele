import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

final class ResourceInspectorEvalBridge implements EvalPlugin {
  ResourceInspectorEvalBridge({required CapabilityRegistry registry})
    : _registry = registry;

  static const String library =
      'package:resource_inspector_consumer/src/adele_eval_bridge.dart';

  final CapabilityRegistry _registry;
  final Map<String, ProviderBinding> _bindings = <String, ProviderBinding>{};
  bool _active = true;
  int _nextToken = 1;

  void invalidate() {
    _active = false;
    _bindings.clear();
  }

  Future<List<({String id, String displayName})>> providersForTest() async =>
      _providerValues();

  Future<({String token, String providerId})> resolveForTest([
    String? providerId,
  ]) => _resolveValue(providerId);

  Future<({String providerLabel, String summary, bool cancelled})>
  inspectForTest(String token, String resourceUri) =>
      _inspectValue(token, resourceUri);

  @override
  String get identifier => 'package:resource_inspector_consumer';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry
      ..defineBridgeClass(_CapabilityProviderData.$declaration)
      ..defineBridgeClass(_ResolvedInspectorData.$declaration)
      ..defineBridgeClass(_InspectionData.$declaration)
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          library,
          'resourceInspectorProviders',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
          ),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          library,
          'resolveResourceInspector',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
            params: <BridgeParameter>[
              BridgeParameter(
                'providerId',
                BridgeTypeAnnotation(
                  BridgeTypeRef(CoreTypes.string),
                  nullable: true,
                ),
                true,
              ),
            ],
          ),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          library,
          'inspectResource',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
            params: <BridgeParameter>[
              BridgeParameter(
                'token',
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
                false,
              ),
              BridgeParameter(
                'resourceUri',
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
                false,
              ),
            ],
          ),
        ),
      );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(library, 'resourceInspectorProviders', _providers)
      ..registerBridgeFunc(library, 'resolveResourceInspector', _resolve)
      ..registerBridgeFunc(library, 'inspectResource', _inspect);
  }

  $Value? _providers(
    Runtime runtime,
    $Value? target,
    List<$Value?> arguments,
  ) => $Future<$Value?>.wrap(
    _providerValues().then(
      (List<({String id, String displayName})> providers) => $List.wrap(
        providers
            .map<$Value>(
              (({String id, String displayName}) provider) =>
                  _CapabilityProviderData(provider.id, provider.displayName),
            )
            .toList(),
      ),
    ),
  );

  $Value? _resolve(Runtime runtime, $Value? target, List<$Value?> arguments) =>
      $Future<$Value?>.wrap(
        _resolveValue(
          arguments.isEmpty ? null : arguments.single?.$value as String?,
        ).then(
          (({String token, String providerId}) value) =>
              _ResolvedInspectorData(value.token, value.providerId),
        ),
      );

  $Value? _inspect(Runtime runtime, $Value? target, List<$Value?> arguments) =>
      $Future<$Value?>.wrap(
        _inspectValue(
          arguments[0]!.$value as String,
          arguments[1]!.$value as String,
        ).then(
          (({String providerLabel, String summary, bool cancelled}) value) =>
              _InspectionData(
                value.providerLabel,
                value.summary,
                value.cancelled,
              ),
        ),
      );

  Future<List<({String id, String displayName})>> _providerValues() async {
    if (!_active) return const <({String id, String displayName})>[];
    return _registry
        .providersFor(resourceInspectCapability)
        .map(
          (ProviderDescriptor provider) =>
              (id: provider.id.value, displayName: provider.displayName),
        )
        .toList(growable: false);
  }

  Future<({String token, String providerId})> _resolveValue(
    String? providerId,
  ) async {
    if (!_active) throw CapabilityUnavailable(resourceInspectCapability);
    final ProviderBinding binding = _registry.resolve(
      resourceInspectCapability,
      providerId: providerId == null ? null : ProviderId(providerId),
    );
    final String token = 'binding-${_nextToken++}';
    _bindings[token] = binding;
    return (token: token, providerId: binding.provider.id.value);
  }

  Future<({String providerLabel, String summary, bool cancelled})>
  _inspectValue(String token, String resourceUri) async {
    if (!_active) return (providerLabel: '', summary: '', cancelled: true);
    try {
      final ProviderBinding? binding = _bindings[token];
      if (binding == null) {
        throw ProviderUnavailable(
          capability: resourceInspectCapability,
          providerId: token,
          availableProviderIds: _registry
              .providersFor(resourceInspectCapability)
              .map((ProviderDescriptor provider) => provider.id),
        );
      }
      final ResourceInspection result = await ResourceInspectorServiceClient(
        binding.requestChannel,
      ).inspect(ResourceRef(uri: Uri.parse(resourceUri)));
      if (!_active) return (providerLabel: '', summary: '', cancelled: true);
      return (
        providerLabel: result.providerLabel,
        summary: result.summary,
        cancelled: false,
      );
    } on Object catch (error, stackTrace) {
      if (!_active) return (providerLabel: '', summary: '', cancelled: true);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

abstract base class _BridgeValue implements $Instance {
  const _BridgeValue();

  @override
  Object get $reified => this;

  @override
  Object get $value => this;

  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('Bridge data is immutable.');
  }
}

final class _CapabilityProviderData extends _BridgeValue {
  const _CapabilityProviderData(this.id, this.displayName);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(
      ResourceInspectorEvalBridge.library,
      'CapabilityProviderData',
    ),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: <String, BridgeConstructorDef>{},
    getters: <String, BridgeMethodDef>{
      'id': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
      'displayName': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
    },
    wrap: true,
  );

  final String id;
  final String displayName;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'id' => $String(id),
        'displayName' => $String(displayName),
        _ => throw UnimplementedError(identifier),
      };

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);
}

final class _ResolvedInspectorData extends _BridgeValue {
  const _ResolvedInspectorData(this.token, this.providerId);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(
      ResourceInspectorEvalBridge.library,
      'ResolvedInspectorData',
    ),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: <String, BridgeConstructorDef>{},
    getters: <String, BridgeMethodDef>{
      'token': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
      'providerId': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
    },
    wrap: true,
  );

  final String token;
  final String providerId;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'token' => $String(token),
        'providerId' => $String(providerId),
        _ => throw UnimplementedError(identifier),
      };

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);
}

final class _InspectionData extends _BridgeValue {
  const _InspectionData(this.providerLabel, this.summary, this.cancelled);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(ResourceInspectorEvalBridge.library, 'InspectionData'),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: <String, BridgeConstructorDef>{},
    getters: <String, BridgeMethodDef>{
      'providerLabel': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
      'summary': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
      'cancelled': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        ),
      ),
    },
    wrap: true,
  );

  final String providerLabel;
  final String summary;
  final bool cancelled;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'providerLabel' => $String(providerLabel),
        'summary' => $String(summary),
        'cancelled' => $bool(cancelled),
        _ => throw UnimplementedError(identifier),
      };

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);
}
