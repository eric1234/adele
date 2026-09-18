import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:file_selector/file_selector.dart' as file_selector;

import 'prepared_frontend.dart';

const _bridgeLibrary = 'package:adele_ui/directory_picker_bridge.dart';

/// Compile-time declarations carry no native picker authority.
class DirectoryPickerDeclarations implements EvalPlugin {
  const DirectoryPickerDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'pickDirectory',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.string),
                nullable: true,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    throw UnsupportedError('Use an operation-scoped DirectoryPickerBridge.');
  }
}

/// Exactly one native selection attempt, owned by one exact frontend operation.
final class DirectoryPickerBridge extends DirectoryPickerDeclarations
    implements PreparedFrontendBridge {
  DirectoryPickerBridge({required bool Function() isActive})
    : _isActive = isActive;

  final bool Function() _isActive;
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _used = false;
  (Object, StackTrace)? _failure;

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_bridgeLibrary, 'pickDirectory', (_, _, _) {
      // Native futures belong to the host zone. Relay their outcome into this
      // eval operation's error zone, where detached derived futures are owned.
      final completion = Completer<$Value>();
      _nativeZone.run(() {
        _pickDirectory().then(
          completion.complete,
          onError: completion.completeError,
        );
      });
      final result = completion.future;
      // Discarding the returned Future must not leak an unhandled native
      // error after settlement. Awaiting it still observes the same failure.
      result.ignore();
      return $Future<$Value>.wrap(result);
    });
  }

  /// Validate even if interpreted code catches a native or single-use failure.
  void validateResult() {
    if (!_active || !_isActive()) {
      throw StateError('The directory selection operation is retired.');
    }
    if (_failure case final failure?) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
  }

  Future<$Value> _pickDirectory() async {
    try {
      validateResult();
      if (_used) {
        throw StateError(
          'Only one directory picker call is allowed per operation.',
        );
      }
      _used = true;
      final path = await file_selector.getDirectoryPath();
      validateResult();
      return path == null ? const $null() : $String(path);
    } on Object catch (error, stack) {
      _failure ??= (error, stack);
      rethrow;
    }
  }

  @override
  void invalidate() => _active = false;
}
