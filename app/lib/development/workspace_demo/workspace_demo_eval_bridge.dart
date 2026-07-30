import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

final class WorkspaceDemoEvalBridge implements EvalPlugin {
  WorkspaceDemoEvalBridge({
    required WorkspaceDemoService service,
    required ResourceRef developmentRoot,
  }) : _service = service,
       _developmentRoot = developmentRoot;

  static const String library =
      'package:workspace_demo_frontend/src/adele_eval_bridge.dart';

  final WorkspaceDemoService _service;
  final ResourceRef _developmentRoot;
  bool _active = true;

  void invalidate() => _active = false;

  @override
  String get identifier => 'package:workspace_demo_frontend';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeClass(_WorkspaceDemoViewData.$declaration);
    registry.defineBridgeClass(_WorkspaceDemoTextData.$declaration);
    registry
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          library,
          'loadWorkspaceDemoDirectory',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
          ),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          library,
          'loadWorkspaceDemoText',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
            params: <BridgeParameter>[
              BridgeParameter(
                'uri',
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
      ..registerBridgeFunc(
        library,
        'WorkspaceDemoTextData.',
        _WorkspaceDemoTextData.construct,
      )
      ..registerBridgeFunc(
        library,
        'loadWorkspaceDemoDirectory',
        _loadDirectory,
      )
      ..registerBridgeFunc(library, 'loadWorkspaceDemoText', _loadText);
  }

  $Value? _loadDirectory(
    Runtime runtime,
    $Value? target,
    List<$Value?> arguments,
  ) {
    return $Future<$Value?>.wrap(
      _guard(() async {
        final DirectoryListing listing = await _service.listDirectory(
          _developmentRoot,
        );
        final List<DirectoryEntry> files = listing.entries
            .where(
              (DirectoryEntry entry) => entry.kind == DirectoryEntryKind.file,
            )
            .toList(growable: false);
        return _WorkspaceDemoViewData(
          names: files.map((DirectoryEntry entry) => entry.name).toList(),
          uris: files
              .map((DirectoryEntry entry) => entry.resource.uri.toString())
              .toList(),
        );
      }),
    );
  }

  $Value? _loadText(Runtime runtime, $Value? target, List<$Value?> arguments) {
    return $Future<$Value?>.wrap(
      _guard(() async {
        final String uri = arguments.single!.$value as String;
        final TextFileContents contents = await _service.readTextFile(
          ResourceRef(uri: Uri.parse(uri)),
        );
        return _WorkspaceDemoTextData(contents.text);
      }),
    );
  }

  Future<$Value?> _guard(Future<$Value?> Function() operation) async {
    if (!_active) throw StateError('The workspace demo bridge is inactive.');
    final $Value? value = await operation();
    if (!_active) throw StateError('The workspace demo bridge is inactive.');
    return value;
  }
}

final class _WorkspaceDemoTextData implements $Instance {
  const _WorkspaceDemoTextData(this.value);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(WorkspaceDemoEvalBridge.library, 'WorkspaceDemoTextData'),
  );

  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: <String, BridgeConstructorDef>{
      '': BridgeConstructorDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation($type),
          params: <BridgeParameter>[
            BridgeParameter(
              'value',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
          ],
        ),
      ),
    },
    getters: <String, BridgeMethodDef>{
      'value': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
    },
    wrap: true,
  );

  final String value;

  static $Value? construct(
    Runtime runtime,
    $Value? target,
    List<$Value?> arguments,
  ) => _WorkspaceDemoTextData(arguments.single!.$value as String);

  @override
  Object get $reified => this;

  @override
  Object get $value => this;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) {
    if (identifier == 'value') return $String(value);
    throw UnimplementedError(identifier);
  }

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);

  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('WorkspaceDemoTextData is immutable.');
  }
}

final class _WorkspaceDemoViewData implements $Instance {
  _WorkspaceDemoViewData({required this.names, required this.uris});

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(WorkspaceDemoEvalBridge.library, 'WorkspaceDemoViewData'),
  );

  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: <String, BridgeConstructorDef>{},
    getters: <String, BridgeMethodDef>{
      'names': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.list)),
        ),
      ),
      'uris': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.list)),
        ),
      ),
    },
    wrap: true,
  );

  final List<String> names;
  final List<String> uris;

  @override
  Object get $reified => this;

  @override
  Object get $value => this;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) {
    return switch (identifier) {
      'names' => $List.wrap(names.map<$Value>(($String.new)).toList()),
      'uris' => $List.wrap(uris.map<$Value>(($String.new)).toList()),
      _ => throw UnimplementedError(identifier),
    };
  }

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);

  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('WorkspaceDemoViewData is immutable.');
  }
}
