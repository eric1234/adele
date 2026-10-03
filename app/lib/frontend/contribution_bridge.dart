import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';

import '../editor/native_code_editor.dart';
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
    const nullableMap = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.map, [
        string,
        BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
      ]),
      nullable: true,
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
      ('readContributionArguments', nullableMap, const <BridgeParameter>[]),
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
        'confirmContribution',
        futureBool,
        const [BridgeParameter('request', map, false)],
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
    this.arguments = const {},
    required this.retainedData,
    required this.nativeCodeEditor,
    this.invoke,
    this.confirm,
  });

  final RetainedContribution owner;
  final bool Function() isActive;
  final Map<String, Object?> arguments;
  final bool retainedData;
  final bool nativeCodeEditor;
  final Future<Map<String, Object?>> Function(String, Map<String, Object?>)?
  invoke;
  final Future<bool> Function(Map<String, Object?> request)? confirm;
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
      ..registerBridgeFunc(_library, 'readContributionArguments', (_, _, _) {
        return wrapStructuredBridgeData(available ? arguments : null);
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
              'message': 'Contribution operation is unavailable.',
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
      ..registerBridgeFunc(_library, 'confirmContribution', (_, _, args) {
        Map<String, Object?> request;
        try {
          request =
              copyStructuredBridgeData(args.single) as Map<String, Object?>;
          const fields = ['title', 'message', 'acceptLabel', 'cancelLabel'];
          if (request.length != fields.length ||
              fields.any(
                (field) =>
                    request[field] is! String ||
                    (request[field]! as String).trim().isEmpty,
              )) {
            return _future(() async => false, unavailable: false);
          }
        } on Object {
          return _future(() async => false, unavailable: false);
        }
        return _future(() async {
          try {
            final accepted = await confirm?.call(request) ?? false;
            return available && accepted;
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
