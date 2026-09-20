import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

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
  }) : _channels = Map.unmodifiable(channels),
       _validateBinding = validateBinding,
       _channel = null;

  OwningBackendBridge.channel(
    OwningBackendChannel channel, {
    required void Function() validateBinding,
  }) : _channel = channel,
       _channels = const {},
       _validateBinding = validateBinding;

  final Map<String, AdeleRequestChannel> _channels;
  final OwningBackendChannel? _channel;
  final void Function() _validateBinding;
  final Zone _nativeZone = Zone.current;
  bool _active = true;

  void _validate() {
    if (!_active) throw StateError('The owning backend bridge is retired.');
    _validateBinding();
    _channel?.validate();
  }

  Future<Object?> request(
    String serviceId,
    String method,
    Object? payload,
  ) async {
    _validate();
    final channel = _channels[serviceId];
    if (channel == null && _channel == null) {
      throw StateError('Backend service is not allowlisted.');
    }
    if (method.isEmpty) throw const FormatException('Backend method is empty.');
    final copied = copyStructuredBridgeData(payload);
    if (copied is! Map<String, Object?>) {
      throw const FormatException('Backend request payload must be a map.');
    }
    final result =
        await (_channel?.request(serviceId, method, copied) ??
            channel!.request(method, copied));
    _validate();
    return copyStructuredBridgeData(result);
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_bridgeLibrary, 'requestOwningBackend', (
      _,
      _,
      args,
    ) {
      final completion = Completer<$Value>();
      _nativeZone.run(() {
        request(
          args[0]!.$value as String,
          args[1]!.$value as String,
          args[2],
        ).then(
          (value) => completion.complete(wrapStructuredBridgeData(value)),
          onError: completion.completeError,
        );
      });
      completion.future.ignore();
      return $Future<$Value>.wrap(completion.future);
    });
  }

  @override
  void invalidate() => _active = false;
}
