import 'dart:async';

import 'package:adele_environment/adele_environment.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';

import '../editor/native_code_editor.dart';
import 'environment_text_files.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/contribution_bridge.dart';

/// Opaque storage and conventional native owners for one exact contribution.
/// No resource paths, revisions, dirty state, or Save policy are interpreted here.
final class RetainedContribution extends ChangeNotifier {
  final Map<String, Map<String, Object?>> _data = {};
  final Map<String, NativeCodeEditor> _editors = {};
  int _nextId = 0;
  bool _closed = false;

  bool get isActive => !_closed;
  List<String> get keys => List.unmodifiable(_data.keys);
  String allocateId() => 'item-${++_nextId}';
  Map<String, Object?> read(String key) => _data[key] ?? const {};

  void write(String key, Map<String, Object?> data) {
    if (_closed) throw StateError('Contribution owner is closed.');
    _data[key] = copyStructuredBridgeData(data) as Map<String, Object?>;
    notifyListeners();
  }

  void remove(String key) {
    if (_closed) throw StateError('Contribution owner is closed.');
    if (_data.remove(key) != null) notifyListeners();
  }

  NativeCodeEditor editor(String id) =>
      _editors[id] ?? (throw StateError('Unknown owned code editor.'));

  Future<bool> createEditor(String id, String text, String language) async {
    if (_closed || _editors.containsKey(id)) return false;
    final editor = NativeCodeEditor(text: text, language: language);
    _editors[id] = editor;
    try {
      await editor.initialize();
      if (_closed || !identical(_editors[id], editor)) return false;
      return true;
    } on Object {
      if (identical(_editors[id], editor)) _editors.remove(id);
      editor.dispose();
      rethrow;
    }
  }

  void releaseEditor(String id) => _editors.remove(id)?.dispose();

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    Object? failure;
    StackTrace? failureStack;
    for (final editor in _editors.values) {
      try {
        editor.dispose();
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    _editors.clear();
    _data.clear();
    super.dispose();
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}

class ContributionDeclarations implements EvalPlugin {
  const ContributionDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const boolean = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool));
    const voidType = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType));
    const strings = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.list, [string]),
    );
    const map = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.map, [
        string,
        BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
      ]),
    );
    const futureMap = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.future, [map]),
    );
    const futureBool = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.future, [boolean]),
    );
    const key = BridgeParameter('key', string, false);
    const id = BridgeParameter('id', string, false);
    const text = BridgeParameter('text', string, false);
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      ('readContributionKeys', strings, const <BridgeParameter>[]),
      ('readContributionData', map, const [key]),
      (
        'writeContributionData',
        boolean,
        const [key, BridgeParameter('data', map, false)],
      ),
      ('removeContributionData', boolean, const [key]),
      ('allocateContributionId', string, const <BridgeParameter>[]),
      ('readContributionContext', map, const <BridgeParameter>[]),
      (
        'invokeContributionOperation',
        futureMap,
        const [
          BridgeParameter('operation', string, false),
          BridgeParameter('arguments', map, false),
        ],
      ),
      ('subscribeContribution', voidType, const [listener]),
      ('unsubscribeContribution', voidType, const [listener]),
      (
        'createContributionCodeEditor',
        futureBool,
        const [id, text, BridgeParameter('language', string, false)],
      ),
      ('snapshotContributionCodeEditor', map, const [id]),
      ('readContributionCodeEditorState', map, const [id]),
      ('releaseContributionCodeEditor', boolean, const [id]),
      (
        'readEnvironmentTextFile',
        futureMap,
        const [BridgeParameter('path', string, false)],
      ),
      (
        'replaceEnvironmentTextFile',
        futureMap,
        const [
          BridgeParameter('path', string, false),
          text,
          BridgeParameter('expectedRevision', string, false),
        ],
      ),
      (
        'confirmContributionDiscard',
        futureBool,
        const [BridgeParameter('message', string, false)],
      ),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(returns: returns, params: params),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a scoped ContributionBridge.');
}

