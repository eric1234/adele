import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

final class ResourceInspectorEvalBridge implements EvalPlugin {
  ResourceInspectorEvalBridge({
    required CapabilityRegistry registry,
    required ResourceRef resource,
  }) : _registry = registry,
       _resource = resource;

  static const String library =
      'package:resource_inspector_consumer/src/adele_eval_bridge.dart';

  final CapabilityRegistry _registry;
  final ResourceRef _resource;
  bool _active = true;

  void invalidate() => _active = false;

  Future<List<String>> loadLinesForTest() async =>
      (await _loadData() as _CapabilityDemoData).lines;

  @override
  String get identifier => 'package:resource_inspector_consumer';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry
      ..defineBridgeClass(_CapabilityDemoData.$declaration)
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          library,
          'loadCapabilityDemo',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
          ),
        ),
      );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(library, 'loadCapabilityDemo', _load);
  }

  $Value? _load(Runtime runtime, $Value? target, List<$Value?> arguments) {
    return $Future<$Value?>.wrap(_loadData());
  }

  Future<$Value?> _loadData() async {
    if (!_active) return const _CapabilityDemoData(<String>[]);
    final List<ProviderDescriptor> providers = _registry.providersFor(
      resourceInspectCapability,
    );
    if (providers.isEmpty) {
      return const _CapabilityDemoData(<String>['Unavailable: no provider']);
    }
    final ProviderBinding defaultBinding = _registry.resolve(
      resourceInspectCapability,
    );
    final List<String> lines = <String>[
      for (final ProviderDescriptor provider in providers)
        'Provider: ${provider.id} | ${provider.displayName}',
      'Default: ${defaultBinding.provider.id}',
      'Default result: ${await _inspect(defaultBinding)}',
      for (final ProviderDescriptor provider in providers)
        'Explicit ${provider.id}: ${await _inspect(_registry.resolve(resourceInspectCapability, providerId: provider.id))}',
    ];
    return _active
        ? _CapabilityDemoData(lines)
        : const _CapabilityDemoData(<String>[]);
  }

  Future<String> _inspect(ProviderBinding binding) async {
    final ResourceInspection result = await ResourceInspectorServiceClient(
      binding.requestChannel,
    ).inspect(_resource);
    return '${result.providerLabel}: ${result.summary}';
  }
}

final class _CapabilityDemoData implements $Instance {
  const _CapabilityDemoData(this.lines);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(ResourceInspectorEvalBridge.library, 'CapabilityDemoData'),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: <String, BridgeConstructorDef>{},
    getters: <String, BridgeMethodDef>{
      'lines': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.list)),
        ),
      ),
    },
    wrap: true,
  );

  final List<String> lines;

  @override
  Object get $reified => this;

  @override
  Object get $value => this;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'lines' => $List.wrap(lines.map<$Value>(($String.new)).toList()),
        _ => throw UnimplementedError(identifier),
      };

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);

  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('CapabilityDemoData is immutable.');
  }
}
