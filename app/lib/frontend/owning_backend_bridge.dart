import 'package:adele_contract/adele_contract.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'backend_invocation_bridge.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _bridgeLibrary = 'package:adele_ui/owning_backend_bridge.dart';

/// Build-time ABI only. The public channel is compiled from its Dart source.
class OwningBackendDeclarations implements EvalPlugin {
  const OwningBackendDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'settleOwningBackendOperation',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.list, [
                  BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
                ]),
              ),
            ]),
          ),
          params: [
            BridgeParameter(
              'operation',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
              false,
            ),
          ],
        ),
      ),
    );
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'streamOwningBackend',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.stream, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.object),
                nullable: true,
              ),
            ]),
          ),
          params: [
            BridgeParameter(
              'serviceId',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter(
              'method',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter('payload', structuredBridgeMapType, false),
          ],
        ),
      ),
    );
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'requestOwningBackend',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.object),
                nullable: true,
              ),
            ]),
          ),
          params: [
            BridgeParameter(
              'serviceId',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter(
              'method',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter('payload', structuredBridgeMapType, false),
          ],
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a presentation-scoped OwningBackendBridge.');
}

/// Channels and their origin are captured once by the native composition owner.
/// Neither plugin payloads nor replacement generations can select another route.
final class OwningBackendBridge extends OwningBackendDeclarations
    implements PreparedFrontendBridge {
  OwningBackendBridge({
    required Map<String, AdeleRequestChannel> channels,
    required void Function() validateBinding,
  }) : this._(Map.unmodifiable(channels), null, validateBinding);

  OwningBackendBridge.channel(
    OwningBackendChannel channel, {
    required void Function() validateBinding,
  }) : this._(const {}, channel, validateBinding);

  OwningBackendBridge._(
    Map<String, AdeleRequestChannel> channels,
    this._channel,
    this._validateBinding,
  ) {
    _invocations = BackendInvocationBridge(
      channelFor: (route) => _channel == null
          ? channels[route]
          : _OwningBackendRoute(_channel, route),
      validateAdmission: _validate,
      validateSettlement: _validate,
      isPresentationActive: () => _presentationActive,
    );
  }

  final OwningBackendChannel? _channel;
  final void Function() _validateBinding;
  late final BackendInvocationBridge _invocations;
  bool _active = true;

  void _validate() {
    if (!_active) throw StateError('The owning backend bridge is retired.');
    _validateBinding();
    _channel?.validate();
  }

  Future<Object?> request(String serviceId, String method, Object? payload) =>
      _invocations.request(serviceId, method, payload);

  Stream<Object?> stream(String serviceId, String method, Object? payload) =>
      _invocations.stream(serviceId, method, payload);

  bool get _presentationActive {
    if (!_active) return false;
    try {
      _validateBinding();
      return true;
    } on Object {
      invalidate();
      return false;
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      _bridgeLibrary,
      'settleOwningBackendOperation',
      (_, _, args) => BackendInvocationBridge.settleOperation(runtime, args),
    );
    runtime.registerBridgeFunc(
      _bridgeLibrary,
      'streamOwningBackend',
      (_, _, args) => _invocations.evalStream(runtime, args),
    );
    runtime.registerBridgeFunc(
      _bridgeLibrary,
      'requestOwningBackend',
      (_, _, args) => _invocations.evalRequest(runtime, args),
    );
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _invocations.invalidate();
  }
}

/// Keep owning-backend validation and retirement in the captured owner channel.
final class _OwningBackendRoute implements AdeleStreamChannel {
  _OwningBackendRoute(this.channel, this.serviceId);

  final OwningBackendChannel channel;
  final String serviceId;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      channel.request(serviceId, method, payload);

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      channel.stream(serviceId, method, payload);
}