/// A fresh view or finite operation over a retained native owner. A view can
/// admit an operation but cannot acquire filesystem access itself.
final class ContributionBridge extends ContributionDeclarations
    implements PreparedFrontendBridge {
  ContributionBridge({
    required this.owner,
    required this.isActive,
    required this.context,
    required this.retainedData,
    required this.nativeCodeEditor,
    this.files,
    this.invoke,
    this.confirmDiscard,
  });

  final RetainedContribution owner;
  final bool Function() isActive;
  final Map<String, Object?> context;
  final bool retainedData;
  final bool nativeCodeEditor;
  final CapturedEnvironmentTextFiles? files;
  final Future<Map<String, Object?>> Function(String, Map<String, Object?>)?
  invoke;
  final Future<bool> Function(String)? confirmDiscard;
  final Zone _nativeZone = Zone.current;
  final Set<EvalCallable> _listeners = Set.identity();
  Runtime? _runtime;
  bool _active = true;
  bool _listening = false;
  bool _scheduled = false;

  bool get available {
    if (!_active || !owner.isActive) return false;
    try {
      if (isActive()) return true;
    } on Object {
      // Failed liveness checks revoke this access, never its retained owner.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!available) throw StateError('Contribution access is retired.');
  }

  void _validateData() {
    _validate();
    if (!retainedData) throw StateError('Retained data was not granted.');
  }

  Map<String, Object?> _observeEditor(String id, {required bool snapshot}) {
    try {
      final editor = _editor(id);
      return snapshot ? editor.snapshot() : editor.readState();
    } on Object {
      return const {};
    }
  }

  NativeCodeEditor _editor(String id) {
    _validate();
    if (!nativeCodeEditor) {
      throw StateError('Native code editor was not granted.');
    }
    return owner.editor(id);
  }

  $Future<$Value> _future(
    Future<Object?> Function() action, {
    Object? unavailable = const {
      'ok': false,
      'failure': {
        'code': 'operation_unavailable',
        'message':
            'Contribution access is unavailable. The operation was not acknowledged.',
        'details': <String, Object?>{},
      },
    },
  }) {
    final completion = Completer<$Value>();
    _nativeZone.run(() {
      Future<Object?>.sync(() {
        if (!available) return unavailable;
        return action();
      }).then(
        (result) {
          try {
            completion.complete(wrapStructuredBridgeData(result));
          } on Object {
            completion.complete(wrapStructuredBridgeData(unavailable));
          }
        },
        onError: (Object _, StackTrace _) {
          completion.complete(wrapStructuredBridgeData(unavailable));
        },
      );
    });
    completion.future.ignore();
    return $Future<$Value>.wrap(completion.future);
  }

  Future<Map<String, Object?>> _file(
    Future<Map<String, Object?>> Function(CapturedEnvironmentTextFiles) action,
  ) async {
    try {
      _validate();
      final access = files;
      if (access == null) {
        throw const AuthorizedEnvironmentBindingUnavailable(
          'Environment file access is unavailable.',
        );
      }
      return await action(access);
    } on EnvironmentFailure catch (failure) {
      return {
        'ok': false,
        'failure': {
          'code': failure.code,
          'message': failure.message,
          'details': failure.details,
        },
      };
    } on AuthorizedEnvironmentBindingException catch (failure) {
      return {
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
      // An unacknowledged mutation must not be represented as a successful write
      // or automatically replayed. The plugin retains its local baseline.
      return {
        'ok': false,
        'failure': {
          'code': 'operation_unacknowledged',
          'message':
              'The Environment operation was not acknowledged. Local changes are retained; do not assume the file was unchanged.',
          'details': <String, Object?>{},
        },
      };
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_runtime != null) {
      throw StateError('Contribution bridge already bound.');
    }
    _runtime = runtime;
    String string(List<$Value?> args, int index) =>
        args[index]!.$value as String;
    runtime
      ..registerBridgeFunc(_library, 'readContributionKeys', (_, _, _) {
        _validateData();
        return wrapStructuredBridgeData(owner.keys);
      })
      ..registerBridgeFunc(_library, 'readContributionData', (_, _, args) {
        _validateData();
        return wrapStructuredBridgeData(owner.read(string(args, 0)));
      })
      ..registerBridgeFunc(_library, 'writeContributionData', (_, _, args) {
        _validateData();
        owner.write(
          string(args, 0),
          copyStructuredBridgeData(args[1]) as Map<String, Object?>,
        );
        return $bool(true);
      })
      ..registerBridgeFunc(_library, 'removeContributionData', (_, _, args) {
        _validateData();
        owner.remove(string(args, 0));
        return $bool(true);
      })
      ..registerBridgeFunc(_library, 'allocateContributionId', (_, _, _) {
        _validateData();
        return $String(owner.allocateId());
      })
      ..registerBridgeFunc(_library, 'readContributionContext', (_, _, _) {
        return wrapStructuredBridgeData(
          available ? context : const <String, Object?>{},
        );
      })
      ..registerBridgeFunc(_library, 'invokeContributionOperation', (
        _,
        _,
        args,
      ) {
        final operation = string(args, 0);
        final arguments =
            copyStructuredBridgeData(args[1]) as Map<String, Object?>;
        return _future(() async {
          final admitted = invoke;
          if (admitted == null) {
            return {
              'ok': false,
              'message': 'Contribution operation is unavailable.',
            };
          }
          try {
            return await admitted(operation, arguments);
          } on Object {
            return {
              'ok': false,
              'message':
                  'Contribution operation is unavailable. Retained content was not discarded.',
            };
          }
        });
      })
      ..registerBridgeFunc(_library, 'subscribeContribution', (_, _, args) {
        _validate();
        _listeners.add(args.single! as EvalCallable);
        if (!_listening) {
          owner.addListener(_changed);
          _listening = true;
        }
        return null;
      })
      ..registerBridgeFunc(_library, 'unsubscribeContribution', (_, _, args) {
        _listeners.remove(args.single! as EvalCallable);
        return null;
      })
      ..registerBridgeFunc(_library, 'createContributionCodeEditor', (
        _,
        _,
        args,
      ) {
        final id = string(args, 0);
        final text = string(args, 1);
        final language = string(args, 2);
        return _future(() async {
          if (!nativeCodeEditor) return false;
          try {
            return await owner.createEditor(id, text, language);
          } on Object {
            return false;
          }
        }, unavailable: false);
      })
      ..registerBridgeFunc(
        _library,
        'snapshotContributionCodeEditor',
        (_, _, args) => wrapStructuredBridgeData(
          _observeEditor(string(args, 0), snapshot: true),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'readContributionCodeEditorState',
        (_, _, args) => wrapStructuredBridgeData(
          _observeEditor(string(args, 0), snapshot: false),
        ),
      )
      ..registerBridgeFunc(_library, 'releaseContributionCodeEditor', (
        _,
        _,
        args,
      ) {
        final id = string(args, 0);
        _editor(id);
        owner.releaseEditor(id);
        return $bool(true);
      })
      ..registerBridgeFunc(_library, 'readEnvironmentTextFile', (_, _, args) {
        final path = string(args, 0);
        return _future(
          () => _file((access) async {
            final file = await access.read(path);
            return {
              'ok': true,
              'path': file.relativePath,
              'text': file.text,
              'sizeBytes': file.sizeBytes,
              'revision': file.revision,
            };
          }),
        );
      })
      ..registerBridgeFunc(_library, 'replaceEnvironmentTextFile', (
        _,
        _,
        args,
      ) {
        final path = string(args, 0);
        final text = string(args, 1);
        final revision = string(args, 2);
        return _future(
          () => _file((access) async {
            final result = await access.replace(path, text, revision);
            return {'ok': true, 'revision': result.revision};
          }),
        );
      })
      ..registerBridgeFunc(_library, 'confirmContributionDiscard', (
        _,
        _,
        args,
      ) {
        final message = string(args, 0);
        return _future(() async {
          try {
            return await confirmDiscard?.call(message) ?? false;
          } on Object {
            return false;
          }
        }, unavailable: false);
      });
  }

  void _changed() {
    if (!available || _scheduled || _listeners.isEmpty) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!available) return;
      for (final listener in _listeners.toList()) {
        if (!available) return;
        if (_listeners.contains(listener)) {
          try {
            listener.call(_runtime!, null, const []);
          } on Object {
            invalidate();
            return;
          }
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _listeners.clear();
    if (_listening) owner.removeListener(_changed);
    _listening = false;
  }
}
