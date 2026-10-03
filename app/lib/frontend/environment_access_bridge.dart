import 'dart:async';

import 'package:adele_environment/adele_environment.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'environment_text_files.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/environment_access_bridge.dart';

class EnvironmentAccessDeclarations implements EvalPlugin {
  const EnvironmentAccessDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const futureMap = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.future, [
        BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.map, [
            string,
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
          ]),
        ),
      ]),
    );
    const path = BridgeParameter('path', string, false);
    for (final (name, params) in [
      ('readEnvironmentTextFile', const [path]),
      (
        'replaceEnvironmentTextFile',
        const [
          path,
          BridgeParameter('text', string, false),
          BridgeParameter('expectedRevision', string, false),
        ],
      ),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(returns: futureMap, params: params),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a scoped EnvironmentAccessBridge.');
}

/// Fresh access for one finite operation over its host-captured Environment.
/// A null capture grants no file access and never materializes an Environment.
final class EnvironmentAccessBridge extends EnvironmentAccessDeclarations
    implements PreparedFrontendBridge {
  EnvironmentAccessBridge({required this.isActive, this.files});

  final bool Function() isActive;
  final CapturedEnvironmentTextFiles? files;
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _configured = false;

  bool get _available {
    if (!_active) return false;
    try {
      if (isActive()) return true;
    } on Object {
      // Failed admission checks revoke this operation, not its capture.
    }
    invalidate();
    return false;
  }

  static const _unacknowledged = {
    'ok': false,
    'failure': {
      'code': 'operation_unacknowledged',
      'message': 'The Environment operation was not acknowledged.',
      'details': <String, Object?>{},
    },
  };

  $Future<$Value> _file(
    Future<Map<String, Object?>> Function(CapturedEnvironmentTextFiles) action,
  ) {
    final completion = Completer<$Value>();
    // Native Future rejections do not reliably unwind through the pinned eval.
    _nativeZone.run(() async {
      Map<String, Object?> result;
      try {
        final access = files;
        if (!_available || access == null) {
          throw const AuthorizedEnvironmentBindingUnavailable(
            'Environment file access is unavailable.',
          );
        }
        // Admission precedes dispatch; a received acknowledgement is not revoked
        // by later navigation. Binding validation belongs to the exact capture.
        result = await action(access);
      } on EnvironmentFailure catch (failure) {
        result = {
          'ok': false,
          'failure': {
            'code': failure.code,
            'message': failure.message,
            'details': failure.details,
          },
        };
      } on AuthorizedEnvironmentBindingException catch (failure) {
        result = {
          'ok': false,
          'failure': {
            'code': failure is AuthorizedEnvironmentBindingStale
                ? 'binding_stale'
                : 'binding_unavailable',
            'message': failure.message,
            'details': <String, Object?>{},
          },
        };
      } on Object {
        result = _unacknowledged;
      }
      try {
        completion.complete(wrapStructuredBridgeData(result));
      } on Object {
        completion.complete(wrapStructuredBridgeData(_unacknowledged));
      }
    });
    return $Future<$Value>.wrap(completion.future);
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Environment access is already bound.');
    _configured = true;
    String string(List<$Value?> args, int index) =>
        args[index]!.$value as String;
    runtime
      ..registerBridgeFunc(_library, 'readEnvironmentTextFile', (_, _, args) {
        return _file((access) async {
          final file = await access.read(string(args, 0));
          return {
            'ok': true,
            'path': file.relativePath,
            'text': file.text,
            'sizeBytes': file.sizeBytes,
            'revision': file.revision,
          };
        });
      })
      ..registerBridgeFunc(_library, 'replaceEnvironmentTextFile', (
        _,
        _,
        args,
      ) {
        return _file((access) async {
          final result = await access.replace(
            string(args, 0),
            string(args, 1),
            string(args, 2),
          );
          return {'ok': true, 'revision': result.revision};
        });
      });
  }

  @override
  void invalidate() => _active = false;
}
